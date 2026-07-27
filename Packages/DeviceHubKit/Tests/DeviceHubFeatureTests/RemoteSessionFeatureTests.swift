import ComposableArchitecture
import CoreGraphics
import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session feature")
struct RemoteSessionFeatureTests {
    @Test("A known selection survives a temporary offline snapshot")
    func preservesKnownOfflineSelection() async {
        let selected = device(
            id: "selected",
            name: "Test iPhone",
            reachability: .reachable
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [selected]),
                selectedDeviceID: selected.id
            )
        ) {
            RemoteSessionFeature()
        }

        var offline = selected
        offline.reachability = .unavailable

        await store.send(
            .availabilitySnapshotReceived([offline])
        ) {
            $0.roster = DeviceRoster(devices: [offline])
        }
    }

    @Test("Switching targets clears old pixels before the next connection")
    func switchingClearsOldPixelsSynchronously() async throws {
        let first = device(id: "first", name: "Test iPhone")
        let second = device(id: "second", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 1000)
        let current = try connectedSession(
            device: first,
            receivedAt: time
        )
        let nextAttemptID = fixtureUUID(1)
        let clock = TestClock()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [first, second]),
                selectedDeviceID: first.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
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
                evaluatedAt: time
            )
        }
        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
    }

    @Test("Stale attempts and generations cannot replace the visible frame")
    func rejectsStaleFrames() async throws {
        let time = Date(timeIntervalSince1970: 2000)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(
            device: device,
            receivedAt: time
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.date.now = time
        }

        let staleFrame = try remoteFrame(
            generation: SessionGeneration(rawValue: fixtureUUID(90)),
            receivedAt: time.addingTimeInterval(1),
            sequenceNumber: 2
        )
        try await store.send(
            .frameReceived(
                attemptID: fixtureUUID(91),
                sessionID: #require(current.sessionID),
                frame: staleFrame
            )
        )
        try await store.send(
            .frameReceived(
                attemptID: current.attemptID,
                sessionID: #require(current.sessionID),
                frame: staleFrame
            )
        )
        expectNoDifference(
            store.state.session?.frame?.metadata,
            current.frame?.metadata
        )
    }

    @Test("A static video frame stays live until the transport ends")
    func staticVideoFrameDoesNotReconnect() async throws {
        let receivedAt = Date(timeIntervalSince1970: 3000)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(
            device: device,
            receivedAt: receivedAt
        )
        var agedSession = current
        agedSession.evaluatedAt =
            receivedAt.addingTimeInterval(60)
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: agedSession
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.date.now = receivedAt
        }
        #expect(store.state.acceptsInput)

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
    }

    @Test("Unsafe input and rotation never reach the client")
    func gatesUnsafeInputAndRotation() async throws {
        let time = Date(timeIntervalSince1970: 4000)
        let device = device(id: "device", name: "Test iPhone")
        var current = try connectedSession(
            device: device,
            receivedAt: time
        )
        current.frame = nil
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.date.now = time
        }

        await store.send(.rotateRightButtonTapped)
        await store.send(
            .tap(
                point: Point2D(x: 50, y: 100),
                viewport: Viewport(
                    origin: Point2D(x: 0, y: 0),
                    size: Size2D(width: 100, height: 200)
                )
            )
        )
    }

    @Test("Safe rotation does not relabel the current frame before media rotates")
    func sendsRotationAndStopsTheActiveSession() async throws {
        let time = Date(timeIntervalSince1970: 4500)
        let device = device(id: "device", name: "Test iPhone")
        let attemptID = fixtureUUID(20)
        let sessionID = DeviceSessionID(rawValue: fixtureUUID(21))
        let generation = SessionGeneration(rawValue: fixtureUUID(22))
        let context = RotationSessionTestContext(
            time: time,
            device: device,
            attemptID: attemptID,
            sessionID: sessionID,
            generation: generation
        )
        let events = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let frames = AsyncStream<RemoteDisplayFrame>.makeStream()
        let recorder = SessionRecorder()
        let transportSession = transportSession(
            id: sessionID,
            device: device,
            events: events.stream,
            frames: frames.stream,
            recorder: recorder
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = time
            $0.deviceHub.connect = { _ in transportSession }
            $0.uuid = .constant(attemptID)
        }

        try await establishInputReadyRotationSession(
            in: store,
            context: context
        )

        await store.send(.rotateRightButtonTapped)
        await recorder.waitForCommandCount(1)
        let commands = await recorder.commands()
        expectNoDifference(
            commands,
            [.rotation(.rotateRight)]
        )
        await store.receive(\.commandFinished)
        #expect(store.state.session?.frame?.metadata.orientation == .portrait)

        await store.send(
            .tap(
                point: Point2D(x: 150, y: 100),
                viewport: Viewport(
                    origin: Point2D(x: 0, y: 0),
                    size: Size2D(width: 200, height: 400)
                )
            )
        )
        await recorder.waitForCommandCount(2)
        let commandsAfterTap = await recorder.commands()
        #expect(commandsAfterTap.count == 2)
        expectNoDifference(
            commandsAfterTap,
            [
                .rotation(.rotateRight),
                .tap(TargetPixelPoint(x: 74.25, y: 49.75))
            ]
        )
        await store.receive(\.commandFinished)

        await store.send(.stopViewingButtonTapped) {
            $0.isViewingStopped = true
            $0.session = nil
        }
        await recorder.waitForDisconnect()
        let disconnectCount = await recorder.disconnectCount()
        expectNoDifference(disconnectCount, 1)
    }

    @Test("Current stream failures expose deterministic remediation")
    func mapsSessionErrorsToRemediation() async throws {
        let time = Date(timeIntervalSince1970: 5000)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(
            device: device,
            receivedAt: time
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        }
        let sessionID = try #require(current.sessionID)
        let errors: [DeviceHubError] = [
            .localNetworkDenied,
            .deviceLocked,
            .developerModeDisabled,
            .deviceBusy,
            .developerImageUnavailable,
            .deviceOffline,
            .decoderFailed,
            .mediaStalled
        ]

        for error in errors {
            await store.send(
                .sessionStreamFailed(
                    attemptID: current.attemptID,
                    sessionID: sessionID,
                    error: error
                )
            ) {
                $0.remediation = DeviceHubRemediation(error: error)
                $0.session?.connectionError = error
            }
        }
    }

    @Test("Backgrounding clears pixels, pairing codes, and held input")
    func backgroundClearsSensitiveState() async throws {
        let time = Date(timeIntervalSince1970: 6000)
        let device = device(id: "device", name: "Test iPhone")
        let code = try #require(PairingCode("123456"))
        let session = try connectedSession(
            device: device,
            receivedAt: time
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                activeContactIDs: [1, 2],
                pairing: PairingFeature.State(
                    phase: .waitingForCodeEntry(code)
                ),
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: session
            )
        ) {
            RemoteSessionFeature()
        }

        await store.send(.appLifecycleChanged(.background)) {
            $0.activeContactIDs = []
            $0.lifecycle = .background
            $0.pairing = nil
            $0.session = nil
        }
    }

    @Test("Stop viewing is explicit and does not lose selection")
    func stopViewing() async throws {
        let time = Date(timeIntervalSince1970: 7000)
        let device = device(id: "device", name: "Test iPhone")
        let session = try connectedSession(
            device: device,
            receivedAt: time
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: session
            )
        ) {
            RemoteSessionFeature()
        }

        await store.send(.stopViewingButtonTapped) {
            $0.isViewingStopped = true
            $0.session = nil
        }
        expectNoDifference(store.state.selectedDeviceID, device.id)
        #expect(store.state.sessionPresentation == nil)
    }
}
