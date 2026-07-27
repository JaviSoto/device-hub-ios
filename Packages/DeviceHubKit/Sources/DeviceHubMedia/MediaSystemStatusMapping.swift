import CoreMedia
import VideoToolbox

// Canonical cross-platform codes; Xcode 27's iOS overlay omits the legacy
// macOS global spellings.
private let osStatusInvalidParameter = OSStatus(-50)
private let osStatusMemoryFull = OSStatus(-108)

/// Reduces framework-specific status values to Device Hub's finite,
/// diagnostics-safe media failure vocabulary.
func sanitizedMediaStatus(_ status: OSStatus) -> MediaSystemStatus {
    switch status {
    case osStatusInvalidParameter,
         OSStatus(kVTParameterErr),
         OSStatus(kCMFormatDescriptionError_InvalidParameter),
         OSStatus(kCMBlockBufferBadCustomBlockSourceErr),
         OSStatus(kCMBlockBufferBadLengthParameterErr),
         OSStatus(kCMBlockBufferBadOffsetParameterErr),
         OSStatus(kCMBlockBufferBadPointerParameterErr),
         OSStatus(kCMSampleBufferError_RequiredParameterMissing),
         OSStatus(kCMSampleBufferError_InvalidEntryCount):
        .invalidArgument

    case osStatusMemoryFull,
         OSStatus(kVTAllocationFailedErr),
         OSStatus(kCMFormatDescriptionError_AllocationFailed),
         OSStatus(kCMBlockBufferStructureAllocationFailedErr),
         OSStatus(kCMBlockBufferBlockAllocationFailedErr),
         OSStatus(kCMSampleBufferError_AllocationFailed):
        .allocationFailed

    case OSStatus(kVTInvalidSessionErr),
         OSStatus(kCMSampleBufferError_Invalidated):
        .invalidated

    case OSStatus(kVTVideoDecoderUnsupportedDataFormatErr),
         OSStatus(kVTFormatDescriptionChangeNotSupportedErr),
         OSStatus(kCMSampleBufferError_InvalidMediaFormat):
        .unsupportedFormat

    case OSStatus(kVTCouldNotFindVideoDecoderErr),
         OSStatus(kVTCouldNotCreateInstanceErr),
         OSStatus(kVTVideoDecoderNotAvailableNowErr),
         OSStatus(kVTVideoDecoderAuthorizationErr),
         OSStatus(kVTVideoDecoderRemovedErr):
        .decoderUnavailable

    case OSStatus(kVTVideoDecoderMalfunctionErr),
         OSStatus(kVTSessionMalfunctionErr),
         OSStatus(kVTVideoDecoderCallbackMessagingErr),
         OSStatus(kVTVideoDecoderUnknownErr):
        .decoderMalfunction

    case OSStatus(kVTVideoDecoderBadDataErr),
         OSStatus(kCMSampleBufferError_InvalidSampleData),
         OSStatus(kCMSampleBufferError_DataFailed):
        .malformedCompressedData

    case OSStatus(kVTVideoDecoderReferenceMissingErr):
        .missingReferenceFrame

    case OSStatus(kVTPropertyNotSupportedErr),
         OSStatus(kVTPropertyReadOnlyErr):
        .propertyUnsupported

    case OSStatus(kVTPixelTransferNotSupportedErr),
         OSStatus(kVTPixelTransferNotPermittedErr),
         OSStatus(kVTInsufficientSourceColorDataErr),
         OSStatus(kVTColorCorrectionPixelTransferFailedErr),
         OSStatus(kVTColorSyncTransformConvertFailedErr):
        .conversionFailed

    default:
        .unrecognized
    }
}
