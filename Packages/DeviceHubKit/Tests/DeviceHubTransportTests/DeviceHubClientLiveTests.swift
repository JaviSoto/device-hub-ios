import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubPersistence
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Live Device Hub client")
struct DeviceHubClientLiveTests {
    @Test("pairing ACKs each durable milestone before advancing")
    func pairingPersistenceOrdering() async throws {
        let operations = OperationProbe()
        let milestones = PairingMilestoneProbe()
        let persistence = try PersistenceProbe(
            records: [],
            operations: operations
        )
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations
        )
        let native = try NativeClientProbe(operations: operations)
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: persistence.client,
            bonjour: bonjour.client,
            pairingMilestoneSink: milestones.record
        )

        var events: [PairingEvent] = []
        for try await event in client.pair(PairingRequest()) {
            events.append(event)
        }

        try expectNoDifference(
            events,
            [
                .advertising,
                .waitingForCodeEntry(
                    code: #require(PairingCode("123456"))
                ),
                .saving,
                .paired(
                    DeviceSummary(
                        id: deviceID,
                        name: "Test iPhone",
                        productType: "iPhone17,1",
                        operatingSystemVersion: nil,
                        pairingState: .paired,
                        reachability: .unavailable
                    )
                )
            ]
        )
        let recordedOperations = await operations.values
        expectNoDifference(
            recordedOperations,
            [
                .nativePairingCreated,
                .nativeStarted,
                .advertised(port: 49155),
                .savedProvisional,
                .acknowledged(requestID: 1, outcome: .succeeded),
                .committed,
                .acknowledged(requestID: 2, outcome: .succeeded),
                .refreshedKnownDevices,
                .resolvedService,
                .advertisementStopped,
                .nativeCancelled
            ]
        )
        expectNoDifference(
            milestones.values,
            [
                .listenerReady,
                .advertisementPublished,
                .peerConnected,
                .waitingForPairingCode,
                .savingPairing,
                .pairingCompleted
            ]
        )
    }
}

let deviceID = DeviceID(rawValue: "test-phone")
let unauthorizedDeviceID = DeviceID(rawValue: "other-phone")
let now = Date(timeIntervalSince1970: 1_750_000_000)
private let clientGeneration = SessionGeneration(
    rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 9
    ))
)
func makeClient(
    nativeSessions: NativeSessionClient = .unavailableForTests,
    persistence: PairingPersistenceClient,
    bonjour: RemotePairingBonjourClient,
    diagnosticSink:
    @escaping @Sendable (DeviceHubError, DiagnosticStage) async throws
        -> Void = { _, _ in },
    pairingMilestoneSink:
    @escaping @Sendable (PairingDiagnosticMilestone) async throws
        -> Void = { _ in },
    reportDiagnosticsFailure:
    @escaping @Sendable (DiagnosticStage) -> Void = { _ in }
) throws -> DeviceHubClient {
    try DeviceHubClient.live(
        nativeSessions: nativeSessions,
        configuration: DeviceHubTransportConfiguration(
            controllerDisplayName: "Test iPhone",
            controllerModel: "iPhone18,2",
            remoteTargetPolicy: .init(
                requiredDisplayName: "Test iPhone"
            )
        ),
        environment: DeviceHubTransportEnvironment(
            persistence: persistence,
            bonjour: bonjour,
            observe: diagnosticSink,
            observePairingMilestone: pairingMilestoneSink,
            now: { now },
            makeUUID: { clientGeneration.rawValue },
            reportDiagnosticsFailure: reportDiagnosticsFailure
        )
    )
}

private func fixtureController() throws -> ControllerIdentity {
    try ControllerIdentity(
        identifier: ControllerIdentifier(
            rawValue: #require(UUID(
                uuidString: "D0A4A010-580E-4C4E-A9E1-06EE86ED79E2"
            ))
        ),
        udid: ControllerUDID(rawValue: "controller-udid"),
        longTermSecretKey: Ed25519SecretKey(
            data: Data(repeating: 1, count: 32)
        ),
        alternateIRK: HostAlternateIRK(
            data: Data(repeating: 2, count: 16)
        ),
        createdAt: now
    )
}

func fixtureRecord(
    deviceID: DeviceID = deviceID,
    displayName: String = "Test iPhone",
    operatingSystemVersion: String? = nil,
    completion: PairingCompletion = .committedAfterM6(
        verifiedAt: now,
        committedAt: now
    )
) throws -> TargetPairingRecord {
    try TargetPairingRecord(
        deviceID: deviceID,
        accountIdentifier: PairingAccountIdentifier(
            rawValue: "account"
        ),
        peerIdentifier: PeerPairingIdentifier(rawValue: "peer"),
        peerPublicKey: Ed25519PublicKey(
            data: Data(repeating: 3, count: 32)
        ),
        peerAlternateIRK: PeerAlternateIRK(
            data: Data(repeating: 4, count: 16)
        ),
        hostIdentityFingerprint: HostIdentityFingerprint(
            data: Data(repeating: 5, count: 32)
        ),
        displayName: displayName,
        productType: "iPhone17,1",
        operatingSystemVersion: operatingSystemVersion,
        completion: completion
    )
}

actor OperationProbe {
    enum Operation: Equatable {
        case acknowledged(
            requestID: UInt64,
            outcome: NativePersistenceOutcome
        )
        case advertised(port: UInt16)
        case advertisementStopped
        case availabilityClaimed(DeviceID)
        case availabilityReleased(DeviceID)
        case committed
        case nativeCancelled
        case nativePairingCreated
        case nativeRemoteCreated
        case nativeStarted
        case refreshedKnownDevices
        case resolvedService
        case savedProvisional
    }

    private(set) var values: [Operation] = []
    private var waiters: [
        (
            operation: Operation,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []

    func append(_ operation: Operation) {
        values.append(operation)
        let ready = waiters.filter { $0.operation == operation }
        waiters.removeAll { $0.operation == operation }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for operation: Operation) async {
        guard !values.contains(operation) else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((operation, continuation))
        }
    }
}

final class TransportDiagnosticFailureProbe: @unchecked Sendable {
    struct Attempt {
        let error: DeviceHubError
        let stage: DiagnosticStage
    }

    private enum Failure: Error {
        case unavailable
    }

    private let lock = NSLock()
    private var recordedAttempts: [Attempt] = []
    private var reports: [DiagnosticStage] = []

    var attempts: [Attempt] {
        lock.withLock { recordedAttempts }
    }

    var reportedStages: [DiagnosticStage] {
        lock.withLock { reports }
    }

    func record(
        _ error: DeviceHubError,
        _ stage: DiagnosticStage
    ) async throws {
        lock.withLock {
            recordedAttempts.append(Attempt(error: error, stage: stage))
        }
        throw Failure.unavailable
    }

    func report(_ stage: DiagnosticStage) {
        lock.withLock {
            reports.append(stage)
        }
    }
}

final class PairingMilestoneProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PairingDiagnosticMilestone] = []

    var values: [PairingDiagnosticMilestone] {
        lock.withLock { storage }
    }

    func record(_ milestone: PairingDiagnosticMilestone) async {
        lock.withLock {
            storage.append(milestone)
        }
    }
}

actor PersistenceProbe {
    private var records: [TargetPairingRecord]
    private let controller: ControllerIdentity
    private let operations: OperationProbe?

    init(
        records: [TargetPairingRecord],
        operations: OperationProbe? = nil
    ) throws {
        controller = try fixtureController()
        self.operations = operations
        self.records = records
    }

    nonisolated var client: PairingPersistenceClient {
        PairingPersistenceClient(
            commitM6: { deviceID, _ in
                try await self.commit(deviceID: deviceID)
            },
            enrichFromAuthenticatedRSD: { metadata, deviceID in
                try await self.enrich(metadata: metadata, deviceID: deviceID)
            },
            forgetTarget: { deviceID in
                await self.forget(deviceID: deviceID)
            },
            loadOrCreateControllerIdentity: {
                self.controller
            },
            pairingRecords: {
                await self.records
            },
            recoveryDecisions: {
                await self.records.map { .ready($0) }
            },
            saveVerifiedM5: { pairing in
                try await self.save(pairing)
            }
        )
    }

    private func commit(
        deviceID: DeviceID
    ) async throws -> TargetPairingRecord {
        await operations?.append(.committed)
        let record = try #require(records.first { $0.deviceID == deviceID })
        let committed = try fixtureRecord(
            operatingSystemVersion: record.operatingSystemVersion
        )
        records = [committed]
        return committed
    }

    private func enrich(
        metadata: AuthenticatedRSDMetadata,
        deviceID: DeviceID
    ) throws -> TargetPairingRecord {
        let record = try #require(records.first { $0.deviceID == deviceID })
        let enriched = try fixtureRecord(
            operatingSystemVersion: metadata.operatingSystemVersion,
            completion: record.completion
        )
        records = [enriched]
        return enriched
    }

    private func forget(deviceID: DeviceID) -> Bool {
        let oldCount = records.count
        records.removeAll { $0.deviceID == deviceID }
        return records.count != oldCount
    }

    private func save(
        _ pairing: VerifiedM5Pairing
    ) async throws -> TargetPairingRecord {
        await operations?.append(.savedProvisional)
        let provisional = try fixtureRecord(
            completion: .provisionalAfterVerifiedM5(
                verifiedAt: pairing.verifiedAt
            )
        )
        records = [provisional]
        return provisional
    }
}

struct BonjourClientProbe: Sendable {
    let client: RemotePairingBonjourClient

    init(
        availability: [RemotePairingAvailability],
        operations: OperationProbe? = nil,
        resolvedService: ValidatedRemotePairingService? = nil,
        advertisementFailure: RemotePairingBonjourError? = nil,
        advertisementLifetime: AdvertisementLifetimeProbe? = nil
    ) {
        client = RemotePairingBonjourClient(
            availability: {
                AsyncThrowingStream { continuation in
                    continuation.yield(availability)
                    continuation.finish()
                }
            },
            claimDevice: { deviceID in
                await operations?.append(.availabilityClaimed(deviceID))
            },
            pairingAdvertisement: { port, _, _ in
                await operations?.append(.advertised(port: port))
                return AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in
                        advertisementLifetime?.markTerminated()
                    }
                    if let advertisementFailure {
                        continuation.finish(
                            throwing: advertisementFailure
                        )
                    } else {
                        continuation.yield(.published)
                    }
                }
            },
            releaseDevice: { deviceID in
                await operations?.append(.availabilityReleased(deviceID))
            },
            stopAvailability: {},
            stopPairingAdvertisement: {
                await operations?.append(.advertisementStopped)
            },
            refreshKnownDevices: { () async throws(RemotePairingBonjourError) in
                await operations?.append(.refreshedKnownDevices)
            },
            resolvedService: { _ in
                await operations?.append(.resolvedService)
                return resolvedService
            }
        )
    }
}

struct RemoteNativeClientProbe: Sendable {
    let client: NativeSessionClient

    init(operations: OperationProbe) {
        let events = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream()
        let session = NativeSession(
            events: events.stream,
            start: { () async throws(NativeSessionFailure) in
                await operations.append(.nativeStarted)
                events.continuation.yield(.failed(NativeSessionFailure(
                    code: "remote_pairing_connect_failed",
                    stage: "session_lifecycle",
                    retryable: true
                )))
                events.continuation.finish()
            },
            completePersistence: { _, _ async throws(NativeSessionFailure) in
            },
            send: { _ async throws(NativeSessionFailure) in },
            cancel: { () async throws(NativeSessionFailure) in
                await operations.append(.nativeCancelled)
            }
        )
        client = NativeSessionClient(
            capabilities: .requiredLiveControl,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "session_lifecycle",
                    retryable: false
                )
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                await operations.append(.nativeRemoteCreated)
                return session
            }
        )
    }
}

actor NativeClientProbe {
    private let committedRequestID: NativePersistenceRequestID
    private let operations: OperationProbe
    private let pairingCode: PairingCode
    private let peer: NativeVerifiedPeer
    private let provisionalRequestID: NativePersistenceRequestID

    init(
        operations: OperationProbe,
        peerDisplayName: String = "Test iPhone"
    ) throws {
        committedRequestID = try #require(
            NativePersistenceRequestID(rawValue: 2)
        )
        self.operations = operations
        pairingCode = try #require(PairingCode("123456"))
        peer = try NativeVerifiedPeer(
            deviceID: deviceID,
            accountIdentifier: "account",
            peerIdentifier: "peer",
            peerPublicKey: Data(repeating: 3, count: 32),
            peerAlternateIRK: Data(repeating: 4, count: 16),
            displayName: peerDisplayName,
            productType: "iPhone17,1"
        )
        provisionalRequestID = try #require(
            NativePersistenceRequestID(rawValue: 1)
        )
    }

    nonisolated var client: NativeSessionClient {
        NativeSessionClient(
            capabilities: .requiredPairing,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                await self.operations.append(.nativePairingCreated)
                return await self.pairingSession
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "session_lifecycle",
                    retryable: false
                )
            }
        )
    }

    private var pairingSession: NativeSession {
        let pair = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream()
        return NativeSession(
            events: pair.stream,
            start: { () async throws(NativeSessionFailure) in
                await self.operations.append(.nativeStarted)
                pair.continuation.yield(
                    .pairingListenerReady(port: 49155)
                )
                pair.continuation.yield(.phaseChanged(.pairing))
                pair.continuation.yield(
                    .pairingCode(self.pairingCode)
                )
                pair.continuation.yield(
                    .pairRecordProvisional(
                        requestID: self.provisionalRequestID,
                        peer: self.peer
                    )
                )
                pair.continuation.yield(
                    .pairRecordCommitted(
                        requestID: self.committedRequestID,
                        peer: self.peer
                    )
                )
                pair.continuation.yield(.completed)
                pair.continuation.finish()
            },
            completePersistence: { requestID, outcome async throws(NativeSessionFailure) in
                await self.operations.append(
                    .acknowledged(
                        requestID: requestID.rawValue,
                        outcome: outcome
                    )
                )
            },
            send: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "session_lifecycle",
                    retryable: false
                )
            },
            cancel: { () async throws(NativeSessionFailure) in
                await self.operations.append(.nativeCancelled)
            }
        )
    }
}

func fixtureRemoteService() throws -> ValidatedRemotePairingService {
    let identifier = "2BE6E510-0325-4365-923E-B14C6F57DB3A"
    return try ValidatedRemotePairingService(
        serviceName: identifier,
        hostName: "test-iphone.local.",
        port: 49155,
        resolvedEndpoints: [testEndpoint()],
        txtRecord: makeTXT([
            ("identifier", identifier),
            ("authTag", "kXjlTr2l"),
            ("flags", "0"),
            ("ver", "26"),
            ("minVer", "8")
        ])
    )
}

extension NativeSessionClient {
    static let unavailableForTests = unavailableForTests(capabilities: [])

    static func unavailableForTests(
        capabilities: NativeSessionCapabilities
    ) -> NativeSessionClient {
        NativeSessionClient(
            capabilities: capabilities,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "session_lifecycle",
                    retryable: false
                )
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "session_lifecycle",
                    retryable: false
                )
            }
        )
    }
}
