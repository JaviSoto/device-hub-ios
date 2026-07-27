import DeviceHubPrivateMedia
import Foundation

/// One-time routing bridge created before either side of a native session.
///
/// AVConference handlers capture this relay weakly. Binding closures later
/// avoids a receiver/context ownership cycle while preserving callback order.
final class DeviceHubNativeSessionRelay: @unchecked Sendable {
    typealias ReceiverEventHandler =
        @Sendable (DHAVConferenceReceiverEvent) -> Void
    typealias VideoNegotiationHandler = @Sendable (Bool) -> Void
    typealias VideoControlHandler = @Sendable (Data) -> Void

    private struct Handlers {
        var receiverEvent: ReceiverEventHandler?
        var videoControl: VideoControlHandler?
        var videoNegotiation: VideoNegotiationHandler?
    }

    private let lock = NSLock()
    private var handlers = Handlers()

    /// Installs both routes exactly once.
    func bind(
        receiverEvent: @escaping ReceiverEventHandler,
        videoControl: @escaping VideoControlHandler,
        videoNegotiation: @escaping VideoNegotiationHandler
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard
            handlers.receiverEvent == nil,
            handlers.videoControl == nil,
            handlers.videoNegotiation == nil
        else {
            return false
        }
        handlers.receiverEvent = receiverEvent
        handlers.videoControl = videoControl
        handlers.videoNegotiation = videoNegotiation
        return true
    }

    func receive(_ event: DHAVConferenceReceiverEvent) {
        let operation = lock.withLock {
            handlers.receiverEvent
        }
        operation?(event)
    }

    func sendVideoControl(_ data: Data) {
        let operation = lock.withLock {
            handlers.videoControl
        }
        operation?(data)
    }

    func completeVideoNegotiation(succeeded: Bool) {
        let operation = lock.withLock {
            handlers.videoNegotiation
        }
        operation?(succeeded)
    }

    func unbind() {
        lock.withLock {
            handlers = Handlers()
        }
    }
}

/// Serial, single-use wrapper around one retained AVConference receiver.
///
/// Offer creation, answer configuration, start, datagram ingestion, and
/// invalidation all execute on the receiver's callback queue. The wrapper owns
/// no Rust handle and never calls back into session teardown.
struct DeviceHubAVConferenceSession: @unchecked Sendable {
    struct Operations: @unchecked Sendable {
        let configureAndStart: (Data) throws -> Void
        let ingest: (Data) throws -> Void
        let invalidate: () -> Void
        let makeOffer: () throws -> Data
    }

    private let operations: Operations

    init(operations: Operations) {
        self.operations = operations
    }

    static func live(
        relay: DeviceHubNativeSessionRelay,
        queueLabel: String
    ) throws -> Self {
        try AVConferenceReceiver.validateRuntimeContract()

        let queue = DispatchQueue(label: queueLabel)
        let receiver = AVConferenceReceiver(
            callbackQueue: queue,
            outboundDatagramHandler: { [weak relay] datagram in
                relay?.sendVideoControl(datagram)
            },
            eventHandler: { [weak relay] event, error in
                traceReceiverFailure(event: event, error: error)
                relay?.receive(event)
            }
        )
        return Self(
            operations: Operations(
                configureAndStart: { answer in
                    try queue.sync {
                        try receiver.configure(
                            withNegotiatorAnswer: answer
                        )
                        try receiver.start()
                    }
                },
                ingest: { datagram in
                    try queue.sync {
                        try receiver.ingestInboundDatagram(datagram)
                    }
                },
                invalidate: {
                    queue.sync {
                        receiver.invalidate()
                    }
                },
                makeOffer: {
                    try queue.sync {
                        try receiver.makeNegotiatorOffer()
                    }
                }
            )
        )
    }

    func configureAndStart(answer: Data) throws {
        try operations.configureAndStart(answer)
    }

    func ingest(_ datagram: Data) throws {
        try operations.ingest(datagram)
    }

    func invalidate() {
        operations.invalidate()
    }

    func makeOffer() throws -> Data {
        try operations.makeOffer()
    }
}

/// Emits only AVConference's documented error classification when an attached
/// device console explicitly enables live protocol tracing.
private func traceReceiverFailure(
    event: DHAVConferenceReceiverEvent,
    error: (any Error)?
) {
    guard
        ProcessInfo.processInfo.environment[
            "DEVICE_HUB_BOOTSTRAP_TRACE"
        ] == "1",
        let error
    else {
        return
    }
    let nativeError = error as NSError
    let operation =
        nativeError.userInfo[DHAVConferenceErrorOperationKey] as? String
            ?? "none"
    let underlyingDomain =
        nativeError.userInfo[
            DHAVConferenceErrorUnderlyingDomainKey
        ] as? String ?? "none"
    let underlyingCode =
        nativeError.userInfo[
            DHAVConferenceErrorUnderlyingCodeKey
        ] as? NSNumber
    FileHandle.standardOutput.write(
        Data(
            (
                "devicehub.avconference event="
                    + String(describing: event)
                    + " domain="
                    + nativeError.domain
                    + " code="
                    + String(nativeError.code)
                    + " operation="
                    + operation
                    + " underlying_domain="
                    + underlyingDomain
                    + " underlying_code="
                    + String(underlyingCode?.intValue ?? 0)
                    + "\n"
            ).utf8
        )
    )
}
