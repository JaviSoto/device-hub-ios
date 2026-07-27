import ComposableArchitecture
import CoreGraphics
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

struct RotationSessionTestContext {
    let time: Date
    let device: DeviceSummary
    let attemptID: UUID
    let sessionID: DeviceSessionID
    let generation: SessionGeneration
}

@MainActor
func establishInputReadyRotationSession(
    in store: TestStoreOf<RemoteSessionFeature>,
    context: RotationSessionTestContext
) async throws {
    await store.send(.availabilitySnapshotReceived([context.device])) {
        $0.roster = DeviceRoster(devices: [context.device])
        $0.selectedDeviceID = context.device.id
        $0.session = ActiveRemoteSession(
            attemptID: context.attemptID,
            device: context.device,
            evaluatedAt: context.time
        )
    }
    await store.receive(\.connectionResponse) {
        $0.session?.sessionID = context.sessionID
    }

    let ready = SessionUpdate(
        generation: context.generation,
        event: .phaseChanged(.ready)
    )
    await store.send(
        .sessionUpdateReceived(
            attemptID: context.attemptID,
            sessionID: context.sessionID,
            update: ready
        )
    ) {
        var remoteState = RemoteSessionState(
            deviceID: context.device.id,
            generation: context.generation
        )
        _ = remoteState.apply(ready)
        $0.session?.remoteState = remoteState
    }

    let hidReady = SessionUpdate(
        generation: context.generation,
        event: .hidReadinessChanged(.ready)
    )
    await store.send(
        .sessionUpdateReceived(
            attemptID: context.attemptID,
            sessionID: context.sessionID,
            update: hidReady
        )
    ) {
        _ = $0.session?.remoteState?.apply(hidReady)
    }

    let frame = try remoteFrame(
        generation: context.generation,
        receivedAt: context.time,
        sequenceNumber: 1,
        pixelSize: PixelSize(width: 100, height: 200)
    )
    await store.send(
        .frameReceived(
            attemptID: context.attemptID,
            sessionID: context.sessionID,
            frame: frame
        )
    ) {
        _ = $0.session?.remoteState?.apply(
            SessionUpdate(
                generation: context.generation,
                event: frame.metadata.sessionEventForTesting
            )
        )
        $0.session?.frame = frame
    }
    #expect(store.state.acceptsInput)
}

func connectedSession(
    device: DeviceSummary,
    receivedAt: Date
) throws -> ActiveRemoteSession {
    let attemptID = fixtureUUID(10)
    let generation = SessionGeneration(rawValue: fixtureUUID(11))
    let sessionID = DeviceSessionID(rawValue: fixtureUUID(12))
    let frame = try remoteFrame(
        generation: generation,
        receivedAt: receivedAt,
        sequenceNumber: 1
    )
    var remoteState = RemoteSessionState(
        deviceID: device.id,
        generation: generation
    )
    _ = remoteState.apply(
        SessionUpdate(
            generation: generation,
            event: .phaseChanged(.ready)
        )
    )
    _ = remoteState.apply(
        SessionUpdate(
            generation: generation,
            event: .hidReadinessChanged(.ready)
        )
    )
    _ = remoteState.apply(
        SessionUpdate(
            generation: generation,
            event: frame.metadata.sessionEventForTesting
        )
    )

    var session = ActiveRemoteSession(
        attemptID: attemptID,
        device: device,
        evaluatedAt: receivedAt
    )
    session.frame = frame
    session.remoteState = remoteState
    session.sessionID = sessionID
    return session
}

func device(
    id: String,
    name: String,
    reachability: DeviceReachability = .reachable
) -> DeviceSummary {
    DeviceSummary(
        id: DeviceID(rawValue: id),
        name: name,
        productType: "iPhone",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: reachability
    )
}

func remoteFrame(
    generation: SessionGeneration,
    receivedAt: Date,
    sequenceNumber: UInt64,
    pixelSize: PixelSize = PixelSize(width: 2, height: 2),
    orientation: ScreenOrientation = .portrait
) throws -> RemoteDisplayFrame {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    let image = try #require(context.makeImage())
    return RemoteDisplayFrame(
        metadata: .videoFrame(
            FrameMetadata(
                generation: generation,
                sequenceNumber: sequenceNumber,
                receivedAt: receivedAt,
                pixelSize: pixelSize,
                orientation: orientation
            )
        ),
        image: image
    )
}

extension ScreenMetadata {
    var sessionEventForTesting: DeviceSessionEvent {
        switch self {
        case let .screenshot(metadata):
            .screenshot(metadata)
        case let .videoFrame(metadata):
            .videoFrame(metadata)
        }
    }
}

func fixtureUUID(_ byte: UInt8) -> UUID {
    UUID(
        uuid: (
            byte, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    )
}

func transportSession(
    id: DeviceSessionID,
    device: DeviceSummary,
    events: AsyncThrowingStream<SessionUpdate, Error>,
    frames: AsyncStream<RemoteDisplayFrame>,
    recorder: SessionRecorder
) -> DeviceSession {
    DeviceSession(
        id: id,
        device: device,
        events: events,
        frames: frames,
        command: { command in
            await recorder.record(command)
        },
        disconnect: {
            await recorder.recordDisconnect()
        }
    )
}

actor SessionRecorder {
    private var commandValues: [DeviceCommand] = []
    private var commandWaiters: [
        (
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []
    private var disconnectContinuations: [
        CheckedContinuation<Void, Never>
    ] = []
    private var disconnectValue = 0

    func commands() -> [DeviceCommand] {
        commandValues
    }

    func disconnectCount() -> Int {
        disconnectValue
    }

    func record(_ command: DeviceCommand) {
        commandValues.append(command)
        let completedWaiters = commandWaiters.filter {
            commandValues.count >= $0.count
        }
        commandWaiters.removeAll {
            commandValues.count >= $0.count
        }
        for waiter in completedWaiters {
            waiter.continuation.resume()
        }
    }

    func recordDisconnect() {
        disconnectValue += 1
        let continuations = disconnectContinuations
        disconnectContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForCommandCount(_ count: Int) async {
        guard commandValues.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            commandWaiters.append((count, continuation))
        }
    }

    func waitForDisconnect() async {
        guard disconnectValue == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            disconnectContinuations.append(continuation)
        }
    }
}
