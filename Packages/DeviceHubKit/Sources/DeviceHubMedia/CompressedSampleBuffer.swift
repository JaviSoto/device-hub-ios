import CoreMedia
import Foundation

/// Builds the CoreMedia sample consumed by the hardware decoder.
func makeSampleBuffer(
    from sample: HEVCCompressedSample,
    formatDescription: CMVideoFormatDescription,
    presentationTime: CMTime
) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: sample.bytes.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: sample.bytes.count,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else {
        throw sampleBufferError(status)
    }

    status = sample.bytes.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: bytes.count
        )
    }
    guard status == noErr else {
        throw sampleBufferError(status)
    }

    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleSize = sample.bytes.count
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw sampleBufferError(status)
    }

    if !sample.isSync {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
            let attachment = attachments.first
        else {
            throw MediaDecoderError.systemFailure(
                .submitFrame,
                .allocationFailed
            )
        }
        attachment[kCMSampleAttachmentKey_NotSync] = true
    }
    return sampleBuffer
}

private func sampleBufferError(_ status: OSStatus) -> MediaDecoderError {
    .systemFailure(.submitFrame, sanitizedMediaStatus(status))
}
