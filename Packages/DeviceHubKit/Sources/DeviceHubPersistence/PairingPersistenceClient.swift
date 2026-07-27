import Dependencies
import DependenciesMacros
import DeviceHubCore
import Foundation

/// Injectable application-facing façade for durable pairing identity.
///
/// The generated test value fails loudly for every endpoint that a test does
/// not explicitly supply, preventing accidental use of live Keychain state.
@DependencyClient
public struct PairingPersistenceClient: Sendable {
    public var commitM6:
        @Sendable (_ deviceID: DeviceID, _ committedAt: Date) async throws
        -> TargetPairingRecord
    public var enrichFromAuthenticatedRSD:
        @Sendable (
            _ metadata: AuthenticatedRSDMetadata,
            _ deviceID: DeviceID
        ) async throws -> TargetPairingRecord
    public var forgetTarget:
        @Sendable (_ deviceID: DeviceID) async throws -> Bool
    public var loadOrCreateControllerIdentity:
        @Sendable () async throws -> ControllerIdentity
    public var pairingRecords:
        @Sendable () async throws -> [TargetPairingRecord]
    public var recoveryDecisions:
        @Sendable () async throws -> [PairingRecoveryDecision]
    public var saveVerifiedM5:
        @Sendable (_ pairing: VerifiedM5Pairing) async throws
        -> TargetPairingRecord
}

extension PairingPersistenceClient: DependencyKey {
    /// Builds a live persistence client for one explicit Keychain item.
    public static func live(
        descriptor: KeychainItemDescriptor = .pairingVault
    ) -> Self {
        let store = KeychainPairingStore(
            driver: SecurityKeychainDriver(),
            descriptor: descriptor,
            generateControllerIdentity:
            SystemControllerIdentityGenerator.generate
        )
        return Self(
            commitM6: { deviceID, committedAt in
                try await store.commitM6(
                    for: deviceID,
                    committedAt: committedAt
                )
            },
            enrichFromAuthenticatedRSD: { metadata, deviceID in
                try await store.enrichFromAuthenticatedRSD(
                    metadata,
                    for: deviceID
                )
            },
            forgetTarget: { deviceID in
                try await store.forgetTarget(deviceID)
            },
            loadOrCreateControllerIdentity: {
                try await store.loadOrCreateControllerIdentity()
            },
            pairingRecords: {
                try await store.pairingRecords()
            },
            recoveryDecisions: {
                try await store.recoveryDecisions()
            },
            saveVerifiedM5: { pairing in
                try await store.saveVerifiedM5(pairing)
            }
        )
    }

    public static let liveValue = live()

    public static let testValue = Self()
}

public extension DependencyValues {
    var pairingPersistence: PairingPersistenceClient {
        get { self[PairingPersistenceClient.self] }
        set { self[PairingPersistenceClient.self] = newValue }
    }
}
