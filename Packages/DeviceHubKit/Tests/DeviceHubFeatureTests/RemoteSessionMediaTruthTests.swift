import ComposableArchitecture
import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session media truth")
struct RemoteSessionMediaTruthTests {
    @Test("Accepted video metadata is live but needs matching fallback pixels")
    func acceptedVideoMetadataNeedsMatchingFrameForInput() async {
        let fixture = MediaTruthFixture()
        let now = fixture.receivedAt.addingTimeInterval(0.25)
        let session = fixture.session()
        let metadata = fixture.frameMetadata(sequenceNumber: 1)
        let update = fixture.update(for: .videoFrame(metadata))
        let store = fixture.store(
            session: session,
            now: now
        )

        await store.send(
            fixture.action(for: update)
        ) {
            $0.session?.evaluatedAt = now
            _ = $0.session?.remoteState?.apply(update)
        }

        #expect(store.state.session?.frame == nil)
        expectNoDifference(store.state.session?.freshness, .live)
        expectNoDifference(store.state.sessionPresentation, .live)
        #expect(!store.state.acceptsInput)
    }

    @Test("Accepted screenshot metadata is fresh but never authorizes input")
    func acceptedScreenshotDoesNotEnableInput() async {
        let fixture = MediaTruthFixture()
        let now = fixture.receivedAt.addingTimeInterval(0.25)
        let metadata = ScreenshotMetadata(
            generation: fixture.generation,
            receivedAt: fixture.receivedAt,
            pixelSize: fixture.pixelSize,
            orientation: .portrait
        )
        let update = fixture.update(for: .screenshot(metadata))
        let store = fixture.store(
            session: fixture.session(),
            now: now
        )

        await store.send(
            fixture.action(for: update)
        ) {
            $0.session?.evaluatedAt = now
            _ = $0.session?.remoteState?.apply(update)
        }

        #expect(store.state.session?.frame == nil)
        expectNoDifference(
            store.state.session?.freshness,
            .awaitingFirstImage
        )
        expectNoDifference(
            store.state.sessionPresentation,
            .connecting(.startingDisplay)
        )
        #expect(!store.state.acceptsInput)
    }

    @Test("Readiness events without media keep the session waiting")
    func readinessWithoutMediaDoesNotRevealOrAuthorize() async {
        let fixture = MediaTruthFixture()
        var session = fixture.session(isConnected: false)
        let hidReady = SessionUpdate(
            generation: fixture.generation,
            event: .hidReadinessChanged(.ready)
        )
        _ = session.remoteState?.apply(hidReady)
        let store = fixture.store(
            session: session,
            now: fixture.receivedAt
        )
        let ready = SessionUpdate(
            generation: fixture.generation,
            event: .phaseChanged(.ready)
        )

        await store.send(
            fixture.action(for: ready)
        ) {
            _ = $0.session?.remoteState?.apply(ready)
        }
        expectNoDifference(
            store.state.sessionPresentation,
            .connecting(.startingDisplay)
        )
        expectNoDifference(
            store.state.session?.freshness,
            .awaitingFirstImage
        )
        #expect(!store.state.acceptsInput)

        let displayReady = SessionUpdate(
            generation: fixture.generation,
            event: .displayReady
        )
        await store.send(fixture.action(for: displayReady))
        expectNoDifference(
            store.state.sessionPresentation,
            .connecting(.startingDisplay)
        )
        #expect(!store.state.acceptsInput)
    }

    @Test("A provisional screenshot waits for the native media outcome")
    func provisionalScreenshotWaitsForNativeMediaOutcome() async {
        let fixture = MediaTruthFixture()
        let metadata = ScreenshotMetadata(
            generation: fixture.generation,
            receivedAt: fixture.receivedAt,
            pixelSize: fixture.pixelSize,
            orientation: .portrait
        )
        var session = fixture.session(
            latestScreen: .screenshot(metadata)
        )
        session.evaluatedAt =
            fixture.receivedAt.addingTimeInterval(60)
        let store = fixture.store(
            session: session,
            now: fixture.receivedAt
        )

        expectNoDifference(
            store.state.session?.freshness,
            .awaitingFirstImage
        )
        expectNoDifference(
            store.state.sessionPresentation,
            .connecting(.startingDisplay)
        )
        #expect(!store.state.acceptsInput)

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
    }

    @Test("Stale and out-of-order metadata cannot replace media truth")
    func rejectsStaleAndOutOfOrderMetadata() async {
        let fixture = MediaTruthFixture()
        let current = fixture.frameMetadata(
            receivedAt: fixture.receivedAt.addingTimeInterval(1),
            sequenceNumber: 2
        )
        let session = fixture.session(
            latestScreen: .videoFrame(current)
        )
        let store = fixture.store(
            session: session,
            now: current.receivedAt
        )
        let staleGeneration = SessionGeneration(
            rawValue: MediaTruthFixture.uuid(99)
        )
        let stale = FrameMetadata(
            generation: staleGeneration,
            sequenceNumber: 3,
            receivedAt: current.receivedAt.addingTimeInterval(1),
            pixelSize: fixture.pixelSize,
            orientation: .portrait
        )
        let older = fixture.frameMetadata(
            receivedAt: fixture.receivedAt,
            sequenceNumber: 1
        )

        await store.send(
            fixture.action(
                for: SessionUpdate(
                    generation: staleGeneration,
                    event: .videoFrame(stale)
                )
            )
        )
        await store.send(
            fixture.action(for: fixture.update(for: .videoFrame(older)))
        )

        expectNoDifference(
            store.state.session?.remoteState?.latestScreen,
            .videoFrame(current)
        )
        expectNoDifference(store.state.session?.freshness, .live)
        #expect(store.state.session?.frame == nil)
    }

    @Test("Switching targets clears metadata, fallback pixels, and input")
    func targetSwitchClearsMediaTruth() async {
        let fixture = MediaTruthFixture()
        let second = fixture.device(id: "second")
        let current = fixture.frameMetadata(sequenceNumber: 1)
        let session = fixture.session(
            latestScreen: .videoFrame(current)
        )
        let nextAttemptID = MediaTruthFixture.uuid(44)
        let clock = TestClock()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(
                    devices: [fixture.device, second]
                ),
                selectedDeviceID: fixture.device.id,
                session: session
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = fixture.receivedAt
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
            $0.uuid = .constant(nextAttemptID)
        }

        await store.send(.deviceSelected(second.id)) {
            $0.selectedDeviceID = second.id
            $0.session = ActiveRemoteSession(
                attemptID: nextAttemptID,
                device: second,
                evaluatedAt: fixture.receivedAt
            )
        }
        expectNoDifference(
            store.state.session?.freshness,
            .awaitingFirstImage
        )
        #expect(store.state.session?.remoteState == nil)
        #expect(store.state.session?.frame == nil)
        #expect(!store.state.acceptsInput)

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
    }
}

private struct MediaTruthFixture {
    let attemptID = uuid(41)
    let device = DeviceSummary(
        id: DeviceID(rawValue: "first"),
        name: "Test iPhone",
        productType: "iPhone",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: .reachable
    )
    let generation = SessionGeneration(rawValue: uuid(42))
    let pixelSize = PixelSize(width: 1179, height: 2556)
    let receivedAt = Date(timeIntervalSince1970: 20000)
    let sessionID = DeviceSessionID(rawValue: uuid(43))

    func action(
        for update: SessionUpdate
    ) -> RemoteSessionFeature.Action {
        .sessionUpdateReceived(
            attemptID: attemptID,
            sessionID: sessionID,
            update: update
        )
    }

    func device(id: String) -> DeviceSummary {
        DeviceSummary(
            id: DeviceID(rawValue: id),
            name: "Test iPhone",
            productType: "iPhone",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .reachable
        )
    }

    func frameMetadata(
        receivedAt: Date? = nil,
        sequenceNumber: UInt64
    ) -> FrameMetadata {
        FrameMetadata(
            generation: generation,
            sequenceNumber: sequenceNumber,
            receivedAt: receivedAt ?? self.receivedAt,
            pixelSize: pixelSize,
            orientation: .portrait
        )
    }

    func session(
        isConnected: Bool = true,
        latestScreen: ScreenMetadata? = nil
    ) -> ActiveRemoteSession {
        var remoteState = RemoteSessionState(
            deviceID: device.id,
            generation: generation
        )
        if isConnected {
            _ = remoteState.apply(
                SessionUpdate(
                    generation: generation,
                    event: .phaseChanged(.ready)
                )
            )
        }
        _ = remoteState.apply(
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        )
        if let latestScreen {
            _ = remoteState.apply(update(for: latestScreen))
        }

        var session = ActiveRemoteSession(
            attemptID: attemptID,
            device: device,
            evaluatedAt: receivedAt
        )
        session.remoteState = remoteState
        session.sessionID = sessionID
        return session
    }

    @MainActor
    func store(
        session: ActiveRemoteSession,
        now: Date,
        clock: TestClock<Duration>? = nil
    ) -> TestStoreOf<RemoteSessionFeature> {
        let testClock = clock ?? TestClock()
        return TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: session
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = testClock
            $0.date.now = now
            $0.deviceHub.connect = { _ in
                try await testClock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }
    }

    func update(for metadata: ScreenMetadata) -> SessionUpdate {
        switch metadata {
        case let .screenshot(metadata):
            SessionUpdate(
                generation: generation,
                event: .screenshot(metadata)
            )
        case let .videoFrame(metadata):
            SessionUpdate(
                generation: generation,
                event: .videoFrame(metadata)
            )
        }
    }

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(
            uuid: (
                byte, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        )
    }
}
