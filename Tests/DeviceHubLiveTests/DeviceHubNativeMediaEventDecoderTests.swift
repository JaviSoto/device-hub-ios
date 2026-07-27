import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native media event decoding")
struct DeviceHubNativeMediaEventDecoderTests {
    private let generation = SessionGeneration(
        rawValue: UUID(
            uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
        )!
    )

    @Test("the media plane is contiguous and starts independently at one")
    func contiguousMediaSequence() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var datagramBytes = Data([0x01])

        #expect(
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &datagramBytes
            ) == .datagram(
                DeviceHubNativeVideoDatagram(
                    sequenceNumber: 1,
                    sourcePort: 50001,
                    bytes: Data([0x01])
                )
            )
        )

        var parameterSets = ParameterSets()
        #expect(
            try decodeConfiguration(
                with: &decoder,
                sequence: 2,
                revision: 7,
                parameterSets: &parameterSets
            ) == .configuration(
                DeviceHubNativeVideoConfiguration(
                    sequenceNumber: 2,
                    revision: 7,
                    pixelSize: PixelSize(width: 1290, height: 2796),
                    orientation: .portrait,
                    videoParameterSet: parameterSets.video,
                    sequenceParameterSet: parameterSets.sequence,
                    pictureParameterSet: parameterSets.picture
                )
            )
        )

        var accessUnitBytes = Data([0, 0, 0, 2, 0x26, 0x01])
        #expect(
            try decodeAccessUnit(
                with: &decoder,
                sequence: 3,
                parameterSetRevision: 7,
                bytes: &accessUnitBytes
            ) == .accessUnit(
                DeviceHubNativeVideoAccessUnit(
                    sequenceNumber: 3,
                    parameterSetRevision: 7,
                    synchronizationSource: 0x1234_5678,
                    rtpTimestamp: 0x9ABC_DEF0,
                    firstRTPSequenceNumber: 65534,
                    lastRTPSequenceNumber: 1,
                    isSync: true,
                    geometry: DeviceHubNativeMediaGeometry(
                        pixelSize: PixelSize(
                            width: 1290,
                            height: 2796
                        ),
                        orientation: .landscapeLeft,
                        isOrientationLocked: false
                    ),
                    bytes: Data([0, 0, 0, 2, 0x26, 0x01])
                )
            )
        )

        #expect(
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 4,
                reason: DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP
            ) == .discontinuity(
                DeviceHubNativeVideoDiscontinuity(
                    sequenceNumber: 4,
                    reason: .sequenceGap
                )
            )
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidSequence
        ) {
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 6,
                reason: DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM
            )
        }
        #expect(
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 5,
                reason: DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM
            ) == .discontinuity(
                DeviceHubNativeVideoDiscontinuity(
                    sequenceNumber: 5,
                    reason: .unexpectedStream
                )
            )
        )
    }

    @Test(
        "native receiver accepts datagrams without a redundant Swift decoder"
    )
    func nativeReceiverOnlyDatagram() async throws {
        let ingests = LockedCounter()
        let pipe = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(4))
        let context = DeviceHubNativeCallbackContext(
            generation: generation,
            controlContinuation: pipe.continuation,
            relay: DeviceHubNativeSessionRelay(),
            avConference: DeviceHubAVConferenceSession(
                operations: .init(
                    configureAndStart: { _ in },
                    ingest: { _ in
                        ingests.increment()
                    },
                    invalidate: {},
                    makeOffer: { Data([0x01]) }
                )
            )
        )
        let bytes = Data([0x80, 0x60, 0x00, 0x01])

        bytes.withUnsafeBytes { buffer in
            var datagram = DhVideoDatagram()
            datagram.bytes = nativeBytes(buffer)
            datagram.source_port = 50001
            withUnsafePointer(to: &datagram) { datagramPointer in
                withMediaEvent(
                    kind: DH_EVENT_VIDEO_DATAGRAM,
                    mutate: { $0.video_datagram = datagramPointer }
                ) {
                    context.handleMedia($0)
                }
            }
        }
        context.finishAfterTeardown()

        var controlEvents: [NativeSessionEvent] = []
        for try await event in pipe.stream {
            controlEvents.append(event)
        }
        #expect(ingests.count == 1)
        #expect(controlEvents.isEmpty)
    }

    @Test("every borrowed byte span is copied before callback return")
    func borrowedBytesAreCopied() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var datagramBytes = Data([0xAA, 0xBB, 0xCC])
        let datagram = try decodeDatagram(
            with: &decoder,
            sequence: 1,
            bytes: &datagramBytes
        )
        datagramBytes.resetBytes(in: datagramBytes.indices)

        var parameterSets = ParameterSets()
        let configuration = try decodeConfiguration(
            with: &decoder,
            sequence: 2,
            revision: 11,
            parameterSets: &parameterSets
        )
        parameterSets.video.resetBytes(in: parameterSets.video.indices)
        parameterSets.sequence.resetBytes(in: parameterSets.sequence.indices)
        parameterSets.picture.resetBytes(in: parameterSets.picture.indices)

        var accessUnitBytes = Data([0, 0, 0, 2, 0x02, 0x01])
        let accessUnit = try decodeAccessUnit(
            with: &decoder,
            sequence: 3,
            parameterSetRevision: 11,
            bytes: &accessUnitBytes
        )
        accessUnitBytes.resetBytes(in: accessUnitBytes.indices)

        guard case let .datagram(copiedDatagram) = datagram,
              case let .configuration(copiedConfiguration) = configuration,
              case let .accessUnit(copiedAccessUnit) = accessUnit
        else {
            Issue.record("Expected three copied media values")
            return
        }
        #expect(copiedDatagram.bytes == Data([0xAA, 0xBB, 0xCC]))
        #expect(
            copiedConfiguration.videoParameterSet
                == ParameterSets().video
        )
        #expect(
            copiedConfiguration.sequenceParameterSet
                == ParameterSets().sequence
        )
        #expect(
            copiedConfiguration.pictureParameterSet
                == ParameterSets().picture
        )
        #expect(
            copiedAccessUnit.bytes
                == Data([0, 0, 0, 2, 0x02, 0x01])
        )
    }

    @Test("exact envelope, generation, and successful sequence are required")
    func envelopeValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try decoder.decodeMedia(nil)
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.struct_size &-= 1 }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.abi_version &+= 1 }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.reserved = 1 }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.staleGeneration
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                generation: DhGeneration(high: 99, low: 100)
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidSequence
        ) {
            try withMediaEvent(
                sequence: 2,
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP)
            ) {
                try decoder.decodeMedia($0)
            }
        }

        #expect(
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 1,
                reason: DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP
            ) == .discontinuity(
                DeviceHubNativeVideoDiscontinuity(
                    sequenceNumber: 1,
                    reason: .sequenceGap
                )
            )
        )
    }

    @Test("media callbacks reject control kinds and non-media envelope data")
    func exactMediaEnvelope() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.unsupportedEvent
        ) {
            try withMediaEvent(kind: DH_EVENT_SESSION_STARTED) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.state = DH_SESSION_STATE_READY }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.phase = DH_CONNECTION_PHASE_READY }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.request_id = 1 }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.image_width = 1 }
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: {
                    $0.payload = DhBytes(
                        data: UnsafePointer<UInt8>(bitPattern: 1),
                        count: 1
                    )
                }
            ) {
                try decoder.decodeMedia($0)
            }
        }
    }

    @Test("datagrams validate pointer shape, reserved bytes, port, and size")
    func datagramValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(kind: DH_EVENT_VIDEO_DATAGRAM) {
                try decoder.decodeMedia($0)
            }
        }

        var empty = Data()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &empty
            )
        }

        var byte = Data([0x01])
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                sourcePort: 0,
                bytes: &byte
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &byte,
                mutate: { $0.reserved.0 = 1 }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &byte,
                nativeBytes: DhBytes(data: nil, count: 1)
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &byte,
                nativeBytes: DhBytes(
                    data: UnsafePointer<UInt8>(bitPattern: 1),
                    count:
                    DeviceHubNativeMediaEventDecoder
                        .maximumDatagramByteCount + 1
                )
            )
        }
    }

    @Test("configurations validate revisions, dimensions, orientation, and spans")
    func configurationValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var parameterSets = ParameterSets()

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(kind: DH_EVENT_VIDEO_CONFIGURATION) {
                try decoder.decodeMedia($0)
            }
        }

        for mutation in [
            ConfigurationMutation.revision(0),
            .pixelWidth(0),
            .pixelHeight(0),
            .pixelWidth(
                UInt32(
                    DeviceHubNativeMediaEventDecoder.maximumPixelDimension
                        + 1
                )
            ),
            .orientation(UInt32.max),
            .reserved
        ] {
            #expect(
                throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
            ) {
                try decodeConfiguration(
                    with: &decoder,
                    sequence: 1,
                    revision: 7,
                    parameterSets: &parameterSets,
                    mutate: mutation.apply
                )
            }
        }

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                eventValue: 8,
                parameterSets: &parameterSets
            )
        }

        parameterSets.video = Data()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                parameterSets: &parameterSets
            )
        }

        parameterSets = ParameterSets()
        parameterSets.video = Data([0x42, 0x01])
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                parameterSets: &parameterSets
            )
        }

        parameterSets = ParameterSets()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                parameterSets: &parameterSets,
                overrideVideoBytes: DhBytes(
                    data: UnsafePointer<UInt8>(bitPattern: 1),
                    count:
                    DeviceHubNativeMediaEventDecoder
                        .maximumParameterSetByteCount + 1
                )
            )
        }
    }

    @Test("configuration preserves flat and unresolved valid orientations")
    func configurationOrientation() throws {
        var flatDecoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var flatSets = ParameterSets()
        let flat = try decodeConfiguration(
            with: &flatDecoder,
            sequence: 1,
            revision: 1,
            parameterSets: &flatSets,
            mutate: { $0.orientation = DH_ORIENTATION_LANDSCAPE_RIGHT }
        )
        guard case let .configuration(flatConfiguration) = flat else {
            Issue.record("Expected a configuration")
            return
        }
        #expect(flatConfiguration.orientation == .landscapeRight)
        #expect(
            flatConfiguration.pixelSize
                == PixelSize(width: 2796, height: 1290)
        )

        for rawOrientation in [
            DH_ORIENTATION_UNKNOWN,
            DH_ORIENTATION_FACE_UP,
            DH_ORIENTATION_FACE_DOWN
        ] {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            var parameterSets = ParameterSets()
            let decoded = try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 1,
                parameterSets: &parameterSets,
                mutate: { $0.orientation = rawOrientation }
            )
            guard case let .configuration(configuration) = decoded else {
                Issue.record("Expected a configuration")
                continue
            }
            #expect(configuration.orientation == nil)
        }
    }

    @Test("access units validate revisions, flags, geometry, and byte bounds")
    func accessUnitValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var bytes = Data([0, 0, 0, 2, 0x02, 0x01])

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(kind: DH_EVENT_VIDEO_ACCESS_UNIT) {
                try decoder.decodeMedia($0)
            }
        }

        for mutation in [
            AccessUnitMutation.revision(0),
            .isSync(2),
            .reserved,
            .pixelWidth(0),
            .pixelHeight(0),
            .pixelHeight(
                UInt32(
                    DeviceHubNativeMediaEventDecoder.maximumPixelDimension
                        + 1
                )
            ),
            .orientationLocked(2),
            .geometryReserved
        ] {
            #expect(
                throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
            ) {
                try decodeAccessUnit(
                    with: &decoder,
                    sequence: 1,
                    parameterSetRevision: 7,
                    bytes: &bytes,
                    mutate: mutation.apply
                )
            }
        }

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                eventValue: 8,
                bytes: &bytes
            )
        }

        var empty = Data()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                bytes: &empty
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                bytes: &bytes,
                nativeBytes: DhBytes(data: nil, count: 1)
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                bytes: &bytes,
                nativeBytes: DhBytes(
                    data: UnsafePointer<UInt8>(bitPattern: 1),
                    count:
                    DeviceHubNativeMediaEventDecoder
                        .maximumAccessUnitByteCount + 1
                )
            )
        }
    }

    @Test("non-flat access-unit orientation uses the validated fallback")
    func geometryOrientationFallback() throws {
        for primary in [
            DH_ORIENTATION_UNKNOWN,
            DH_ORIENTATION_FACE_UP,
            DH_ORIENTATION_FACE_DOWN
        ] {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            var bytes = Data([0, 0, 0, 2, 0x02, 0x01])
            let decoded = try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 1,
                bytes: &bytes,
                mutate: {
                    $0.geometry.orientation = primary
                    $0.geometry.non_flat_orientation =
                        DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN
                    $0.geometry.orientation_locked = 1
                }
            )
            guard case let .accessUnit(accessUnit) = decoded else {
                Issue.record("Expected an access unit")
                continue
            }
            #expect(
                accessUnit.geometry.orientation == .portraitUpsideDown
            )
            #expect(accessUnit.geometry.isOrientationLocked)
        }

        for mutation in [
            AccessUnitMutation.orientation(UInt32.max),
            .fallback(UInt32.max)
        ] {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            var bytes = Data([0, 0, 0, 2, 0x02, 0x01])
            #expect(
                throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
            ) {
                try decodeAccessUnit(
                    with: &decoder,
                    sequence: 1,
                    parameterSetRevision: 1,
                    bytes: &bytes,
                    mutate: mutation.apply
                )
            }
        }

        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var bytes = Data([0, 0, 0, 2, 0x02, 0x01])
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 1,
                bytes: &bytes,
                mutate: {
                    $0.geometry.orientation = DH_ORIENTATION_FACE_UP
                    $0.geometry.non_flat_orientation =
                        DH_ORIENTATION_FACE_DOWN
                }
            )
        }
    }

    @Test("every discontinuity reason is preserved and unknown values fail")
    func discontinuityReasons() throws {
        let reasons: [
            (DhVideoDiscontinuity, DeviceHubNativeVideoDiscontinuityReason)
        ] = [
            (
                DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP,
                .sequenceGap
            ),
            (
                DH_VIDEO_DISCONTINUITY_TIMESTAMP_CHANGED_WITHOUT_MARKER,
                .timestampChangedWithoutMarker
            ),
            (
                DH_VIDEO_DISCONTINUITY_MALFORMED_PAYLOAD,
                .malformedPayload
            ),
            (DH_VIDEO_DISCONTINUITY_NAL_TOO_LARGE, .nalTooLarge),
            (
                DH_VIDEO_DISCONTINUITY_PARAMETER_SET_TOO_LARGE,
                .parameterSetTooLarge
            ),
            (
                DH_VIDEO_DISCONTINUITY_ACCESS_UNIT_TOO_LARGE,
                .accessUnitTooLarge
            ),
            (
                DH_VIDEO_DISCONTINUITY_TOO_MANY_NAL_UNITS,
                .tooManyNALUnits
            ),
            (
                DH_VIDEO_DISCONTINUITY_MISSING_PARAMETER_SETS,
                .missingParameterSets
            ),
            (
                DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM,
                .unexpectedStream
            )
        ]

        for (index, reason) in reasons.enumerated() {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            #expect(
                try decodeDiscontinuity(
                    with: &decoder,
                    sequence: 1,
                    reason: reason.0
                ) == .discontinuity(
                    DeviceHubNativeVideoDiscontinuity(
                        sequenceNumber: 1,
                        reason: reason.1
                    )
                ),
                "Failed reason at index \(index)"
            )
        }

        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64.max
            ) {
                try decoder.decodeMedia($0)
            }
        }
    }

    @Test("errors expose only a bounded sanitized category")
    func sanitizedErrors() {
        let error = DeviceHubNativeMediaEventDecodingError.invalidPayload

        #expect(
            error.description
                == "<redacted-native-media-decoding-error invalid-payload>"
        )
        #expect(error.debugDescription == error.description)
        #expect(
            error.customMirror.children.map(\.label) == ["failure"]
        )
        #expect(
            error.customMirror.children.first?.value as? String
                == error.description
        )
    }

    private func decodeDatagram(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        sourcePort: UInt16 = 50001,
        bytes: inout Data,
        nativeBytes: DhBytes? = nil,
        mutate: (inout DhVideoDatagram) -> Void = { _ in }
    ) throws -> DeviceHubNativeMediaEvent {
        try bytes.withUnsafeBytes { buffer in
            var datagram = DhVideoDatagram()
            datagram.bytes =
                nativeBytes
                    ?? DhBytes(
                        data: buffer.baseAddress?.assumingMemoryBound(
                            to: UInt8.self
                        ),
                        count: buffer.count
                    )
            datagram.source_port = sourcePort
            mutate(&datagram)
            return try withUnsafePointer(to: &datagram) { pointer in
                try withMediaEvent(
                    sequence: sequence,
                    kind: DH_EVENT_VIDEO_DATAGRAM,
                    mutate: { $0.video_datagram = pointer }
                ) {
                    try decoder.decodeMedia($0)
                }
            }
        }
    }

    private func decodeConfiguration(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        revision: UInt64,
        eventValue: UInt64? = nil,
        parameterSets: inout ParameterSets,
        overrideVideoBytes: DhBytes? = nil,
        mutate: (inout DhVideoConfiguration) -> Void = { _ in }
    ) throws -> DeviceHubNativeMediaEvent {
        try parameterSets.video.withUnsafeBytes { videoBuffer in
            try parameterSets.sequence.withUnsafeBytes { sequenceBuffer in
                try parameterSets.picture.withUnsafeBytes { pictureBuffer in
                    var configuration = DhVideoConfiguration()
                    configuration.revision = revision
                    configuration.pixel_width = 1290
                    configuration.pixel_height = 2796
                    configuration.orientation = DH_ORIENTATION_PORTRAIT
                    configuration.video_parameter_set =
                        overrideVideoBytes
                            ?? nativeBytes(videoBuffer)
                    configuration.sequence_parameter_set = nativeBytes(
                        sequenceBuffer
                    )
                    configuration.picture_parameter_set = nativeBytes(
                        pictureBuffer
                    )
                    mutate(&configuration)
                    return try withUnsafePointer(
                        to: &configuration
                    ) { pointer in
                        try withMediaEvent(
                            sequence: sequence,
                            kind: DH_EVENT_VIDEO_CONFIGURATION,
                            value: eventValue ?? revision,
                            mutate: {
                                $0.video_configuration = pointer
                            }
                        ) {
                            try decoder.decodeMedia($0)
                        }
                    }
                }
            }
        }
    }

    private func decodeAccessUnit(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        parameterSetRevision: UInt64,
        eventValue: UInt64? = nil,
        bytes: inout Data,
        nativeBytes: DhBytes? = nil,
        mutate: (inout DhVideoAccessUnit) -> Void = { _ in }
    ) throws -> DeviceHubNativeMediaEvent {
        try bytes.withUnsafeBytes { buffer in
            var accessUnit = DhVideoAccessUnit()
            accessUnit.bytes = nativeBytes ?? self.nativeBytes(buffer)
            accessUnit.parameter_set_revision = parameterSetRevision
            accessUnit.ssrc = 0x1234_5678
            accessUnit.rtp_timestamp = 0x9ABC_DEF0
            accessUnit.first_sequence_number = 65534
            accessUnit.last_sequence_number = 1
            accessUnit.is_sync = 1
            accessUnit.geometry = geometry()
            mutate(&accessUnit)
            return try withUnsafePointer(to: &accessUnit) { pointer in
                try withMediaEvent(
                    sequence: sequence,
                    kind: DH_EVENT_VIDEO_ACCESS_UNIT,
                    value: eventValue ?? parameterSetRevision,
                    mutate: { $0.video_access_unit = pointer }
                ) {
                    try decoder.decodeMedia($0)
                }
            }
        }
    }

    private func decodeDiscontinuity(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        reason: DhVideoDiscontinuity
    ) throws -> DeviceHubNativeMediaEvent {
        try withMediaEvent(
            sequence: sequence,
            kind: DH_EVENT_VIDEO_DISCONTINUITY,
            value: UInt64(reason)
        ) {
            try decoder.decodeMedia($0)
        }
    }

    private func withMediaEvent<Result>(
        sequence: UInt64 = 1,
        kind: DhEventKind,
        value: UInt64 = 0,
        generation: DhGeneration? = nil,
        mutate: (inout DhEvent) -> Void = { _ in },
        operation: (UnsafePointer<DhEvent>) throws -> Result
    ) rethrows -> Result {
        let nativeGeneration = DeviceHubNativeGeneration(
            self.generation.rawValue
        )
        var event = DhEvent()
        event.struct_size = UInt32(MemoryLayout<DhEvent>.size)
        event.abi_version = DeviceHubNativeABI.expectedVersion
        event.generation =
            generation
                ?? DhGeneration(
                    high: nativeGeneration.high,
                    low: nativeGeneration.low
                )
        event.sequence = sequence
        event.kind = kind
        event.state = DH_SESSION_STATE_CONNECTED
        event.phase = DH_CONNECTION_PHASE_STREAMING
        event.value = value
        mutate(&event)
        return try withUnsafePointer(to: &event, operation)
    }

    private func nativeBytes(
        _ buffer: UnsafeRawBufferPointer
    ) -> DhBytes {
        DhBytes(
            data: buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
            count: buffer.count
        )
    }

    private func geometry() -> DhDisplayGeometry {
        var geometry = DhDisplayGeometry()
        geometry.pixel_width = 2796
        geometry.pixel_height = 1290
        geometry.orientation = DH_ORIENTATION_LANDSCAPE_LEFT
        geometry.non_flat_orientation = DH_ORIENTATION_LANDSCAPE_LEFT
        return geometry
    }
}

private struct ParameterSets {
    var video = Data([0x40, 0x01])
    var sequence = Data([0x42, 0x01])
    var picture = Data([0x44, 0x01])
}

private enum ConfigurationMutation {
    case orientation(DhOrientation)
    case pixelHeight(UInt32)
    case pixelWidth(UInt32)
    case reserved
    case revision(UInt64)

    func apply(to configuration: inout DhVideoConfiguration) {
        switch self {
        case let .orientation(value):
            configuration.orientation = value
        case let .pixelHeight(value):
            configuration.pixel_height = value
        case let .pixelWidth(value):
            configuration.pixel_width = value
        case .reserved:
            configuration.reserved = 1
        case let .revision(value):
            configuration.revision = value
        }
    }
}

private enum AccessUnitMutation {
    case fallback(DhOrientation)
    case geometryReserved
    case isSync(UInt8)
    case orientation(DhOrientation)
    case orientationLocked(UInt8)
    case pixelHeight(UInt32)
    case pixelWidth(UInt32)
    case reserved
    case revision(UInt64)

    func apply(to accessUnit: inout DhVideoAccessUnit) {
        switch self {
        case let .fallback(value):
            accessUnit.geometry.non_flat_orientation = value
        case .geometryReserved:
            accessUnit.geometry.reserved.0 = 1
        case let .isSync(value):
            accessUnit.is_sync = value
        case let .orientation(value):
            accessUnit.geometry.orientation = value
        case let .orientationLocked(value):
            accessUnit.geometry.orientation_locked = value
        case let .pixelHeight(value):
            accessUnit.geometry.pixel_height = value
        case let .pixelWidth(value):
            accessUnit.geometry.pixel_width = value
        case .reserved:
            accessUnit.reserved.0 = 1
        case let .revision(value):
            accessUnit.parameter_set_revision = value
        }
    }
}
