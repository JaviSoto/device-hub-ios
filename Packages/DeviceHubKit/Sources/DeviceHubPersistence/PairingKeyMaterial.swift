import Foundation

/// Compile-time shape of one fixed-length pairing key.
public protocol KeyMaterialSpecification: Sendable {
    static var byteCount: Int { get }
    static var field: PairingPersistenceError.KeyMaterialField { get }
}

/// Validated fixed-length bytes with universally redacted reflection.
///
/// This type deliberately exposes no byte-copy property. Protocol integration
/// can borrow bytes only for the duration of `withUnsafeBytes`.
public struct RedactedKeyMaterial<Specification: KeyMaterialSpecification>:
    Codable,
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    private let storage: Data

    public init(data: Data) throws {
        try KeyMaterialValidation.require(
            data,
            count: Specification.byteCount,
            field: Specification.field
        )
        storage = data
    }

    public var byteCount: Int {
        storage.count
    }

    public var description: String {
        "<redacted>"
    }

    public var debugDescription: String {
        "<redacted>"
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "value": "<redacted>",
                "byteCount": storage.count
            ],
            displayStyle: .struct
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(data: container.decode(Data.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    /// Borrows key material without creating a second durable representation.
    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes { bytes in
            try body(bytes)
        }
    }
}

/// Shape marker for a 32-byte Ed25519 controller signing secret.
public enum ControllerSecretKeyMaterial: KeyMaterialSpecification {
    public static let byteCount = 32
    public static let field =
        PairingPersistenceError.KeyMaterialField.controllerSecretKey
}

/// Shape marker for a 32-byte Ed25519 peer verification key.
public enum PeerPublicKeyMaterial: KeyMaterialSpecification {
    public static let byteCount = 32
    public static let field =
        PairingPersistenceError.KeyMaterialField.peerPublicKey
}

/// Shape marker for the host's 16-byte identity-resolution key.
public enum HostAlternateIRKMaterial: KeyMaterialSpecification {
    public static let byteCount = 16
    public static let field =
        PairingPersistenceError.KeyMaterialField.hostAlternateIRK
}

/// Shape marker for a peer's 16-byte identity-resolution key.
public enum PeerAlternateIRKMaterial: KeyMaterialSpecification {
    public static let byteCount = 16
    public static let field =
        PairingPersistenceError.KeyMaterialField.peerAlternateIRK
}

/// Shape marker for a 32-byte host identity fingerprint.
public enum HostIdentityFingerprintMaterial: KeyMaterialSpecification {
    public static let byteCount = 32
    public static let field =
        PairingPersistenceError.KeyMaterialField.hostIdentityFingerprint
}

/// Exactly 32 bytes of Ed25519 controller signing secret.
public typealias Ed25519SecretKey =
    RedactedKeyMaterial<ControllerSecretKeyMaterial>

/// Exactly 32 bytes of the peer Ed25519 verification key from pairing M5.
///
/// Public keys remain redacted to avoid their accidental use as tracking IDs.
public typealias Ed25519PublicKey =
    RedactedKeyMaterial<PeerPublicKeyMaterial>

/// Exactly 16 bytes of host identity-resolution key material.
///
/// This controller-wide value must survive upgrades and app relaunches.
public typealias HostAlternateIRK =
    RedactedKeyMaterial<HostAlternateIRKMaterial>

/// Exactly 16 bytes of peer identity-resolution key material.
public typealias PeerAlternateIRK =
    RedactedKeyMaterial<PeerAlternateIRKMaterial>

/// SHA-256 fingerprint binding a peer record to its host identity.
public typealias HostIdentityFingerprint =
    RedactedKeyMaterial<HostIdentityFingerprintMaterial>

private enum KeyMaterialValidation {
    static func require(
        _ data: Data,
        count expectedCount: Int,
        field: PairingPersistenceError.KeyMaterialField
    ) throws {
        guard data.count == expectedCount else {
            throw PairingPersistenceError.invalidByteCount(
                field: field,
                expected: expectedCount,
                actual: data.count
            )
        }
        guard data.contains(where: { $0 != 0 }) else {
            throw PairingPersistenceError.keyMaterialIsAllZero(field)
        }
    }
}
