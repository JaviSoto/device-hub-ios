import DeviceHubDiagnostics
@testable import DeviceHubLive
import Testing

@Suite("Diagnostics build provisioning")
struct DiagnosticsBuildProvisioningTests {
    @Test("ordinary builds remain local-only")
    func ordinaryBuildsRemainLocalOnly() throws {
        #expect(
            try DeviceHubDiagnosticsBuildProvisioning
                .uploadProvisioning() == nil
        )
    }

    @Test("bundle configuration requires a complete endpoint and token pair")
    func bundleConfigurationMustBeComplete() throws {
        #expect(throws: DiagnosticUploadFailure.invalidConfiguration) {
            try DeviceHubDiagnosticsBuildProvisioning.uploadProvisioning(
                infoDictionary: [
                    "DeviceHubDiagnosticsEndpoint":
                        "https://diagnostics.example.test/v1/diagnostics"
                ]
            )
        }

        #expect(
            try DeviceHubDiagnosticsBuildProvisioning.uploadProvisioning(
                infoDictionary: [
                    "DeviceHubDiagnosticsEndpoint":
                        "https://diagnostics.example.test/v1/diagnostics",
                    "DeviceHubDiagnosticsBearerToken":
                        "test-only-diagnostics-token-value-0001"
                ]
            ) != nil
        )
    }
}
