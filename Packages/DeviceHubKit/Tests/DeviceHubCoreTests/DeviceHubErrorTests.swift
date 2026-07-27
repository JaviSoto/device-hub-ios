import CustomDump
import DeviceHubCore
import Testing

struct DeviceHubErrorTests {
    private struct Expectation {
        let classification: DeviceHubError.Classification
        let remedy: DeviceHubError.Remedy
        let retryability: DeviceHubError.Retryability
    }

    @Test
    func errorsHaveStableClassificationRetryabilityAndRemedies() throws {
        let expected: [DeviceHubError: Expectation] = [
            .localNetworkDenied: Expectation(
                classification: .actionable,
                remedy: .grantLocalNetworkAccess,
                retryability: .afterRemedy
            ),
            .pairingTimedOut: Expectation(
                classification: .actionable,
                remedy: .retry,
                retryability: .userInitiated
            ),
            .pairingRejected: Expectation(
                classification: .actionable,
                remedy: .retry,
                retryability: .userInitiated
            ),
            .incorrectPairingCode: Expectation(
                classification: .actionable,
                remedy: .retry,
                retryability: .userInitiated
            ),
            .needsPairing: Expectation(
                classification: .actionable,
                remedy: .pairAgain,
                retryability: .afterRemedy
            ),
            .developerModeDisabled: Expectation(
                classification: .actionable,
                remedy: .enableDeveloperMode,
                retryability: .afterRemedy
            ),
            .deviceLocked: Expectation(
                classification: .actionable,
                remedy: .unlockDevice,
                retryability: .afterRemedy
            ),
            .deviceBusy: Expectation(
                classification: .actionable,
                remedy: .stopOtherRemoteSession,
                retryability: .afterRemedy
            ),
            .developerImageUnavailable: Expectation(
                classification: .actionable,
                remedy: .prepareWithXcode,
                retryability: .afterRemedy
            ),
            .developerImageIncompatible: Expectation(
                classification: .actionable,
                remedy: .prepareWithXcode,
                retryability: .afterRemedy
            ),
            .corruptPairingRecord: Expectation(
                classification: .integrity,
                remedy: .pairAgain,
                retryability: .afterRemedy
            ),
            .peerAuthenticationFailed: Expectation(
                classification: .integrity,
                remedy: .pairAgain,
                retryability: .afterRemedy
            ),
            .malformedDeviceAnnouncement: Expectation(
                classification: .integrity,
                remedy: .none,
                retryability: .notRetryable
            ),
            .unsupportedProtocolVersion: Expectation(
                classification: .integrity,
                remedy: .updateApp,
                retryability: .afterRemedy
            ),
            .deviceOffline: Expectation(
                classification: .transient,
                remedy: .bringDeviceNearby,
                retryability: .automatic
            ),
            .connectionLost: Expectation(
                classification: .transient,
                remedy: .bringDeviceNearby,
                retryability: .automatic
            ),
            .secureConnectionFailed: Expectation(
                classification: .transient,
                remedy: .retry,
                retryability: .automatic
            ),
            .mediaStalled: Expectation(
                classification: .transient,
                remedy: .retry,
                retryability: .automatic
            ),
            .decoderFailed: Expectation(
                classification: .transient,
                remedy: .retry,
                retryability: .automatic
            )
        ]

        expectNoDifference(Set(expected.keys), Set(DeviceHubError.allCases))

        for error in DeviceHubError.allCases {
            let expectation = try #require(expected[error])
            expectNoDifference(error.classification, expectation.classification)
            expectNoDifference(error.retryability, expectation.retryability)
            expectNoDifference(error.remedy, expectation.remedy)
        }
    }

    @Test
    func userCopyIsActionableAndContainsNoProtocolVocabulary() {
        let forbiddenTerms = [
            "bonjour",
            "ddi",
            "ip address",
            "psk",
            "rsd",
            "rtp",
            "tunnel",
            "udid"
        ]

        for error in DeviceHubError.allCases {
            #expect(!error.userFacing.title.isEmpty)
            #expect(!error.userFacing.message.isEmpty)

            let copy = "\(error.userFacing.title) \(error.userFacing.message)"
                .lowercased()
            for term in forbiddenTerms {
                #expect(!copy.contains(term))
            }

            if error.remedy != .none {
                #expect(!error.remedy.actionTitle.isEmpty)
            }
        }
    }

    @Test
    func developerSupportErrorsGiveExactXcodePreparationGuidance() {
        expectNoDifference(
            DeviceHubError.developerImageUnavailable.userFacing,
            DeviceHubError.UserFacingCopy(
                title: "Developer Support Isn’t Ready",
                message: """
                Connect this device to a Mac with a compatible Xcode, unlock it, \
                and wait for Xcode to finish preparing it. Then try again.
                """
            )
        )
        expectNoDifference(
            DeviceHubError.developerImageIncompatible.userFacing,
            DeviceHubError.UserFacingCopy(
                title: "Developer Support Doesn’t Match",
                message: """
                Update Xcode to a version that supports this device’s iOS build, \
                prepare the device again, then try again.
                """
            )
        )
        expectNoDifference(
            DeviceHubError.Remedy.prepareWithXcode.actionTitle,
            "Show Xcode Steps"
        )
        expectNoDifference(
            DeviceHubError.unsupportedProtocolVersion.remedy,
            .updateApp
        )
    }
}
