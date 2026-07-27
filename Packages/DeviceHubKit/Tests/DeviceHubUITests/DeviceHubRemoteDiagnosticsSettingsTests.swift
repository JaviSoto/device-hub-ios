@testable import DeviceHubUI
import Testing

@Suite("Remote diagnostics settings")
@MainActor
struct DeviceHubRemoteDiagnosticsSettingsTests {
    @Test("unconfigured builds cannot enable remote sharing")
    func unconfiguredBuildRemainsOff() {
        var choices: [Bool] = []
        let settings = DeviceHubRemoteDiagnosticsSettings(
            destinationHost: nil,
            isEnabled: false,
            setEnabled: { choices.append($0) }
        )

        settings.setEnabled(true)

        #expect(settings.destinationHost == nil)
        #expect(!settings.isEnabled)
        #expect(choices.isEmpty)
    }

    @Test("configured builds expose and apply the user's choice")
    func configuredBuildAppliesChoice() {
        var choices: [Bool] = []
        let settings = DeviceHubRemoteDiagnosticsSettings(
            destinationHost: "diagnostics.example.test",
            isEnabled: false,
            setEnabled: { choices.append($0) }
        )

        settings.setEnabled(true)

        #expect(
            settings.destinationHost == "diagnostics.example.test"
        )
        #expect(settings.isEnabled)
        #expect(choices == [true])
    }
}
