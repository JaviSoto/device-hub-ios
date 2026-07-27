import DeviceHubCore
import Foundation
import IssueReporting

/// Identity of one transport generation and its generation-scoped resources.
///
/// Live clients use the same UUID for `DeviceSessionID` and
/// `SessionGeneration`. Reconnecting creates a new session identity so native
/// display surfaces and callbacks can never be reused across generations.
public struct DeviceSessionID: Equatable, Hashable, RawRepresentable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Connected-device façade with explicit lifetime and backpressure semantics.
///
/// `events` is an ordered, bounded control-plane stream and must never carry
/// frame pixels or other high-frequency payloads. Overflow is terminal rather
/// than silently losing a lifecycle transition. `frames` holds at most the
/// newest decoded image, so a slow renderer cannot delay lifecycle changes,
/// errors, or teardown. Calling ``disconnect()`` cancels both upstream streams
/// before invoking the transport teardown, and invokes that teardown at most
/// once even when several tasks disconnect concurrently. The standard stream
/// uses `Error` as its failure type, but live producers must finish it only with
/// sanitized `DeviceHubError` values.
public struct DeviceSession: Identifiable, Sendable {
    /// Generous guardrail for low-volume lifecycle updates.
    static let eventBufferLimit = 64

    public let device: DeviceSummary
    public let events: AsyncThrowingStream<SessionUpdate, Error>
    public let frames: AsyncStream<RemoteDisplayFrame>
    public let id: DeviceSessionID

    private let commandOperation:
        @Sendable (DeviceCommand) async throws -> Void
    private let disconnectOperation: @Sendable () async -> Void

    public init(
        id: DeviceSessionID,
        device: DeviceSummary,
        events sourceEvents: AsyncThrowingStream<SessionUpdate, Error>,
        frames sourceFrames: AsyncStream<RemoteDisplayFrame>,
        command: @escaping @Sendable (DeviceCommand) async throws -> Void,
        disconnect: @escaping @Sendable () async -> Void
    ) {
        let eventRelay = Self.makeEventRelay(sourceEvents)
        let frameRelay = Self.makeFrameRelay(sourceFrames)
        let lifetime = DeviceSessionLifetime(
            eventRelay: eventRelay.task,
            frameRelay: frameRelay.task,
            command: command,
            disconnect: disconnect
        )

        commandOperation = { command in
            try await lifetime.command(command)
        }
        self.device = device
        disconnectOperation = {
            await lifetime.disconnect()
        }
        events = eventRelay.stream
        frames = frameRelay.stream
        self.id = id
    }

    /// Forwards one semantic input command while the session remains active.
    public func command(_ command: DeviceCommand) async throws {
        try await commandOperation(command)
    }

    /// Stops observation and tears down the underlying transport exactly once.
    public func disconnect() async {
        await disconnectOperation()
    }

    /// Builds the ordered control-plane relay independently from frame pixels.
    static func makeEventRelay(
        _ source: AsyncThrowingStream<SessionUpdate, Error>
    ) -> (
        stream: AsyncThrowingStream<SessionUpdate, Error>,
        task: Task<Void, Never>
    ) {
        let pipe = AsyncThrowingStream<SessionUpdate, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(eventBufferLimit)
        )
        let task = Task {
            do {
                for try await update in source {
                    switch pipe.continuation.yield(update) {
                    case .enqueued:
                        break
                    case .dropped:
                        reportIssue(
                            "The lossless DeviceSession event stream dropped an update."
                        )
                        pipe.continuation.finish(
                            throwing: DeviceHubError.secureConnectionFailed
                        )
                        return
                    case .terminated:
                        return
                    @unknown default:
                        reportIssue(
                            "The DeviceSession event stream returned an unknown yield result."
                        )
                        pipe.continuation.finish(
                            throwing: DeviceHubError.secureConnectionFailed
                        )
                        return
                    }
                }
                pipe.continuation.finish()
            } catch is CancellationError where Task.isCancelled {
                pipe.continuation.finish()
            } catch let error as DeviceHubError {
                pipe.continuation.finish(throwing: error)
            } catch {
                reportIssue(
                    "The DeviceSession event source emitted an unsanitized error."
                )
                pipe.continuation.finish(
                    throwing: DeviceHubError.secureConnectionFailed
                )
            }
        }
        pipe.continuation.onTermination = { _ in
            task.cancel()
        }
        return (pipe.stream, task)
    }

    /// Builds the latest-only pixel relay independently from lifecycle events.
    static func makeFrameRelay(
        _ source: AsyncStream<RemoteDisplayFrame>
    ) -> (
        stream: AsyncStream<RemoteDisplayFrame>,
        task: Task<Void, Never>
    ) {
        let pipe = AsyncStream<RemoteDisplayFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            for await frame in source {
                switch pipe.continuation.yield(frame) {
                case .enqueued, .dropped:
                    break
                case .terminated:
                    return
                @unknown default:
                    reportIssue(
                        "The DeviceSession frame stream returned an unknown yield result."
                    )
                    pipe.continuation.finish()
                    return
                }
            }
            pipe.continuation.finish()
        }
        pipe.continuation.onTermination = { _ in
            task.cancel()
        }
        return (pipe.stream, task)
    }
}

/// Serializes the single terminal transition shared by all session copies.
private actor DeviceSessionLifetime {
    private enum State {
        case active
        case disconnecting(Task<Void, Never>)
        case disconnected
    }

    private let commandOperation:
        @Sendable (DeviceCommand) async throws -> Void
    private let disconnectOperation: @Sendable () async -> Void
    private let eventRelay: Task<Void, Never>
    private let frameRelay: Task<Void, Never>
    private var state = State.active

    init(
        eventRelay: Task<Void, Never>,
        frameRelay: Task<Void, Never>,
        command: @escaping @Sendable (DeviceCommand) async throws -> Void,
        disconnect: @escaping @Sendable () async -> Void
    ) {
        commandOperation = command
        disconnectOperation = disconnect
        self.eventRelay = eventRelay
        self.frameRelay = frameRelay
    }

    deinit {
        eventRelay.cancel()
        frameRelay.cancel()
    }

    func command(_ command: DeviceCommand) async throws {
        guard case .active = state else {
            throw DeviceHubError.connectionLost
        }
        try await commandOperation(command)
    }

    func disconnect() async {
        let task: Task<Void, Never>
        switch state {
        case .active:
            let eventRelay = eventRelay
            let frameRelay = frameRelay
            let disconnectOperation = disconnectOperation
            task = Task {
                eventRelay.cancel()
                frameRelay.cancel()
                await eventRelay.value
                await frameRelay.value
                await disconnectOperation()
            }
            state = .disconnecting(task)

        case let .disconnecting(existingTask):
            task = existingTask

        case .disconnected:
            return
        }

        await task.value
        state = .disconnected
    }
}
