import ComposableArchitecture
import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Pairing feature")
struct PairingFeatureTests {
    @Test("Pairing starts by preparing its listener")
    func defaultStatePreparesListener() {
        let state = PairingFeature.State()

        expectNoDifference(state.phase, .preparing)
        expectNoDifference(state.pairingCode, nil)
    }

    @Test("Pairing stays preparing until publication is confirmed")
    func taskWaitsForAdvertisingEvent() async {
        let clock = TestClock()
        let pipe = AsyncThrowingStream<
            PairingEvent,
            Error
        >.makeStream()
        let store = TestStore(
            initialState: PairingFeature.State()
        ) {
            PairingFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pair = { _ in pipe.stream }
        }

        await store.send(.task)
        expectNoDifference(store.state.phase, .preparing)

        pipe.continuation.yield(.advertising)
        await store.receive(
            \.pairingEventReceived,
            .advertising
        ) {
            $0.phase = .advertising
        }

        await store.send(.cancelButtonTapped) {
            $0.phase = .preparing
        }
        await store.receive(\.delegate.cancelled)
        pipe.continuation.finish()
    }

    @Test("Pairing preparation cannot spin forever")
    func preparationTimesOut() async {
        let clock = TestClock()
        let pipe = AsyncThrowingStream<
            PairingEvent,
            Error
        >.makeStream()
        let store = TestStore(
            initialState: PairingFeature.State()
        ) {
            PairingFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pair = { _ in pipe.stream }
        }

        await store.send(.task)
        await clock.advance(by: .seconds(15))
        await store.receive(\.preparationTimedOut) {
            $0.remediation = DeviceHubRemediation(
                error: .pairingTimedOut
            )
        }
    }

    @Test(
        "Platform remediations delegate without restarting pairing",
        arguments: [
            (
                DeviceHubError.localNetworkDenied,
                DeviceHubError.Remedy.grantLocalNetworkAccess
            ),
            (
                DeviceHubError.developerModeDisabled,
                DeviceHubError.Remedy.enableDeveloperMode
            ),
            (
                DeviceHubError.developerImageUnavailable,
                DeviceHubError.Remedy.prepareWithXcode
            ),
            (
                DeviceHubError.unsupportedProtocolVersion,
                DeviceHubError.Remedy.updateApp
            )
        ]
    )
    func platformRemediationDelegates(
        error: DeviceHubError,
        remedy: DeviceHubError.Remedy
    ) async {
        let pairingProbe = PairingProbe()
        let store = TestStore(
            initialState: PairingFeature.State(
                remediation: DeviceHubRemediation(error: error)
            )
        ) {
            PairingFeature()
        } withDependencies: {
            $0.deviceHub.pair = { _ in
                pairingProbe.record()
                return AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            }
        }

        await store.send(.remediationButtonTapped) {
            $0.remediation = nil
        }
        let remediationRequested: CaseKeyPath<
            PairingFeature.Action,
            DeviceHubError.Remedy
        > = \.delegate.remediationRequested
        await store.receive(
            remediationRequested,
            remedy
        )
        #expect(!pairingProbe.wasInvoked)
    }

    @Test(
        "Retryable remediations start a new pairing attempt",
        arguments: [
            DeviceHubError.pairingTimedOut,
            .needsPairing,
            .deviceLocked,
            .deviceBusy,
            .deviceOffline
        ]
    )
    func retryableRemediationStartsPairing(
        error: DeviceHubError
    ) async throws {
        let clock = TestClock()
        let pipe = AsyncThrowingStream<
            PairingEvent,
            Error
        >.makeStream()
        let code = try #require(PairingCode("420027"))
        let store = TestStore(
            initialState: PairingFeature.State(
                phase: .waitingForCodeEntry(code),
                remediation: DeviceHubRemediation(error: error)
            )
        ) {
            PairingFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pair = { _ in pipe.stream }
        }
        await store.send(.remediationButtonTapped) {
            $0.phase = .preparing
            $0.remediation = nil
        }
        expectNoDifference(store.state.pairingCode, nil)

        pipe.continuation.yield(.advertising)
        await store.receive(
            \.pairingEventReceived,
            .advertising
        ) {
            $0.phase = .advertising
        }
        await store.send(.cancelButtonTapped) {
            $0.phase = .preparing
        }
        await store.receive(\.delegate.cancelled)
        pipe.continuation.finish()
    }

    @Test("A remediation without an action stays visible without a button")
    func remediationWithoutAction() async {
        let remediation = DeviceHubRemediation(
            error: .malformedDeviceAnnouncement
        )
        let store = TestStore(
            initialState: PairingFeature.State(
                remediation: remediation
            )
        ) {
            PairingFeature()
        }

        #expect(store.state.remediationActionTitle == nil)
        await store.send(.remediationButtonTapped)
        expectNoDifference(store.state.remediation, remediation)
    }

    @Test("A pairing code is cleared when pairing fails")
    func clearsCodeOnFailure() async throws {
        let clock = TestClock()
        let pipe = AsyncThrowingStream<
            PairingEvent,
            Error
        >.makeStream()
        let store = TestStore(
            initialState: PairingFeature.State()
        ) {
            PairingFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pair = { _ in pipe.stream }
        }
        let code = try #require(PairingCode("654321"))

        await store.send(.task)
        pipe.continuation.yield(
            .waitingForCodeEntry(code: code)
        )
        await store.receive(\.pairingEventReceived) {
            $0.phase = .waitingForCodeEntry(code)
        }

        pipe.continuation.finish(
            throwing: DeviceHubError.incorrectPairingCode
        )
        await store.receive(\.pairingFailed) {
            $0.phase = .preparing
            $0.remediation = DeviceHubRemediation(
                error: .incorrectPairingCode
            )
        }
        #expect(store.state.pairingCode == nil)
    }

    @Test("Cancelling clears the code before delegating")
    func cancellationClearsCode() async throws {
        let clock = TestClock()
        let pipe = AsyncThrowingStream<
            PairingEvent,
            Error
        >.makeStream()
        let store = TestStore(
            initialState: PairingFeature.State()
        ) {
            PairingFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pair = { _ in pipe.stream }
        }
        let code = try #require(PairingCode("123456"))

        await store.send(.task)
        pipe.continuation.yield(
            .waitingForCodeEntry(code: code)
        )
        await store.receive(\.pairingEventReceived) {
            $0.phase = .waitingForCodeEntry(code)
        }
        await store.send(.cancelButtonTapped) {
            $0.phase = .preparing
        }
        await store.receive(\.delegate.cancelled)
        expectNoDifference(store.state.pairingCode, nil)
    }

    @Test("A finished pairing stream clears the code before showing recovery")
    func finishedStreamClearsCode() async throws {
        let clock = TestClock()
        let pipe = AsyncThrowingStream<
            PairingEvent,
            Error
        >.makeStream()
        let store = TestStore(
            initialState: PairingFeature.State()
        ) {
            PairingFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pair = { _ in pipe.stream }
        }
        let code = try #require(PairingCode("270027"))

        await store.send(.task)
        pipe.continuation.yield(
            .waitingForCodeEntry(code: code)
        )
        await store.receive(\.pairingEventReceived) {
            $0.phase = .waitingForCodeEntry(code)
        }

        pipe.continuation.finish()
        await store.receive(\.pairingStreamFinished) {
            $0.phase = .preparing
            $0.remediation = DeviceHubRemediation(
                error: .pairingTimedOut
            )
        }
        expectNoDifference(store.state.pairingCode, nil)
    }
}

private final class PairingProbe: @unchecked Sendable {
    private var didInvoke = false
    private let lock = NSLock()

    func record() {
        lock.lock()
        defer { lock.unlock() }
        didInvoke = true
    }

    var wasInvoked: Bool {
        lock.withLock {
            didInvoke
        }
    }
}
