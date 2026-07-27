import Foundation

/// Fail-closed errors for the app's Keychain identity configuration.
public enum PairingPersistenceProvisioningError:
    Error,
    Equatable,
    Sendable
{
    case invalidConfiguration
}

/// Resolves the Keychain service without embedding a developer-specific
/// identifier in public source.
public enum DeviceHubPairingPersistenceProvisioning {
    private static let key = "DeviceHubPairingKeychainService"
    private static let maximumUTF8Length = 128

    /// Reads and validates the configured service from an application bundle.
    public static func keychainService(
        bundle: Bundle = .main
    ) throws -> String {
        try keychainService(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// Validates a complete Keychain service identifier.
    public static func keychainService(
        infoDictionary: [String: Any]
    ) throws -> String {
        guard
            let service = infoDictionary[key] as? String,
            !service.isEmpty,
            service.utf8.count <= maximumUTF8Length,
            service
            == service.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            service.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw PairingPersistenceProvisioningError
                .invalidConfiguration
        }
        return service
    }
}
