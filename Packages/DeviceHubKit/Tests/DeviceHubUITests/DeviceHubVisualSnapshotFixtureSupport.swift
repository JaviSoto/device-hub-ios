#if os(iOS)
    import CoreGraphics
    import DeviceHubCore
    import UIKit

    enum FixturePresentation {
        case connecting
        case live
        case viewingOnly
    }

    struct FixtureRemoteGeometry {
        let imageHeight: Int
        let imageWidth: Int
        let orientation: ScreenOrientation
        let pixelSize: PixelSize
    }

    enum FixtureRemoteScreen {
        case phonePortrait
        case tabletLandscape

        var geometry: FixtureRemoteGeometry {
            switch self {
            case .phonePortrait:
                FixtureRemoteGeometry(
                    imageHeight: 852,
                    imageWidth: 393,
                    orientation: .portrait,
                    pixelSize: PixelSize(width: 1179, height: 2556)
                )

            case .tabletLandscape:
                FixtureRemoteGeometry(
                    imageHeight: 1024,
                    imageWidth: 1366,
                    orientation: .landscapeRight,
                    pixelSize: PixelSize(width: 2064, height: 2752)
                )
            }
        }
    }

    struct FixtureDevices {
        let reachable: DeviceSummary
        let offline: DeviceSummary
        let landscapeIPad: DeviceSummary
        let roster: DeviceRoster
    }

    enum VisualFixtureError: Error {
        case imageContextCreationFailed
        case imageCreationFailed
        case invalidPairingCode
        case invalidRemoteState
        case invalidUUID
        case unexpectedScenario
    }

    extension VisualScenario {
        var appearance: UIUserInterfaceStyle {
            switch self {
            case .emptyIPhoneLight,
                 .liveIPadLight,
                 .connectingIPhoneLight,
                 .deviceDetailsPendingVersionIPadLight,
                 .aboutNoticesIPadLight,
                 .developerImageUnavailableIPadLight,
                 .xcodePreparationIPadLight,
                 .lockedIPhoneAccessibility,
                 .developerModeIPadAccessibility,
                 .viewingOnlyIPadLight:
                .light
            case .pairingIPhoneDark,
                 .liveIPadDark,
                 .liveIPhoneDark,
                 .liveLandscapeIPadTargetIPhoneDark,
                 .offlineIPhoneDark,
                 .noticesUnavailableIPhoneDark,
                 .developerImageIncompatibleIPhoneDark,
                 .localNetworkDeniedIPadDark,
                 .deviceBusyIPhoneDark:
                .dark
            }
        }

        var size: CGSize {
            switch self {
            case .liveLandscapeIPadTargetIPhoneDark:
                CGSize(width: 956, height: 440)
            case .emptyIPhoneLight,
                 .pairingIPhoneDark,
                 .connectingIPhoneLight,
                 .liveIPhoneDark,
                 .offlineIPhoneDark,
                 .lockedIPhoneAccessibility,
                 .deviceBusyIPhoneDark,
                 .developerImageIncompatibleIPhoneDark,
                 .noticesUnavailableIPhoneDark:
                CGSize(width: 440, height: 956)
            default:
                CGSize(width: 1180, height: 820)
            }
        }

        var usesAccessibilityText: Bool {
            self == .lockedIPhoneAccessibility
                || self == .developerModeIPadAccessibility
        }
    }
#endif
