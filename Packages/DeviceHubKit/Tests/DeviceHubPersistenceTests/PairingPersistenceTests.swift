import CustomDump
import DeviceHubCore
import DeviceHubPersistence
import Foundation
import Testing

@Suite("Pairing persistence")
struct PairingPersistenceTests {
    @Test("load-or-create preserves one controller identity")
    func loadOrCreateIsStable() async throws {
        let driver = MemoryKeychainDriver()
        let generator = try IdentityGeneratorProbe(
            identities: [
                fixtureController(seed: 1),
                fixtureController(seed: 2)
            ]
        )
        let store = KeychainPairingStore(
            driver: driver,
            generateControllerIdentity: generator.generate
        )

        let first = try await store.loadOrCreateControllerIdentity()
        let second = try await store.loadOrCreateControllerIdentity()
        let relaunchedStore = KeychainPairingStore(
            driver: driver,
            generateControllerIdentity: generator.generate
        )
        let afterRelaunch = try await relaunchedStore
            .loadOrCreateControllerIdentity()

        #expect(first == second)
        #expect(first == afterRelaunch)
        #expect(generator.callCount == 1)
        #expect(driver.operationKinds == [.read, .add, .read])
    }

    @Test("verified M5 persistence reuses the already-loaded pairing vault")
    func verifiedM5PersistenceDoesNotRepeatKeychainRead() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        _ = try await store.loadOrCreateControllerIdentity()
        driver.failNextRead(
            with: KeychainDriverError.osStatus(
                operation: .read,
                status: -34018
            )
        )

        let record = try await store.saveVerifiedM5(fixtureVerifiedM5())

        #expect(
            record.completion
                == .provisionalAfterVerifiedM5(
                    verifiedAt: Date(timeIntervalSince1970: 1_750_000_000)
                )
        )
        #expect(driver.operationKinds == [.read, .add, .update])
    }

    @Test("a transient read failure never regenerates controller credentials")
    func readFailureDoesNotRegenerate() async throws {
        let driver = MemoryKeychainDriver()
        let expectedError = KeychainDriverError.osStatus(
            operation: .read,
            status: -34018
        )
        driver.failNextRead(with: expectedError)
        let generator = try IdentityGeneratorProbe(
            identities: [fixtureController(seed: 3)]
        )
        let store = KeychainPairingStore(
            driver: driver,
            generateControllerIdentity: generator.generate
        )

        await expectError(expectedError) {
            try await store.loadOrCreateControllerIdentity()
        }
        #expect(generator.callCount == 0)

        let identity = try await store.loadOrCreateControllerIdentity()
        let expectedIdentity = try fixtureController(seed: 3)
        #expect(identity == expectedIdentity)
        #expect(generator.callCount == 1)
    }

    @Test("fixed-length key material rejects malformed and zero values")
    func fixedLengthValidation() throws {
        #expect(throws: PairingPersistenceError.self) {
            try Ed25519SecretKey(data: Data(repeating: 1, count: 31))
        }
        #expect(throws: PairingPersistenceError.self) {
            try Ed25519SecretKey(data: Data(repeating: 0, count: 32))
        }
        #expect(throws: PairingPersistenceError.self) {
            try Ed25519PublicKey(data: Data(repeating: 2, count: 33))
        }
        #expect(throws: PairingPersistenceError.self) {
            try HostAlternateIRK(data: Data(repeating: 0, count: 16))
        }

        #expect(
            try Ed25519SecretKey(data: Data(repeating: 1, count: 32))
                .byteCount == 32
        )
        #expect(
            try Ed25519PublicKey(data: Data(repeating: 2, count: 32))
                .byteCount == 32
        )
        #expect(
            try HostAlternateIRK(data: Data(repeating: 3, count: 16))
                .byteCount == 16
        )

        let encodedZeroSecret = try JSONEncoder().encode(
            Data(repeating: 0, count: 32)
        )
        #expect(throws: PairingPersistenceError.self) {
            try JSONDecoder().decode(
                Ed25519SecretKey.self,
                from: encodedZeroSecret
            )
        }
    }

    @Test("verified M5 is durable and recovers through an explicit decision")
    func provisionalCommitAndRecovery() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let verifiedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let committedAt = verifiedAt.addingTimeInterval(2)
        let verified = try fixtureVerifiedM5(verifiedAt: verifiedAt)

        let provisional = try await store.saveVerifiedM5(verified)
        let controller = try await store.loadOrCreateControllerIdentity()
        let controllerFingerprint = try controller.fingerprint()
        #expect(
            provisional.completion
                == .provisionalAfterVerifiedM5(verifiedAt: verifiedAt)
        )
        #expect(
            provisional.hostIdentityFingerprint == controllerFingerprint
        )
        #expect(provisional.peerAlternateIRK.byteCount == 16)
        #expect(
            try await store.recoveryDecisions()
                == [.verifyThenCommit(provisional)]
        )

        let committed = try await store.commitM6(
            for: verified.deviceID,
            committedAt: committedAt
        )
        #expect(
            committed.completion == .committedAfterM6(
                verifiedAt: verifiedAt,
                committedAt: committedAt
            )
        )
        #expect(
            try await store.recoveryDecisions() == [.ready(committed)]
        )

        let repeatedCommit = try await store.commitM6(
            for: verified.deviceID,
            committedAt: committedAt.addingTimeInterval(5)
        )
        #expect(repeatedCommit == committed)
    }

    @Test("the decoder distinguishes unknown schemas from corrupt payloads")
    func schemaAndCorruptionFailures() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        driver.seed(
            Data(
                """
                {"schemaVersion": 999}
                """.utf8
            )
        )

        await expectError(
            PairingPersistenceError.unsupportedSchemaVersion(999)
        ) {
            try await store.loadOrCreateControllerIdentity()
        }

        driver.seed(Data([0xFF, 0x00, 0x7B]))
        await expectError(PairingPersistenceError.corruptPayload) {
            try await store.loadOrCreateControllerIdentity()
        }
    }

    @Test("every operation uses a device-only, unsynchronized Keychain item")
    func keychainQueryContract() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)

        _ = try await store.loadOrCreateControllerIdentity()

        let descriptors = driver.operations.map(\.descriptor)
        #expect(!descriptors.isEmpty)
        #expect(
            descriptors.allSatisfy {
                $0 == KeychainItemDescriptor.pairingVault
            }
        )
        #expect(
            KeychainItemDescriptor.pairingVault.accessibility
                == .afterFirstUnlockThisDeviceOnly
        )
        #expect(!KeychainItemDescriptor.pairingVault.synchronizesWithCloud)
        #expect(KeychainItemDescriptor.pairingVault.accessGroup == nil)
        #expect(KeychainItemDescriptor.pairingVault.account == "pairing-vault")
    }

    @Test("a configured Keychain service preserves the storage contract")
    func configuredKeychainService() {
        let descriptor = KeychainItemDescriptor.pairingVault(
            service: "com.example.DeviceHub.PairingVault"
        )

        #expect(
            descriptor.service == "com.example.DeviceHub.PairingVault"
        )
        #expect(descriptor.account == "pairing-vault")
        #expect(
            descriptor.accessibility
                == .afterFirstUnlockThisDeviceOnly
        )
        #expect(!descriptor.synchronizesWithCloud)
        #expect(descriptor.accessGroup == nil)
    }

    @Test("OSStatus failures preserve operation and status")
    func statusPropagation() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let expectedError = KeychainDriverError.osStatus(
            operation: .add,
            status: -25243
        )
        driver.failNextAdd(with: expectedError)

        await expectError(expectedError) {
            try await store.loadOrCreateControllerIdentity()
        }
    }

    @Test("an atomic update failure leaves the previous vault intact")
    func failedUpdatePreservesVault() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let controller = try await store.loadOrCreateControllerIdentity()
        let expectedError = KeychainDriverError.osStatus(
            operation: .update,
            status: -25291
        )
        driver.failNextUpdate(with: expectedError)

        await expectError(expectedError) {
            try await store.saveVerifiedM5(fixtureVerifiedM5())
        }

        #expect(try await store.pairingRecords().isEmpty)
        #expect(
            try await store.loadOrCreateControllerIdentity() == controller
        )
    }

    @Test("forget is idempotent and never removes the controller identity")
    func deleteSemantics() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let controller = try await store.loadOrCreateControllerIdentity()
        let verified = try fixtureVerifiedM5()
        _ = try await store.saveVerifiedM5(verified)

        #expect(try await store.forgetTarget(verified.deviceID))
        #expect(try await !(store.forgetTarget(verified.deviceID)))
        #expect(try await store.pairingRecords().isEmpty)
        #expect(
            try await store.loadOrCreateControllerIdentity() == controller
        )
        #expect(!driver.operationKinds.contains(.delete))
    }

    @Test("secret and public key values are redacted from every description")
    func keyMaterialRedaction() throws {
        let secretBytes = Data(repeating: 0xAB, count: 32)
        let publicBytes = Data(repeating: 0xCD, count: 32)
        let irkBytes = Data(repeating: 0xEF, count: 16)
        let peerIRKBytes = Data(repeating: 0xBC, count: 16)
        let secret = try Ed25519SecretKey(data: secretBytes)
        let publicKey = try Ed25519PublicKey(data: publicBytes)
        let irk = try HostAlternateIRK(data: irkBytes)
        let peerIRK = try PeerAlternateIRK(data: peerIRKBytes)

        let output = [
            String(describing: secret),
            String(reflecting: secret),
            String(customDumping: secret),
            String(describing: publicKey),
            String(reflecting: publicKey),
            String(customDumping: publicKey),
            String(describing: irk),
            String(reflecting: irk),
            String(customDumping: irk),
            String(describing: peerIRK),
            String(reflecting: peerIRK),
            String(customDumping: peerIRK)
        ].joined(separator: "\n")

        #expect(output.contains("<redacted>"))
        #expect(!output.contains(secretBytes.base64EncodedString()))
        #expect(!output.contains(publicBytes.base64EncodedString()))
        #expect(!output.contains(irkBytes.base64EncodedString()))
        #expect(!output.contains(peerIRKBytes.base64EncodedString()))
        #expect(!output.contains("171, 171"))
        #expect(!output.contains("205, 205"))
        #expect(!output.contains("239, 239"))
        #expect(!output.contains("188, 188"))
    }

    @Test("host fingerprint mismatch is rejected during vault recovery")
    func hostFingerprintMismatch() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let verified = try fixtureVerifiedM5()
        let record = try await store.saveVerifiedM5(verified)
        let originalFingerprint = record.hostIdentityFingerprint
            .withUnsafeBytes { Data($0) }
            .base64EncodedString()
        let wrongFingerprint = Data(repeating: 0x9A, count: 32)
            .base64EncodedString()
        let payload = try #require(driver.storedData)
        let payloadText = try #require(String(data: payload, encoding: .utf8))
        let tamperedText = payloadText.replacingOccurrences(
            of: originalFingerprint,
            with: wrongFingerprint
        )
        #expect(tamperedText != payloadText)
        driver.seed(Data(tamperedText.utf8))
        let relaunchedStore = try makeStore(driver: driver)

        await expectError(
            PairingPersistenceError.hostIdentityMismatch(verified.deviceID)
        ) {
            try await relaunchedStore.recoveryDecisions()
        }
    }
}

private func fixtureController(seed: UInt8) throws -> ControllerIdentity {
    guard let identifier = UUID(
        uuidString: "E2827B92-4672-4D5B-A8A4-00000000000\(seed)"
    ) else {
        throw FixtureError.invalidUUID
    }
    return try ControllerIdentity(
        identifier: ControllerIdentifier(rawValue: identifier),
        udid: ControllerUDID(
            rawValue: "00008140-CONTROLLER-00000000000\(seed)"
        ),
        longTermSecretKey: Ed25519SecretKey(
            data: Data(repeating: seed, count: 32)
        ),
        alternateIRK: HostAlternateIRK(
            data: Data(repeating: seed &+ 10, count: 16)
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

func fixtureVerifiedM5(
    verifiedAt: Date = Date(timeIntervalSince1970: 1_750_000_000),
    peerSeed: UInt8 = 4
) throws -> VerifiedM5Pairing {
    try VerifiedM5Pairing(
        deviceID: DeviceID(rawValue: "00008140-DEVICE-HUB"),
        accountIdentifier: PairingAccountIdentifier(
            rawValue: "device-account"
        ),
        peerIdentifier: PeerPairingIdentifier(
            rawValue: "peer-identifier-\(peerSeed)"
        ),
        peerPublicKey: Ed25519PublicKey(
            data: Data(repeating: peerSeed, count: 32)
        ),
        peerAlternateIRK: PeerAlternateIRK(
            data: Data(repeating: peerSeed &+ 1, count: 16)
        ),
        displayName: "Test iPhone",
        productType: "iPhone19,1",
        verifiedAt: verifiedAt
    )
}

func makeStore(
    driver: MemoryKeychainDriver
) throws -> KeychainPairingStore {
    let generator = try IdentityGeneratorProbe(
        identities: [fixtureController(seed: 8)]
    )
    return KeychainPairingStore(
        driver: driver,
        generateControllerIdentity: generator.generate
    )
}

func expectError<E: Error & Equatable>(
    _ expectedError: E,
    operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expectedError)")
    } catch let error as E {
        #expect(error == expectedError)
    } catch {
        Issue.record("Expected \(expectedError), got \(error)")
    }
}

private enum FixtureError: Error {
    case invalidUUID
}

private final class IdentityGeneratorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [ControllerIdentity]
    private var mutableCallCount = 0

    init(identities: [ControllerIdentity]) {
        self.identities = identities
    }

    var callCount: Int {
        lock.withLock { mutableCallCount }
    }

    func generate() throws -> ControllerIdentity {
        try lock.withLock {
            guard let identity = identities.first else {
                throw ProbeError.exhausted
            }
            identities.removeFirst()
            mutableCallCount += 1
            return identity
        }
    }

    enum ProbeError: Error {
        case exhausted
    }
}

final class MemoryKeychainDriver: KeychainDriving, @unchecked Sendable {
    struct Operation: Equatable, Sendable {
        let descriptor: KeychainItemDescriptor
        let kind: KeychainOperation
    }

    private struct State {
        var data: Data?
        var nextAddError: KeychainDriverError?
        var nextReadError: KeychainDriverError?
        var nextUpdateError: KeychainDriverError?
        var operations: [Operation] = []
    }

    private let lock = NSLock()
    private var state = State()

    var operations: [Operation] {
        lock.withLock { state.operations }
    }

    var operationKinds: [KeychainOperation] {
        operations.map(\.kind)
    }

    var storedData: Data? {
        lock.withLock { state.data }
    }

    func seed(_ data: Data?) {
        lock.withLock {
            state.data = data
        }
    }

    func failNextAdd(with error: KeychainDriverError) {
        lock.withLock {
            state.nextAddError = error
        }
    }

    func failNextRead(with error: KeychainDriverError) {
        lock.withLock {
            state.nextReadError = error
        }
    }

    func failNextUpdate(with error: KeychainDriverError) {
        lock.withLock {
            state.nextUpdateError = error
        }
    }

    func read(_ descriptor: KeychainItemDescriptor) throws -> Data? {
        try lock.withLock {
            state.operations.append(
                Operation(descriptor: descriptor, kind: .read)
            )
            if let error = state.nextReadError {
                state.nextReadError = nil
                throw error
            }
            return state.data
        }
    }

    func add(
        _ data: Data,
        for descriptor: KeychainItemDescriptor
    ) throws {
        try lock.withLock {
            state.operations.append(
                Operation(descriptor: descriptor, kind: .add)
            )
            if let error = state.nextAddError {
                state.nextAddError = nil
                throw error
            }
            guard state.data == nil else {
                throw KeychainDriverError.osStatus(
                    operation: .add,
                    status: KeychainStatus.duplicateItem
                )
            }
            state.data = data
        }
    }

    func update(
        _ data: Data,
        for descriptor: KeychainItemDescriptor
    ) throws {
        try lock.withLock {
            state.operations.append(
                Operation(descriptor: descriptor, kind: .update)
            )
            if let error = state.nextUpdateError {
                state.nextUpdateError = nil
                throw error
            }
            guard state.data != nil else {
                throw KeychainDriverError.osStatus(
                    operation: .update,
                    status: KeychainStatus.itemNotFound
                )
            }
            state.data = data
        }
    }

    func delete(_ descriptor: KeychainItemDescriptor) throws {
        lock.withLock {
            state.operations.append(
                Operation(descriptor: descriptor, kind: .delete)
            )
            state.data = nil
        }
    }
}
