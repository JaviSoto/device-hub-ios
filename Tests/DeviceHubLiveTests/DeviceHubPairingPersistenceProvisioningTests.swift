@testable import DeviceHubLive
import Testing

@Suite("Pairing persistence provisioning")
struct DeviceHubPairingPersistenceProvisioningTests {
    @Test("a configured Keychain service is preserved exactly")
    func configuredService() throws {
        #expect(
            try DeviceHubPairingPersistenceProvisioning.keychainService(
                infoDictionary: [
                    "DeviceHubPairingKeychainService":
                        "com.example.DeviceHub.PairingVault"
                ]
            ) == "com.example.DeviceHub.PairingVault"
        )
    }

    @Test(
        "invalid Keychain services fail closed",
        arguments: [
            nil,
            "",
            " ",
            " pairing-vault",
            "pairing-vault ",
            "pairing\nvault",
            "pairing\tvault",
            String(repeating: "a", count: 129)
        ]
    )
    func invalidServicesFailClosed(
        service: String?
    ) {
        let infoDictionary: [String: Any] =
            service.map {
                ["DeviceHubPairingKeychainService": $0]
            } ?? [:]
        #expect(
            throws:
            PairingPersistenceProvisioningError
                .invalidConfiguration
        ) {
            try DeviceHubPairingPersistenceProvisioning.keychainService(
                infoDictionary: infoDictionary
            )
        }
    }

    @Test("a service may use the full 128-byte limit")
    func maximumLengthService() throws {
        let service = String(repeating: "a", count: 128)
        #expect(
            try DeviceHubPairingPersistenceProvisioning.keychainService(
                infoDictionary: [
                    "DeviceHubPairingKeychainService": service
                ]
            ) == service
        )
    }
}
