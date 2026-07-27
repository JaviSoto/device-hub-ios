import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native event decoding")
struct DeviceHubNativeEventDecoderTests {
    private let generation = SessionGeneration(
        rawValue: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    )

    @Test("control callbacks require the exact ABI, generation, and sequence")
    func controlEnvelopeValidation() throws {
        var decoder = DeviceHubNativeEventDecoder(generation: generation)

        #expect(
            try withEvent(kind: DH_EVENT_SESSION_STARTED) {
                try decoder.decodeControl($0)
            } == .event(.started)
        )
        #expect(
            try withEvent(
                sequence: 2,
                kind: DH_EVENT_SESSION_COMPLETED
            ) {
                try decoder.decodeControl($0)
            } == .event(.completed)
        )

        #expect(
            throws: DeviceHubNativeEventDecodingError.invalidSequence
        ) {
            try withEvent(
                sequence: 4,
                kind: DH_EVENT_SESSION_CANCELLED
            ) {
                try decoder.decodeControl($0)
            }
        }

        #expect(
            throws: DeviceHubNativeEventDecodingError.staleGeneration
        ) {
            try withEvent(
                sequence: 3,
                kind: DH_EVENT_SESSION_CANCELLED,
                generation: DhGeneration(high: 99, low: 100)
            ) {
                try decoder.decodeControl($0)
            }
        }
    }

    @Test("borrowed pairing-code bytes are copied before callback return")
    func pairingCodeCopy() throws {
        var decoder = DeviceHubNativeEventDecoder(generation: generation)
        var payload = Data("814206".utf8)

        let decoded = try payload.withUnsafeMutableBytes { bytes in
            try withEvent(
                kind: DH_EVENT_PAIRING_CODE,
                payload: UnsafeRawBufferPointer(bytes)
            ) {
                try decoder.decodeControl($0)
            }
        }
        payload.resetBytes(in: payload.indices)

        guard case let .event(.pairingCode(code)) = decoded else {
            Issue.record("Expected a copied pairing code")
            return
        }
        #expect(code.displayValue == "814206")
    }

    @Test("video negotiation remains an internal copied control event")
    func videoNegotiationCopy() throws {
        var decoder = DeviceHubNativeEventDecoder(generation: generation)
        var payload = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])

        let decoded = try payload.withUnsafeMutableBytes { bytes in
            try withEvent(
                kind: DH_EVENT_VIDEO_NEGOTIATION_ANSWER,
                payload: UnsafeRawBufferPointer(bytes)
            ) {
                try decoder.decodeControl($0)
            }
        }
        payload.resetBytes(in: payload.indices)

        #expect(
            decoded == .videoNegotiationAnswer(
                Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])
            )
        )
    }

    @Test("landscape control geometry uses native portrait dimensions")
    func landscapeControlGeometryUsesNativePortraitDimensions() throws {
        var geometry = DhDisplayGeometry()
        geometry.pixel_width = 2272
        geometry.pixel_height = 1504
        geometry.orientation = DH_ORIENTATION_LANDSCAPE_LEFT
        geometry.non_flat_orientation = DH_ORIENTATION_LANDSCAPE_LEFT

        let decoded = try withUnsafePointer(to: &geometry) { geometry in
            try withEvent(
                kind: DH_EVENT_DISPLAY_GEOMETRY,
                displayGeometry: geometry
            ) { event in
                var decoder = DeviceHubNativeEventDecoder(
                    generation: generation
                )
                return try decoder.decodeControl(event)
            }
        }

        guard case let .event(.displayGeometry(decodedGeometry)) = decoded
        else {
            Issue.record("Expected display geometry")
            return
        }
        #expect(
            decodedGeometry.pixelSize
                == PixelSize(width: 1504, height: 2272)
        )
        #expect(decodedGeometry.orientation == .landscapeLeft)
    }

    @Test("malformed payload spans and unknown event kinds fail closed")
    func malformedEvent() {
        var decoder = DeviceHubNativeEventDecoder(generation: generation)

        #expect(
            throws: DeviceHubNativeEventDecodingError.invalidPayload
        ) {
            try withEvent(
                kind: DH_EVENT_PAIRING_CODE,
                nativePayload: DhBytes(data: nil, count: 6)
            ) {
                try decoder.decodeControl($0)
            }
        }

        var secondDecoder = DeviceHubNativeEventDecoder(
            generation: generation
        )
        #expect(
            throws: DeviceHubNativeEventDecodingError.unsupportedEvent
        ) {
            try withEvent(kind: UInt32.max) {
                try secondDecoder.decodeControl($0)
            }
        }
    }

    private func withEvent<Result>(
        sequence: UInt64 = 1,
        kind: DhEventKind,
        payload: UnsafeRawBufferPointer = UnsafeRawBufferPointer(
            start: nil,
            count: 0
        ),
        nativePayload: DhBytes? = nil,
        generation: DhGeneration? = nil,
        displayGeometry: UnsafePointer<DhDisplayGeometry>? = nil,
        operation: (UnsafePointer<DhEvent>) throws -> Result
    ) rethrows -> Result {
        let expectedGeneration = DeviceHubNativeGeneration(
            self.generation.rawValue
        )
        var event = DhEvent()
        event.struct_size = UInt32(MemoryLayout<DhEvent>.size)
        event.abi_version = DeviceHubNativeABI.expectedVersion
        event.generation = generation
            ?? DhGeneration(
                high: expectedGeneration.high,
                low: expectedGeneration.low
            )
        event.sequence = sequence
        event.kind = kind
        event.state = DH_SESSION_STATE_RUNNING
        event.phase = DH_CONNECTION_PHASE_IDLE
        event.payload =
            nativePayload
                ?? DhBytes(
                    data: payload.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    count: payload.count
                )
        event.display_geometry = displayGeometry
        return try withUnsafePointer(to: &event, operation)
    }
}
