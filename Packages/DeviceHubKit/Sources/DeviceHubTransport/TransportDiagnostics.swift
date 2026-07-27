import DeviceHubCore
import DeviceHubDiagnostics

func mapAvailabilityFailure(_ error: any Error) -> DeviceHubError {
    guard let error = error as? RemotePairingBonjourError else {
        return .corruptPairingRecord
    }
    switch error {
    case let .browserFailed(code),
         let .browserStartFailed(code),
         let .publisherFailed(code),
         let .publisherStartFailed(code):
        return code == -65570 ? .localNetworkDenied : .deviceOffline
    case .invalidPairableHostConfiguration,
         .pairingRecordsUnavailable:
        return .corruptPairingRecord
    }
}

func diagnosticFailureCode(
    for error: DeviceHubError
) -> DiagnosticFailureCode {
    switch error {
    case .localNetworkDenied: .localNetworkDenied
    case .pairingTimedOut: .pairingTimedOut
    case .pairingRejected: .pairingRejected
    case .incorrectPairingCode: .incorrectPairingCode
    case .needsPairing: .needsPairing
    case .developerModeDisabled: .developerModeDisabled
    case .deviceLocked: .deviceLocked
    case .deviceBusy: .deviceBusy
    case .developerImageUnavailable: .developerImageUnavailable
    case .developerImageIncompatible: .developerImageIncompatible
    case .corruptPairingRecord: .corruptPairingRecord
    case .peerAuthenticationFailed: .peerAuthenticationFailed
    case .malformedDeviceAnnouncement: .malformedAnnouncement
    case .unsupportedProtocolVersion: .unsupportedProtocolVersion
    case .deviceOffline: .deviceOffline
    case .connectionLost: .connectionLost
    case .secureConnectionFailed: .secureConnectionFailed
    case .mediaStalled: .mediaStalled
    case .decoderFailed: .decoderFailed
    }
}

func diagnosticRetryability(
    for error: DeviceHubError
) -> DiagnosticRetryability {
    switch error.retryability {
    case .automatic: .automatic
    case .userInitiated: .userInitiated
    case .afterRemedy: .afterRemedy
    case .notRetryable: .never
    }
}

func diagnosticCategory(
    for stage: DiagnosticStage
) -> DiagnosticCategory {
    switch stage {
    case .advertisingPairing,
         .pairing,
         .pairingComplete,
         .savingPairing,
         .waitingForPairingCode:
        .pairing
    case .applyingVideoAnswer,
         .capturingScreenshot,
         .configuringVideoReceiver,
         .creatingVideoReceiver,
         .decoding,
         .displayStalled,
         .displayStopped,
         .firstVisual,
         .generatingVideoConfiguration,
         .generatingVideoOptions,
         .startingDisplay,
         .startingVideoReceiver,
         .validatingVideoReceiver:
        .media
    case .openingTunnel:
        .tunnel
    case .locating:
        .discovery
    default:
        .connection
    }
}

func diagnosticService(
    for stage: DiagnosticStage
) -> DiagnosticService {
    switch stage {
    case .capturingScreenshot:
        .screenshot
    case .discoveringServices:
        .remoteServiceDiscovery
    case .openingTunnel:
        .tunnel
    case .applyingVideoAnswer,
         .configuringVideoReceiver,
         .creatingVideoReceiver,
         .generatingVideoConfiguration,
         .generatingVideoOptions,
         .startingDisplay,
         .startingVideoReceiver,
         .validatingVideoReceiver,
         .displayStalled,
         .displayStopped,
         .firstVisual,
         .decoding:
        .screenSharing
    default:
        .remotePairing
    }
}
