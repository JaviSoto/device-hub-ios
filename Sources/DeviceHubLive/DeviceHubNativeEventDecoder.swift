import DeviceHubCore
import DeviceHubFFI
import DeviceHubTransport
import Foundation

/// Fail-closed reasons a borrowed native callback cannot enter Swift state.
enum DeviceHubNativeEventDecodingError: Error, Equatable, Sendable {
    case invalidEnvelope
    case invalidPayload
    case invalidSequence
    case staleGeneration
    case unsupportedEvent
}

/// Copied control-plane output from one native callback.
///
/// Video negotiation is kept inside the imperative shell because it must be
/// acknowledged by the retained AVConference receiver before the transport
/// feature may advance.
enum DeviceHubNativeControlEvent: Equatable, Sendable {
    case event(NativeSessionEvent)
    case videoNegotiationAnswer(Data)
}

/// Converts coded display dimensions into the native portrait touch space.
enum DeviceHubNativeGeometry {
    static func nativePortraitPixelSize(
        _ encodedPixelSize: PixelSize,
        orientation: ScreenOrientation
    ) -> PixelSize {
        switch orientation {
        case .portrait, .portraitUpsideDown:
            encodedPixelSize
        case .landscapeLeft, .landscapeRight:
            PixelSize(
                width: encodedPixelSize.height,
                height: encodedPixelSize.width
            )
        }
    }
}

/// Stateful decoder for one native session generation.
///
/// Rust owns every callback pointer and byte span only until the callback
/// returns. This decoder validates the complete envelope, copies all retained
/// bytes synchronously, and enforces a lossless control-plane sequence.
struct DeviceHubNativeEventDecoder {
    private static let maximumPayloadByteCount = 64 * 1024 * 1024

    private let expectedGeneration: DeviceHubNativeGeneration
    private var lastControlSequence: UInt64?

    init(generation: SessionGeneration) {
        expectedGeneration = DeviceHubNativeGeneration(generation.rawValue)
    }

    mutating func decodeControl(
        _ pointer: UnsafePointer<DhEvent>?
    ) throws(DeviceHubNativeEventDecodingError) -> DeviceHubNativeControlEvent {
        guard let pointer else {
            throw .invalidEnvelope
        }
        let native = pointer.pointee
        try validateEnvelope(native)
        try validateControlSequence(native.sequence)

        let decoded: DeviceHubNativeControlEvent
        do {
            decoded = try decodeValidatedControlEvent(native)
        } catch let error as DeviceHubNativeEventDecodingError {
            throw error
        } catch {
            throw .invalidPayload
        }
        lastControlSequence = native.sequence
        return decoded
    }

    private func validateEnvelope(
        _ event: DhEvent
    ) throws(DeviceHubNativeEventDecodingError) {
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
    }

    private func validateControlSequence(
        _ sequence: UInt64
    ) throws(DeviceHubNativeEventDecodingError) {
        let expected = lastControlSequence.map { previous in
            previous == UInt64.max ? nil : previous + 1
        } ?? 1
        guard let expected, sequence == expected else {
            throw .invalidSequence
        }
    }

    private func decodeValidatedControlEvent(
        _ event: DhEvent
    ) throws -> DeviceHubNativeControlEvent {
        switch event.kind {
        case DH_EVENT_SESSION_STARTED:
            return .event(.started)

        case DH_EVENT_PHASE_CHANGED:
            return try .event(.phaseChanged(connectionPhase(event.phase)))

        case DH_EVENT_PAIRING_LISTENER_READY:
            guard
                event.value > 0,
                event.value <= UInt64(UInt16.max)
            else {
                throw DeviceHubNativeEventDecodingError.invalidPayload
            }
            return .event(.pairingListenerReady(port: UInt16(event.value)))

        case DH_EVENT_PAIRING_CODE:
            let text = try requiredText(event.payload)
            guard let code = PairingCode(text) else {
                throw DeviceHubNativeEventDecodingError.invalidPayload
            }
            return .event(.pairingCode(code))

        case DH_EVENT_PAIR_RECORD_PROVISIONAL:
            return try .event(
                .pairRecordProvisional(
                    requestID: persistenceRequestID(event.request_id),
                    peer: verifiedPeer(event.peer)
                )
            )

        case DH_EVENT_PAIR_RECORD_COMMITTED:
            return try .event(
                .pairRecordCommitted(
                    requestID: persistenceRequestID(event.request_id),
                    peer: verifiedPeer(event.peer)
                )
            )

        case DH_EVENT_AUTHENTICATED:
            return .event(.authenticated)

        case DH_EVENT_RSD_READY:
            return try .event(.rsdReady(rsdMetadata(event.rsd)))

        case DH_EVENT_SCREENSHOT_PNG:
            guard
                event.image_width > 0,
                event.image_height > 0,
                let width = Int(exactly: event.image_width),
                let height = Int(exactly: event.image_height)
            else {
                throw DeviceHubNativeEventDecodingError.invalidPayload
            }
            let screenshot = try NativeScreenshot(
                bytes: copy(event.payload),
                pixelSize: PixelSize(width: width, height: height)
            )
            return .event(.screenshot(screenshot))

        case DH_EVENT_SESSION_COMPLETED:
            return .event(.completed)

        case DH_EVENT_SESSION_FAILED:
            return try .event(
                .failed(
                    DeviceHubNativeFailureDecoder.decode(
                        copy(event.payload)
                    )
                )
            )

        case DH_EVENT_SESSION_CANCELLED:
            return .event(.cancelled)

        case DH_EVENT_VIDEO_NEGOTIATION_ANSWER:
            let payload = try copy(event.payload)
            guard !payload.isEmpty else {
                throw DeviceHubNativeEventDecodingError.invalidPayload
            }
            return .videoNegotiationAnswer(payload)

        case DH_EVENT_INPUT_READY:
            return .event(.inputReady)

        case DH_EVENT_DISPLAY_GEOMETRY:
            return try .event(
                .displayGeometry(
                    displayGeometry(event.display_geometry)
                )
            )

        default:
            throw DeviceHubNativeEventDecodingError.unsupportedEvent
        }
    }

    private func persistenceRequestID(
        _ rawValue: UInt64
    ) throws(DeviceHubNativeEventDecodingError) -> NativePersistenceRequestID {
        guard let requestID = NativePersistenceRequestID(rawValue: rawValue)
        else {
            throw .invalidPayload
        }
        return requestID
    }

    private func verifiedPeer(
        _ pointer: UnsafePointer<DhVerifiedPeer>?
    ) throws -> NativeVerifiedPeer {
        guard let pointer else {
            throw DeviceHubNativeEventDecodingError.invalidPayload
        }
        let peer = pointer.pointee
        return try NativeVerifiedPeer(
            deviceID: DeviceID(rawValue: requiredText(peer.device_id)),
            accountIdentifier: requiredText(peer.account_identifier),
            peerIdentifier: requiredText(peer.peer_identifier),
            peerPublicKey: copy(peer.peer_public_key),
            peerAlternateIRK: copy(peer.peer_alternate_irk),
            displayName: requiredText(peer.display_name),
            productType: requiredText(peer.product_type)
        )
    }

    private func rsdMetadata(
        _ pointer: UnsafePointer<DhRsdMetadata>?
    ) throws -> NativeRSDMetadata {
        guard let pointer else {
            throw DeviceHubNativeEventDecodingError.invalidPayload
        }
        let metadata = pointer.pointee
        guard
            let uuid = try UUID(uuidString: requiredText(metadata.uuid))
        else {
            throw DeviceHubNativeEventDecodingError.invalidPayload
        }
        return try NativeRSDMetadata(
            uuid: uuid,
            operatingSystemVersion: optionalText(
                metadata.operating_system_version
            ),
            buildVersion: optionalText(metadata.build_version),
            uniqueDeviceID: DeviceID(
                rawValue: requiredText(metadata.unique_device_id)
            ),
            productType: requiredText(metadata.product_type),
            protocolVersion: metadata.protocol_version,
            serviceCount: metadata.service_count,
            screenshotServiceAvailable:
            metadata.screenshot_service_available == 1
        )
    }

    private func displayGeometry(
        _ pointer: UnsafePointer<DhDisplayGeometry>?
    ) throws -> NativeDisplayGeometry {
        guard let pointer else {
            throw DeviceHubNativeEventDecodingError.invalidPayload
        }
        let geometry = pointer.pointee
        let orientation = try screenOrientation(
            geometry.orientation,
            fallback: geometry.non_flat_orientation
        )
        guard
            let width = Int(exactly: geometry.pixel_width),
            let height = Int(exactly: geometry.pixel_height)
        else {
            throw DeviceHubNativeEventDecodingError.invalidPayload
        }
        let encodedPixelSize = PixelSize(width: width, height: height)
        return try NativeDisplayGeometry(
            pixelSize: DeviceHubNativeGeometry.nativePortraitPixelSize(
                encodedPixelSize,
                orientation: orientation
            ),
            orientation: orientation
        )
    }

    private func screenOrientation(
        _ value: DhOrientation,
        fallback: DhOrientation
    ) throws(DeviceHubNativeEventDecodingError) -> ScreenOrientation {
        let resolved = switch value {
        case DH_ORIENTATION_PORTRAIT,
             DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN,
             DH_ORIENTATION_LANDSCAPE_LEFT,
             DH_ORIENTATION_LANDSCAPE_RIGHT:
            value
        default:
            fallback
        }
        return switch resolved {
        case DH_ORIENTATION_PORTRAIT:
            .portrait
        case DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN:
            .portraitUpsideDown
        case DH_ORIENTATION_LANDSCAPE_LEFT:
            .landscapeLeft
        case DH_ORIENTATION_LANDSCAPE_RIGHT:
            .landscapeRight
        default:
            throw .invalidPayload
        }
    }

    private func connectionPhase(
        _ phase: DhConnectionPhase
    ) throws(DeviceHubNativeEventDecodingError) -> NativeConnectionPhase {
        switch phase {
        case DH_CONNECTION_PHASE_IDLE:
            return .idle
        case DH_CONNECTION_PHASE_BINDING_PAIRING_LISTENER:
            return .bindingPairingListener
        case DH_CONNECTION_PHASE_AWAITING_PAIRING_PEER:
            return .awaitingPairingPeer
        case DH_CONNECTION_PHASE_PAIRING:
            return .pairing
        case DH_CONNECTION_PHASE_PERSISTING_PAIR_RECORD:
            return .persistingPairRecord
        case DH_CONNECTION_PHASE_VERIFYING_PAIRING:
            return .verifyingPairing
        case DH_CONNECTION_PHASE_OPENING_TUNNEL:
            return .openingTunnel
        case DH_CONNECTION_PHASE_DISCOVERING_SERVICES:
            return .discoveringServices
        case DH_CONNECTION_PHASE_CAPTURING_SCREENSHOT:
            return .capturingScreenshot
        case DH_CONNECTION_PHASE_READY:
            return .ready
        case DH_CONNECTION_PHASE_PREPARING_DEVICE:
            return .preparingDevice
        case DH_CONNECTION_PHASE_STARTING_DISPLAY_STREAM:
            return .startingDisplayStream
        case DH_CONNECTION_PHASE_WAITING_FOR_VIDEO_RECEIVER:
            return .waitingForVideoReceiver
        case DH_CONNECTION_PHASE_OPENING_INPUT:
            return .openingInput
        case DH_CONNECTION_PHASE_STREAMING:
            return .streaming
        default:
            throw .invalidPayload
        }
    }

    private func requiredText(
        _ bytes: DhBytes
    ) throws(DeviceHubNativeEventDecodingError) -> String {
        let data = try copy(bytes)
        guard
            !data.isEmpty,
            let string = String(data: data, encoding: .utf8),
            !string.isEmpty
        else {
            throw .invalidPayload
        }
        return string
    }

    private func optionalText(
        _ bytes: DhBytes
    ) throws(DeviceHubNativeEventDecodingError) -> String? {
        let data = try copy(bytes)
        guard !data.isEmpty else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw .invalidPayload
        }
        return string
    }

    private func copy(
        _ bytes: DhBytes
    ) throws(DeviceHubNativeEventDecodingError) -> Data {
        guard bytes.count <= Self.maximumPayloadByteCount else {
            throw .invalidPayload
        }
        guard bytes.count >= 1 else {
            return Data()
        }
        guard let pointer = bytes.data else {
            throw .invalidPayload
        }
        return Data(bytes: pointer, count: bytes.count)
    }
}
