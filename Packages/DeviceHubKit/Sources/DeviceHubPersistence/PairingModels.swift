import CryptoKit
import DeviceHubCore
import Foundation

/// Validation failures at the durable pairing boundary.
///
/// Cases intentionally identify only a field and shape failure. They never
/// include the rejected bytes or persisted payload.
public enum PairingPersistenceError: Error, Equatable, Sendable {
    case corruptPayload
    case duplicateTarget(DeviceID)
    case hostIdentityMismatch(DeviceID)
    case invalidByteCount(
        field: KeyMaterialField,
        expected: Int,
        actual: Int
    )
    case invalidCompletionState
    case invalidControllerSecretKey
    case invalidDate(DateField)
    case invalidText(TextField)
    case keyMaterialIsAllZero(KeyMaterialField)
    case randomGenerationFailed(status: Int32)
    case targetNotFound(DeviceID)
    case tooManyTargets(maximum: Int)
    case unsupportedSchemaVersion(Int)
    case vaultChangedDuringMutation
    case vaultTooLarge(maximumBytes: Int, actualBytes: Int)

    public enum DateField: String, Equatable, Sendable {
        case committedAt
        case controllerCreatedAt
        case verifiedAt
    }

    public enum KeyMaterialField: String, Equatable, Sendable {
        case controllerSecretKey
        case hostAlternateIRK
        case hostIdentityFingerprint
        case peerAlternateIRK
        case peerPublicKey
    }

    public enum TextField: String, Equatable, Sendable {
        case accountIdentifier
        case controllerUDID
        case deviceIdentifier
        case displayName
        case operatingSystemVersion
        case peerIdentifier
        case productType
    }
}

/// Stable UUID advertised by this controller during remote pairing.
public struct ControllerIdentifier:
    Codable,
    Equatable,
    Hashable,
    RawRepresentable,
    Sendable
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Controller credentials that remain stable for the lifetime of pairing.
///
/// The secret key and alternate IRK are persisted only inside a local,
/// device-only Keychain item. They must never be regenerated merely because a
/// read operation failed.
public struct ControllerIdentity: Codable, Equatable, Sendable {
    public let alternateIRK: HostAlternateIRK
    public let createdAt: Date
    public let identifier: ControllerIdentifier
    public let longTermSecretKey: Ed25519SecretKey
    public let udid: ControllerUDID

    public init(
        identifier: ControllerIdentifier,
        udid: ControllerUDID,
        longTermSecretKey: Ed25519SecretKey,
        alternateIRK: HostAlternateIRK,
        createdAt: Date
    ) throws {
        try DateValidation.requireFinite(
            createdAt,
            field: .controllerCreatedAt
        )
        self.alternateIRK = alternateIRK
        self.createdAt = createdAt
        self.identifier = identifier
        self.longTermSecretKey = longTermSecretKey
        self.udid = udid
    }

    private enum CodingKeys: String, CodingKey {
        case alternateIRK
        case createdAt
        case identifier
        case longTermSecretKey
        case udid
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(
                ControllerIdentifier.self,
                forKey: .identifier
            ),
            udid: container.decode(ControllerUDID.self, forKey: .udid),
            longTermSecretKey: container.decode(
                Ed25519SecretKey.self,
                forKey: .longTermSecretKey
            ),
            alternateIRK: container.decode(
                HostAlternateIRK.self,
                forKey: .alternateIRK
            ),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    /// Stable non-secret binding used to reject records from another host.
    public func fingerprint() throws -> HostIdentityFingerprint {
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try longTermSecretKey.withUnsafeBytes { bytes in
                try Curve25519.Signing.PrivateKey(
                    rawRepresentation: Data(bytes)
                )
            }
        } catch {
            throw PairingPersistenceError.invalidControllerSecretKey
        }

        var hasher = SHA256()
        hasher.update(data: Data("DeviceHubHostIdentityV1".utf8))
        hasher.update(
            data: Data(identifier.rawValue.uuidString.lowercased().utf8)
        )
        hasher.update(data: Data(udid.rawValue.utf8))
        hasher.update(data: privateKey.publicKey.rawRepresentation)
        return try HostIdentityFingerprint(data: Data(hasher.finalize()))
    }
}

/// Durable milestone reached by one target pairing.
///
/// A record is written as provisional immediately after M5 signature
/// verification and before replying with M6. On launch, provisional records
/// require pair-verify before promotion; they are never silently treated as
/// committed or discarded.
public enum PairingCompletion: Codable, Equatable, Sendable {
    case committedAfterM6(verifiedAt: Date, committedAt: Date)
    case provisionalAfterVerifiedM5(verifiedAt: Date)

    private enum CodingKeys: String, CodingKey {
        case committedAt
        case stage
        case verifiedAt
    }

    private enum Stage: String, Codable {
        case committedAfterM6
        case provisionalAfterVerifiedM5
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stage = try container.decode(Stage.self, forKey: .stage)
        let verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
        try DateValidation.requireFinite(verifiedAt, field: .verifiedAt)

        switch stage {
        case .provisionalAfterVerifiedM5:
            guard !container.contains(.committedAt) else {
                throw PairingPersistenceError.invalidCompletionState
            }
            self = .provisionalAfterVerifiedM5(verifiedAt: verifiedAt)

        case .committedAfterM6:
            let committedAt = try container.decode(
                Date.self,
                forKey: .committedAt
            )
            try DateValidation.requireFinite(
                committedAt,
                field: .committedAt
            )
            guard committedAt >= verifiedAt else {
                throw PairingPersistenceError.invalidCompletionState
            }
            self = .committedAfterM6(
                verifiedAt: verifiedAt,
                committedAt: committedAt
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .provisionalAfterVerifiedM5(verifiedAt):
            try container.encode(
                Stage.provisionalAfterVerifiedM5,
                forKey: .stage
            )
            try container.encode(verifiedAt, forKey: .verifiedAt)

        case let .committedAfterM6(verifiedAt, committedAt):
            try container.encode(Stage.committedAfterM6, forKey: .stage)
            try container.encode(verifiedAt, forKey: .verifiedAt)
            try container.encode(committedAt, forKey: .committedAt)
        }
    }

    public var verifiedAt: Date {
        switch self {
        case let .provisionalAfterVerifiedM5(verifiedAt),
             let .committedAfterM6(verifiedAt, _):
            verifiedAt
        }
    }

    func validate() throws {
        try DateValidation.requireFinite(verifiedAt, field: .verifiedAt)
        if case let .committedAfterM6(_, committedAt) = self {
            try DateValidation.requireFinite(
                committedAt,
                field: .committedAt
            )
            guard committedAt >= verifiedAt else {
                throw PairingPersistenceError.invalidCompletionState
            }
        }
    }
}

/// Authenticated output of remote-pairing M5, ready for provisional storage.
///
/// This deliberately excludes SRP state, shared secrets, PINs, TLS/tunnel
/// PSKs, counters, network addresses, packets, media, and OS version. The M5
/// payload does not carry an OS version.
public struct VerifiedM5Pairing: Equatable, Sendable {
    public let accountIdentifier: PairingAccountIdentifier
    public let deviceID: DeviceID
    public let displayName: String
    public let peerAlternateIRK: PeerAlternateIRK
    public let peerIdentifier: PeerPairingIdentifier
    public let peerPublicKey: Ed25519PublicKey
    public let productType: String
    public let verifiedAt: Date

    public init(
        deviceID: DeviceID,
        accountIdentifier: PairingAccountIdentifier,
        peerIdentifier: PeerPairingIdentifier,
        peerPublicKey: Ed25519PublicKey,
        peerAlternateIRK: PeerAlternateIRK,
        displayName: String,
        productType: String,
        verifiedAt: Date
    ) throws {
        try TargetPairingRecord.validate(
            deviceID: deviceID,
            displayName: displayName,
            productType: productType,
            operatingSystemVersion: nil
        )
        try DateValidation.requireFinite(verifiedAt, field: .verifiedAt)
        self.accountIdentifier = accountIdentifier
        self.deviceID = deviceID
        self.displayName = displayName
        self.peerAlternateIRK = peerAlternateIRK
        self.peerIdentifier = peerIdentifier
        self.peerPublicKey = peerPublicKey
        self.productType = productType
        self.verifiedAt = verifiedAt
    }
}

/// Device metadata read only after Remote Service Discovery authentication.
///
/// Transport code must construct this value only from the authenticated RSD
/// channel. Keeping it separate from `VerifiedM5Pairing` prevents callers from
/// inventing metadata that the M5 payload does not carry.
public struct AuthenticatedRSDMetadata: Equatable, Sendable {
    public let operatingSystemVersion: String

    public init(operatingSystemVersion: String) throws {
        try PairingTextValidation.require(
            operatingSystemVersion,
            field: .operatingSystemVersion,
            maximumUTF8Length: 64
        )
        self.operatingSystemVersion = operatingSystemVersion
    }
}

/// Closed, versioned-safe target record stored in the Keychain vault.
public struct TargetPairingRecord: Codable, Equatable, Sendable {
    public let accountIdentifier: PairingAccountIdentifier
    public let completion: PairingCompletion
    public let deviceID: DeviceID
    public let displayName: String
    public let hostIdentityFingerprint: HostIdentityFingerprint
    /// Version learned from authenticated RSD, or `nil` for M5-only records.
    public let operatingSystemVersion: String?
    public let peerAlternateIRK: PeerAlternateIRK
    public let peerIdentifier: PeerPairingIdentifier
    public let peerPublicKey: Ed25519PublicKey
    public let productType: String

    public init(
        deviceID: DeviceID,
        accountIdentifier: PairingAccountIdentifier,
        peerIdentifier: PeerPairingIdentifier,
        peerPublicKey: Ed25519PublicKey,
        peerAlternateIRK: PeerAlternateIRK,
        hostIdentityFingerprint: HostIdentityFingerprint,
        displayName: String,
        productType: String,
        operatingSystemVersion: String?,
        completion: PairingCompletion
    ) throws {
        try Self.validate(
            deviceID: deviceID,
            displayName: displayName,
            productType: productType,
            operatingSystemVersion: operatingSystemVersion
        )
        try completion.validate()
        self.accountIdentifier = accountIdentifier
        self.completion = completion
        self.deviceID = deviceID
        self.displayName = displayName
        self.hostIdentityFingerprint = hostIdentityFingerprint
        self.operatingSystemVersion = operatingSystemVersion
        self.peerAlternateIRK = peerAlternateIRK
        self.peerIdentifier = peerIdentifier
        self.peerPublicKey = peerPublicKey
        self.productType = productType
    }

    init(
        verifiedM5 pairing: VerifiedM5Pairing,
        hostIdentityFingerprint: HostIdentityFingerprint
    ) throws {
        try self.init(
            deviceID: pairing.deviceID,
            accountIdentifier: pairing.accountIdentifier,
            peerIdentifier: pairing.peerIdentifier,
            peerPublicKey: pairing.peerPublicKey,
            peerAlternateIRK: pairing.peerAlternateIRK,
            hostIdentityFingerprint: hostIdentityFingerprint,
            displayName: pairing.displayName,
            productType: pairing.productType,
            operatingSystemVersion: nil,
            completion: .provisionalAfterVerifiedM5(
                verifiedAt: pairing.verifiedAt
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accountIdentifier
        case completion
        case deviceID
        case displayName
        case hostIdentityFingerprint
        case operatingSystemVersion
        case peerAlternateIRK
        case peerIdentifier
        case peerPublicKey
        case productType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceID: container.decode(DeviceID.self, forKey: .deviceID),
            accountIdentifier: container.decode(
                PairingAccountIdentifier.self,
                forKey: .accountIdentifier
            ),
            peerIdentifier: container.decode(
                PeerPairingIdentifier.self,
                forKey: .peerIdentifier
            ),
            peerPublicKey: container.decode(
                Ed25519PublicKey.self,
                forKey: .peerPublicKey
            ),
            peerAlternateIRK: container.decode(
                PeerAlternateIRK.self,
                forKey: .peerAlternateIRK
            ),
            hostIdentityFingerprint: container.decode(
                HostIdentityFingerprint.self,
                forKey: .hostIdentityFingerprint
            ),
            displayName: container.decode(
                String.self,
                forKey: .displayName
            ),
            productType: container.decode(
                String.self,
                forKey: .productType
            ),
            operatingSystemVersion: container.decodeIfPresent(
                String.self,
                forKey: .operatingSystemVersion
            ),
            completion: container.decode(
                PairingCompletion.self,
                forKey: .completion
            )
        )
    }

    static func validate(
        deviceID: DeviceID,
        displayName: String,
        productType: String,
        operatingSystemVersion: String?
    ) throws {
        try PairingTextValidation.require(
            deviceID.rawValue,
            field: .deviceIdentifier,
            maximumUTF8Length: 256
        )
        try PairingTextValidation.require(
            displayName,
            field: .displayName,
            maximumUTF8Length: 256
        )
        try PairingTextValidation.require(
            productType,
            field: .productType,
            maximumUTF8Length: 128
        )
        if let operatingSystemVersion {
            try PairingTextValidation.require(
                operatingSystemVersion,
                field: .operatingSystemVersion,
                maximumUTF8Length: 64
            )
        }
    }
}

/// Deterministic launch decision for one durable pairing record.
public enum PairingRecoveryDecision: Equatable, Sendable {
    /// Pair-verify the peer; commit only after authenticated success.
    case verifyThenCommit(TargetPairingRecord)

    /// The M6 milestone was already durably committed.
    case ready(TargetPairingRecord)
}

private enum DateValidation {
    static func requireFinite(
        _ date: Date,
        field: PairingPersistenceError.DateField
    ) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw PairingPersistenceError.invalidDate(field)
        }
    }
}
