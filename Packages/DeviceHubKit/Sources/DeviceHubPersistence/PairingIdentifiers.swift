import Foundation

/// Compile-time validation policy for one pairing identifier.
public protocol PairingTextSpecification: Sendable {
    static var field: PairingPersistenceError.TextField { get }
    static var maximumUTF8Length: Int { get }
}

/// A strongly typed pairing identifier validated at construction and decode.
public struct ValidatedPairingIdentifier<
    Specification: PairingTextSpecification
>: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try PairingTextValidation.require(
            rawValue,
            field: Specification.field,
            maximumUTF8Length: Specification.maximumUTF8Length
        )
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Validation policy for the stable controller UDID.
public enum ControllerUDIDSpecification: PairingTextSpecification {
    public static let field =
        PairingPersistenceError.TextField.controllerUDID
    public static let maximumUTF8Length = 128
}

/// Validation policy for the target account identifier.
public enum PairingAccountIdentifierSpecification:
    PairingTextSpecification
{
    public static let field =
        PairingPersistenceError.TextField.accountIdentifier
    public static let maximumUTF8Length = 256
}

/// Validation policy for the peer's remote-pairing identifier.
public enum PeerPairingIdentifierSpecification: PairingTextSpecification {
    public static let field =
        PairingPersistenceError.TextField.peerIdentifier
    public static let maximumUTF8Length = 256
}

/// Stable UDID included in this controller's remote-pairing identity.
public typealias ControllerUDID =
    ValidatedPairingIdentifier<ControllerUDIDSpecification>

/// Validated account identifier reported by the target.
public typealias PairingAccountIdentifier =
    ValidatedPairingIdentifier<PairingAccountIdentifierSpecification>

/// Long-term peer identifier authenticated in pairing M5.
public typealias PeerPairingIdentifier =
    ValidatedPairingIdentifier<PeerPairingIdentifierSpecification>

enum PairingTextValidation {
    static func require(
        _ value: String,
        field: PairingPersistenceError.TextField,
        maximumUTF8Length: Int
    ) throws {
        let hasControlCharacters = value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumUTF8Length,
              !hasControlCharacters
        else {
            throw PairingPersistenceError.invalidText(field)
        }
    }
}
