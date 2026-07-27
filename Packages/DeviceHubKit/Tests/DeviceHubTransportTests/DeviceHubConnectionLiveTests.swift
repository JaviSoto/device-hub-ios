import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubPersistence
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Live Device Hub connection")
struct DeviceHubConnectionLiveTests {
    @Test("successful Pair Verify commits a provisional record exactly once")
    func successfulPairVerifyCommitsProvisionalRecord() async throws {
        let operations = OperationProbe()
        let record = try fixtureRecord(
            completion: .provisionalAfterVerifiedM5(verifiedAt: now)
        )
        let persistence = try PersistenceProbe(
            records: [record],
            operations: operations
        )
        let service = try fixtureRemoteService(for: record)
        let native = NativeSessionClient(
            capabilities: [.pairVerifyDiscovery],
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw unavailableNativeSessionFailure
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                throw unavailableNativeSessionFailure
            },
            verifyRemotePairing: { _ in }
        )

        let didVerify = await verifyRemotePairingCandidate(
            deviceID: record.deviceID,
            service: service,
            nativeSessions: native,
            pairingPersistence: persistence.client
        )

        #expect(didVerify)
        #expect(await operations.values.filter { $0 == .committed }.count == 1)
    }

    @Test("failed Pair Verify leaves a provisional record uncommitted")
    func failedPairVerifyDoesNotCommitProvisionalRecord() async throws {
        let operations = OperationProbe()
        let record = try fixtureRecord(
            completion: .provisionalAfterVerifiedM5(verifiedAt: now)
        )
        let persistence = try PersistenceProbe(
            records: [record],
            operations: operations
        )
        let service = try fixtureRemoteService(for: record)
        let native = NativeSessionClient(
            capabilities: [.pairVerifyDiscovery],
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw unavailableNativeSessionFailure
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                throw unavailableNativeSessionFailure
            },
            verifyRemotePairing: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(
                    code: "pair_verify_failed",
                    stage: "pair_verify_m2_signature",
                    retryable: false
                )
            }
        )

        let didVerify = await verifyRemotePairingCandidate(
            deviceID: record.deviceID,
            service: service,
            nativeSessions: native,
            pairingPersistence: persistence.client
        )

        #expect(!didVerify)
        #expect(await operations.values.allSatisfy { $0 != .committed })
    }

    @Test("a live session owns availability until disconnect")
    func liveSessionOwnsAvailability() async throws {
        let operations = OperationProbe()
        let controlEvents = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream()
        let nativeSession = NativeSession(
            events: controlEvents.stream,
            start: {
                await operations.append(.nativeStarted)
            },
            completePersistence: { _, _ in },
            send: { _ in },
            cancel: {
                await operations.append(.nativeCancelled)
                controlEvents.continuation.finish()
            }
        )
        let native = NativeSessionClient(
            capabilities: .requiredLiveControl,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw unavailableNativeSessionFailure
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                await operations.append(.nativeRemoteCreated)
                return nativeSession
            }
        )
        let persistence = try PersistenceProbe(
            records: [fixtureRecord()]
        )
        let bonjour = try BonjourClientProbe(
            availability: [],
            operations: operations,
            resolvedService: fixtureRemoteService()
        )
        let client = try makeClient(
            nativeSessions: native,
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        let session = try await client.connect(deviceID)
        await session.disconnect()

        let recordedOperations = await operations.values
        expectNoDifference(
            recordedOperations,
            [
                .resolvedService,
                .availabilityClaimed(deviceID),
                .nativeRemoteCreated,
                .nativeStarted,
                .nativeCancelled,
                .availabilityReleased(deviceID)
            ]
        )
    }
}

private let unavailableNativeSessionFailure = NativeSessionFailure(
    code: "invalid_state",
    stage: "session_lifecycle",
    retryable: false
)

private func fixtureRemoteService(
    for record: TargetPairingRecord
) throws -> ValidatedRemotePairingService {
    let identifier = "2BE6E510-0325-4365-923E-B14C6F57DB3A"
    let authTag = RemotePairingAuthTag.compute(
        alternateIRK: record.peerAlternateIRK.withUnsafeBytes { Data($0) },
        serviceIdentifier: identifier
    )
    return try ValidatedRemotePairingService(
        serviceName: identifier,
        hostName: "test-iphone.local.",
        port: 49155,
        resolvedEndpoints: [testEndpoint()],
        txtRecord: makeTXT([
            ("identifier", identifier),
            ("authTag", authTag.base64EncodedString()),
            ("flags", "0"),
            ("ver", "26"),
            ("minVer", "8")
        ])
    )
}
