import CustomDump
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

extension DeviceHubClientLiveTests {
    @Test("pairing keeps its advertisement alive through Pair Setup")
    func pairingAdvertisementLifetime() async throws {
        let operations = OperationProbe()
        let persistence = try PersistenceProbe(records: [])
        let advertisementLifetime = AdvertisementLifetimeProbe()
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations,
            advertisementLifetime: advertisementLifetime
        )
        let native = ManualPairingNativeProbe(operations: operations)
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        let stream = client.pair(PairingRequest())
        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()

        #expect(event == .advertising)
        #expect(!advertisementLifetime.isTerminated)

        try await native.beginPairing(
            code: #require(PairingCode("123456"))
        )
        #expect(
            try await iterator.next()
                == .waitingForCodeEntry(
                    code: #require(PairingCode("123456"))
                )
        )
        #expect(
            await !(operations.values).contains(.advertisementStopped)
        )
        #expect(!advertisementLifetime.isTerminated)

        await native.fail()

        do {
            _ = try await iterator.next()
            Issue.record("Expected the injected native pairing failure.")
        } catch let error as DeviceHubError {
            #expect(error == .secureConnectionFailed)
        }
        await operations.wait(for: .advertisementStopped)
    }

    @Test("pairing rejects a non-target M5 before persistence")
    func pairingRejectsNonTargetBeforePersistence() async throws {
        let operations = OperationProbe()
        let persistence = try PersistenceProbe(
            records: [],
            operations: operations
        )
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations
        )
        let native = try NativeClientProbe(
            operations: operations,
            peerDisplayName: "Other iPhone"
        )
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        var events: [PairingEvent] = []
        do {
            for try await event in client.pair(PairingRequest()) {
                events.append(event)
            }
            Issue.record("Pairing accepted a target outside the allowlist.")
        } catch let error as DeviceHubError {
            #expect(error == .peerAuthenticationFailed)
        }

        try expectNoDifference(
            events,
            [
                .advertising,
                .waitingForCodeEntry(
                    code: #require(PairingCode("123456"))
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
                .acknowledged(requestID: 1, outcome: .failed),
                .advertisementStopped,
                .nativeCancelled
            ]
        )
        #expect(try await persistence.client.pairingRecords().isEmpty)
    }
}

final class AdvertisementLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    func markTerminated() {
        lock.withLock {
            terminated = true
        }
    }
}

actor ManualPairingNativeProbe {
    private let events = AsyncThrowingStream<
        NativeSessionEvent,
        Error
    >.makeStream()
    private let operations: OperationProbe

    init(operations: OperationProbe) {
        self.operations = operations
    }

    nonisolated var client: NativeSessionClient {
        NativeSessionClient(
            capabilities: .requiredPairing,
            makePairingSession: { _ in
                await self.makePairingSession()
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

    func beginPairing(code: PairingCode) {
        events.continuation.yield(.phaseChanged(.pairing))
        events.continuation.yield(.pairingCode(code))
    }

    func fail() {
        events.continuation.yield(.failed(NativeSessionFailure(
            code: "listener_failed",
            stage: "session_lifecycle",
            retryable: true
        )))
        events.continuation.finish()
    }

    private func makePairingSession() async -> NativeSession {
        await operations.append(.nativePairingCreated)
        return NativeSession(
            events: events.stream,
            start: {
                await self.operations.append(.nativeStarted)
                await self.listenerReady()
            },
            completePersistence: { _, _ async throws(NativeSessionFailure) in
            },
            send: { _ async throws(NativeSessionFailure) in },
            cancel: {
                await self.operations.append(.nativeCancelled)
            }
        )
    }

    private func listenerReady() {
        events.continuation.yield(.pairingListenerReady(port: 49155))
    }
}
