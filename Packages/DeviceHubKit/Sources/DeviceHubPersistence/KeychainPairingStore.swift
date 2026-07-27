import DeviceHubCore
import Foundation
import Security

/// Actor-isolated, atomic persistence for controller and peer identities.
///
/// The store uses one versioned Keychain value so controller identity and
/// target state cannot become partially updated. It never caches a read error
/// as "missing" and never regenerates credentials after any Keychain failure.
public actor KeychainPairingStore {
    public typealias ControllerIdentityGenerator =
        @Sendable () throws -> ControllerIdentity

    private let descriptor: KeychainItemDescriptor
    private let driver: any KeychainDriving
    private let generateControllerIdentity: ControllerIdentityGenerator
    /// Last successfully decoded or persisted vault for this process.
    ///
    /// The actor is the sole in-process writer for its Keychain item. Retaining
    /// the value avoids another Security.framework round trip between
    /// authenticated M5 and M6, where the peer requires a prompt persistence
    /// acknowledgement. A new store instance still re-reads the Keychain and
    /// therefore preserves launch-time corruption and recovery checks.
    private var cachedVault: PairingVault?

    public init(
        driver: any KeychainDriving,
        descriptor: KeychainItemDescriptor = .pairingVault,
        generateControllerIdentity:
        @escaping ControllerIdentityGenerator
    ) {
        self.descriptor = descriptor
        self.driver = driver
        self.generateControllerIdentity = generateControllerIdentity
    }

    /// Loads the controller identity or creates it only after a confirmed miss.
    public func loadOrCreateControllerIdentity() throws
        -> ControllerIdentity
    {
        try loadOrCreateVault().controller
    }

    /// Returns all target records in stable device-identifier order.
    public func pairingRecords() throws -> [TargetPairingRecord] {
        try readVault()?.targets ?? []
    }

    /// Maps durable milestones to explicit reconnect work after launch.
    public func recoveryDecisions() throws
        -> [PairingRecoveryDecision]
    {
        try pairingRecords().map { record in
            switch record.completion {
            case .provisionalAfterVerifiedM5:
                .verifyThenCommit(record)
            case .committedAfterM6:
                .ready(record)
            }
        }
    }

    /// Persists authenticated peer identity before the protocol sends M6.
    @discardableResult
    public func saveVerifiedM5(
        _ pairing: VerifiedM5Pairing
    ) throws -> TargetPairingRecord {
        var vault = try loadOrCreateVault()
        let record = try TargetPairingRecord(
            verifiedM5: pairing,
            hostIdentityFingerprint: vault.controller.fingerprint()
        )

        if let index = vault.targets.firstIndex(where: {
            $0.deviceID == pairing.deviceID
        }) {
            vault.targets[index] = record
        } else {
            guard vault.targets.count < PairingVault.maximumTargetCount else {
                throw PairingPersistenceError.tooManyTargets(
                    maximum: PairingVault.maximumTargetCount
                )
            }
            vault.targets.append(record)
        }
        vault.canonicalize()
        try persistMutation(vault)
        return record
    }

    /// Atomically enriches a pairing from an authenticated RSD channel.
    ///
    /// Pairing identity, host binding, and completion state are preserved.
    @discardableResult
    public func enrichFromAuthenticatedRSD(
        _ metadata: AuthenticatedRSDMetadata,
        for deviceID: DeviceID
    ) throws -> TargetPairingRecord {
        guard var vault = try readVault(),
              let index = vault.targets.firstIndex(where: {
                  $0.deviceID == deviceID
              })
        else {
            throw PairingPersistenceError.targetNotFound(deviceID)
        }

        let record = vault.targets[index]
        guard record.operatingSystemVersion
            != metadata.operatingSystemVersion
        else {
            return record
        }
        let enriched = try TargetPairingRecord(
            deviceID: record.deviceID,
            accountIdentifier: record.accountIdentifier,
            peerIdentifier: record.peerIdentifier,
            peerPublicKey: record.peerPublicKey,
            peerAlternateIRK: record.peerAlternateIRK,
            hostIdentityFingerprint: record.hostIdentityFingerprint,
            displayName: record.displayName,
            productType: record.productType,
            operatingSystemVersion: metadata.operatingSystemVersion,
            completion: record.completion
        )
        vault.targets[index] = enriched
        try persistMutation(vault)
        return enriched
    }

    /// Atomically promotes a verified-M5 record after M6 succeeds.
    ///
    /// Repeating a commit is idempotent and preserves the original timestamp.
    @discardableResult
    public func commitM6(
        for deviceID: DeviceID,
        committedAt: Date
    ) throws -> TargetPairingRecord {
        guard var vault = try readVault(),
              let index = vault.targets.firstIndex(where: {
                  $0.deviceID == deviceID
              })
        else {
            throw PairingPersistenceError.targetNotFound(deviceID)
        }

        let record = vault.targets[index]
        switch record.completion {
        case .committedAfterM6:
            return record

        case let .provisionalAfterVerifiedM5(verifiedAt):
            try DateValidationForStore.requireValidCommit(
                verifiedAt: verifiedAt,
                committedAt: committedAt
            )
            let committed = try TargetPairingRecord(
                deviceID: record.deviceID,
                accountIdentifier: record.accountIdentifier,
                peerIdentifier: record.peerIdentifier,
                peerPublicKey: record.peerPublicKey,
                peerAlternateIRK: record.peerAlternateIRK,
                hostIdentityFingerprint: record.hostIdentityFingerprint,
                displayName: record.displayName,
                productType: record.productType,
                operatingSystemVersion: record.operatingSystemVersion,
                completion: .committedAfterM6(
                    verifiedAt: verifiedAt,
                    committedAt: committedAt
                )
            )
            vault.targets[index] = committed
            try persistMutation(vault)
            return committed
        }
    }

    /// Removes one target idempotently while preserving controller credentials.
    @discardableResult
    public func forgetTarget(_ deviceID: DeviceID) throws -> Bool {
        guard var vault = try readVault(),
              let index = vault.targets.firstIndex(where: {
                  $0.deviceID == deviceID
              })
        else {
            return false
        }
        vault.targets.remove(at: index)
        try persistMutation(vault)
        return true
    }

    private func loadOrCreateVault() throws -> PairingVault {
        if let vault = try readVault() {
            return vault
        }

        let candidate = try PairingVault(
            controller: generateControllerIdentity()
        )
        let encodedCandidate = try PairingVaultCodec.encode(candidate)
        do {
            try driver.add(encodedCandidate, for: descriptor)
            cachedVault = candidate
            return candidate
        } catch let error as KeychainDriverError
            where error.matches(
                operation: .add,
                status: KeychainStatus.duplicateItem
            )
        {
            guard let winner = try readVault() else {
                throw PairingPersistenceError.vaultChangedDuringMutation
            }
            return winner
        }
    }

    private func persistMutation(_ vault: PairingVault) throws {
        let data = try PairingVaultCodec.encode(vault)
        do {
            try driver.update(data, for: descriptor)
            cachedVault = vault
        } catch let error as KeychainDriverError
            where error.matches(
                operation: .update,
                status: KeychainStatus.itemNotFound
            )
        {
            throw PairingPersistenceError.vaultChangedDuringMutation
        }
    }

    private func readVault() throws -> PairingVault? {
        if let cachedVault {
            return cachedVault
        }
        let storedData: Data?
        do {
            storedData = try driver.read(descriptor)
        } catch let error as KeychainDriverError {
            traceKeychainReadFailure(error)
            throw error
        }
        guard let data = storedData else {
            return nil
        }
        let vault = try PairingVaultCodec.decode(data)
        cachedVault = vault
        return vault
    }
}

private struct PairingVault: Codable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumTargetCount = 64

    let controller: ControllerIdentity
    let schemaVersion: Int
    var targets: [TargetPairingRecord]

    init(controller: ControllerIdentity) {
        self.controller = controller
        schemaVersion = Self.currentSchemaVersion
        targets = []
    }

    private enum CodingKeys: String, CodingKey {
        case controller
        case schemaVersion
        case targets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PairingPersistenceError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        let targets = try container.decode(
            [TargetPairingRecord].self,
            forKey: .targets
        )
        guard targets.count <= Self.maximumTargetCount else {
            throw PairingPersistenceError.tooManyTargets(
                maximum: Self.maximumTargetCount
            )
        }
        var identifiers: Set<DeviceID> = []
        for target in targets {
            guard identifiers.insert(target.deviceID).inserted else {
                throw PairingPersistenceError.duplicateTarget(
                    target.deviceID
                )
            }
        }

        controller = try container.decode(
            ControllerIdentity.self,
            forKey: .controller
        )
        self.schemaVersion = schemaVersion
        self.targets = targets
        let expectedFingerprint = try controller.fingerprint()
        for target in targets {
            guard target.hostIdentityFingerprint == expectedFingerprint else {
                throw PairingPersistenceError.hostIdentityMismatch(
                    target.deviceID
                )
            }
        }
        canonicalize()
    }

    mutating func canonicalize() {
        targets.sort {
            $0.deviceID.rawValue < $1.deviceID.rawValue
        }
    }
}

private enum PairingVaultCodec {
    static let maximumEncodedByteCount = 128 * 1024

    static func decode(_ data: Data) throws -> PairingVault {
        guard data.count <= maximumEncodedByteCount else {
            throw PairingPersistenceError.vaultTooLarge(
                maximumBytes: maximumEncodedByteCount,
                actualBytes: data.count
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(PairingVault.self, from: data)
        } catch let error as PairingPersistenceError {
            traceDecodeFailure(error)
            throw error
        } catch {
            traceDecodeFailure(.corruptPayload)
            throw PairingPersistenceError.corruptPayload
        }
    }

    static func encode(_ vault: PairingVault) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(vault)
        } catch let error as PairingPersistenceError {
            throw error
        } catch {
            throw PairingPersistenceError.corruptPayload
        }
        guard data.count <= maximumEncodedByteCount else {
            throw PairingPersistenceError.vaultTooLarge(
                maximumBytes: maximumEncodedByteCount,
                actualBytes: data.count
            )
        }
        return data
    }
}

private func traceDecodeFailure(_ error: PairingPersistenceError) {
    guard
        ProcessInfo.processInfo.environment[
            "DEVICE_HUB_BOOTSTRAP_TRACE"
        ] == "1"
    else {
        return
    }
    let code = switch error {
    case .corruptPayload:
        "corrupt_payload"
    case .duplicateTarget:
        "duplicate_target"
    case .hostIdentityMismatch:
        "host_identity_mismatch"
    case let .invalidByteCount(field, _, _):
        "invalid_byte_count_\(field.rawValue)"
    case .invalidCompletionState:
        "invalid_completion_state"
    case .invalidControllerSecretKey:
        "invalid_controller_secret_key"
    case let .invalidDate(field):
        "invalid_date_\(field.rawValue)"
    case let .invalidText(field):
        "invalid_text_\(field.rawValue)"
    case let .keyMaterialIsAllZero(field):
        "zero_key_material_\(field.rawValue)"
    case .randomGenerationFailed:
        "random_generation_failed"
    case .targetNotFound:
        "target_not_found"
    case .tooManyTargets:
        "too_many_targets"
    case .unsupportedSchemaVersion:
        "unsupported_schema_version"
    case .vaultChangedDuringMutation:
        "vault_changed_during_mutation"
    case .vaultTooLarge:
        "vault_too_large"
    }
    FileHandle.standardOutput.write(
        Data("devicehub.persistence decode_failed code=\(code)\n".utf8)
    )
}

private func traceKeychainReadFailure(_ error: KeychainDriverError) {
    guard
        ProcessInfo.processInfo.environment[
            "DEVICE_HUB_BOOTSTRAP_TRACE"
        ] == "1"
    else {
        return
    }
    let code = switch error {
    case let .osStatus(operation, status):
        "\(operation.rawValue)_osstatus_\(status)"
    case let .unexpectedResult(operation):
        "\(operation.rawValue)_unexpected_result"
    }
    FileHandle.standardOutput.write(
        Data("devicehub.persistence keychain_failed code=\(code)\n".utf8)
    )
}

private enum DateValidationForStore {
    static func requireValidCommit(
        verifiedAt: Date,
        committedAt: Date
    ) throws {
        guard committedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PairingPersistenceError.invalidDate(.committedAt)
        }
        guard committedAt >= verifiedAt else {
            throw PairingPersistenceError.invalidCompletionState
        }
    }
}

private extension KeychainDriverError {
    func matches(
        operation: KeychainOperation,
        status: Int32
    ) -> Bool {
        self == .osStatus(operation: operation, status: status)
    }
}

/// Generates controller credentials with Security.framework entropy.
public enum SystemControllerIdentityGenerator {
    /// Creates a fresh identity. Call only after a confirmed Keychain miss.
    public static func generate() throws -> ControllerIdentity {
        try ControllerIdentity(
            identifier: ControllerIdentifier(rawValue: UUID()),
            udid: ControllerUDID(rawValue: UUID().uuidString),
            longTermSecretKey: Ed25519SecretKey(
                data: randomData(count: 32)
            ),
            alternateIRK: HostAlternateIRK(
                data: randomData(count: 16)
            ),
            createdAt: Date()
        )
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                baseAddress
            )
        }
        guard status == errSecSuccess else {
            throw PairingPersistenceError.randomGenerationFailed(
                status: Int32(status)
            )
        }
        return data
    }
}
