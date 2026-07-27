/// Failures that can cross the protocol boundary into application state.
///
/// The cases deliberately omit transport addresses, service names, packet
/// details, and underlying error strings. Those belong in redacted diagnostics,
/// not feature state or user-facing copy.
public enum DeviceHubError: Error, CaseIterable, Codable, Hashable, Sendable {
    case localNetworkDenied
    case pairingTimedOut
    case pairingRejected
    case incorrectPairingCode
    case needsPairing
    case developerModeDisabled
    case deviceLocked
    case deviceBusy
    case developerImageUnavailable
    case developerImageIncompatible

    case corruptPairingRecord
    case peerAuthenticationFailed
    case malformedDeviceAnnouncement
    case unsupportedProtocolVersion

    case deviceOffline
    case connectionLost
    case secureConnectionFailed
    case mediaStalled
    case decoderFailed

    public enum Classification: Codable, Equatable, Sendable {
        case actionable
        case integrity
        case transient
    }

    public enum Retryability: Codable, Equatable, Sendable {
        case automatic
        case userInitiated
        case afterRemedy
        case notRetryable
    }

    public enum Remedy: Codable, Equatable, Sendable {
        case retry
        case grantLocalNetworkAccess
        case pairAgain
        case enableDeveloperMode
        case unlockDevice
        case stopOtherRemoteSession
        case prepareWithXcode
        case updateApp
        case bringDeviceNearby
        case none

        public var actionTitle: String {
            switch self {
            case .retry:
                "Try Again"
            case .grantLocalNetworkAccess:
                "Open Settings"
            case .pairAgain:
                "Pair Again"
            case .enableDeveloperMode:
                "Show Instructions"
            case .unlockDevice:
                "Try Again"
            case .stopOtherRemoteSession:
                "Try Again"
            case .prepareWithXcode:
                "Show Xcode Steps"
            case .updateApp:
                "Check for Update"
            case .bringDeviceNearby:
                "Keep Trying"
            case .none:
                ""
            }
        }
    }

    public struct UserFacingCopy: Equatable, Sendable {
        public let message: String
        public let title: String

        public init(title: String, message: String) {
            self.message = message
            self.title = title
        }
    }

    public var classification: Classification {
        switch self {
        case .localNetworkDenied,
             .pairingTimedOut,
             .pairingRejected,
             .incorrectPairingCode,
             .needsPairing,
             .developerModeDisabled,
             .deviceLocked,
             .deviceBusy,
             .developerImageUnavailable,
             .developerImageIncompatible:
            .actionable

        case .corruptPairingRecord,
             .peerAuthenticationFailed,
             .malformedDeviceAnnouncement,
             .unsupportedProtocolVersion:
            .integrity

        case .deviceOffline,
             .connectionLost,
             .secureConnectionFailed,
             .mediaStalled,
             .decoderFailed:
            .transient
        }
    }

    public var retryability: Retryability {
        switch self {
        case .deviceOffline,
             .connectionLost,
             .secureConnectionFailed,
             .mediaStalled,
             .decoderFailed:
            .automatic

        case .pairingTimedOut,
             .pairingRejected,
             .incorrectPairingCode:
            .userInitiated

        case .localNetworkDenied,
             .needsPairing,
             .developerModeDisabled,
             .deviceLocked,
             .deviceBusy,
             .developerImageUnavailable,
             .developerImageIncompatible,
             .corruptPairingRecord,
             .peerAuthenticationFailed,
             .unsupportedProtocolVersion:
            .afterRemedy

        case .malformedDeviceAnnouncement:
            .notRetryable
        }
    }

    public var remedy: Remedy {
        switch self {
        case .localNetworkDenied:
            .grantLocalNetworkAccess
        case .pairingTimedOut,
             .pairingRejected,
             .incorrectPairingCode,
             .secureConnectionFailed,
             .mediaStalled,
             .decoderFailed:
            .retry
        case .needsPairing,
             .corruptPairingRecord,
             .peerAuthenticationFailed:
            .pairAgain
        case .developerModeDisabled:
            .enableDeveloperMode
        case .deviceLocked:
            .unlockDevice
        case .deviceBusy:
            .stopOtherRemoteSession
        case .developerImageUnavailable,
             .developerImageIncompatible:
            .prepareWithXcode
        case .unsupportedProtocolVersion:
            .updateApp
        case .deviceOffline,
             .connectionLost:
            .bringDeviceNearby
        case .malformedDeviceAnnouncement:
            .none
        }
    }

    public var userFacing: UserFacingCopy {
        switch self {
        case .localNetworkDenied:
            UserFacingCopy(
                title: "Local Network Access Is Off",
                message: "Allow Device Hub to find nearby devices in Settings."
            )
        case .pairingTimedOut:
            UserFacingCopy(
                title: "Pairing Timed Out",
                message: "Keep both devices awake and try pairing again."
            )
        case .pairingRejected:
            UserFacingCopy(
                title: "Pairing Was Declined",
                message: "Start pairing again when the other device is ready."
            )
        case .incorrectPairingCode:
            UserFacingCopy(
                title: "Code Wasn’t Accepted",
                message: "Check the displayed code and try pairing again."
            )
        case .needsPairing:
            UserFacingCopy(
                title: "Pairing Required",
                message: "Pair this device again before starting a remote session."
            )
        case .developerModeDisabled:
            UserFacingCopy(
                title: "Developer Mode Is Off",
                message: "Enable Developer Mode on the other device, then reconnect."
            )
        case .deviceLocked:
            UserFacingCopy(
                title: "Device Is Locked",
                message: "Unlock the other device, then try again."
            )
        case .deviceBusy:
            UserFacingCopy(
                title: "Device Is In Use",
                message: "Stop the other remote session, then try again."
            )
        case .developerImageUnavailable:
            UserFacingCopy(
                title: "Developer Support Isn’t Ready",
                message: """
                Connect this device to a Mac with a compatible Xcode, unlock it, \
                and wait for Xcode to finish preparing it. Then try again.
                """
            )
        case .developerImageIncompatible:
            UserFacingCopy(
                title: "Developer Support Doesn’t Match",
                message: """
                Update Xcode to a version that supports this device’s iOS build, \
                prepare the device again, then try again.
                """
            )
        case .corruptPairingRecord:
            UserFacingCopy(
                title: "Pairing Couldn’t Be Restored",
                message: "Pair this device again to replace the damaged credentials."
            )
        case .peerAuthenticationFailed:
            UserFacingCopy(
                title: "Device Identity Changed",
                message: "Pair again to confirm that this is the same device."
            )
        case .malformedDeviceAnnouncement:
            UserFacingCopy(
                title: "Device Couldn’t Be Verified",
                message: "The nearby device sent an invalid response."
            )
        case .unsupportedProtocolVersion:
            UserFacingCopy(
                title: "Device Version Isn’t Supported",
                message: "Update Device Hub to add support for this device."
            )
        case .deviceOffline:
            UserFacingCopy(
                title: "Device Is Offline",
                message: "Keep it awake and on the same network. Device Hub will reconnect."
            )
        case .connectionLost:
            UserFacingCopy(
                title: "Connection Lost",
                message: "Device Hub is reconnecting to the device."
            )
        case .secureConnectionFailed:
            UserFacingCopy(
                title: "Couldn’t Connect",
                message: "Keep both devices awake and try again."
            )
        case .mediaStalled:
            UserFacingCopy(
                title: "Live View Paused",
                message: "Device Hub is restarting the live view."
            )
        case .decoderFailed:
            UserFacingCopy(
                title: "Screen Couldn’t Be Displayed",
                message: "Device Hub is restarting the live view."
            )
        }
    }
}
