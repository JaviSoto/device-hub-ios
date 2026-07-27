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

        var idiom: UIUserInterfaceIdiom {
            switch self {
            case .developerModeIPadAccessibility,
                 .deviceDetailsPendingVersionIPadLight,
                 .aboutNoticesIPadLight,
                 .developerImageUnavailableIPadLight,
                 .xcodePreparationIPadLight,
                 .localNetworkDeniedIPadDark,
                 .viewingOnlyIPadLight:
                .pad
            default:
                .phone
            }
        }

        var size: CGSize {
            if self == .liveLandscapeIPadTargetIPhoneDark {
                return CGSize(width: 956, height: 440)
            }
            return idiom == .pad
                ? CGSize(width: 1180, height: 820)
                : CGSize(width: 440, height: 956)
        }

        var usesAccessibilityText: Bool {
            self == .lockedIPhoneAccessibility
                || self == .developerModeIPadAccessibility
        }
    }
#endif
