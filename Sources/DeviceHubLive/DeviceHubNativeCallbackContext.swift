import DeviceHubClient
import DeviceHubCore
import DeviceHubFFI
import DeviceHubPrivateMedia
import DeviceHubTransport
import Foundation
import OSLog

/// Emits opt-in native callback milestones without retaining device or media
/// payloads in the process log.
enum DeviceHubNativeTrace {
    static func emit(_ message: String) {
        guard
            ProcessInfo.processInfo.environment[
                "DEVICE_HUB_BOOTSTRAP_TRACE"
            ] == "1"
        else {
            return
        }
        FileHandle.standardOutput.write(
            Data("devicehub.native \(message)\n".utf8)
        )
    }
}

/// Session-scoped state recovered from both noncapturing C callbacks.
///
/// The context never owns or frees the native handle. It copies borrowed
/// values synchronously, routes media, and suppresses every callback once
/// teardown begins.
final class DeviceHubNativeCallbackContext: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DeviceHub",
        category: "native-session"
    )

    private let avConference: DeviceHubAVConferenceSession?
    private var controlDecoder: DeviceHubNativeEventDecoder
    private let controlContinuation:
        AsyncThrowingStream<NativeSessionEvent, Error>.Continuation
    private var currentGeometry: NativeDisplayGeometry?
    private let generation: SessionGeneration
    private var isClosing = false
    private var isTerminal = false
    private let lock = NSLock()
    private var mediaDecoder: DeviceHubNativeMediaEventDecoder?
    private var mediaParameterSetRevision: UInt64?
    private let now: @Sendable () -> Date
    private let relay: DeviceHubNativeSessionRelay
    private var tracedAccessUnitCount = 0
    private var tracedDiscontinuityCount = 0
    private let videoBridge: NativeVideoEventBridge?

    init(
        generation: SessionGeneration,
        controlContinuation:
        AsyncThrowingStream<NativeSessionEvent, Error>.Continuation,
        relay: DeviceHubNativeSessionRelay,
        avConference: DeviceHubAVConferenceSession? = nil,
        videoBridge: NativeVideoEventBridge? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.avConference = avConference
        controlDecoder = DeviceHubNativeEventDecoder(
            generation: generation
        )
        self.controlContinuation = controlContinuation
        self.generation = generation
        mediaDecoder =
            avConference != nil || videoBridge != nil
                ? DeviceHubNativeMediaEventDecoder(generation: generation)
                : nil
        self.now = now
        self.relay = relay
        self.videoBridge = videoBridge
    }

    func handleControl(_ event: UnsafePointer<DhEvent>?) {
        if let native = event?.pointee {
            DeviceHubNativeTrace.emit(
                "control_callback sequence=\(native.sequence) "
                    + "kind=\(native.kind) state=\(native.state) "
                    + "phase=\(native.phase)"
            )
        } else {
            DeviceHubNativeTrace.emit("control_callback pointer=nil")
        }
        let decoded: DeviceHubNativeControlEvent?
        do {
            decoded = try lock.withLock {
                guard !isClosing, !isTerminal else {
                    return nil
                }
                return try controlDecoder.decodeControl(event)
            }
        } catch {
            DeviceHubNativeTrace.emit(
                "control_decode_failed reason=\(String(describing: error))"
            )
            Self.logger.error(
                "Control callback decoding failed"
            )
            fail(nativeDispatchFailure)
            return
        }
        guard let decoded else {
            return
        }

        switch decoded {
        case let .event(event):
            if case let .displayGeometry(geometry) = event {
                lock.withLock {
                    currentGeometry = geometry
                }
            }
            switch event {
            case .cancelled, .completed, .failed:
                finish(with: event)
            default:
                emit(event)
            }

        case let .videoNegotiationAnswer(answer):
            guard let avConference else {
                relay.completeVideoNegotiation(succeeded: false)
                fail(videoNegotiationFailure(for: nil))
                return
            }
            do {
                try avConference.configureAndStart(answer: answer)
                relay.completeVideoNegotiation(succeeded: true)
            } catch {
                let failure = videoNegotiationFailure(for: error)
                Self.log(failure, origin: "avconference")
                relay.completeVideoNegotiation(succeeded: false)
                fail(failure)
            }
        }
    }

    func handleMedia(_ event: UnsafePointer<DhEvent>?) {
        let decoded: DeviceHubNativeMediaEvent?
        do {
            decoded = try lock.withLock {
                guard !isClosing, !isTerminal else {
                    return nil
                }
                guard var decoder = mediaDecoder else {
                    throw DeviceHubNativeMediaEventDecodingError
                        .invalidEnvelope
                }
                let output = try decoder.decodeMedia(event)
                mediaDecoder = decoder
                return output
            }
        } catch {
            Self.logger.error(
                "Native media callback decoding failed"
            )
            fail(videoStreamFailure)
            return
        }
        guard let decoded else {
            return
        }

        switch decoded {
        case let .datagram(datagram):
            handleDatagram(datagram)

        case let .configuration(configuration):
            handleConfiguration(configuration)

        case let .accessUnit(accessUnit):
            handleAccessUnit(accessUnit)

        case let .discontinuity(discontinuity):
            handleDiscontinuity(discontinuity)
        }
    }

    private func handleDatagram(_ datagram: DeviceHubNativeVideoDatagram) {
        guard let avConference else {
            fail(videoDatagramFailure)
            return
        }
        do {
            try avConference.ingest(datagram.bytes)
        } catch {
            Self.logger.error(
                "AVConference rejected an inbound datagram"
            )
            fail(videoDatagramFailure)
        }
    }

    private func handleConfiguration(
        _ configuration: DeviceHubNativeVideoConfiguration
    ) {
        DeviceHubNativeTrace.emit(
            "video_configuration sequence=\(configuration.sequenceNumber) "
                + "revision=\(configuration.revision) "
                + "pixels=\(configuration.pixelSize.width)x"
                + "\(configuration.pixelSize.height)"
        )
        guard let videoBridge else {
            return
        }
        let result = configuration.videoParameterSet
            .withUnsafeBytes { videoParameterSet in
                configuration.sequenceParameterSet
                    .withUnsafeBytes { sequenceParameterSet in
                        configuration.pictureParameterSet
                            .withUnsafeBytes { pictureParameterSet in
                                videoBridge.receiveConfiguration(
                                    sequenceNumber: configuration.sequenceNumber,
                                    videoParameterSet: videoParameterSet,
                                    sequenceParameterSet: sequenceParameterSet,
                                    pictureParameterSet: pictureParameterSet
                                )
                            }
                    }
            }
        switch result {
        case .accepted:
            lock.withLock {
                mediaParameterSetRevision = configuration.revision
            }

        case .terminal:
            DeviceHubNativeTrace.emit(
                "video_configuration_rejected "
                    + "result=\(String(describing: result))"
            )
            fail(videoStreamFailure)
        }
    }
}

extension DeviceHubNativeCallbackContext {
    private func handleAccessUnit(
        _ accessUnit: DeviceHubNativeVideoAccessUnit
    ) {
        let traceOrdinal = lock.withLock {
            tracedAccessUnitCount += 1
            return tracedAccessUnitCount
        }
        if traceOrdinal <= 10 || traceOrdinal.isMultiple(of: 60) {
            DeviceHubNativeTrace.emit(
                "video_access_unit ordinal=\(traceOrdinal) "
                    + "sequence=\(accessUnit.sequenceNumber) "
                    + "revision=\(accessUnit.parameterSetRevision) "
                    + "sync=\(accessUnit.isSync) "
                    + "orientation=\(accessUnit.geometry.orientation) "
                    + "pixels=\(accessUnit.geometry.pixelSize.width)x"
                    + "\(accessUnit.geometry.pixelSize.height) "
                    + "bytes=\(accessUnit.bytes.count)"
            )
        }
        guard let videoBridge else {
            return
        }
        guard
            lock.withLock({
                mediaParameterSetRevision
                    == accessUnit.parameterSetRevision
            })
        else {
            fail(videoStreamFailure)
            return
        }
        let result = accessUnit.bytes.withUnsafeBytes { bytes in
            videoBridge.receiveAccessUnit(
                sequenceNumber: accessUnit.sequenceNumber,
                receivedAt: now(),
                orientation: accessUnit.geometry.orientation,
                pixelSize: accessUnit.geometry.pixelSize,
                bytes: bytes
            )
        }
        switch result {
        case .accepted:
            break

        case .terminal:
            DeviceHubNativeTrace.emit(
                "video_access_unit_rejected "
                    + "result=\(String(describing: result))"
            )
            fail(videoStreamFailure)
        }
    }

    private func handleDiscontinuity(
        _ discontinuity: DeviceHubNativeVideoDiscontinuity
    ) {
        let traceOrdinal = lock.withLock {
            tracedDiscontinuityCount += 1
            mediaParameterSetRevision = nil
            return tracedDiscontinuityCount
        }
        if traceOrdinal <= 10 || traceOrdinal.isMultiple(of: 60) {
            DeviceHubNativeTrace.emit(
                "video_discontinuity ordinal=\(traceOrdinal) "
                    + "reason=\(String(describing: discontinuity.reason))"
            )
        }
        guard let videoBridge else {
            return
        }
        guard
            case .accepted = videoBridge.receiveDiscontinuity(
                sequenceNumber: discontinuity.sequenceNumber
            )
        else {
            fail(videoStreamFailure)
            return
        }
    }

    func handleReceiverEvent(_ event: DHAVConferenceReceiverEvent) {
        DeviceHubNativeTrace.emit(
            "receiver_event=\(String(describing: event))"
        )
        switch event {
        case .didStart:
            return

        case .didStop,
             .didFail,
             .didReceiveRTPTimeout,
             .didReceiveRTCPTimeout:
            Self.logger.error(
                "AVConference receiver terminated: \(String(describing: event), privacy: .public)"
            )
            fail(videoStreamFailure)

        case .didRecoverFromRTCPTimeout:
            return

        @unknown default:
            Self.logger.error(
                "AVConference receiver emitted an unknown terminal event"
            )
            fail(videoStreamFailure)
        }
    }

    func beginClosing() {
        lock.withLock {
            guard !isClosing else {
                return
            }
            isClosing = true
        }
    }

    func cancelVideoAfterNativeCancellation() {
        _ = videoBridge?.cancel()
    }

    func finishAfterTeardown() {
        lock.withLock {
            isClosing = true
            isTerminal = true
            mediaParameterSetRevision = nil
        }
        _ = videoBridge?.cancel()
        controlContinuation.finish()
    }

    /// Fails both native streams after an ordered executor call is rejected.
    func reportFailure(_ failure: NativeSessionFailure) {
        fail(failure)
    }

    func pixelSizeForInput() -> PixelSize? {
        lock.withLock {
            currentGeometry?.pixelSize
        }
    }

    private func emit(_ event: NativeSessionEvent) {
        let mayEmit = lock.withLock {
            !isClosing && !isTerminal
        }
        guard mayEmit else {
            return
        }
        switch controlContinuation.yield(event) {
        case .enqueued:
            return
        case .dropped, .terminated:
            fail(nativeDispatchFailure)
        @unknown default:
            fail(nativeDispatchFailure)
        }
    }

    private func finish(with event: NativeSessionEvent) {
        let shouldFinish = lock.withLock {
            guard !isClosing, !isTerminal else {
                return false
            }
            isTerminal = true
            return true
        }
        guard shouldFinish else {
            return
        }

        switch event {
        case let .failed(failure):
            Self.log(failure, origin: "native-control")
            _ = videoBridge?.receiveFailure(failure)
            _ = controlContinuation.yield(event)
            controlContinuation.finish(throwing: failure)

        case .cancelled:
            _ = videoBridge?.cancel()
            switch controlContinuation.yield(event) {
            case .enqueued:
                controlContinuation.finish()
            case .dropped, .terminated:
                controlContinuation.finish(
                    throwing: nativeDispatchFailure
                )
            @unknown default:
                controlContinuation.finish(
                    throwing: nativeDispatchFailure
                )
            }

        case .completed:
            _ = videoBridge?.finish()
            switch controlContinuation.yield(event) {
            case .enqueued:
                controlContinuation.finish()
            case .dropped, .terminated:
                controlContinuation.finish(
                    throwing: nativeDispatchFailure
                )
            @unknown default:
                controlContinuation.finish(
                    throwing: nativeDispatchFailure
                )
            }

        default:
            preconditionFailure("Only terminal native events may finish.")
        }
    }

    private func fail(_ failure: NativeSessionFailure) {
        let shouldFinish = lock.withLock {
            guard !isClosing, !isTerminal else {
                return false
            }
            isTerminal = true
            return true
        }
        guard shouldFinish else {
            return
        }
        Self.log(failure, origin: "swift-callback")
        _ = videoBridge?.receiveFailure(failure)
        _ = controlContinuation.yield(.failed(failure))
        controlContinuation.finish(throwing: failure)
    }

    private static func log(
        _ failure: NativeSessionFailure,
        origin: String
    ) {
        DeviceHubNativeTrace.emit(
            "failure_origin=\(origin) code=\(failure.code) "
                + "stage=\(failure.stage)"
        )
        logger.error(
            """
            Session failed origin=\(origin, privacy: .public) \
            code=\(failure.code, privacy: .public) \
            stage=\(failure.stage, privacy: .public) \
            retryable=\(failure.retryable, privacy: .public)
            """
        )
    }

    private var nativeDispatchFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "event_dispatch_unavailable",
            stage: "session_dispatch",
            retryable: false
        )
    }

    private var videoDatagramFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "video_datagram_rejected",
            stage: "video_stream",
            retryable: true
        )
    }

    private var videoStreamFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "video_stream_failed",
            stage: "video_stream",
            retryable: true
        )
    }
}

/// Reduces an AVConference error to a closed operation vocabulary without
/// retaining framework messages, payloads, device metadata, or answer bytes.
func videoNegotiationFailure(
    for error: (any Error)?
) -> NativeSessionFailure {
    let nativeError = error.map { $0 as NSError }
    let operation: String? =
        if let nativeError,
        nativeError.domain == DHAVConferenceErrorDomain {
            nativeError.userInfo[DHAVConferenceErrorOperationKey] as? String
        } else {
            nil
        }
    let stage = switch operation {
    case "applyNegotiatorAnswer":
        "video_apply_answer"
    case "generateStreamConfiguration":
        "video_generate_configuration"
    case "generateStreamOptions":
        "video_generate_options"
    case "validateInProcessMode":
        "video_validate_receiver"
    case "createVideoStream":
        "video_create_receiver"
    case "configureVideoStream":
        "video_configure_receiver"
    case "start":
        "video_start_receiver"
    default:
        "video_negotiation"
    }
    return NativeSessionFailure(
        code: "video_receiver_rejected",
        stage: stage,
        retryable: false
    )
}
