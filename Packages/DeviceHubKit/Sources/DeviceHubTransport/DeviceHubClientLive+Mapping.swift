import DeviceHubCore
import DeviceHubPersistence

extension TargetPairingRecord {
    func deviceSummary(
        reachability: DeviceReachability
    ) -> DeviceSummary {
        DeviceSummary(
            id: deviceID,
            name: displayName,
            productType: productType,
            operatingSystemVersion: operatingSystemVersion,
            pairingState: .paired,
            reachability: reachability
        )
    }
}

extension NativeConnectionPhase {
    var connectionPhase: ConnectionPhase? {
        switch self {
        case .idle:
            .locating
        case .verifyingPairing:
            .verifyingPairing
        case .openingTunnel:
            .openingTunnel
        case .discoveringServices:
            .discoveringServices
        case .capturingScreenshot:
            .capturingScreenshot
        case .preparingDevice:
            .preparingDeveloperServices
        case .openingInput,
             .startingDisplayStream,
             .waitingForVideoReceiver:
            .startingDisplay
        case .ready, .streaming:
            .ready
        case .awaitingPairingPeer,
             .bindingPairingListener,
             .pairing,
             .persistingPairRecord:
            nil
        }
    }
}

func mapNativeFailure(
    _ failure: NativeSessionFailure
) -> DeviceHubError {
    switch failure.code {
    case "bonjour_authentication_failed",
         "pair_verify_failed":
        .peerAuthenticationFailed
    case "developer_mode_disabled":
        .developerModeDisabled
    case "developer_image_unavailable":
        .developerImageUnavailable
    case "developer_image_incompatible":
        .developerImageIncompatible
    case "developer_image_lookup_presence_malformed",
         "developer_image_lookup_signature_array_malformed",
         "developer_image_lookup_signature_array_empty",
         "developer_image_lookup_signature_empty",
         "developer_image_lookup_signature_malformed",
         "developer_image_lookup_signature_missing",
         "developer_image_lookup_signature_type_unsupported",
         "developer_image_lookup_unsupported",
         "developer_mode_status_unsupported",
         "video_negotiation_rejected":
        .unsupportedProtocolVersion
    case "pair_setup_failed":
        .pairingRejected
    case "pairing_listener_accept_failed":
        .pairingTimedOut
    case "remote_pairing_connect_failed":
        .deviceOffline
    case "screenshot_capture_failed",
         "screenshot_service_connect_failed",
         "screenshot_service_unavailable",
         "video_datagram_rejected",
         "video_negotiation_failed",
         "video_negotiation_timeout",
         "video_stream_failed",
         "video_stream_receive_failed":
        .decoderFailed
    case "invalid_argument",
         "invalid_rsd_metadata",
         "invalid_screenshot_png":
        .malformedDeviceAnnouncement
    default:
        .secureConnectionFailed
    }
}
