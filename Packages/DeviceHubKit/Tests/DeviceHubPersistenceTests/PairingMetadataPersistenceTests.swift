import DeviceHubCore
import DeviceHubPersistence
import Foundation
import Testing

@Suite("Pairing metadata persistence")
struct PairingMetadataPersistenceTests {
    @Test("verified M5 persists without inventing an OS version")
    func verifiedM5DoesNotInventOperatingSystemVersion() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let pairing = try VerifiedM5Pairing(
            deviceID: DeviceID(rawValue: "00008140-DEVICE-HUB"),
            accountIdentifier: PairingAccountIdentifier(
                rawValue: "device-account"
            ),
            peerIdentifier: PeerPairingIdentifier(
                rawValue: "peer-identifier"
            ),
            peerPublicKey: Ed25519PublicKey(
                data: Data(repeating: 4, count: 32)
            ),
            peerAlternateIRK: PeerAlternateIRK(
                data: Data(repeating: 5, count: 16)
            ),
            displayName: "Test iPhone",
            productType: "iPhone19,1",
            verifiedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let record = try await store.saveVerifiedM5(pairing)
        #expect(record.operatingSystemVersion == nil)
        let payload = try #require(driver.storedData)
        let payloadText = try #require(String(data: payload, encoding: .utf8))
        #expect(payloadText.contains("\"schemaVersion\":1"))
        #expect(!payloadText.contains("\"operatingSystemVersion\""))

        let relaunchedStore = try makeStore(driver: driver)
        let relaunchedRecord = try #require(
            await relaunchedStore.pairingRecords().first
        )
        #expect(relaunchedRecord.operatingSystemVersion == nil)
    }

    @Test("authenticated RSD enriches metadata without changing pairing state")
    func authenticatedRSDEnrichmentPreservesPairingState() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let pairing = try fixtureVerifiedM5()
        let provisional = try await store.saveVerifiedM5(pairing)
        let metadata = try AuthenticatedRSDMetadata(
            operatingSystemVersion: "27.0"
        )

        let enriched = try await store.enrichFromAuthenticatedRSD(
            metadata,
            for: pairing.deviceID
        )

        #expect(enriched.operatingSystemVersion == "27.0")
        #expect(enriched.accountIdentifier == provisional.accountIdentifier)
        #expect(enriched.completion == provisional.completion)
        #expect(enriched.deviceID == provisional.deviceID)
        #expect(enriched.displayName == provisional.displayName)
        #expect(
            enriched.hostIdentityFingerprint
                == provisional.hostIdentityFingerprint
        )
        #expect(enriched.peerAlternateIRK == provisional.peerAlternateIRK)
        #expect(enriched.peerIdentifier == provisional.peerIdentifier)
        #expect(enriched.peerPublicKey == provisional.peerPublicKey)
        #expect(enriched.productType == provisional.productType)
        #expect(
            try await store.recoveryDecisions()
                == [.verifyThenCommit(enriched)]
        )

        let committed = try await store.commitM6(
            for: pairing.deviceID,
            committedAt: pairing.verifiedAt.addingTimeInterval(1)
        )
        #expect(committed.operatingSystemVersion == "27.0")
        #expect(
            try await store.recoveryDecisions() == [.ready(committed)]
        )
    }

    @Test("authenticated RSD can enrich an already committed pairing")
    func authenticatedRSDEnrichesCommittedPairing() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let pairing = try fixtureVerifiedM5()
        _ = try await store.saveVerifiedM5(pairing)
        let committed = try await store.commitM6(
            for: pairing.deviceID,
            committedAt: pairing.verifiedAt.addingTimeInterval(1)
        )

        let enriched = try await store.enrichFromAuthenticatedRSD(
            AuthenticatedRSDMetadata(operatingSystemVersion: "27.0"),
            for: pairing.deviceID
        )

        #expect(enriched.operatingSystemVersion == "27.0")
        #expect(enriched.completion == committed.completion)
        let relaunchedStore = try makeStore(driver: driver)
        #expect(try await relaunchedStore.pairingRecords() == [enriched])
    }

    @Test("authenticated RSD enrichment is idempotent and replaceable")
    func authenticatedRSDEnrichmentUpdateRules() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let pairing = try fixtureVerifiedM5()
        _ = try await store.saveVerifiedM5(pairing)
        let first = try AuthenticatedRSDMetadata(
            operatingSystemVersion: "27.0"
        )
        _ = try await store.enrichFromAuthenticatedRSD(
            first,
            for: pairing.deviceID
        )
        let updateCount = driver.operationKinds.filter { $0 == .update }.count

        let unchanged = try await store.enrichFromAuthenticatedRSD(
            first,
            for: pairing.deviceID
        )
        #expect(unchanged.operatingSystemVersion == "27.0")
        #expect(
            driver.operationKinds.filter { $0 == .update }.count
                == updateCount
        )

        let replaced = try await store.enrichFromAuthenticatedRSD(
            AuthenticatedRSDMetadata(operatingSystemVersion: "27.1"),
            for: pairing.deviceID
        )
        #expect(replaced.operatingSystemVersion == "27.1")
        #expect(
            driver.operationKinds.filter { $0 == .update }.count
                == updateCount + 1
        )
    }

    @Test("failed RSD enrichment atomically preserves prior metadata")
    func failedAuthenticatedRSDEnrichmentPreservesRecord() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let pairing = try fixtureVerifiedM5()
        _ = try await store.saveVerifiedM5(pairing)
        let original = try await store.enrichFromAuthenticatedRSD(
            AuthenticatedRSDMetadata(operatingSystemVersion: "27.0"),
            for: pairing.deviceID
        )
        let originalPayload = try #require(driver.storedData)
        let expectedError = KeychainDriverError.osStatus(
            operation: .update,
            status: -25291
        )
        driver.failNextUpdate(with: expectedError)

        await expectError(expectedError) {
            try await store.enrichFromAuthenticatedRSD(
                AuthenticatedRSDMetadata(
                    operatingSystemVersion: "27.1"
                ),
                for: pairing.deviceID
            )
        }

        #expect(driver.storedData == originalPayload)
        #expect(try await store.pairingRecords() == [original])
    }

    @Test("RSD metadata cannot be persisted without a paired identity")
    func authenticatedRSDEnrichmentRequiresPairing() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let deviceID = DeviceID(rawValue: "00008140-UNPAIRED")

        await expectError(
            PairingPersistenceError.targetNotFound(deviceID)
        ) {
            try await store.enrichFromAuthenticatedRSD(
                AuthenticatedRSDMetadata(
                    operatingSystemVersion: "27.0"
                ),
                for: deviceID
            )
        }

        #expect(driver.storedData == nil)
        #expect(driver.operationKinds == [.read])
    }

    @Test("a new M5 identity never inherits stale RSD metadata")
    func replacementPairingClearsAuthenticatedRSDMetadata() async throws {
        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let original = try fixtureVerifiedM5()
        _ = try await store.saveVerifiedM5(original)
        let enriched = try await store.enrichFromAuthenticatedRSD(
            AuthenticatedRSDMetadata(operatingSystemVersion: "27.0"),
            for: original.deviceID
        )
        let replacement = try fixtureVerifiedM5(
            verifiedAt: original.verifiedAt.addingTimeInterval(10),
            peerSeed: 9
        )

        let replaced = try await store.saveVerifiedM5(replacement)

        #expect(replaced.operatingSystemVersion == nil)
        #expect(replaced.peerPublicKey != enriched.peerPublicKey)
        #expect(
            replaced.hostIdentityFingerprint
                == enriched.hostIdentityFingerprint
        )
        #expect(
            replaced.completion == .provisionalAfterVerifiedM5(
                verifiedAt: replacement.verifiedAt
            )
        )
    }

    @Test("schema-one records with an OS version remain compatible")
    func schemaOneOperatingSystemVersionCompatibility() async throws {
        let writerDriver = MemoryKeychainDriver()
        let writer = try makeStore(driver: writerDriver)
        let pairing = try fixtureVerifiedM5()
        _ = try await writer.saveVerifiedM5(pairing)
        _ = try await writer.enrichFromAuthenticatedRSD(
            AuthenticatedRSDMetadata(operatingSystemVersion: "26.4.1"),
            for: pairing.deviceID
        )
        let schemaOnePayload = try #require(writerDriver.storedData)
        let payloadText = try #require(
            String(data: schemaOnePayload, encoding: .utf8)
        )
        #expect(payloadText.contains("\"schemaVersion\":1"))
        #expect(
            payloadText.contains(
                "\"operatingSystemVersion\":\"26.4.1\""
            )
        )

        let readerDriver = MemoryKeychainDriver()
        readerDriver.seed(schemaOnePayload)
        let reader = try makeStore(driver: readerDriver)
        let decoded = try #require(await reader.pairingRecords().first)

        #expect(decoded.operatingSystemVersion == "26.4.1")
        #expect(readerDriver.operationKinds == [.read])
    }

    @Test("authenticated RSD metadata is validated at every boundary")
    func authenticatedRSDMetadataValidation() async throws {
        let expectedError = PairingPersistenceError.invalidText(
            .operatingSystemVersion
        )
        for invalidValue in [
            " ",
            "27.0\n",
            String(repeating: "a", count: 65)
        ] {
            await expectError(expectedError) {
                try AuthenticatedRSDMetadata(
                    operatingSystemVersion: invalidValue
                )
            }
        }

        let driver = MemoryKeychainDriver()
        let store = try makeStore(driver: driver)
        let pairing = try fixtureVerifiedM5()
        _ = try await store.saveVerifiedM5(pairing)
        _ = try await store.enrichFromAuthenticatedRSD(
            AuthenticatedRSDMetadata(operatingSystemVersion: "27.0"),
            for: pairing.deviceID
        )
        let payload = try #require(driver.storedData)
        let payloadText = try #require(String(data: payload, encoding: .utf8))
        let invalidPayloadText = payloadText.replacingOccurrences(
            of: "\"operatingSystemVersion\":\"27.0\"",
            with: "\"operatingSystemVersion\":\"\""
        )
        #expect(invalidPayloadText != payloadText)
        driver.seed(Data(invalidPayloadText.utf8))
        let relaunchedStore = try makeStore(driver: driver)

        await expectError(expectedError) {
            try await relaunchedStore.pairingRecords()
        }
    }
}
