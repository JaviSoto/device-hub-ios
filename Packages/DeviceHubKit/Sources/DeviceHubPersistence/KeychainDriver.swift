import Foundation
import Security

/// Operation that produced a Keychain failure.
public enum KeychainOperation: String, Equatable, Sendable {
    case add
    case delete
    case read
    case update
}

/// Security.framework status values that affect atomic store behavior.
public enum KeychainStatus {
    public static let duplicateItem = Int32(errSecDuplicateItem)
    public static let itemNotFound = Int32(errSecItemNotFound)
}

/// Explicit, redaction-safe failures from the Keychain shell.
public enum KeychainDriverError: Error, Equatable, Sendable {
    case osStatus(operation: KeychainOperation, status: Int32)
    case unexpectedResult(operation: KeychainOperation)
}

/// Accessibility policy of a durable pairing item.
public enum KeychainAccessibility: Equatable, Sendable {
    /// Available after first device unlock, never migratable to another device.
    case afterFirstUnlockThisDeviceOnly
}

/// Complete non-secret identity of a Keychain generic-password item.
///
/// Pairing material is explicitly device-only, excluded from iCloud Keychain,
/// and not placed in a shared access group.
public struct KeychainItemDescriptor: Equatable, Sendable {
    public let accessGroup: String?
    public let accessibility: KeychainAccessibility
    public let account: String
    public let service: String
    public let synchronizesWithCloud: Bool

    public init(
        service: String,
        account: String,
        accessibility: KeychainAccessibility,
        synchronizesWithCloud: Bool,
        accessGroup: String?
    ) {
        self.accessGroup = accessGroup
        self.accessibility = accessibility
        self.account = account
        self.service = service
        self.synchronizesWithCloud = synchronizesWithCloud
    }

    /// Builds the device-only descriptor for a configured app identity.
    public static func pairingVault(service: String) -> Self {
        Self(
            service: service,
            account: "pairing-vault",
            accessibility: .afterFirstUnlockThisDeviceOnly,
            synchronizesWithCloud: false,
            accessGroup: nil
        )
    }

    /// Portable default used by package clients and tests.
    public static let pairingVault = pairingVault(
        service: "DeviceHub.PairingVault"
    )
}

/// Injectable imperative shell around Security.framework.
///
/// Production uses `SecurityKeychainDriver`; unit tests provide an in-memory
/// implementation and therefore never read or mutate the user's Keychain.
public protocol KeychainDriving: Sendable {
    func add(
        _ data: Data,
        for descriptor: KeychainItemDescriptor
    ) throws

    func delete(_ descriptor: KeychainItemDescriptor) throws

    func read(_ descriptor: KeychainItemDescriptor) throws -> Data?

    func update(
        _ data: Data,
        for descriptor: KeychainItemDescriptor
    ) throws
}

/// Security.framework implementation with atomic value replacement.
public struct SecurityKeychainDriver: KeychainDriving {
    public init() {}

    public func read(
        _ descriptor: KeychainItemDescriptor
    ) throws -> Data? {
        var query = baseQuery(for: descriptor)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainDriverError.unexpectedResult(operation: .read)
            }
            return data

        case errSecItemNotFound:
            return nil

        default:
            throw KeychainDriverError.osStatus(
                operation: .read,
                status: Int32(status)
            )
        }
    }

    public func add(
        _ data: Data,
        for descriptor: KeychainItemDescriptor
    ) throws {
        var attributes = baseQuery(for: descriptor)
        attributes[kSecAttrAccessible] = securityAccessibility(
            descriptor.accessibility
        )
        attributes[kSecValueData] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainDriverError.osStatus(
                operation: .add,
                status: Int32(status)
            )
        }
    }

    public func update(
        _ data: Data,
        for descriptor: KeychainItemDescriptor
    ) throws {
        let query = baseQuery(for: descriptor)
        let attributes: [CFString: Any] = [
            kSecAttrAccessible: securityAccessibility(
                descriptor.accessibility
            ),
            kSecValueData: data
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            throw KeychainDriverError.osStatus(
                operation: .update,
                status: Int32(status)
            )
        }
    }

    public func delete(
        _ descriptor: KeychainItemDescriptor
    ) throws {
        let status = SecItemDelete(
            baseQuery(for: descriptor) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainDriverError.osStatus(
                operation: .delete,
                status: Int32(status)
            )
        }
    }

    private func baseQuery(
        for descriptor: KeychainItemDescriptor
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: descriptor.account,
            kSecAttrService: descriptor.service,
            kSecAttrSynchronizable: descriptor.synchronizesWithCloud
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        ]
        if let accessGroup = descriptor.accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func securityAccessibility(
        _ accessibility: KeychainAccessibility
    ) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}
