import CoreGraphics
import CustomDump
@testable import DeviceHubClient
import DeviceHubCore
import Foundation
import IssueReporting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DeviceSessionTests {
    @Test
    func forwardsCommandsInOrder() async throws {
        let recorder = CommandRecorder()
        let session = DeviceSession.fixture { command in
            await recorder.record(command)
        }
        let commands: [DeviceCommand] = [
            .button(.home, phase: .press),
            .button(.home, phase: .release),
            .key(
                KeyCommand(
                    key: .character("h"),
                    phase: .press
                )
            )
        ]

        for command in commands {
            try await session.command(command)
        }

        let recordedCommands = await recorder.snapshot()
        expectNoDifference(recordedCommands, commands)
    }

    @Test
    func disconnectIsIdempotentAcrossConcurrentAndSequentialCallers() async {
        let probe = DisconnectProbe()
        let session = DeviceSession.fixture(disconnect: {
            await probe.run()
        })

        let tasks = (0 ..< 8).map { _ in
            Task {
                await session.disconnect()
            }
        }

        await probe.waitUntilStarted()
        let callCountWhileSuspended = await probe.snapshot()
        expectNoDifference(callCountWhileSuspended, 1)
        await probe.complete()

        for task in tasks {
            await task.value
        }
        await session.disconnect()

        let finalCallCount = await probe.snapshot()
        expectNoDifference(finalCallCount, 1)
    }

    @Test
    func commandsAfterDisconnectFailWithoutReachingTheTransport() async {
        let recorder = CommandRecorder()
        let session = DeviceSession.fixture { command in
            await recorder.record(command)
        }
        await session.disconnect()

        do {
            try await session.command(.button(.lock, phase: .press))
            Issue.record("A disconnected session accepted an input command.")
        } catch let error as DeviceHubError {
            expectNoDifference(error, .connectionLost)
        } catch {
            Issue.record("Unexpected command error: \(error)")
        }

        let recordedCommands = await recorder.snapshot()
        expectNoDifference(recordedCommands, [])
    }

    @Test
    func eventsPreserveOrder() async throws {
        let generation = SessionGeneration.fixture()
        let eventSource = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let session = DeviceSession.fixture(
            events: eventSource.stream
        )
        let expectedEvents: [SessionUpdate] = [
            SessionUpdate(
                generation: generation,
                event: .phaseChanged(.locating)
            ),
            SessionUpdate(
                generation: generation,
                event: .phaseChanged(.verifyingPairing)
            ),
            SessionUpdate(
                generation: generation,
                event: .phaseChanged(.openingTunnel)
            )
        ]

        for event in expectedEvents {
            eventSource.continuation.yield(event)
        }
        eventSource.continuation.finish()

        var receivedEvents: [SessionUpdate] = []
        for try await event in session.events {
            receivedEvents.append(event)
        }

        expectNoDifference(receivedEvents, expectedEvents)
    }

    @Test
    func eventOverflowFailsTerminallyWithoutLosingTheBufferedPrefix() async {
        await withExpectedIssue {
            let generation = SessionGeneration.fixture()
            let source = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
            let relay = DeviceSession.makeEventRelay(source.stream)
            let updates = (0 ... DeviceSession.eventBufferLimit).map { index in
                SessionUpdate(
                    generation: generation,
                    event: .deviceInfoUpdated(
                        .fixture(name: "Device \(index)")
                    )
                )
            }

            for update in updates {
                source.continuation.yield(update)
            }
            source.continuation.finish()
            await relay.task.value

            var received: [SessionUpdate] = []
            do {
                for try await update in relay.stream {
                    received.append(update)
                }
                Issue.record("An overflowing event relay terminated successfully.")
            } catch let error as DeviceHubError {
                expectNoDifference(error, .secureConnectionFailed)
            } catch {
                Issue.record("Unexpected event-overflow error: \(error)")
            }

            expectNoDifference(
                received,
                Array(updates.prefix(DeviceSession.eventBufferLimit))
            )
        }
    }

    @Test
    func framesCoalesceToNewestWithoutBackpressuringLifecycleEvents() async throws {
        let generation = SessionGeneration.fixture()
        let source = AsyncStream<RemoteDisplayFrame>.makeStream()
        let relay = DeviceSession.makeFrameRelay(source.stream)
        let frames = try [
            RemoteDisplayFrame.fixture(
                generation: generation,
                sequenceNumber: 1,
                image: makeImage(red: 1)
            ),
            RemoteDisplayFrame.fixture(
                generation: generation,
                sequenceNumber: 2,
                image: makeImage(red: 2)
            ),
            RemoteDisplayFrame.fixture(
                generation: generation,
                sequenceNumber: 3,
                image: makeImage(red: 3)
            )
        ]

        for frame in frames {
            source.continuation.yield(frame)
        }
        source.continuation.finish()
        await relay.task.value

        var receivedFrames: [RemoteDisplayFrame] = []
        for await frame in relay.stream {
            receivedFrames.append(frame)
        }

        expectNoDifference(
            receivedFrames.map(\.metadata),
            [frames[2].metadata]
        )
    }

    @Test
    func frameDescriptionRedactsPixelPayload() throws {
        let frame = try RemoteDisplayFrame.fixture(
            sequenceNumber: 1,
            image: makeImage(red: 255)
        )

        expectNoDifference(
            String(reflecting: frame),
            "RemoteDisplayFrame(<redacted>)"
        )
        #expect(!String(customDumping: frame).contains("CGImage"))
    }

    @Test
    func disconnectTerminatesBothStreamsBeforeReturning() async {
        let eventTermination = TerminationRecorder<
            AsyncThrowingStream<SessionUpdate, Error>.Continuation.Termination
        >()
        let frameTermination = TerminationRecorder<
            AsyncStream<RemoteDisplayFrame>.Continuation.Termination
        >()
        let eventSource = AsyncThrowingStream<SessionUpdate, Error> { continuation in
            continuation.onTermination = { termination in
                Task {
                    await eventTermination.record(termination)
                }
            }
        }
        let frameSource = AsyncStream<RemoteDisplayFrame> { continuation in
            continuation.onTermination = { termination in
                Task {
                    await frameTermination.record(termination)
                }
            }
        }
        let session = DeviceSession.fixture(events: eventSource, frames: frameSource)

        let eventConsumer = Task {
            for try await _ in session.events {}
        }
        let frameConsumer = Task {
            for await _ in session.frames {}
        }
        await Task.yield()

        await session.disconnect()
        do {
            try await eventConsumer.value
        } catch {
            Issue.record("Unexpected event-consumer error during disconnect: \(error)")
        }
        await frameConsumer.value

        let eventTerminationReason = await eventTermination.snapshot()
        let frameTerminationReason = await frameTermination.snapshot()
        #expect(eventTerminationReason != nil)
        #expect(frameTerminationReason != nil)
    }

    @Test
    func consumerCancellationPropagatesToUpstreamEventSource() async {
        let termination = TerminationRecorder<
            AsyncThrowingStream<SessionUpdate, Error>.Continuation.Termination
        >()
        let eventSource = AsyncThrowingStream<SessionUpdate, Error> { continuation in
            continuation.onTermination = { reason in
                Task {
                    await termination.record(reason)
                }
            }
        }
        let session = DeviceSession.fixture(events: eventSource)
        let consumer = Task {
            for try await _ in session.events {}
        }
        await Task.yield()

        consumer.cancel()
        do {
            try await consumer.value
        } catch is CancellationError {
            // Expected when cancellation reaches the upstream source.
        } catch {
            Issue.record("Unexpected event-consumer cancellation error: \(error)")
        }

        await termination.waitUntilRecorded()
        let terminationReason = await termination.snapshot()
        #expect(terminationReason != nil)
    }

    @Test
    func upstreamEventFailureIsForwardedAndTerminatesWithoutAffectingFrames() async throws {
        let eventSource = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let frameSource = AsyncStream<RemoteDisplayFrame>.makeStream()
        let session = DeviceSession.fixture(
            events: eventSource.stream,
            frames: frameSource.stream
        )
        let frame = try RemoteDisplayFrame.fixture(
            sequenceNumber: 42,
            image: makeImage(red: 42)
        )

        eventSource.continuation.finish(throwing: DeviceHubError.connectionLost)
        frameSource.continuation.yield(frame)
        frameSource.continuation.finish()

        do {
            for try await _ in session.events {}
            Issue.record("Expected the event stream to fail.")
        } catch let error as DeviceHubError {
            expectNoDifference(error, .connectionLost)
        } catch {
            Issue.record("Unexpected event-stream error: \(error)")
        }

        var frames: [RemoteDisplayFrame] = []
        for await receivedFrame in session.frames {
            frames.append(receivedFrame)
        }
        expectNoDifference(frames.map(\.metadata), [frame.metadata])
    }

    @Test
    func unexpectedUpstreamEventFailureIsSanitized() async {
        await withExpectedIssue {
            let source = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
            let relay = DeviceSession.makeEventRelay(source.stream)

            source.continuation.finish(throwing: UnexpectedUpstreamError())

            do {
                for try await _ in relay.stream {}
                Issue.record("Expected the event stream to fail.")
            } catch let error as DeviceHubError {
                expectNoDifference(error, .secureConnectionFailed)
            } catch {
                Issue.record("Unexpected sanitized event-stream error: \(error)")
            }
        }
    }
}

private struct UnexpectedUpstreamError: Error {}

private actor CommandRecorder {
    private(set) var commands: [DeviceCommand] = []

    func record(_ command: DeviceCommand) {
        commands.append(command)
    }

    func snapshot() -> [DeviceCommand] {
        commands
    }
}

private actor DisconnectProbe {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while callCount == 0 {
            await Task.yield()
        }
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }

    func snapshot() -> Int {
        callCount
    }
}

private actor TerminationRecorder<Value: Sendable> {
    private(set) var value: Value?

    func record(_ value: Value) {
        self.value = value
    }

    func waitUntilRecorded() async {
        while value == nil {
            await Task.yield()
        }
    }

    func snapshot() -> Value? {
        value
    }
}

private func makeImage(red: UInt8) throws -> CGImage {
    var pixel = [red, 0, 0, UInt8.max]
    let data = Data(bytes: &pixel, count: pixel.count)
    let provider = try #require(CGDataProvider(data: data as CFData))
    return try #require(
        CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    )
}
