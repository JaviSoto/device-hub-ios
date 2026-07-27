@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Production transport composition")
struct DeviceHubProductionCompositionTests {
    @Test("Controller name prefers the private user-assigned device name")
    func controllerDeviceName() {
        #expect(
            DeviceHubCurrentDeviceName.resolve(
                privateName: "  Test iPhone  ",
                publicName: "iPhone",
                modelName: "iPhone"
            ) == "Test iPhone"
        )
    }

    @Test("Generic iOS names require a user-provided advertised name")
    func genericControllerDeviceName() {
        #expect(
            DeviceHubCurrentDeviceName.requiresUserProvidedName("iPhone")
        )
        #expect(
            DeviceHubCurrentDeviceName.requiresUserProvidedName("iPad")
        )
        #expect(
            !DeviceHubCurrentDeviceName.requiresUserProvidedName("Test iPhone")
        )
    }

    @Test("User-provided advertised names persist after normalization")
    func persistedControllerDeviceName() throws {
        let suiteName = "DeviceHubCurrentDeviceNameTests-\(UUID())"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        DeviceHubCurrentDeviceName.saveUserProvidedName(
            "  Test iPhone  ",
            userDefaults: userDefaults
        )

        #expect(
            DeviceHubCurrentDeviceName.userProvidedName(
                userDefaults: userDefaults
            ) == "Test iPhone"
        )
    }

    @Test("Pairable Host identifies the controller device")
    func pairableHostIdentity() throws {
        let configuration =
            try DeviceHubProductionComposition.makeTransportConfiguration(
                controllerDeviceName: "Test iPhone"
            )

        #expect(
            configuration.controllerDisplayName
                == "Device Hub App in Test iPhone"
        )
        #expect(configuration.controllerModel == "Mac17,7")
        #expect(
            configuration.remoteTargetPolicy == .authenticatedDevices
        )
        #expect(
            configuration.remoteTargetPolicy.permits(
                displayName: "Test iPad"
            )
        )
    }

    @Test("Long device names remain valid Bonjour TXT values")
    func longControllerDeviceName() throws {
        let configuration =
            try DeviceHubProductionComposition.makeTransportConfiguration(
                controllerDeviceName: String(repeating: "📱", count: 100)
            )

        #expect(configuration.controllerDisplayName.utf8.count <= 128)
        #expect(
            configuration.controllerDisplayName
                .hasPrefix("Device Hub App in ")
        )
    }
}
