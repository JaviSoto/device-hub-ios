import Darwin
import Foundation

extension BonjourBrowserClient {
    @MainActor
    static func foundation() -> Self {
        let owner = FoundationBonjourBrowserOwner()
        return Self(
            start: { handler async throws(BonjourNativeFailure) in
                do {
                    try await owner.start(handler: handler)
                } catch let failure as BonjourNativeFailure {
                    throw failure
                } catch {
                    throw BonjourNativeFailure(
                        operation: .browseStart,
                        code: FoundationBonjourErrorCode.unknown
                    )
                }
            },
            stop: {
                await owner.stop()
            }
        )
    }
}

extension BonjourPublisherClient {
    @MainActor
    static func foundation() -> Self {
        let owner = FoundationBonjourPublisherOwner()
        return Self(
            start: { advertisement, handler async throws(BonjourNativeFailure) in
                do {
                    try await owner.start(
                        advertisement: advertisement,
                        handler: handler
                    )
                } catch let failure as BonjourNativeFailure {
                    throw failure
                } catch {
                    throw BonjourNativeFailure(
                        operation: .publishStart,
                        code: FoundationBonjourErrorCode.unknown
                    )
                }
            },
            stop: {
                await owner.stop()
            }
        )
    }
}

/// Main-actor shell retaining the non-Sendable Foundation delegate graph.
@MainActor
private final class FoundationBonjourBrowserOwner {
    private let bridge = FoundationBonjourBrowserDelegateBridge()

    func start(
        handler: @escaping @Sendable (BonjourBrowserEvent) -> Void
    ) throws(BonjourNativeFailure) {
        try bridge.start(handler: handler)
    }

    func stop() {
        bridge.stop()
    }
}

/// Run-loop-confined delegate bridge for `NetServiceBrowser` and `NetService`.
///
/// The bridge is deliberately not `Sendable` and never leaves its main-actor
/// owner. Foundation delivers callbacks on the run loop where browsing starts,
/// so delegate mutation remains confined to that owner. Only copied,
/// value-semantic snapshots cross into the transport actor.
private final class FoundationBonjourBrowserDelegateBridge:
    NSObject,
    NetServiceBrowserDelegate,
    NetServiceDelegate
{
    private var browser: NetServiceBrowser?
    private var handler: (@Sendable (BonjourBrowserEvent) -> Void)?
    private var services: [ObjectIdentifier: NetService] = [:]

    func start(
        handler: @escaping @Sendable (BonjourBrowserEvent) -> Void
    ) throws(BonjourNativeFailure) {
        guard browser == nil else {
            throw BonjourNativeFailure(
                operation: .browseStart,
                code: FoundationBonjourErrorCode.activityInProgress
            )
        }

        let browser = NetServiceBrowser()
        self.browser = browser
        self.handler = handler
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(
            ofType: ValidatedRemotePairingService.serviceType,
            inDomain: "local."
        )
    }

    func stop() {
        guard let browser else {
            return
        }
        self.browser = nil
        handler = nil
        browser.delegate = nil
        browser.stop()
        for service in services.values {
            service.delegate = nil
            service.stop()
        }
        services.removeAll()
    }

    func netServiceBrowser(
        _: NetServiceBrowser,
        didFind service: NetService,
        moreComing _: Bool
    ) {
        guard browser != nil else {
            return
        }
        services[ObjectIdentifier(service)] = service
        service.delegate = self
        service.includesPeerToPeer = true
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(
        _: NetServiceBrowser,
        didRemove service: NetService,
        moreComing _: Bool
    ) {
        guard browser != nil else {
            return
        }
        services.removeValue(forKey: ObjectIdentifier(service))
        service.delegate = nil
        service.stop()
        handler?(.removed(serviceName: service.name))
    }

    func netServiceBrowser(
        _: NetServiceBrowser,
        didNotSearch errorDictionary: [String: NSNumber]
    ) {
        guard browser != nil else {
            return
        }
        handler?(.failed(BonjourNativeFailure(
            operation: .browseRuntime,
            code: Self.errorCode(from: errorDictionary)
        )))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard
            browser != nil,
            services[ObjectIdentifier(sender)] != nil,
            let hostName = sender.hostName,
            let addresses = sender.addresses,
            !addresses.isEmpty,
            let txtRecord = sender.txtRecordData()
        else {
            handler?(.resolutionFailed(BonjourNativeFailure(
                operation: .resolve,
                code: FoundationBonjourErrorCode.notFound
            )))
            return
        }
        let resolvedEndpoints = addresses.compactMap(Self.endpoint(from:))
        guard !resolvedEndpoints.isEmpty else {
            handler?(.resolutionFailed(BonjourNativeFailure(
                operation: .resolve,
                code: FoundationBonjourErrorCode.notFound
            )))
            return
        }

        handler?(.resolved(BonjourResolvedServiceSnapshot(
            serviceName: sender.name,
            hostName: hostName,
            port: sender.port,
            resolvedEndpoints: resolvedEndpoints,
            txtRecord: Data(txtRecord)
        )))
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDictionary: [String: NSNumber]
    ) {
        guard
            browser != nil,
            services[ObjectIdentifier(sender)] != nil
        else {
            return
        }
        handler?(.resolutionFailed(BonjourNativeFailure(
            operation: .resolve,
            code: Self.errorCode(from: errorDictionary)
        )))
    }

    private static func errorCode(
        from dictionary: [String: NSNumber]
    ) -> Int {
        dictionary[NetService.errorCode]?.intValue
            ?? FoundationBonjourErrorCode.unknown
    }

    private static func endpoint(
        from data: Data
    ) -> NativeResolvedEndpoint? {
        guard data.count >= MemoryLayout<sockaddr>.size else {
            return nil
        }
        let family = data.withUnsafeBytes {
            $0.loadUnaligned(as: sockaddr.self).sa_family
        }

        do {
            switch Int32(family) {
            case AF_INET:
                guard data.count >= MemoryLayout<sockaddr_in>.size else {
                    return nil
                }
                let socketAddress = data.withUnsafeBytes {
                    $0.loadUnaligned(as: sockaddr_in.self)
                }
                let address = withUnsafeBytes(
                    of: socketAddress.sin_addr
                ) { Data($0) }
                return try NativeResolvedEndpoint(
                    family: .ipv4,
                    address: address,
                    scopeID: 0,
                    port: UInt16(bigEndian: socketAddress.sin_port)
                )

            case AF_INET6:
                guard data.count >= MemoryLayout<sockaddr_in6>.size else {
                    return nil
                }
                let socketAddress = data.withUnsafeBytes {
                    $0.loadUnaligned(as: sockaddr_in6.self)
                }
                let address = withUnsafeBytes(
                    of: socketAddress.sin6_addr
                ) { Data($0) }
                return try NativeResolvedEndpoint(
                    family: .ipv6,
                    address: address,
                    scopeID: socketAddress.sin6_scope_id,
                    port: UInt16(bigEndian: socketAddress.sin6_port)
                )

            default:
                return nil
            }
        } catch is NativeSessionContractError {
            return nil
        } catch {
            return nil
        }
    }
}

/// Main-actor shell retaining one non-Sendable publication delegate.
@MainActor
private final class FoundationBonjourPublisherOwner {
    private let bridge = FoundationBonjourPublisherDelegateBridge()

    func start(
        advertisement: PairableHostAdvertisement,
        handler: @escaping @Sendable (BonjourPublisherEvent) -> Void
    ) throws(BonjourNativeFailure) {
        try bridge.start(
            advertisement: advertisement,
            handler: handler
        )
    }

    func stop() {
        bridge.stop()
    }
}

/// Run-loop-confined delegate bridge for one existing Rust TCP listener.
///
/// `.listenForConnections` is intentionally absent: NetService advertises the
/// supplied port but never creates or owns the socket.
private final class FoundationBonjourPublisherDelegateBridge:
    NSObject,
    NetServiceDelegate
{
    private var handler: (@Sendable (BonjourPublisherEvent) -> Void)?
    private var service: NetService?

    func start(
        advertisement: PairableHostAdvertisement,
        handler: @escaping @Sendable (BonjourPublisherEvent) -> Void
    ) throws(BonjourNativeFailure) {
        guard service == nil else {
            throw BonjourNativeFailure(
                operation: .publishStart,
                code: FoundationBonjourErrorCode.activityInProgress
            )
        }

        let service = NetService(
            domain: "local.",
            type: advertisement.serviceType,
            name: advertisement.serviceName,
            port: Int32(advertisement.listenerPort)
        )
        guard service.setTXTRecord(advertisement.txtRecord) else {
            throw BonjourNativeFailure(
                operation: .publishStart,
                code: FoundationBonjourErrorCode.badArgument
            )
        }
        self.handler = handler
        self.service = service
        service.delegate = self
        service.includesPeerToPeer = true
        service.publish(options: .noAutoRename)
    }

    func stop() {
        guard let service else {
            return
        }
        self.service = nil
        handler = nil
        service.delegate = nil
        service.stop()
    }

    func netServiceDidPublish(_: NetService) {
        guard service != nil else {
            return
        }
        handler?(.published)
    }

    func netService(
        _: NetService,
        didNotPublish errorDictionary: [String: NSNumber]
    ) {
        guard service != nil else {
            return
        }
        handler?(.failed(BonjourNativeFailure(
            operation: .publishRuntime,
            code: errorDictionary[NetService.errorCode]?.intValue
                ?? FoundationBonjourErrorCode.unknown
        )))
    }
}

private enum FoundationBonjourErrorCode {
    static let activityInProgress = -72003
    static let badArgument = -72004
    static let notFound = -72002
    static let unknown = -72000
}
