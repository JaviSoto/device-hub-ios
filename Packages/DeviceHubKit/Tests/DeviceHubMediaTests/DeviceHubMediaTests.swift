import CoreVideo
import CustomDump
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubMedia
import Dispatch
import Foundation
import Testing
import VideoToolbox

struct HEVCVideoDecoderTests {
    @Test(.timeLimit(.minutes(1)))
    func decodesARealGeneratedHEVCFrame() async throws {
        let generation = SessionGeneration.fixture()
        let fixture = try HEVCFixture.load(
            named: "solid-green",
            generation: generation,
            sequenceNumber: 41,
            receivedAt: Date(timeIntervalSince1970: 123),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let decoder = HEVCVideoDecoder(generation: generation)
        var frames = decoder.frames.makeAsyncIterator()

        try await decoder.decode(fixture.input)
        let decoded = try await frames.next()
        let frame = try #require(decoded)

        expectNoDifference(
            frame.metadata,
            .videoFrame(
                FrameMetadata(
                    generation: generation,
                    sequenceNumber: 41,
                    receivedAt: Date(timeIntervalSince1970: 123),
                    pixelSize: PixelSize(width: 64, height: 64),
                    orientation: .portrait
                )
            )
        )
        #expect(frame.image.width == 64)
        #expect(frame.image.height == 64)
        try await decoder.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func atomicallyReplacesTheDecoderWhenConfigurationChanges() async throws {
        let generation = SessionGeneration.fixture()
        let green = try HEVCFixture.load(
            named: "solid-green",
            generation: generation,
            sequenceNumber: 1,
            receivedAt: Date(timeIntervalSince1970: 1),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let blue = try HEVCFixture.load(
            named: "solid-blue",
            generation: generation,
            sequenceNumber: 2,
            receivedAt: Date(timeIntervalSince1970: 2),
            pixelSize: PixelSize(width: 96, height: 64)
        )
        let decoder = HEVCVideoDecoder(generation: generation)
        var frames = decoder.frames.makeAsyncIterator()

        try await decoder.decode(green.input)
        try await decoder.waitForPendingFrames()
        let greenFrame = try #require(try await frames.next())
        #expect(greenFrame.image.width == 64)

        try await decoder.decode(blue.input)
        try await decoder.waitForPendingFrames()
        let blueFrame = try #require(try await frames.next())
        #expect(blueFrame.image.width == 96)
        expectNoDifference(
            blueFrame.metadata,
            .videoFrame(
                FrameMetadata(
                    generation: generation,
                    sequenceNumber: 2,
                    receivedAt: Date(timeIntervalSince1970: 2),
                    pixelSize: PixelSize(width: 96, height: 64),
                    orientation: .portrait
                )
            )
        )
        try await decoder.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementCannotRaceAnOldFramePublication() async throws {
        let oldFramePaused = BlockingSynchronizationPoint()
        let pair = AsyncThrowingStream.makeStream(
            of: RemoteDisplayFrame.self,
            throwing: Error.self,
            bufferingPolicy: .unbounded
        )
        let gate = FrameDeliveryGate(
            continuation: pair.continuation,
            synchronization: FrameDeliveryGateSynchronization(
                beforePublishingFrame: { token in
                    guard token == 1 else {
                        return
                    }
                    oldFramePaused.arriveAndWait()
                }
            )
        )
        let metadata = FrameMetadata(
            generation: .fixture(),
            sequenceNumber: 1,
            receivedAt: Date(timeIntervalSince1970: 1),
            pixelSize: PixelSize(width: 64, height: 64),
            orientation: .portrait
        )
        gate.activate(token: 1)

        let oldDelivery = Task.detached {
            try gate.receive(
                token: 1,
                status: noErr,
                infoFlags: [],
                imageBuffer: makePixelBuffer(width: 64, height: 64),
                metadata: metadata
            )
        }
        await oldFramePaused.waitUntilReached()

        gate.activate(token: 2)
        oldFramePaused.release()
        try await oldDelivery.value
        gate.finish()

        var frames = pair.stream.makeAsyncIterator()
        let publishedAfterReplacement = try await frames.next()
        #expect(publishedAfterReplacement == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsStaleGenerationWithoutPoisoningTheDecoder() async throws {
        let activeGeneration = SessionGeneration.fixture()
        let staleGeneration = SessionGeneration(
            rawValue: UUID(
                uuid: (
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 2
                )
            )
        )
        let stale = try HEVCFixture.load(
            named: "solid-green",
            generation: staleGeneration,
            sequenceNumber: 1,
            receivedAt: Date(timeIntervalSince1970: 1),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let active = try HEVCFixture.load(
            named: "solid-green",
            generation: activeGeneration,
            sequenceNumber: 2,
            receivedAt: Date(timeIntervalSince1970: 2),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let decoder = HEVCVideoDecoder(generation: activeGeneration)
        var frames = decoder.frames.makeAsyncIterator()

        let staleError = await captureMediaError {
            try await decoder.decode(stale.input)
        }
        expectNoDifference(staleError, .staleGeneration)

        try await decoder.decode(active.input)
        let decoded = try #require(try await frames.next())
        expectNoDifference(
            decoded.metadata,
            .videoFrame(
                FrameMetadata(
                    generation: activeGeneration,
                    sequenceNumber: 2,
                    receivedAt: Date(timeIntervalSince1970: 2),
                    pixelSize: PixelSize(width: 64, height: 64),
                    orientation: .portrait
                )
            )
        )
        try await decoder.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func retainsOnlyTheNewestFrameUnderBackpressure() async throws {
        let generation = SessionGeneration.fixture()
        let decoder = HEVCVideoDecoder(generation: generation)

        for sequenceNumber in UInt64(1) ... 3 {
            let fixture = try HEVCFixture.load(
                named: "solid-green",
                generation: generation,
                sequenceNumber: sequenceNumber,
                receivedAt: Date(
                    timeIntervalSince1970: TimeInterval(sequenceNumber)
                ),
                pixelSize: PixelSize(width: 64, height: 64)
            )
            try await decoder.decode(fixture.input)
        }
        try await decoder.waitForPendingFrames()
        try await decoder.stop()

        var frames = decoder.frames.makeAsyncIterator()
        let decoded = try #require(try await frames.next())
        expectNoDifference(decoded.metadata.videoSequenceNumber, 3)
        let frameAfterNewest = try await frames.next()
        #expect(frameAfterNewest == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopIsIdempotentAndClosesAllCallbackDelivery() async throws {
        let generation = SessionGeneration.fixture()
        let decoder = HEVCVideoDecoder(generation: generation)

        for sequenceNumber in UInt64(1) ... 12 {
            let fixture = try HEVCFixture.load(
                named: "solid-green",
                generation: generation,
                sequenceNumber: sequenceNumber,
                receivedAt: Date(
                    timeIntervalSince1970: TimeInterval(sequenceNumber)
                ),
                pixelSize: PixelSize(width: 64, height: 64)
            )
            try await decoder.decode(fixture.input)
        }

        try await decoder.stop()
        try await decoder.stop()

        var deliveredFrames = 0
        for try await _ in decoder.frames {
            deliveredFrames += 1
        }
        #expect(deliveredFrames <= 1)

        let fixture = try HEVCFixture.load(
            named: "solid-green",
            generation: generation,
            sequenceNumber: 13,
            receivedAt: Date(timeIntervalSince1970: 13),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let stoppedError = await captureMediaError {
            try await decoder.decode(fixture.input)
        }
        expectNoDifference(stoppedError, .decoderStopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheConsumerPermanentlyClosesDelivery() async throws {
        let generation = SessionGeneration.fixture()
        let decoder = HEVCVideoDecoder(generation: generation)
        let waitingConsumer = Task {
            var frames = decoder.frames.makeAsyncIterator()
            return try await frames.next()
        }

        await Task.yield()
        waitingConsumer.cancel()
        let cancelledResult = try await waitingConsumer.value
        switch cancelledResult {
        case nil:
            break
        case .some:
            Issue.record("A cancelled consumer unexpectedly received a frame")
        }

        let fixture = try HEVCFixture.load(
            named: "solid-green",
            generation: generation,
            sequenceNumber: 1,
            receivedAt: Date(timeIntervalSince1970: 1),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let cancellationError = await captureMediaError {
            try await decoder.decode(fixture.input)
        }
        expectNoDifference(cancellationError, .decoderStopped)
        try await decoder.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func releasingWithoutStopFinishesTheStreamSafely() async throws {
        let generation = SessionGeneration.fixture()
        var decoder: HEVCVideoDecoder? = HEVCVideoDecoder(
            generation: generation
        )
        let frames = try #require(decoder).frames

        for sequenceNumber in UInt64(1) ... 12 {
            let fixture = try HEVCFixture.load(
                named: "solid-green",
                generation: generation,
                sequenceNumber: sequenceNumber,
                receivedAt: Date(
                    timeIntervalSince1970: TimeInterval(sequenceNumber)
                ),
                pixelSize: PixelSize(width: 64, height: 64)
            )
            guard let decoder else {
                Issue.record("Decoder released before the lifetime test ended")
                return
            }
            try await decoder.decode(fixture.input)
        }

        decoder = nil
        var deliveredFrames = 0
        for try await _ in frames {
            deliveredFrames += 1
        }
        #expect(deliveredFrames <= 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedCandidateConfigurationLeavesTheLiveDecoderUsable() async throws {
        let generation = SessionGeneration.fixture()
        let first = try HEVCFixture.load(
            named: "solid-green",
            generation: generation,
            sequenceNumber: 1,
            receivedAt: Date(timeIntervalSince1970: 1),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let second = try HEVCFixture.load(
            named: "solid-green",
            generation: generation,
            sequenceNumber: 2,
            receivedAt: Date(timeIntervalSince1970: 2),
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let malformedConfiguration = try HEVCConfiguration(
            videoParameterSet: Data([0x40, 0x01]),
            sequenceParameterSet: Data([0x42, 0x01]),
            pictureParameterSet: Data([0x44, 0x01])
        )
        let decoder = HEVCVideoDecoder(generation: generation)
        var frames = decoder.frames.makeAsyncIterator()

        try await decoder.decode(first.input)
        _ = try #require(try await frames.next())

        let configurationError = await captureMediaError {
            try await decoder.decode(
                HEVCDecodeInput(
                    configuration: malformedConfiguration,
                    sample: second.sample
                )
            )
        }
        let resolvedConfigurationError = try #require(configurationError)
        guard case .systemFailure(
            .createFormatDescription,
            _
        ) = resolvedConfigurationError
        else {
            Issue.record("Expected a format-description failure")
            try await decoder.stop()
            return
        }

        try await decoder.decode(second.input)
        let recoveredFrame = try #require(try await frames.next())
        expectNoDifference(recoveredFrame.metadata.videoSequenceNumber, 2)
        try await decoder.stop()
    }
}

struct HEVCConfigurationTests {
    @Test func rejectsAnEmptyVideoParameterSet() {
        do {
            _ = try HEVCConfiguration(
                videoParameterSet: Data(),
                sequenceParameterSet: Data([0x42]),
                pictureParameterSet: Data([0x44])
            )
            Issue.record("Expected an empty video parameter set to be rejected")
        } catch let error as MediaDecoderError {
            expectNoDifference(
                error,
                .invalidParameterSet(.video, .empty)
            )
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test func rejectsEveryInvalidParameterSetKindAndLimit() {
        let validVideo = Data([0x40, 0x01])
        let validSequence = Data([0x42, 0x01])
        let validPicture = Data([0x44, 0x01])

        let cases = [
            HEVCConfigurationCase(
                video: Data([0x42, 0x01]),
                sequence: validSequence,
                picture: validPicture,
                expected: .invalidParameterSet(
                    .video,
                    .unexpectedNALUnitType
                )
            ),
            HEVCConfigurationCase(
                video: validVideo,
                sequence: Data(),
                picture: validPicture,
                expected: .invalidParameterSet(.sequence, .empty)
            ),
            HEVCConfigurationCase(
                video: validVideo,
                sequence: Data([0x44, 0x01]),
                picture: validPicture,
                expected: .invalidParameterSet(
                    .sequence,
                    .unexpectedNALUnitType
                )
            ),
            HEVCConfigurationCase(
                video: validVideo,
                sequence: validSequence,
                picture: Data(),
                expected: .invalidParameterSet(.picture, .empty)
            ),
            HEVCConfigurationCase(
                video: validVideo,
                sequence: validSequence,
                picture: Data([0x40, 0x01]),
                expected: .invalidParameterSet(
                    .picture,
                    .unexpectedNALUnitType
                )
            ),
            HEVCConfigurationCase(
                video: Data(
                    repeating: 0x40,
                    count: HEVCConfiguration.maximumParameterSetSize + 1
                ),
                sequence: validSequence,
                picture: validPicture,
                expected: .invalidParameterSet(.video, .exceedsSizeLimit)
            )
        ]

        for testCase in cases {
            let error = captureMediaError {
                _ = try HEVCConfiguration(
                    videoParameterSet: testCase.video,
                    sequenceParameterSet: testCase.sequence,
                    pictureParameterSet: testCase.picture
                )
            }
            expectNoDifference(error, testCase.expected)
        }
    }
}

private enum PixelBufferFixtureError: Error {
    case allocationFailed(CVReturn)
}

private func makePixelBuffer(
    width: Int,
    height: Int
) throws -> CVPixelBuffer {
    let attributes = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ] as CFDictionary
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw PixelBufferFixtureError.allocationFailed(status)
    }
    return pixelBuffer
}

private final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending = lock.withLock {
            guard !signaled else {
                return [CheckedContinuation<Void, Never>]()
            }
            signaled = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if signaled {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class BlockingSynchronizationPoint: @unchecked Sendable {
    private let reached = TestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func arriveAndWait() {
        reached.signal()
        releaseSemaphore.wait()
    }

    func waitUntilReached() async {
        await reached.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

struct MediaDecoderErrorTests {
    @Test func mapsFrameworkStatusesWithoutLeakingRawInput() {
        expectNoDifference(
            [
                sanitizedMediaStatus(OSStatus(-50)),
                sanitizedMediaStatus(OSStatus(-108)),
                sanitizedMediaStatus(kVTParameterErr),
                sanitizedMediaStatus(kVTAllocationFailedErr),
                sanitizedMediaStatus(kVTInvalidSessionErr),
                sanitizedMediaStatus(
                    kVTVideoDecoderUnsupportedDataFormatErr
                ),
                sanitizedMediaStatus(kVTVideoDecoderNotAvailableNowErr),
                sanitizedMediaStatus(kVTVideoDecoderMalfunctionErr),
                sanitizedMediaStatus(kVTVideoDecoderBadDataErr),
                sanitizedMediaStatus(kVTVideoDecoderReferenceMissingErr),
                sanitizedMediaStatus(kVTPropertyNotSupportedErr),
                sanitizedMediaStatus(kVTPixelTransferNotSupportedErr),
                sanitizedMediaStatus(-999_999)
            ],
            [
                .invalidArgument,
                .allocationFailed,
                .invalidArgument,
                .allocationFailed,
                .invalidated,
                .unsupportedFormat,
                .decoderUnavailable,
                .decoderMalfunction,
                .malformedCompressedData,
                .missingReferenceFrame,
                .propertyUnsupported,
                .conversionFailed,
                .unrecognized
            ]
        )

        let secret = "private-frame-payload"
        let error = MediaDecoderError.systemFailure(
            .completeFrame,
            sanitizedMediaStatus(kVTVideoDecoderBadDataErr)
        )
        #expect(!String(reflecting: error).contains(secret))
        expectNoDifference(error.deviceHubError, .decoderFailed)
    }
}
