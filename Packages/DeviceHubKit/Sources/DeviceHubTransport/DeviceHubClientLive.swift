import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubPersistence
import Foundation
import OSLog

private let candidateVerificationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "DeviceHub",
    category: "remote-pairing-candidate"
)

/// Fail-closed policy for the authenticated device identity accepted as the
/// remote viewing and control target.
public struct DeviceHubRemoteTargetPolicy: Equatable, Sendable {
    /// Accepts any target whose identity was verified by Pair Setup.
    public static let authenticatedDevices = Self(
        requiredDisplayName: nil
    )

    private let requiredDisplayName: String?

    /// Creates a policy that optionally restricts an authenticated peer to an
    /// exact display name.
    public init(requiredDisplayName: String? = nil) {
        self.requiredDisplayName = requiredDisplayName
    }

    /// Returns whether an authenticated target satisfies the configured
    /// shipping or test policy.
    public func permits(displayName: String) -> Bool {
        requiredDisplayName.map { displayName == $0 } ?? true
    }
}

/// Stable Pairable Host presentation supplied by the iOS app shell.
public struct DeviceHubTransportConfiguration: Equatable, Sendable {
    public let controllerDisplayName: String
    public let controllerModel: String
    public let remoteTargetPolicy: DeviceHubRemoteTargetPolicy
    public let requestedPairingPort: UInt16

    public init(
        controllerDisplayName: String,
        controllerModel: String,
        remoteTargetPolicy: DeviceHubRemoteTargetPolicy,
        requestedPairingPort: UInt16 = 0
    ) throws {
        try Self.requireText(
            controllerDisplayName,
            maximumUTF8Length: 256
        )
        try Self.requireText(
            controllerModel,
            maximumUTF8Length: 128
        )
        self.controllerDisplayName = controllerDisplayName
        self.controllerModel = controllerModel
        self.remoteTargetPolicy = remoteTargetPolicy
        self.requestedPairingPort = requestedPairingPort
    }

    private static func requireText(
        _ value: String,
        maximumUTF8Length: Int
    ) throws {
        let trimmedValue = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !trimmedValue.isEmpty,
            value == trimmedValue,
            value.utf8.count <= maximumUTF8Length,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw NativeSessionContractError.invalidText
        }
    }
}

extension DeviceHubClient {
    /// Builds the shipping client around Foundation Bonjour, Keychain
    /// persistence, structured diagnostics, and an artifact-backed adapter.
    @MainActor
    public static func live(
        nativeSessions: NativeSessionClient,
        configuration: DeviceHubTransportConfiguration,
        diagnostics: DiagnosticRecorder,
        requestDiagnosticsUpload:
        @escaping @Sendable () async -> Void = {},
        pairingPersistence: PairingPersistenceClient = .liveValue
    ) -> Self {
        let diagnosticsPipeline = DeviceHubTransportDiagnosticsPipeline(
            recorder: diagnostics,
            requestUpload: requestDiagnosticsUpload
        )
        let bonjour = RemotePairingBonjourTransport.live(
            pairingPersistence: pairingPersistence,
            diagnostics: diagnostics,
            verifyCandidate: { deviceID, service in
                await verifyRemotePairingCandidate(
                    deviceID: deviceID,
                    service: service,
                    nativeSessions: nativeSessions,
                    pairingPersistence: pairingPersistence
                )
            }
        )
        return live(
            nativeSessions: nativeSessions,
            configuration: configuration,
            environment: DeviceHubTransportEnvironment(
                persistence: pairingPersistence,
                bonjour: bonjour.client,
                observe: { error, stage in
                    diagnosticsPipeline.submit(
                        .failure(error, stage: stage)
                    )
                },
                observePairingMilestone: { milestone in
                    diagnosticsPipeline.submit(.milestone(milestone))
                },
                now: Date.init,
                makeUUID: UUID.init
            )
        )
    }

    static func live(
        nativeSessions: NativeSessionClient,
        configuration: DeviceHubTransportConfiguration,
        environment: DeviceHubTransportEnvironment
    ) -> Self {
        let runtime = DeviceHubTransportRuntime(
            nativeSessions: nativeSessions,
            configuration: configuration,
            environment: environment
        )
        return Self(
            pairedDevices: {
                try await runtime.pairedDevices()
            },
            availability: {
                runtime.availability()
            },
            pair: { _ in
                runtime.pair()
            },
            connect: { deviceID in
                try await runtime.connect(deviceID)
            },
            forget: { deviceID in
                try await runtime.forget(deviceID)
            }
        )
    }
}

func verifyRemotePairingCandidate(
    deviceID: DeviceID,
    service: ValidatedRemotePairingService,
    nativeSessions: NativeSessionClient,
    pairingPersistence: PairingPersistenceClient
) async -> Bool {
    guard !Task.isCancelled else {
        return false
    }

    var hintMatched = false
    do {
        let records = try await pairingPersistence.pairingRecords()
        guard let record = records.first(where: {
            $0.deviceID == deviceID
        }) else {
            return false
        }
        let expectedTag = RemotePairingAuthTag.compute(
            alternateIRK: record.peerAlternateIRK.withUnsafeBytes { Data($0) },
            serviceIdentifier: service.identifier
        )
        hintMatched = service.authTags.contains(expectedTag)
        guard hintMatched else {
            return false
        }
        let request = try await NativeRemoteSessionRequest(
            generation: SessionGeneration(rawValue: UUID()),
            controller: nativeController(
                pairingPersistence.loadOrCreateControllerIdentity()
            ),
            target: nativeTarget(record),
            service: nativeService(service)
        )
        try await nativeSessions.verifyRemotePairing(request)
        guard !Task.isCancelled else {
            return false
        }
        if case .provisionalAfterVerifiedM5 = record.completion {
            _ = try await pairingPersistence.commitM6(deviceID, Date())
        }
        return !Task.isCancelled
    } catch {
        if let failure = error as? NativeSessionFailure {
            candidateVerificationLogger.error(
                """
                Pair Verify candidate failed \
                code=\(failure.code, privacy: .public) \
                stage=\(failure.stage, privacy: .public) \
                authTagHintMatched=\(hintMatched, privacy: .public)
                """
            )
        }
        return false
    }
}

/// Side-effecting dependencies used by the live client runtime.
///
/// Throwing diagnostic sinks are converted here into nonthrowing observation,
/// keeping telemetry failures outside every transport control path.
struct DeviceHubTransportEnvironment: Sendable {
    typealias Observation =
        @Sendable (DeviceHubError, DiagnosticStage) async -> Void
    typealias DiagnosticSink =
        @Sendable (DeviceHubError, DiagnosticStage) async throws -> Void
    typealias PairingMilestoneObservation =
        @Sendable (PairingDiagnosticMilestone) async -> Void
    typealias PairingMilestoneSink =
        @Sendable (PairingDiagnosticMilestone) async throws -> Void

    let persistence: PairingPersistenceClient
    let bonjour: RemotePairingBonjourClient
    let observe: Observation
    let observePairingMilestone: PairingMilestoneObservation
    let now: @Sendable () -> Date
    let makeUUID: @Sendable () -> UUID

    init(
        persistence: PairingPersistenceClient,
        bonjour: RemotePairingBonjourClient,
        observe: @escaping DiagnosticSink,
        observePairingMilestone:
        @escaping PairingMilestoneSink = { _ in },
        now: @escaping @Sendable () -> Date,
        makeUUID: @escaping @Sendable () -> UUID,
        reportDiagnosticsFailure:
        @escaping @Sendable (DiagnosticStage) -> Void = { stage in
            reportTransportDiagnosticsFailure(stage)
        }
    ) {
        self.bonjour = bonjour
        self.makeUUID = makeUUID
        self.now = now
        self.observe = { error, stage in
            do {
                try await observe(error, stage)
            } catch {
                reportDiagnosticsFailure(stage)
            }
        }
        self.observePairingMilestone = { milestone in
            do {
                try await observePairingMilestone(milestone)
            } catch {
                reportDiagnosticsFailure(milestone.stage)
            }
        }
        self.persistence = persistence
    }
}

/// Testable closure façade over the actor-owned Bonjour implementation.
struct RemotePairingBonjourClient: Sendable {
    var availability:
        @Sendable () async -> AsyncThrowingStream<
            [RemotePairingAvailability],
            Error
        >
    var claimDevice: @Sendable (DeviceID) async -> Void
    var pairingAdvertisement:
        @Sendable (
            UInt16,
            String,
            String
        ) async -> AsyncThrowingStream<PairingAdvertisementEvent, Error>
    var releaseDevice: @Sendable (DeviceID) async -> Void
    var stopAvailability: @Sendable () async -> Void
    var stopPairingAdvertisement: @Sendable () async -> Void
    var refreshKnownDevices:
        @Sendable () async throws(RemotePairingBonjourError) -> Void
    var resolvedService:
        @Sendable (DeviceID) async -> ValidatedRemotePairingService?
}

private extension RemotePairingBonjourTransport {
    nonisolated var client: RemotePairingBonjourClient {
        RemotePairingBonjourClient(
            availability: {
                await self.availability()
            },
            claimDevice: { deviceID in
                await self.claimDevice(deviceID)
            },
            pairingAdvertisement: { port, displayName, model in
                await self.pairingAdvertisement(
                    listenerPort: port,
                    displayName: displayName,
                    model: model
                )
            },
            releaseDevice: { deviceID in
                await self.releaseDevice(deviceID)
            },
            stopAvailability: {
                await self.stopAvailability()
            },
            stopPairingAdvertisement: {
                await self.stopPairingAdvertisement()
            },
            refreshKnownDevices: { () async throws(RemotePairingBonjourError) in
                do {
                    try await self.refreshKnownDevices()
                } catch let error as RemotePairingBonjourError {
                    throw error
                } catch {
                    throw RemotePairingBonjourError
                        .pairingRecordsUnavailable
                }
            },
            resolvedService: { deviceID in
                await self.resolvedService(for: deviceID)
            }
        )
    }
}

private actor DeviceHubTransportRuntime {
    private let configuration: DeviceHubTransportConfiguration
    private let environment: DeviceHubTransportEnvironment
    private let nativeSessions: NativeSessionClient

    init(
        nativeSessions: NativeSessionClient,
        configuration: DeviceHubTransportConfiguration,
        environment: DeviceHubTransportEnvironment
    ) {
        self.configuration = configuration
        self.environment = environment
        self.nativeSessions = nativeSessions
    }

    func pairedDevices() async throws -> [DeviceSummary] {
        do {
            return try await environment.persistence.pairingRecords()
                .filter {
                    configuration.remoteTargetPolicy.permits(
                        displayName: $0.displayName
                    )
                }
                .map { $0.deviceSummary(reachability: .unavailable) }
        } catch {
            throw DeviceHubError.corruptPairingRecord
        }
    }

    nonisolated func availability() -> AsyncStream<[DeviceSummary]> {
        let stream = AsyncStream<[DeviceSummary]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            await self.runAvailability(continuation: stream.continuation)
        }
        stream.continuation.onTermination = { _ in
            task.cancel()
            Task {
                await self.environment.bonjour.stopAvailability()
            }
        }
        return stream.stream
    }

    nonisolated func pair() -> AsyncThrowingStream<PairingEvent, Error> {
        let operation = PairingOperation(
            nativeSessions: nativeSessions,
            configuration: configuration,
            persistence: environment.persistence,
            bonjour: environment.bonjour,
            observe: environment.observe,
            observeMilestone: environment.observePairingMilestone,
            now: environment.now,
            generation: SessionGeneration(rawValue: environment.makeUUID())
        )
        let stream = AsyncThrowingStream<PairingEvent, Error>.makeStream()
        let task = Task {
            await operation.run(continuation: stream.continuation)
        }
        stream.continuation.onTermination = { _ in
            task.cancel()
            Task {
                await operation.cancelFromConsumer()
            }
        }
        return stream.stream
    }

    func connect(_ deviceID: DeviceID) async throws -> DeviceSession {
        guard
            nativeSessions.capabilities.contains(.requiredLiveControl)
        else {
            throw DeviceHubError.unsupportedProtocolVersion
        }

        let records: [TargetPairingRecord]
        do {
            records = try await environment.persistence.pairingRecords()
        } catch {
            throw DeviceHubError.corruptPairingRecord
        }
        guard let record = records.first(where: { $0.deviceID == deviceID })
        else {
            throw DeviceHubError.needsPairing
        }
        guard configuration.remoteTargetPolicy.permits(
            displayName: record.displayName
        ) else {
            throw DeviceHubError.peerAuthenticationFailed
        }
        guard
            let service = await environment.bonjour.resolvedService(deviceID)
        else {
            throw DeviceHubError.deviceOffline
        }

        let request: NativeRemoteSessionRequest
        do {
            request = try await NativeRemoteSessionRequest(
                generation: SessionGeneration(
                    rawValue: environment.makeUUID()
                ),
                controller: nativeController(
                    environment.persistence
                        .loadOrCreateControllerIdentity()
                ),
                target: nativeTarget(record),
                service: nativeService(service)
            )
        } catch {
            throw DeviceHubError.corruptPairingRecord
        }

        await environment.bonjour.claimDevice(deviceID)
        let nativeSession: NativeSession
        do {
            nativeSession = try await nativeSessions.makeRemoteSession(request)
        } catch {
            await environment.bonjour.releaseDevice(deviceID)
            throw mapNativeFailure(error)
        }
        let operation = await RemoteSessionOperation.make(
            nativeSession: nativeSession,
            generation: request.generation,
            initialDevice: record.deviceSummary(reachability: .reachable),
            claimedDeviceID: deviceID,
            environment: environment
        )
        do {
            try await operation.start()
        } catch {
            await operation.disconnect()
            throw error
        }
        return operation.deviceSession
    }

    func forget(_ deviceID: DeviceID) async throws {
        do {
            guard try await environment.persistence.forgetTarget(deviceID)
            else {
                throw DeviceHubError.needsPairing
            }
            try await environment.bonjour.refreshKnownDevices()
        } catch let error as DeviceHubError {
            throw error
        } catch {
            throw DeviceHubError.corruptPairingRecord
        }
    }

    private func runAvailability(
        continuation: AsyncStream<[DeviceSummary]>.Continuation
    ) async {
        let source = await environment.bonjour.availability()
        do {
            for try await availability in source {
                try Task.checkCancellation()
                let records = try await environment.persistence
                    .pairingRecords()
                let reachability = Dictionary(
                    uniqueKeysWithValues: availability.map {
                        ($0.deviceID, $0.reachability)
                    }
                )
                continuation.yield(
                    records.filter {
                        configuration.remoteTargetPolicy.permits(
                            displayName: $0.displayName
                        )
                    }.map {
                        $0.deviceSummary(
                            reachability: reachability[$0.deviceID]
                                ?? .unavailable
                        )
                    }
                )
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            await environment.observe(
                mapAvailabilityFailure(error),
                .locating
            )
            continuation.finish()
        }
    }
}

func nativeController(
    _ identity: ControllerIdentity
) throws -> NativeControllerIdentity {
    try NativeControllerIdentity(
        identifier: identity.identifier.rawValue,
        udid: identity.udid.rawValue,
        longTermSecretKey: identity.longTermSecretKey
            .withUnsafeBytes { Data($0) },
        alternateIRK: identity.alternateIRK
            .withUnsafeBytes { Data($0) }
    )
}

private func nativeTarget(
    _ record: TargetPairingRecord
) throws -> NativeTargetPairingRecord {
    let completion: NativePairingCompletion = switch record.completion {
    case .provisionalAfterVerifiedM5:
        .provisional
    case .committedAfterM6:
        .committed
    }
    return try NativeTargetPairingRecord(
        deviceID: record.deviceID,
        accountIdentifier: record.accountIdentifier.rawValue,
        peerIdentifier: record.peerIdentifier.rawValue,
        peerPublicKey: record.peerPublicKey.withUnsafeBytes { Data($0) },
        peerAlternateIRK: record.peerAlternateIRK
            .withUnsafeBytes { Data($0) },
        displayName: record.displayName,
        productType: record.productType,
        completion: completion
    )
}

private func nativeService(
    _ service: ValidatedRemotePairingService
) throws -> NativeRemoteService {
    guard
        let identifier = UUID(uuidString: service.identifier),
        let endpoint = service.resolvedEndpoints.first
    else {
        throw NativeSessionContractError.invalidText
    }
    return try NativeRemoteService(
        endpoint: endpoint,
        identifier: identifier,
        authTags: service.authTags
    )
}

func verifiedM5(
    _ peer: NativeVerifiedPeer,
    verifiedAt: Date
) throws -> VerifiedM5Pairing {
    try VerifiedM5Pairing(
        deviceID: peer.deviceID,
        accountIdentifier: PairingAccountIdentifier(
            rawValue: peer.accountIdentifier
        ),
        peerIdentifier: PeerPairingIdentifier(
            rawValue: peer.peerIdentifier
        ),
        peerPublicKey: Ed25519PublicKey(data: peer.peerPublicKey),
        peerAlternateIRK: PeerAlternateIRK(
            data: peer.peerAlternateIRK
        ),
        displayName: peer.displayName,
        productType: peer.productType,
        verifiedAt: verifiedAt
    )
}
