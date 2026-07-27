import DeviceHubCore
import DeviceHubFFI
import Foundation

/// Fail-closed reasons a borrowed native media callback cannot enter Swift.
///
/// No case retains native values, protocol payloads, device identifiers, or
/// media bytes. The textual and reflected forms expose only a bounded category.
enum DeviceHubNativeMediaEventDecodingError:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Error,
    Equatable,
    Sendable
{
    case invalidEnvelope
    case invalidPayload
    case invalidSequence
    case staleGeneration
    case unsupportedEvent

    var description: String {
        let category = switch self {
        case .invalidEnvelope:
            "invalid-envelope"
        case .invalidPayload:
            "invalid-payload"
        case .invalidSequence:
            "invalid-sequence"
        case .staleGeneration:
            "stale-generation"
        case .unsupportedEvent:
            "unsupported-event"
        }
        return "<redacted-native-media-decoding-error \(category)>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: ["failure": description],
            displayStyle: .enum
        )
    }
}

/// Copied, validated output from one synchronous native media callback.
enum DeviceHubNativeMediaEvent: Equatable, Sendable {
    case accessUnit(DeviceHubNativeVideoAccessUnit)
    case configuration(DeviceHubNativeVideoConfiguration)
    case datagram(DeviceHubNativeVideoDatagram)
    case discontinuity(DeviceHubNativeVideoDiscontinuity)
}

/// One complete inbound video datagram copied from borrowed native storage.
struct DeviceHubNativeVideoDatagram: Equatable, Sendable {
    let sequenceNumber: UInt64
    let sourcePort: UInt16
    let bytes: Data
}

/// One changed HEVC decoder configuration copied from native storage.
///
/// `revision` remains separate from the callback sequence so the imperative
/// shell can require an exact match before admitting a later access unit.
struct DeviceHubNativeVideoConfiguration: Equatable, Sendable {
    let sequenceNumber: UInt64
    let revision: UInt64
    let pixelSize: PixelSize
    let orientation: ScreenOrientation?
    let videoParameterSet: Data
    let sequenceParameterSet: Data
    let pictureParameterSet: Data
}

/// Authoritative geometry snapshot carried by one access unit.
struct DeviceHubNativeMediaGeometry: Equatable, Sendable {
    let pixelSize: PixelSize
    let orientation: ScreenOrientation
    let isOrientationLocked: Bool
}

/// One complete marker-closed HEVC access unit copied from native storage.
///
/// The RTP sequence range may wrap. `parameterSetRevision` is preserved so the
/// shell can reject an access unit from any decoder-configuration epoch other
/// than the one it most recently admitted.
struct DeviceHubNativeVideoAccessUnit: Equatable, Sendable {
    let sequenceNumber: UInt64
    let parameterSetRevision: UInt64
    let synchronizationSource: UInt32
    let rtpTimestamp: UInt32
    let firstRTPSequenceNumber: UInt16
    let lastRTPSequenceNumber: UInt16
    let isSync: Bool
    let geometry: DeviceHubNativeMediaGeometry
    let bytes: Data
}

/// Sanitized discontinuity category emitted by the native HEVC assembler.
enum DeviceHubNativeVideoDiscontinuityReason: Equatable, Sendable {
    case accessUnitTooLarge
    case malformedPayload
    case missingParameterSets
    case nalTooLarge
    case parameterSetTooLarge
    case sequenceGap
    case timestampChangedWithoutMarker
    case tooManyNALUnits
    case unexpectedStream
}

/// One ordered decoder-reset boundary in the native media plane.
struct DeviceHubNativeVideoDiscontinuity: Equatable, Sendable {
    let sequenceNumber: UInt64
    let reason: DeviceHubNativeVideoDiscontinuityReason
}

/// Stateful decoder for the synchronous media callback of one native session.
///
/// Rust owns every pointer reachable from `DhEvent` only until its callback
/// returns. This decoder therefore validates the complete envelope and nested
/// records, copies every retained span synchronously, and commits the media
/// sequence only after decoding succeeds. The sequence is intentionally
/// independent from the control callback's sequence.
struct DeviceHubNativeMediaEventDecoder {
    static let maximumAccessUnitByteCount = 33_554_432
    static let maximumDatagramByteCount = 65535
    static let maximumParameterSetByteCount = 1_048_576
    static let maximumPixelDimension: UInt32 = 16384

    private let expectedGeneration: DeviceHubNativeGeneration
    private var lastMediaSequence: UInt64?

    init(generation: SessionGeneration) {
        expectedGeneration = DeviceHubNativeGeneration(generation.rawValue)
    }

    mutating func decodeMedia(
        _ pointer: UnsafePointer<DhEvent>?
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeMediaEvent
    {
        guard let pointer else {
            throw .invalidEnvelope
        }
        let event = pointer.pointee
        try validateEnvelope(event)
        try validateSequence(event.sequence)

        let decoded = try decodeValidatedEvent(event)
        lastMediaSequence = event.sequence
        return decoded
    }

    private func validateEnvelope(
        _ event: DhEvent
    ) throws(DeviceHubNativeMediaEventDecodingError) {
        guard
            event.struct_size == UInt32(MemoryLayout<DhEvent>.size),
            event.abi_version == DeviceHubNativeABI.expectedVersion,
            event.reserved == 0
        else {
            throw .invalidEnvelope
        }
        guard
            event.generation.high == expectedGeneration.high,
            event.generation.low == expectedGeneration.low
        else {
            throw .staleGeneration
        }
        guard
            event.state == DH_SESSION_STATE_CONNECTED,
            event.phase == DH_CONNECTION_PHASE_STREAMING,
            event.request_id == 0,
            event.payload.data == nil,
            event.payload.count < 1,
            event.peer == nil,
            event.rsd == nil,
            event.display_geometry == nil,
            event.image_width == 0,
            event.image_height == 0
        else {
            throw .invalidEnvelope
        }
    }

    private func validateSequence(
        _ sequence: UInt64
    ) throws(DeviceHubNativeMediaEventDecodingError) {
        let expectedSequence: UInt64? = if let lastMediaSequence {
            lastMediaSequence == UInt64.max
                ? nil
                : lastMediaSequence + 1
        } else {
            1
        }
        guard let expectedSequence, sequence == expectedSequence else {
            throw .invalidSequence
        }
    }

    private func decodeValidatedEvent(
        _ event: DhEvent
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeMediaEvent
    {
        switch event.kind {
        case DH_EVENT_VIDEO_DATAGRAM:
            return try .datagram(datagram(event))
        case DH_EVENT_VIDEO_CONFIGURATION:
            return try .configuration(configuration(event))
        case DH_EVENT_VIDEO_ACCESS_UNIT:
            return try .accessUnit(accessUnit(event))
        case DH_EVENT_VIDEO_DISCONTINUITY:
            return try .discontinuity(discontinuity(event))
        default:
            throw .unsupportedEvent
        }
    }

    private func datagram(
        _ event: DhEvent
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeVideoDatagram
    {
        guard
            event.value == 0,
            event.video_configuration == nil,
            event.video_access_unit == nil,
            let pointer = event.video_datagram
        else {
            throw .invalidPayload
        }
        let native = pointer.pointee
        guard
            allBytesAreZero(native.reserved),
            native.source_port > 0
        else {
            throw .invalidPayload
        }
        return try DeviceHubNativeVideoDatagram(
            sequenceNumber: event.sequence,
            sourcePort: native.source_port,
            bytes: copyRequired(
                native.bytes,
                minimumCount: 1,
                maximumCount: Self.maximumDatagramByteCount
            )
        )
    }

    private func configuration(
        _ event: DhEvent
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeVideoConfiguration
    {
        guard
            event.video_access_unit == nil,
            event.video_datagram == nil,
            let pointer = event.video_configuration
        else {
            throw .invalidPayload
        }
        let native = pointer.pointee
        guard
            native.revision > 0,
            event.value == native.revision,
            native.reserved == 0
        else {
            throw .invalidPayload
        }
        let encodedPixelSize = try validatedPixelSize(
            width: native.pixel_width,
            height: native.pixel_height
        )
        let orientation = try optionalScreenOrientation(native.orientation)
        let pixelSize = orientation.map {
            DeviceHubNativeGeometry.nativePortraitPixelSize(
                encodedPixelSize,
                orientation: $0
            )
        } ?? encodedPixelSize
        let videoParameterSet = try copyParameterSet(
            native.video_parameter_set,
            expectedNALUnitType: 32
        )
        let sequenceParameterSet = try copyParameterSet(
            native.sequence_parameter_set,
            expectedNALUnitType: 33
        )
        let pictureParameterSet = try copyParameterSet(
            native.picture_parameter_set,
            expectedNALUnitType: 34
        )
        return DeviceHubNativeVideoConfiguration(
            sequenceNumber: event.sequence,
            revision: native.revision,
            pixelSize: pixelSize,
            orientation: orientation,
            videoParameterSet: videoParameterSet,
            sequenceParameterSet: sequenceParameterSet,
            pictureParameterSet: pictureParameterSet
        )
    }

    private func accessUnit(
        _ event: DhEvent
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeVideoAccessUnit
    {
        guard
            event.video_configuration == nil,
            event.video_datagram == nil,
            let pointer = event.video_access_unit
        else {
            throw .invalidPayload
        }
        let native = pointer.pointee
        guard
            native.parameter_set_revision > 0,
            event.value == native.parameter_set_revision,
            native.is_sync <= 1,
            allBytesAreZero(native.reserved)
        else {
            throw .invalidPayload
        }
        return try DeviceHubNativeVideoAccessUnit(
            sequenceNumber: event.sequence,
            parameterSetRevision: native.parameter_set_revision,
            synchronizationSource: native.ssrc,
            rtpTimestamp: native.rtp_timestamp,
            firstRTPSequenceNumber: native.first_sequence_number,
            lastRTPSequenceNumber: native.last_sequence_number,
            isSync: native.is_sync == 1,
            geometry: geometry(native.geometry),
            bytes: copyRequired(
                native.bytes,
                minimumCount: 1,
                maximumCount: Self.maximumAccessUnitByteCount
            )
        )
    }

    private func discontinuity(
        _ event: DhEvent
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeVideoDiscontinuity
    {
        guard
            event.video_configuration == nil,
            event.video_access_unit == nil,
            event.video_datagram == nil
        else {
            throw .invalidPayload
        }
        let reason: DeviceHubNativeVideoDiscontinuityReason =
            switch event.value {
            case UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP):
                .sequenceGap
            case UInt64(
                DH_VIDEO_DISCONTINUITY_TIMESTAMP_CHANGED_WITHOUT_MARKER
            ):
                .timestampChangedWithoutMarker
            case UInt64(DH_VIDEO_DISCONTINUITY_MALFORMED_PAYLOAD):
                .malformedPayload
            case UInt64(DH_VIDEO_DISCONTINUITY_NAL_TOO_LARGE):
                .nalTooLarge
            case UInt64(DH_VIDEO_DISCONTINUITY_PARAMETER_SET_TOO_LARGE):
                .parameterSetTooLarge
            case UInt64(DH_VIDEO_DISCONTINUITY_ACCESS_UNIT_TOO_LARGE):
                .accessUnitTooLarge
            case UInt64(DH_VIDEO_DISCONTINUITY_TOO_MANY_NAL_UNITS):
                .tooManyNALUnits
            case UInt64(DH_VIDEO_DISCONTINUITY_MISSING_PARAMETER_SETS):
                .missingParameterSets
            case UInt64(DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM):
                .unexpectedStream
            default:
                throw .invalidPayload
            }
        return DeviceHubNativeVideoDiscontinuity(
            sequenceNumber: event.sequence,
            reason: reason
        )
    }

    private func geometry(
        _ native: DhDisplayGeometry
    ) throws(DeviceHubNativeMediaEventDecodingError)
        -> DeviceHubNativeMediaGeometry
    {
        guard
            allBytesAreZero(native.reserved),
            native.orientation_locked <= 1,
            isKnownNativeOrientation(native.orientation),
            isKnownNativeOrientation(native.non_flat_orientation)
        else {
            throw .invalidPayload
        }

        let primary = flatScreenOrientation(native.orientation)
        let fallback = flatScreenOrientation(native.non_flat_orientation)
        guard let orientation = primary ?? fallback else {
            throw .invalidPayload
        }
        let encodedPixelSize = try validatedPixelSize(
            width: native.pixel_width,
            height: native.pixel_height
        )
        return DeviceHubNativeMediaGeometry(
            pixelSize: DeviceHubNativeGeometry.nativePortraitPixelSize(
                encodedPixelSize,
                orientation: orientation
            ),
            orientation: orientation,
            isOrientationLocked: native.orientation_locked == 1
        )
    }

    private func validatedPixelSize(
        width: UInt32,
        height: UInt32
    ) throws(DeviceHubNativeMediaEventDecodingError) -> PixelSize {
        guard
            width > 0,
            height > 0,
            width <= Self.maximumPixelDimension,
            height <= Self.maximumPixelDimension
        else {
            throw .invalidPayload
        }
        return PixelSize(width: Int(width), height: Int(height))
    }

    private func optionalScreenOrientation(
        _ orientation: DhOrientation
    ) throws(DeviceHubNativeMediaEventDecodingError) -> ScreenOrientation? {
        guard isKnownNativeOrientation(orientation) else {
            throw .invalidPayload
        }
        return flatScreenOrientation(orientation)
    }

    private func flatScreenOrientation(
        _ orientation: DhOrientation
    ) -> ScreenOrientation? {
        switch orientation {
        case DH_ORIENTATION_PORTRAIT:
            .portrait
        case DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN:
            .portraitUpsideDown
        case DH_ORIENTATION_LANDSCAPE_LEFT:
            .landscapeLeft
        case DH_ORIENTATION_LANDSCAPE_RIGHT:
            .landscapeRight
        default:
            nil
        }
    }

    private func isKnownNativeOrientation(
        _ orientation: DhOrientation
    ) -> Bool {
        switch orientation {
        case DH_ORIENTATION_UNKNOWN,
             DH_ORIENTATION_PORTRAIT,
             DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN,
             DH_ORIENTATION_LANDSCAPE_LEFT,
             DH_ORIENTATION_LANDSCAPE_RIGHT,
             DH_ORIENTATION_FACE_UP,
             DH_ORIENTATION_FACE_DOWN:
            true
        default:
            false
        }
    }

    private func copyParameterSet(
        _ bytes: DhBytes,
        expectedNALUnitType: UInt8
    ) throws(DeviceHubNativeMediaEventDecodingError) -> Data {
        let data = try copyRequired(
            bytes,
            minimumCount: 2,
            maximumCount: Self.maximumParameterSetByteCount
        )
        guard
            ((data[data.startIndex] >> 1) & 0x3F)
            == expectedNALUnitType
        else {
            throw .invalidPayload
        }
        return data
    }

    private func copyRequired(
        _ bytes: DhBytes,
        minimumCount: Int,
        maximumCount: Int
    ) throws(DeviceHubNativeMediaEventDecodingError) -> Data {
        guard
            bytes.count >= minimumCount,
            bytes.count <= maximumCount,
            let pointer = bytes.data
        else {
            throw .invalidPayload
        }
        return Data(bytes: pointer, count: bytes.count)
    }

    private func allBytesAreZero(_ value: some Any) -> Bool {
        withUnsafeBytes(of: value) { bytes in
            bytes.allSatisfy { $0 == 0 }
        }
    }
}
