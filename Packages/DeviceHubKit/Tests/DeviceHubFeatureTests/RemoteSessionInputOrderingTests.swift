import ComposableArchitecture
import CoreGraphics
import CustomDump
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session input ordering")
struct RemoteSessionInputOrderingTests {
    @Test("Touch trace milestones never contain screen coordinates")
    func touchTraceMilestonesAreCoordinateFree() {
        let message = DeviceHubFeatureTrace.Milestone.touchTap.message

        #expect(message == "input_geometry kind=touch_tap")
        #expect(!message.contains("123.456"))
        #expect(!message.contains("789.012"))
    }

    @Test("Semantic taps remain one command while transport is suspended")
    func semanticTapsRemainAtomicWhenTransportIsSuspended() async throws {
        let fixture = AtomicInputFixture()
        let recorder = SuspendingCommandRecorder()
        let store = try await fixture.readyStore(recorder: recorder)

        let buttonTask = await store.send(.buttonTapped(.home))
        await recorder.waitForCommandCount(1)
        let suspendedCommands = await recorder.snapshot()
        expectNoDifference(
            suspendedCommands,
            [.buttonTap(.home)]
        )

        await recorder.resumeFirst()
        await store.receive(\.commandFinished)
        await buttonTask.finish()
        let buttonCommands = await recorder.snapshot()
        expectNoDifference(
            buttonCommands,
            [.buttonTap(.home)]
        )

        let keyTask = await store.send(
            .keyTapped(.tab, modifiers: [.command, .shift])
        )
        await recorder.waitForCommandCount(2)
        await store.receive(\.commandFinished)
        await keyTask.finish()
        let keyCommands = await recorder.snapshot()
        expectNoDifference(
            keyCommands,
            [
                .buttonTap(.home),
                .keyTap(.tab, modifiers: [.command, .shift])
            ]
        )

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
        await recorder.waitForCommandCount(3)
        let finalCommands = await recorder.snapshot()
        expectNoDifference(
            finalCommands,
            [
                .buttonTap(.home),
                .keyTap(.tab, modifiers: [.command, .shift]),
                .releaseAllInput
            ]
        )
    }

    @Test("A static video frame preserves input until teardown")
    func staticVideoFramePreservesInputUntilTeardown() async throws {
        let fixture = AtomicInputFixture()
        let recorder = SuspendingCommandRecorder()
        let store = try await fixture.readyStore(recorder: recorder)

        let buttonTask = await store.send(.buttonTapped(.home))
        await recorder.waitForCommandCount(1)
        await recorder.resumeFirst()
        await store.receive(\.commandFinished)
        await buttonTask.finish()
        let commandsWhileStatic = await recorder.snapshot()
        expectNoDifference(
            commandsWhileStatic,
            [.buttonTap(.home)]
        )

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
        await recorder.waitForCommandCount(2)
        let teardownCommands = await recorder.snapshot()
        expectNoDifference(
            teardownCommands,
            [
                .buttonTap(.home),
                .releaseAllInput
            ]
        )
    }

    @Test("Touch edges wait for the preceding edge to finish")
    func touchEdgesRemainStrictlyOrderedWhileTransportIsSuspended() async throws {
        let fixture = AtomicInputFixture()
        let recorder = SuspendingCommandRecorder()
        let store = try await fixture.readyStore(recorder: recorder)
        let viewport = Viewport(
            origin: Point2D(x: 0, y: 0),
            size: Size2D(width: 2, height: 2)
        )

        let began = await store.send(
            .touch(
                contactID: 7,
                phase: .began,
                point: Point2D(x: 0, y: 0),
                viewport: viewport
            )
        ) {
            $0.activeContactIDs.insert(7)
        }
        await recorder.waitForCommandCount(1)
        let moved = await store.send(
            .touch(
                contactID: 7,
                phase: .moved,
                point: Point2D(x: 0.5, y: 0.5),
                viewport: viewport
            )
        )
        let ended = await store.send(
            .touch(
                contactID: 7,
                phase: .ended,
                point: Point2D(x: 1, y: 1),
                viewport: viewport
            )
        ) {
            $0.activeContactIDs.remove(7)
        }

        let commandsWhileBeganIsSuspended = await recorder.snapshot()
        expectNoDifference(
            commandsWhileBeganIsSuspended,
            [
                .touch(
                    TouchCommand(
                        contactID: 7,
                        point: TargetPixelPoint(x: 0, y: 0),
                        phase: .began
                    )
                )
            ]
        )

        await recorder.resumeFirst()
        await store.receive(\.commandFinished)
        await store.receive(\.commandFinished)
        await store.receive(\.commandFinished)
        await recorder.waitForCommandCount(3)
        await began.finish()
        await moved.finish()
        await ended.finish()
        let completedCommands = await recorder.snapshot()
        expectNoDifference(
            completedCommands,
            [
                .touch(
                    TouchCommand(
                        contactID: 7,
                        point: TargetPixelPoint(x: 0, y: 0),
                        phase: .began
                    )
                ),
                .touch(
                    TouchCommand(
                        contactID: 7,
                        point: TargetPixelPoint(x: 0.25, y: 0.25),
                        phase: .moved
                    )
                ),
                .touch(
                    TouchCommand(
                        contactID: 7,
                        point: TargetPixelPoint(x: 0.5, y: 0.5),
                        phase: .ended
                    )
                )
            ]
        )

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
        await recorder.waitForCommandCount(4)
    }
}

private struct AtomicInputFixture {
    let attemptID = uuid(50)
    let device = DeviceSummary(
        id: DeviceID(rawValue: "ordered"),
        name: "Test iPhone",
        productType: "iPhone",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: .reachable
    )
    let generation = SessionGeneration(rawValue: uuid(51))
    let sessionID = DeviceSessionID(rawValue: uuid(52))
    let time = Date(timeIntervalSince1970: 4750)

    @MainActor
    func readyStore(
        recorder: SuspendingCommandRecorder
    ) async throws -> TestStoreOf<RemoteSessionFeature> {
        let eventStream =
            AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let frameStream = AsyncStream<RemoteDisplayFrame>.makeStream()
        let transportSession = DeviceSession(
            id: sessionID,
            device: device,
            events: eventStream.stream,
            frames: frameStream.stream,
            command: { command in
                await recorder.record(command)
            },
            disconnect: {}
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

        await store.send(.availabilitySnapshotReceived([device])) {
            $0.roster = DeviceRoster(devices: [device])
            $0.selectedDeviceID = device.id
            $0.session = ActiveRemoteSession(
                attemptID: attemptID,
                device: device,
                evaluatedAt: time
            )
        }
        await store.receive(\.connectionResponse) {
            $0.session?.sessionID = sessionID
        }
        await sendReadiness(to: store)
        try await sendFrame(to: store)
        return store
    }

    @MainActor
    private func sendReadiness(
        to store: TestStoreOf<RemoteSessionFeature>
    ) async {
        let ready = SessionUpdate(
            generation: generation,
            event: .phaseChanged(.ready)
        )
        await store.send(action(ready)) {
            var remoteState = RemoteSessionState(
                deviceID: device.id,
                generation: generation
            )
            _ = remoteState.apply(ready)
            $0.session?.remoteState = remoteState
        }
        let hidReady = SessionUpdate(
            generation: generation,
            event: .hidReadinessChanged(.ready)
        )
        await store.send(action(hidReady)) {
            _ = $0.session?.remoteState?.apply(hidReady)
        }
    }

    @MainActor
    private func sendFrame(
        to store: TestStoreOf<RemoteSessionFeature>
    ) async throws {
        let frame = try makeFrame()
        await store.send(
            .frameReceived(
                attemptID: attemptID,
                sessionID: sessionID,
                frame: frame
            )
        ) {
            _ = $0.session?.remoteState?.apply(
                SessionUpdate(
                    generation: generation,
                    event: frame.metadata.event
                )
            )
            $0.session?.frame = frame
        }
    }

    private func action(
        _ update: SessionUpdate
    ) -> RemoteSessionFeature.Action {
        .sessionUpdateReceived(
            attemptID: attemptID,
            sessionID: sessionID,
            update: update
        )
    }

    private func makeFrame() throws -> RemoteDisplayFrame {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo:
                CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        return RemoteDisplayFrame(
            metadata: .videoFrame(
                FrameMetadata(
                    generation: generation,
                    sequenceNumber: 1,
                    receivedAt: time,
                    pixelSize: PixelSize(width: 2, height: 2),
                    orientation: .portrait
                )
            ),
            image: image
        )
    }
}

private actor SuspendingCommandRecorder {
    private var commands: [DeviceCommand] = []
    private var firstCommandContinuation:
        CheckedContinuation<Void, Never>?
    private var shouldSuspendFirstCommand = true
    private var waiters: [
        (
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []

    func record(_ command: DeviceCommand) async {
        commands.append(command)
        resumeSatisfiedWaiters()
        guard shouldSuspendFirstCommand else {
            return
        }
        shouldSuspendFirstCommand = false
        await withCheckedContinuation { continuation in
            firstCommandContinuation = continuation
        }
    }

    func resumeFirst() {
        firstCommandContinuation?.resume()
        firstCommandContinuation = nil
    }

    func snapshot() -> [DeviceCommand] {
        commands
    }

    func waitForCommandCount(_ count: Int) async {
        guard commands.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter {
            commands.count >= $0.count
        }
        waiters.removeAll {
            commands.count >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

private extension ScreenMetadata {
    var event: DeviceSessionEvent {
        switch self {
        case let .screenshot(metadata):
            .screenshot(metadata)
        case let .videoFrame(metadata):
            .videoFrame(metadata)
        }
    }
}

private func uuid(_ byte: UInt8) -> UUID {
    UUID(
        uuid: (
            byte, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    )
}
