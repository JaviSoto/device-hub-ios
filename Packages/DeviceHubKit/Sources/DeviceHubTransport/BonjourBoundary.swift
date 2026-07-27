import DeviceHubCore
import Foundation

/// User-safe availability for one device already known to this controller.
///
/// Bonjour instance names, TXT data, hosts, ports, addresses, and
/// authentication tags deliberately remain inside `DeviceHubTransport`.
public struct RemotePairingAvailability: Equatable, Sendable {
    public let deviceID: DeviceID
    public let reachability: DeviceReachability

    public init(
        deviceID: DeviceID,
        reachability: DeviceReachability
    ) {
        self.deviceID = deviceID
        self.reachability = reachability
    }
}

public enum PairingAdvertisementEvent: Equatable, Sendable {
    case published
}

/// Redacted failures surfaced by the system Bonjour lifecycle.
public enum RemotePairingBonjourError: Error, Equatable, Sendable {
    case browserFailed(code: Int)
    case browserStartFailed(code: Int)
    case invalidPairableHostConfiguration
    case pairingRecordsUnavailable
    case publisherFailed(code: Int)
    case publisherStartFailed(code: Int)
}

struct PairableHostIdentity:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Sendable
{
    let alternateIRK: Data
    let identifier: UUID

    init(identifier: UUID, alternateIRK: Data) throws {
        guard
            alternateIRK.count == 16,
            alternateIRK.contains(where: { $0 != 0 })
        else {
            throw RemotePairingTXTError.invalidAuthTag
        }
        self.alternateIRK = alternateIRK
        self.identifier = identifier
    }

    var description: String {
        "<redacted-pairable-host-identity>"
    }

    var debugDescription: String {
        description
    }
}

enum BonjourNativeOperation: Equatable, Sendable {
    case browseRuntime
    case browseStart
    case publishRuntime
    case publishStart
    case resolve
}

/// Numeric system failure stripped of Foundation's potentially identifying
/// service dictionary and localized payload.
struct BonjourNativeFailure:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Error,
    Equatable,
    Sendable
{
    let operation: BonjourNativeOperation
    let code: Int

    var description: String {
        "<redacted-bonjour-failure operation=\(operation) code=\(code)>"
    }

    var debugDescription: String {
        description
    }
}

/// Immutable snapshot copied from a resolved `NetService` callback.
///
/// The owning Foundation bridge copies only value-semantic fields before
/// crossing from the main actor. Reflection is redacted because this value
/// contains a local hostname and raw TXT record.
struct BonjourResolvedServiceSnapshot:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Sendable
{
    let hostName: String
    let port: Int
    let resolvedEndpoints: [NativeResolvedEndpoint]
    let serviceName: String
    let txtRecord: Data

    init(
        serviceName: String,
        hostName: String,
        port: Int,
        resolvedEndpoints: [NativeResolvedEndpoint],
        txtRecord: Data
    ) {
        self.hostName = hostName
        self.port = port
        self.resolvedEndpoints = resolvedEndpoints
        self.serviceName = serviceName
        self.txtRecord = txtRecord
    }

    var description: String {
        "<redacted-bonjour-service>"
    }

    var debugDescription: String {
        description
    }
}

enum BonjourBrowserEvent: Sendable {
    case failed(BonjourNativeFailure)
    case removed(serviceName: String)
    case resolutionFailed(BonjourNativeFailure)
    case resolved(BonjourResolvedServiceSnapshot)
}

enum BonjourPublisherEvent: Sendable {
    case failed(BonjourNativeFailure)
    case published
}

/// Sendable closure façade around the main-actor Foundation browser.
///
/// Tests supply an in-memory implementation, so unit coverage never opens a
/// multicast socket or triggers local-network permission.
struct BonjourBrowserClient: Sendable {
    var start:
        @Sendable (
            _ handler: @escaping @Sendable (BonjourBrowserEvent) -> Void
        ) async throws(BonjourNativeFailure) -> Void
    var stop: @Sendable () async -> Void
}

/// Sendable closure façade around the main-actor Foundation publisher.
struct BonjourPublisherClient: Sendable {
    var start:
        @Sendable (
            _ advertisement: PairableHostAdvertisement,
            _ handler: @escaping @Sendable (BonjourPublisherEvent) -> Void
        ) async throws(BonjourNativeFailure) -> Void
    var stop: @Sendable () async -> Void
}

enum BonjourTransportObservation: Equatable, Sendable {
    case ambiguousAnnouncement
    case malformedAnnouncement
    case resolutionFailed
    case unknownAnnouncement
}
