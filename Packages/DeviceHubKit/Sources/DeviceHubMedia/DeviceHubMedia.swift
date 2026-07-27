import DeviceHubCore
import Foundation

/// The three parameter-set kinds required to construct an HEVC decoder.
public enum HEVCParameterSetKind: Equatable, Sendable {
    case video
    case sequence
    case picture
}

/// Structural reasons that compressed input is rejected before reaching CoreMedia.
public enum MediaInputViolation: Equatable, Sendable {
    case empty
    case exceedsSizeLimit
    case unexpectedNALUnitType
}

/// Structural reasons that a complete access unit is rejected.
public enum HEVCSampleViolation: Equatable, Sendable {
    case empty
    case exceedsSizeLimit
    case invalidPixelSize
    case invalidTimestamp
    case tooManyNALUnits
    case truncatedLengthPrefix
    case zeroLengthNALUnit
    case truncatedNALUnit
    case malformedNALUnitHeader
    case missingVideoCodingLayerNALUnit
}

/// Media framework operation whose finite status mapping failed.
public enum MediaSystemOperation: Equatable, Sendable {
    case createFormatDescription
    case createDecompressionSession
    case configureRealTimeDecoding
    case submitFrame
    case completeFrame
    case createImage
    case waitForFrames
}

/// Sanitized category for CoreMedia and VideoToolbox status values.
public enum MediaSystemStatus: Equatable, Sendable {
    case invalidArgument
    case allocationFailed
    case invalidated
    case unsupportedFormat
    case decoderUnavailable
    case decoderMalfunction
    case malformedCompressedData
    case missingReferenceFrame
    case propertyUnsupported
    case conversionFailed
    case unrecognized
}

/// Sanitized failures produced by the media boundary.
///
/// Cases never contain compressed bytes, decoded pixels, transport details, or
/// arbitrary underlying error text, so they are safe to carry into diagnostics.
public enum MediaDecoderError: Error, Equatable, Sendable {
    case decoderStopped
    case decodedDimensionsMismatch
    case outputFrameDropped
    case outputFrameMissing
    case invalidParameterSet(HEVCParameterSetKind, MediaInputViolation)
    case invalidSample(HEVCSampleViolation)
    case staleGeneration
    case systemFailure(MediaSystemOperation, MediaSystemStatus)

    /// Stable app-wide category suitable for user-facing recovery logic.
    public var deviceHubError: DeviceHubError {
        .decoderFailed
    }
}

/// A complete, immutable HEVC decoder configuration.
///
/// Parameter sets include their two-byte NAL headers and exclude Annex-B start
/// codes. Construction performs the cheap structural checks needed before any
/// CoreMedia or VideoToolbox API receives the bytes.
public struct HEVCConfiguration: Equatable, Sendable {
    /// Per-parameter-set allocation ceiling enforced before CoreMedia.
    public static let maximumParameterSetSize = 1_048_576

    public let pictureParameterSet: Data
    public let sequenceParameterSet: Data
    public let videoParameterSet: Data

    public init(
        videoParameterSet: Data,
        sequenceParameterSet: Data,
        pictureParameterSet: Data
    ) throws {
        try Self.validate(
            videoParameterSet,
            kind: .video,
            expectedNALUnitType: 32
        )
        try Self.validate(
            sequenceParameterSet,
            kind: .sequence,
            expectedNALUnitType: 33
        )
        try Self.validate(
            pictureParameterSet,
            kind: .picture,
            expectedNALUnitType: 34
        )

        self.pictureParameterSet = pictureParameterSet
        self.sequenceParameterSet = sequenceParameterSet
        self.videoParameterSet = videoParameterSet
    }

    private static func validate(
        _ parameterSet: Data,
        kind: HEVCParameterSetKind,
        expectedNALUnitType: UInt8
    ) throws {
        guard !parameterSet.isEmpty else {
            throw MediaDecoderError.invalidParameterSet(kind, .empty)
        }
        guard parameterSet.count <= maximumParameterSetSize else {
            throw MediaDecoderError.invalidParameterSet(
                kind,
                .exceedsSizeLimit
            )
        }
        guard parameterSet.count >= 2,
              (parameterSet[parameterSet.startIndex] >> 1) & 0x3F
              == expectedNALUnitType
        else {
            throw MediaDecoderError.invalidParameterSet(
                kind,
                .unexpectedNALUnitType
            )
        }
    }
}

/// One complete HEVC access unit and the metadata needed to publish its frame.
///
/// `bytes` contains one or more NAL units, each prefixed by a four-byte
/// big-endian length. RTP fragments, Annex-B start codes, and incomplete access
/// units must be assembled and integrity-checked by the Rust transport first.
public struct HEVCCompressedSample: Equatable, Sendable {
    /// Largest accepted width or height, bounded before decoder allocation.
    public static let maximumDimension = 16384

    /// Maximum NAL units accepted in one complete access unit.
    public static let maximumNALUnitCount = 256

    /// Maximum compressed access-unit size accepted before CoreMedia.
    public static let maximumSampleSize = 33_554_432

    public let bytes: Data
    public let generation: SessionGeneration
    public let isSync: Bool
    public let orientation: ScreenOrientation
    public let pixelSize: PixelSize
    public let receivedAt: Date
    public let sequenceNumber: UInt64

    public init(
        generation: SessionGeneration,
        sequenceNumber: UInt64,
        receivedAt: Date,
        orientation: ScreenOrientation,
        pixelSize: PixelSize,
        bytes: Data
    ) throws {
        guard pixelSize.width > 0,
              pixelSize.height > 0,
              pixelSize.width <= Self.maximumDimension,
              pixelSize.height <= Self.maximumDimension
        else {
            throw MediaDecoderError.invalidSample(.invalidPixelSize)
        }
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MediaDecoderError.invalidSample(.invalidTimestamp)
        }
        let isSync = try Self.validate(bytes)

        self.bytes = bytes
        self.generation = generation
        self.isSync = isSync
        self.orientation = orientation
        self.pixelSize = pixelSize
        self.receivedAt = receivedAt
        self.sequenceNumber = sequenceNumber
    }

    private static func validate(_ bytes: Data) throws -> Bool {
        guard !bytes.isEmpty else {
            throw MediaDecoderError.invalidSample(.empty)
        }
        guard bytes.count <= maximumSampleSize else {
            throw MediaDecoderError.invalidSample(.exceedsSizeLimit)
        }

        var containsVideoCodingLayerNALUnit = false
        var containsSyncNALUnit = false
        var index = bytes.startIndex
        var nalUnitCount = 0

        while index < bytes.endIndex {
            guard bytes.distance(from: index, to: bytes.endIndex) >= 4 else {
                throw MediaDecoderError.invalidSample(.truncatedLengthPrefix)
            }
            let lengthEnd = bytes.index(index, offsetBy: 4)
            let nalUnitLength = bytes[index ..< lengthEnd].reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard nalUnitLength > 0 else {
                throw MediaDecoderError.invalidSample(.zeroLengthNALUnit)
            }

            let nalUnitStart = lengthEnd
            guard bytes.distance(
                from: nalUnitStart,
                to: bytes.endIndex
            ) >= nalUnitLength
            else {
                throw MediaDecoderError.invalidSample(.truncatedNALUnit)
            }
            guard nalUnitLength >= 2 else {
                throw MediaDecoderError.invalidSample(.malformedNALUnitHeader)
            }

            nalUnitCount += 1
            guard nalUnitCount <= maximumNALUnitCount else {
                throw MediaDecoderError.invalidSample(.tooManyNALUnits)
            }

            let nalUnitType = (bytes[nalUnitStart] >> 1) & 0x3F
            containsVideoCodingLayerNALUnit =
                containsVideoCodingLayerNALUnit || nalUnitType <= 31
            containsSyncNALUnit =
                containsSyncNALUnit || (16 ... 23).contains(nalUnitType)
            index = bytes.index(nalUnitStart, offsetBy: nalUnitLength)
        }

        guard containsVideoCodingLayerNALUnit else {
            throw MediaDecoderError.invalidSample(
                .missingVideoCodingLayerNALUnit
            )
        }
        return containsSyncNALUnit
    }
}
