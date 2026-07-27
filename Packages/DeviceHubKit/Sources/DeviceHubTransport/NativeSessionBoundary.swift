import DeviceHubCore
import Foundation

/// Capabilities implemented by the artifact-backed native session adapter.
///
/// Bit positions intentionally match Device Hub FFI ABI version 2. The Swift
/// package does not import that ABI, so package builds and tests remain usable
/// before an XCFramework has been generated.
public struct NativeSessionCapabilities:
    OptionSet,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let sessionLifecycle = Self(rawValue: 1 << 0)
    public static let generationTaggedEvents = Self(rawValue: 1 << 1)
    public static let sensitiveInputCopy = Self(rawValue: 1 << 2)
    public static let pairableHost = Self(rawValue: 1 << 3)
    public static let acknowledgedPairRecords = Self(rawValue: 1 << 4)
    public static let authenticatedReconnect = Self(rawValue: 1 << 5)
    public static let rsdMetadata = Self(rawValue: 1 << 6)
    public static let pngScreenshot = Self(rawValue: 1 << 7)
    public static let developerReadiness = Self(rawValue: 1 << 8)
    public static let controlStream = Self(rawValue: 1 << 9)
    public static let videoNegotiation = Self(rawValue: 1 << 10)
    public static let rawVideoDatagrams = Self(rawValue: 1 << 11)
    public static let hevcAccessUnits = Self(rawValue: 1 << 12)
    public static let touchInput = Self(rawValue: 1 << 13)
    public static let keyboardInput = Self(rawValue: 1 << 14)
    public static let hardwareButtonInput = Self(rawValue: 1 << 15)
    public static let rotation = Self(rawValue: 1 << 16)
    public static let splitMediaCallback = Self(rawValue: 1 << 17)
    public static let releaseAllInput = Self(rawValue: 1 << 18)
    public static let mediaGeometrySnapshots = Self(rawValue: 1 << 19)
    public static let pairVerifyDiscovery = Self(rawValue: 1 << 20)

    /// Minimum fail-closed capability set for Pairable Host onboarding.
    public static let requiredPairing: Self = [
        .sessionLifecycle,
        .generationTaggedEvents,
        .sensitiveInputCopy,
        .pairableHost,
        .acknowledgedPairRecords
    ]

    /// Minimum fail-closed set for shipping live viewing and control.
    public static let requiredLiveControl: Self = [
        .sessionLifecycle,
        .generationTaggedEvents,
        .sensitiveInputCopy,
        .authenticatedReconnect,
        .rsdMetadata,
        .pngScreenshot,
        .developerReadiness,
        .controlStream,
        .videoNegotiation,
        .rawVideoDatagrams,
        .hevcAccessUnits,
        .touchInput,
        .keyboardInput,
        .hardwareButtonInput,
        .rotation,
        .splitMediaCallback,
        .releaseAllInput,
        .mediaGeometrySnapshots,
        .pairVerifyDiscovery
    ]
}

/// Shape failures rejected before values reach an artifact-backed adapter.
public enum NativeSessionContractError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidAuthenticationTags
    case invalidDisplayGeometry
    case invalidKeyMaterial
    case invalidPersistenceRequestID
    case invalidPort
    case invalidScreenshot
    case invalidText
}

/// A sanitized native failure with no payload, endpoint, or key material.
public struct NativeSessionFailure:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Error,
    Equatable,
    Sendable
{
    public let code: String
    public let retryable: Bool
    public let stage: String

    public init(
        code: String,
        stage: String,
        retryable: Bool
    ) {
        guard
            Self.allowedCodes.contains(code),
            Self.allowedStages.contains(stage)
        else {
            self.code = "native_failure"
            self.retryable = false
            self.stage = "native_boundary"
            return
        }
        self.code = code
        self.retryable = retryable
        self.stage = stage
    }

    public var description: String {
        "<redacted-native-session-failure>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["failure": "<redacted>"],
            displayStyle: .struct
        )
    }

    private static let allowedCodes: Set<String> = [
        "bonjour_authentication_failed",
        "control_channel_closed",
        "control_queue_unavailable",
        "developer_image_connection_failed",
        "developer_image_incompatible",
        "developer_image_lookup_unsupported",
        "developer_image_lookup_presence_malformed",
        "developer_image_lookup_signature_array_malformed",
        "developer_image_lookup_signature_array_empty",
        "developer_image_lookup_signature_empty",
        "developer_image_lookup_signature_malformed",
        "developer_image_lookup_signature_missing",
        "developer_image_lookup_signature_type_unsupported",
        "developer_image_unavailable",
        "developer_mode_status_unsupported",
        "developer_mode_disabled",
        "dispatcher_start_failed",
        "display_service_connect_failed",
        "display_stream_start_failed",
        "error_serialization",
        "event_dispatch_unavailable",
        "invalid_argument",
        "invalid_input_transition",
        "invalid_rsd_metadata",
        "invalid_screenshot_png",
        "invalid_state",
        "invalid_tunnel_address",
        "invalid_tunnel_mtu",
        "invalid_tunnel_parameters",
        "native_failure",
        "input_cleanup_timeout",
        "input_delivery_failed",
        "input_service_connect_failed",
        "media_callback_unavailable",
        "media_sequence_exhausted",
        "orientation_service_connect_failed",
        "orientation_query_failed",
        "pair_record_commit_failed",
        "pair_setup_failed",
        "pair_verify_failed",
        "pairing_listener_accept_failed",
        "pairing_listener_address_failed",
        "pairing_listener_bind_failed",
        "pairing_listener_create_failed",
        "pairing_listener_dual_stack_failed",
        "pairing_listener_invalid_port",
        "pairing_listener_listen_failed",
        "pairing_listener_nonblocking_failed",
        "pairing_listener_runtime_failed",
        "panic",
        "persistence_dispatch_failed",
        "protocol_worker_start_failed",
        "protocol_worker_unavailable",
        "remote_pairing_connect_failed",
        "rsd_connect_failed",
        "rsd_handshake_failed",
        "runtime_start_failed",
        "rotation_failed",
        "screenshot_capture_failed",
        "screenshot_service_connect_failed",
        "screenshot_service_unavailable",
        "stale_persistence_request",
        "stale_generation",
        "stale_video_negotiation",
        "tls_psk_tunnel_failed",
        "tunnel_connect_failed",
        "tunnel_listener_failed",
        "tunnel_listener_invalid_port",
        "tunnel_shutdown_failed",
        "unsupported_device_orientation",
        "unsupported_protocol_version",
        "video_configuration_missing",
        "video_control_delivery_failed",
        "video_datagram_rejected",
        "video_negotiation_failed",
        "video_negotiation_rejected",
        "video_negotiation_timeout",
        "video_receiver_rejected",
        "video_stream_failed",
        "video_stream_receive_failed"
    ]

    private static let allowedStages: Set<String> = [
        "bonjour_authentication",
        "cd_tunnel",
        "control_stream",
        "developer_readiness",
        "display_stream",
        "ffi_boundary",
        "hardware_button_input",
        "input",
        "input_cleanup",
        "keyboard_input",
        "media_dispatch",
        "native_boundary",
        "pair_record_persistence",
        "pair_setup",
        "pair_verify",
        "pair_verify_m2_authentication",
        "pair_verify_m2_decryption",
        "pair_verify_m2_identifier",
        "pair_verify_m2_shape",
        "pair_verify_m2_signature",
        "pair_verify_m4_completion",
        "pair_verify_peer_rejection",
        "pair_verify_protocol",
        "pair_verify_timeout",
        "pair_verify_transport",
        "pairing_listener",
        "rsd_handshake",
        "rotation",
        "screenshot",
        "session_dispatch",
        "session_lifecycle",
        "session_teardown",
        "tls_psk_tunnel",
        "tunnel_listener",
        "touch_input",
        "video_control",
        "video_answer_extraction",
        "video_answer_parse",
        "video_apply_answer",
        "video_configure_receiver",
        "video_create_receiver",
        "video_generate_configuration",
        "video_generate_options",
        "video_negotiation",
        "video_start_receiver",
        "video_stream_group_missing",
        "video_stream_payload_encrypted",
        "video_stream_payload_invalid",
        "video_stream_payload_missing",
        "video_stream_selection_ambiguous",
        "video_stream_ssrc_mismatch",
        "video_stream_ssrc_invalid",
        "video_stream_ssrc_missing",
        "video_stream_ssrc_zero",
        "video_validate_receiver",
        "video_stream"
    ]
}

/// Stable controller material copied synchronously by the native constructor.
///
/// The Swift value is deliberately short-lived. Durable ownership remains in
/// the device-only Keychain store, while the native session copies and
/// zeroizes its own in-memory representation.
public struct NativeControllerIdentity:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Sendable
{
    public let alternateIRK: Data
    public let identifier: UUID
    public let longTermSecretKey: Data
    public let udid: String

    public init(
        identifier: UUID,
        udid: String,
        longTermSecretKey: Data,
        alternateIRK: Data
    ) throws {
        guard
            longTermSecretKey.count == 32,
            longTermSecretKey.contains(where: { $0 != 0 }),
            alternateIRK.count == 16,
            alternateIRK.contains(where: { $0 != 0 })
        else {
            throw NativeSessionContractError.invalidKeyMaterial
        }
        try NativeSessionValidation.requireText(
            udid,
            maximumUTF8Length: 256
        )
        self.alternateIRK = alternateIRK
        self.identifier = identifier
        self.longTermSecretKey = longTermSecretKey
        self.udid = udid
    }

    public var description: String {
        "<redacted-native-controller-identity>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["credentials": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Address family for a Foundation-resolved numeric endpoint.
public enum NativeIPAddressFamily: Equatable, Sendable {
    case ipv4
    case ipv6
}

/// One numeric endpoint copied from a system Bonjour resolution.
public struct NativeResolvedEndpoint:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let address: Data
    public let family: NativeIPAddressFamily
    public let port: UInt16
    public let scopeID: UInt32

    public init(
        family: NativeIPAddressFamily,
        address: Data,
        scopeID: UInt32,
        port: UInt16
    ) throws {
        guard port != 0 else {
            throw NativeSessionContractError.invalidPort
        }
        switch family {
        case .ipv4:
            let isLoopback = address.first == 127
            let isLimitedBroadcast =
                address.elementsEqual([255, 255, 255, 255])
            guard
                address.count == 4,
                scopeID == 0,
                address.contains(where: { $0 != 0 }),
                !(224 ... 239).contains(Int(address[0])),
                !isLoopback,
                !isLimitedBroadcast
            else {
                throw NativeSessionContractError.invalidAddress
            }

        case .ipv6:
            let isLoopback =
                address.dropLast().allSatisfy { $0 == 0 }
                    && address.last == 1
            guard
                address.count == 16,
                address.contains(where: { $0 != 0 }),
                address[0] != 0xFF,
                !isLoopback
            else {
                throw NativeSessionContractError.invalidAddress
            }
            let isLinkLocal =
                address[0] == 0xFE && address[1] & 0xC0 == 0x80
            guard
                (isLinkLocal && scopeID != 0)
                || (!isLinkLocal && scopeID == 0)
            else {
                throw NativeSessionContractError.invalidAddress
            }
        }

        self.address = address
        self.family = family
        self.port = port
        self.scopeID = scopeID
    }

    public var description: String {
        "<redacted-native-endpoint>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["endpoint": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Durable milestone copied to the native Pair Verify constructor.
public enum NativePairingCompletion: Equatable, Sendable {
    case committed
    case provisional
}

/// Authenticated target material copied synchronously for Pair Verify.
public struct NativeTargetPairingRecord:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Sendable
{
    public let accountIdentifier: String
    public let completion: NativePairingCompletion
    public let deviceID: DeviceID
    public let displayName: String
    public let peerAlternateIRK: Data
    public let peerIdentifier: String
    public let peerPublicKey: Data
    public let productType: String

    public init(
        deviceID: DeviceID,
        accountIdentifier: String,
        peerIdentifier: String,
        peerPublicKey: Data,
        peerAlternateIRK: Data,
        displayName: String,
        productType: String,
        completion: NativePairingCompletion
    ) throws {
        guard
            peerPublicKey.count == 32,
            peerPublicKey.contains(where: { $0 != 0 }),
            peerAlternateIRK.count == 16,
            peerAlternateIRK.contains(where: { $0 != 0 })
        else {
            throw NativeSessionContractError.invalidKeyMaterial
        }
        try NativeSessionValidation.requireText(
            deviceID.rawValue,
            maximumUTF8Length: 256
        )
        try NativeSessionValidation.requireText(
            accountIdentifier,
            maximumUTF8Length: 256
        )
        try NativeSessionValidation.requireText(
            peerIdentifier,
            maximumUTF8Length: 256
        )
        try NativeSessionValidation.requireText(
            displayName,
            maximumUTF8Length: 256
        )
        try NativeSessionValidation.requireText(
            productType,
            maximumUTF8Length: 128
        )
        self.accountIdentifier = accountIdentifier
        self.completion = completion
        self.deviceID = deviceID
        self.displayName = displayName
        self.peerAlternateIRK = peerAlternateIRK
        self.peerIdentifier = peerIdentifier
        self.peerPublicKey = peerPublicKey
        self.productType = productType
    }

    public var description: String {
        "<redacted-native-target-pairing-record>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["credentials": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Authenticated peer values borrowed from a native pair-record event.
public struct NativeVerifiedPeer:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let accountIdentifier: String
    public let deviceID: DeviceID
    public let displayName: String
    public let peerAlternateIRK: Data
    public let peerIdentifier: String
    public let peerPublicKey: Data
    public let productType: String

    public init(
        deviceID: DeviceID,
        accountIdentifier: String,
        peerIdentifier: String,
        peerPublicKey: Data,
        peerAlternateIRK: Data,
        displayName: String,
        productType: String
    ) throws {
        let record = try NativeTargetPairingRecord(
            deviceID: deviceID,
            accountIdentifier: accountIdentifier,
            peerIdentifier: peerIdentifier,
            peerPublicKey: peerPublicKey,
            peerAlternateIRK: peerAlternateIRK,
            displayName: displayName,
            productType: productType,
            completion: .provisional
        )
        self.accountIdentifier = record.accountIdentifier
        self.deviceID = record.deviceID
        self.displayName = record.displayName
        self.peerAlternateIRK = record.peerAlternateIRK
        self.peerIdentifier = record.peerIdentifier
        self.peerPublicKey = record.peerPublicKey
        self.productType = record.productType
    }

    public var description: String {
        "<redacted-native-verified-peer>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["identity": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Semantic `_remotepairing._tcp` values already validated by Swift.
public struct NativeRemoteService:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Sendable
{
    public let authTags: [Data]
    public let endpoint: NativeResolvedEndpoint
    public let identifier: UUID

    public init(
        endpoint: NativeResolvedEndpoint,
        identifier: UUID,
        authTags: [Data]
    ) throws {
        guard
            !authTags.isEmpty,
            authTags.count <= Self.maximumAuthenticationTagCount,
            authTags.allSatisfy({ $0.count == 6 }),
            Set(authTags).count == authTags.count
        else {
            throw NativeSessionContractError.invalidAuthenticationTags
        }
        self.authTags = authTags
        self.endpoint = endpoint
        self.identifier = identifier
    }

    public static let flags: UInt8 = 0
    public static let minimumWireProtocolVersion: UInt8 = 8
    public static let wireProtocolVersion: UInt8 = 26

    private static let maximumAuthenticationTagCount = 32

    public var description: String {
        "<redacted-native-remote-service>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["service": "<redacted>"],
            displayStyle: .struct
        )
    }
}

enum NativeSessionValidation {
    static func requireText(
        _ value: String,
        maximumUTF8Length: Int
    ) throws {
        guard
            !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            value.utf8.count <= maximumUTF8Length,
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw NativeSessionContractError.invalidText
        }
    }
}
