import CoreGraphics
import CoreMedia
import CoreVideo
import DeviceHubClient
import DeviceHubCore
import Foundation
import VideoToolbox

/// A decoder input whose configuration and access unit are already closed and validated.
public struct HEVCDecodeInput: Equatable, Sendable {
    public let configuration: HEVCConfiguration
    public let sample: HEVCCompressedSample

    public init(
        configuration: HEVCConfiguration,
        sample: HEVCCompressedSample
    ) {
        self.configuration = configuration
        self.sample = sample
    }
}

/// A single-generation, low-latency HEVC decoder.
///
/// The actor owns every CoreMedia and VideoToolbox object. Call ``stop()`` before releasing it;
/// this rejects new work, waits for asynchronous output, invalidates the session, then finishes
/// ``frames``. The stream retains only the newest image and has one logical consumer; cancelling
/// that consumer permanently rejects delivery. Callbacks capture a narrow lock-protected gate,
/// not this actor, and can never publish a stale configuration or connection generation.
public actor HEVCVideoDecoder {
    /// Capacity-one stream of immutable decoded frames.
    public nonisolated let frames: AsyncThrowingStream<RemoteDisplayFrame, Error>

    private let generation: SessionGeneration
    private let gate: FrameDeliveryGate
    private var nextPipelineToken: UInt64 = 1
    private var nextPresentationTimeValue: Int64 = 0
    private var pipeline: DecoderPipeline?
    private var stopped = false
    private var tracedDecodeCount = 0

    /// Creates a decoder permanently scoped to one connection generation.
    public init(generation: SessionGeneration) {
        let pair = AsyncThrowingStream.makeStream(
            of: RemoteDisplayFrame.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let gate = FrameDeliveryGate(continuation: pair.continuation)
        pair.continuation.onTermination = { [weak gate] termination in
            if case .cancelled = termination {
                gate?.consumerCancelled()
            }
        }
        frames = pair.stream
        self.generation = generation
        self.gate = gate
    }

    isolated deinit {
        gate.stopAccepting()
        if let pipeline {
            let status = VTDecompressionSessionWaitForAsynchronousFrames(
                pipeline.session
            )
            VTDecompressionSessionInvalidate(pipeline.session)
            if status != noErr {
                gate.finish(
                    throwing: mediaSystemError(
                        operation: .waitForFrames,
                        status: status
                    )
                )
                return
            }
        }
        gate.finish()
    }

    /// Submits one complete access unit for asynchronous low-latency decoding.
    ///
    /// The method returns after VideoToolbox accepts the sample. Decode completion
    /// is delivered through ``frames``. A callback failure terminates that stream
    /// with a sanitized ``MediaDecoderError`` and makes later submissions fail.
    public func decode(_ input: HEVCDecodeInput) throws {
        guard !stopped else {
            throw MediaDecoderError.decoderStopped
        }
        if let terminalError = gate.terminalError {
            throw terminalError
        }
        guard input.sample.generation == generation else {
            throw MediaDecoderError.staleGeneration
        }

        try ensurePipeline(for: input.configuration)
        guard let pipeline else {
            throw MediaDecoderError.decoderStopped
        }

        let presentationTime = CMTime(
            value: nextPresentationTimeValue,
            timescale: 1_000_000
        )
        nextPresentationTimeValue &+= 1
        let sampleBuffer = makeSampleBuffer(
            from: input.sample,
            formatDescription: pipeline.formatDescription,
            presentationTime: presentationTime
        )
        let metadata = FrameMetadata(
            generation: input.sample.generation,
            sequenceNumber: input.sample.sequenceNumber,
            receivedAt: input.sample.receivedAt,
            pixelSize: input.sample.pixelSize,
            orientation: input.sample.orientation
        )
        tracedDecodeCount += 1
        let shouldTrace =
            tracedDecodeCount <= 10 || tracedDecodeCount.isMultiple(of: 60)
        if shouldTrace {
            DeviceHubMediaTrace.emit(
                "decoder_submit ordinal=\(tracedDecodeCount) "
                    + "sequence=\(input.sample.sequenceNumber) "
                    + "sync=\(input.sample.isSync) "
                    + "bytes=\(input.sample.bytes.count)"
            )
        }
        var infoFlags = VTDecodeInfoFlags()
        let completion = makeDecodeCompletion(
            gate: gate,
            token: pipeline.token,
            metadata: metadata,
            shouldTrace: shouldTrace
        )
        let status = sampleBuffer.withUnsafeSampleBuffer { rawSampleBuffer in
            VTDecompressionSessionDecodeFrame(
                pipeline.session,
                sampleBuffer: rawSampleBuffer,
                flags: asynchronousDecompressionFlag,
                infoFlagsOut: &infoFlags,
                completionHandler: completion
            )
        }
        guard status == noErr else {
            DeviceHubMediaTrace.emit(
                "decoder_submit_failed status=\(status)"
            )
            throw mediaSystemError(
                operation: .submitFrame,
                status: status
            )
        }
        guard !infoFlags.contains(.frameDropped) else {
            DeviceHubMediaTrace.emit("decoder_submit_dropped")
            throw MediaDecoderError.outputFrameDropped
        }
    }

    /// Waits until every sample accepted so far has completed decoding.
    ///
    /// This is useful at explicit synchronization points and in tests; routine
    /// rendering should consume ``frames`` continuously instead of flushing.
    public func waitForPendingFrames() throws {
        guard !stopped else {
            throw MediaDecoderError.decoderStopped
        }
        if let terminalError = gate.terminalError {
            throw terminalError
        }
        guard let pipeline else {
            return
        }

        let status = VTDecompressionSessionWaitForAsynchronousFrames(
            pipeline.session
        )
        guard status == noErr else {
            let error = mediaSystemError(
                operation: .waitForFrames,
                status: status
            )
            gate.fail(token: pipeline.token, error: error)
            throw error
        }
        if let terminalError = gate.terminalError {
            throw terminalError
        }
    }

    /// Completes all asynchronous work and permanently closes this decoder.
    ///
    /// Repeated calls are no-ops. If VideoToolbox reports a teardown failure, the
    /// session is still invalidated and the same typed failure closes ``frames``.
    public func stop() throws {
        guard !stopped else {
            return
        }
        stopped = true
        gate.stopAccepting()

        guard let pipeline else {
            gate.finish()
            return
        }
        self.pipeline = nil

        let status = VTDecompressionSessionWaitForAsynchronousFrames(
            pipeline.session
        )
        VTDecompressionSessionInvalidate(pipeline.session)
        guard status == noErr else {
            let error = mediaSystemError(
                operation: .waitForFrames,
                status: status
            )
            gate.finish(throwing: error)
            throw error
        }
        gate.finish()
    }

    private func ensurePipeline(
        for configuration: HEVCConfiguration
    ) throws {
        guard pipeline?.configuration != configuration else {
            return
        }

        let token = nextPipelineToken
        nextPipelineToken &+= 1
        let candidate = try makePipeline(
            configuration: configuration,
            token: token
        )

        if let previous = pipeline {
            gate.activate(token: token)
            pipeline = candidate

            let status = VTDecompressionSessionWaitForAsynchronousFrames(
                previous.session
            )
            VTDecompressionSessionInvalidate(previous.session)
            guard status == noErr else {
                VTDecompressionSessionInvalidate(candidate.session)
                pipeline = nil
                let error = mediaSystemError(
                    operation: .waitForFrames,
                    status: status
                )
                gate.fail(token: token, error: error)
                throw error
            }
        } else {
            gate.activate(token: token)
            pipeline = candidate
        }
    }

    private func makePipeline(
        configuration: HEVCConfiguration,
        token: UInt64
    ) throws -> DecoderPipeline {
        let formatDescription = try makeFormatDescription(
            from: configuration
        )
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey:
                [:] as CFDictionary
        ] as CFDictionary
        var session: VTDecompressionSession?
        let creationStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            decompressionSessionOut: &session
        )
        guard creationStatus == noErr, let session else {
            throw mediaSystemError(
                operation: .createDecompressionSession,
                status: creationStatus
            )
        }

        let propertyStatus = VTSessionSetProperty(
            session,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        guard propertyStatus == noErr else {
            VTDecompressionSessionInvalidate(session)
            throw mediaSystemError(
                operation: .configureRealTimeDecoding,
                status: propertyStatus
            )
        }

        return DecoderPipeline(
            configuration: configuration,
            formatDescription: formatDescription,
            session: session,
            token: token
        )
    }
}

/// Xcode 27 currently imports this public bit as an underscored enum member.
/// Constructing the documented bit-zero flag avoids coupling to that importer bug.
private let asynchronousDecompressionFlag = VTDecodeFrameFlags(rawValue: 1)

private struct DecoderPipeline {
    let configuration: HEVCConfiguration
    let formatDescription: CMVideoFormatDescription
    let session: VTDecompressionSession
    let token: UInt64
}

private typealias DecodeCompletion = @Sendable (
    OSStatus,
    VTDecodeInfoFlags,
    CVImageBuffer?,
    [CMTaggedBuffer]?,
    CMTime,
    CMTime
) -> Void

/// Captures only immutable metadata and the lock-protected callback boundary.
private func makeDecodeCompletion(
    gate: FrameDeliveryGate,
    token: UInt64,
    metadata: FrameMetadata,
    shouldTrace: Bool
) -> DecodeCompletion {
    { status, infoFlags, imageBuffer, _, _, _ in
        if shouldTrace {
            DeviceHubMediaTrace.emit(
                "decoder_complete sequence=\(metadata.sequenceNumber) "
                    + "status=\(status) "
                    + "dropped=\(infoFlags.contains(.frameDropped)) "
                    + "image=\(imageBuffer != nil)"
            )
        }
        gate.receive(
            token: token,
            status: status,
            infoFlags: infoFlags,
            imageBuffer: imageBuffer,
            metadata: metadata
        )
    }
}

private func makeFormatDescription(
    from configuration: HEVCConfiguration
) throws -> CMVideoFormatDescription {
    var formatDescription: CMFormatDescription?
    let status = configuration.videoParameterSet.withUnsafeBytes { video in
        configuration.sequenceParameterSet.withUnsafeBytes { sequence in
            configuration.pictureParameterSet.withUnsafeBytes { picture in
                guard
                    let videoAddress = video.bindMemory(
                        to: UInt8.self
                    ).baseAddress,
                    let sequenceAddress = sequence.bindMemory(
                        to: UInt8.self
                    ).baseAddress,
                    let pictureAddress = picture.bindMemory(
                        to: UInt8.self
                    ).baseAddress
                else {
                    return OSStatus(kCMFormatDescriptionError_InvalidParameter)
                }

                let pointers = [
                    videoAddress,
                    sequenceAddress,
                    pictureAddress
                ]
                let sizes = [
                    configuration.videoParameterSet.count,
                    configuration.sequenceParameterSet.count,
                    configuration.pictureParameterSet.count
                ]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: pointers.count,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }
    }

    guard status == noErr, let formatDescription else {
        throw mediaSystemError(
            operation: .createFormatDescription,
            status: status
        )
    }
    return formatDescription
}

private func makeSampleBuffer(
    from sample: HEVCCompressedSample,
    formatDescription: CMVideoFormatDescription,
    presentationTime: CMTime
) -> CMReadySampleBuffer<CMReadOnlyDataBlockBuffer> {
    var attachments = CMSampleBuffer.SampleAttachments()
    attachments.isNotSync = !sample.isSync
    let properties = CMSampleBuffer.SamplePropertiesCollection([
        .init(
            size: sample.bytes.count,
            timing: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: .invalid
            ),
            attachments: attachments
        )
    ])
    return CMReadySampleBuffer(
        dataBuffer: CMReadOnlyDataBlockBuffer(sample.bytes),
        formatDescription: formatDescription,
        sampleProperties: properties
    )
}

/// Synchronizes the single C callback boundary and owns stream completion.
///
/// This is deliberately the only `@unchecked Sendable` type in the decoder. Its
/// mutable state is exclusively accessed under `NSLock`; it never exposes pixel
/// buffers, and the immutable `CGImage` is created before crossing into the stream.
final class FrameDeliveryGate: @unchecked Sendable {
    private struct State {
        var activeToken: UInt64?
        var stopped = false
        var terminalError: MediaDecoderError?
    }

    private let continuation:
        AsyncThrowingStream<RemoteDisplayFrame, Error>.Continuation
    private let lock = NSLock()
    private let synchronization: FrameDeliveryGateSynchronization
    private var state = State()

    init(
        continuation:
        AsyncThrowingStream<RemoteDisplayFrame, Error>.Continuation,
        synchronization: FrameDeliveryGateSynchronization = .none
    ) {
        self.continuation = continuation
        self.synchronization = synchronization
    }

    var terminalError: MediaDecoderError? {
        lock.withLock {
            state.terminalError
        }
    }

    func activate(token: UInt64) {
        lock.withLock {
            guard !state.stopped, state.terminalError == nil else {
                return
            }
            state.activeToken = token
        }
    }

    func receive(
        token: UInt64,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        metadata: FrameMetadata
    ) {
        guard isActive(token: token) else {
            return
        }
        guard status == noErr else {
            fail(
                token: token,
                error: mediaSystemError(
                    operation: .completeFrame,
                    status: status
                )
            )
            return
        }
        guard !infoFlags.contains(.frameDropped) else {
            fail(token: token, error: .outputFrameDropped)
            return
        }
        guard let imageBuffer else {
            fail(token: token, error: .outputFrameMissing)
            return
        }

        var image: CGImage?
        let conversionStatus = VTCreateCGImageFromCVPixelBuffer(
            imageBuffer,
            options: nil,
            imageOut: &image
        )
        guard conversionStatus == noErr, let image else {
            fail(
                token: token,
                error: mediaSystemError(
                    operation: .createImage,
                    status: conversionStatus
                )
            )
            return
        }

        let expectedSize = metadata.orientation.orientedSize(
            for: metadata.pixelSize
        )
        guard image.width == expectedSize.width,
              image.height == expectedSize.height
        else {
            fail(token: token, error: .decodedDimensionsMismatch)
            return
        }
        guard isActive(token: token) else {
            return
        }

        synchronization.beforePublishingFrame(token)
        publish(
            RemoteDisplayFrame(
                metadata: .videoFrame(metadata),
                image: image
            ),
            token: token
        )
    }

    func fail(
        token: UInt64,
        error: MediaDecoderError
    ) {
        let shouldFinish = lock.withLock {
            guard !state.stopped,
                  state.activeToken == token,
                  state.terminalError == nil
            else {
                return false
            }
            state.activeToken = nil
            state.terminalError = error
            return true
        }
        if shouldFinish {
            continuation.finish(throwing: error)
        }
    }

    func stopAccepting() {
        lock.withLock {
            state.activeToken = nil
            state.stopped = true
        }
    }

    func consumerCancelled() {
        lock.withLock {
            guard state.terminalError == nil else {
                return
            }
            state.activeToken = nil
            state.stopped = true
            state.terminalError = .decoderStopped
        }
    }

    func finish(throwing error: MediaDecoderError? = nil) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func isActive(token: UInt64) -> Bool {
        lock.withLock {
            !state.stopped
                && state.terminalError == nil
                && state.activeToken == token
        }
    }

    private func publish(
        _ frame: RemoteDisplayFrame,
        token: UInt64
    ) {
        lock.withLock {
            guard !state.stopped,
                  state.terminalError == nil,
                  state.activeToken == token
            else {
                return
            }
            continuation.yield(frame)
        }
    }
}

/// Deterministic observation points for exercising decoder callback interleavings.
///
/// Production uses ``none``; tests can pause a callback without depending on
/// VideoToolbox scheduling.
struct FrameDeliveryGateSynchronization: Sendable {
    let beforePublishingFrame: @Sendable (UInt64) -> Void

    static let none = Self(beforePublishingFrame: { _ in })
}

private func mediaSystemError(
    operation: MediaSystemOperation,
    status: OSStatus
) -> MediaDecoderError {
    .systemFailure(operation, sanitizedMediaStatus(status))
}
