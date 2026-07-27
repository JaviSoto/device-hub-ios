import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubPersistence
@testable import DeviceHubTransport
import Testing

@Suite("Device Hub transport configuration")
struct DeviceHubTransportConfigurationTests {
    @Test("roster and availability preserve authenticated optional metadata")
    func rosterAndAvailability() async throws {
        let persistence = try PersistenceProbe(
            records: [
                fixtureRecord(
                    operatingSystemVersion: nil,
                    completion: .provisionalAfterVerifiedM5(
                        verifiedAt: now
                    )
                ),
                fixtureRecord(
                    deviceID: unauthorizedDeviceID,
                    displayName: "Other iPhone"
                )
            ]
        )
        let bonjour = BonjourClientProbe(
            availability: [
                RemotePairingAvailability(
                    deviceID: deviceID,
                    reachability: .reachable
                ),
                RemotePairingAvailability(
                    deviceID: unauthorizedDeviceID,
                    reachability: .reachable
                )
            ]
        )
        let client = try makeClient(
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        let pairedDevices = try await client.pairedDevices()
        expectNoDifference(
            pairedDevices,
            [
                DeviceSummary(
                    id: deviceID,
                    name: "Test iPhone",
                    productType: "iPhone17,1",
                    operatingSystemVersion: nil,
                    pairingState: .paired,
                    reachability: .unavailable
                )
            ]
        )
        var iterator = client.availability().makeAsyncIterator()
        let availability = await iterator.next()
        expectNoDifference(
            availability,
            [
                DeviceSummary(
                    id: deviceID,
                    name: "Test iPhone",
                    productType: "iPhone17,1",
                    operatingSystemVersion: nil,
                    pairingState: .paired,
                    reachability: .reachable
                )
            ]
        )
        #expect(await iterator.next() == nil)
    }

    @Test("remote target policy matches only the exact authenticated name")
    func remoteTargetPolicyRequiresExactName() {
        let policy = DeviceHubRemoteTargetPolicy(
            requiredDisplayName: "Test iPhone"
        )

        #expect(policy.permits(displayName: "Test iPhone"))
        #expect(!policy.permits(displayName: "test iPhone"))
        #expect(!policy.permits(displayName: "Test iPhone "))
        #expect(!policy.permits(displayName: "Other iPhone"))
    }

    @Test("shipping policy permits every cryptographically authenticated target")
    func authenticatedTargetPolicy() {
        let policy = DeviceHubRemoteTargetPolicy.authenticatedDevices

        #expect(policy.permits(displayName: "Test iPhone"))
        #expect(policy.permits(displayName: "Test iPad"))
    }

    @Test("outer whitespace is rejected without forbidding internal spaces")
    func rejectsOuterWhitespace() throws {
        for displayName in [" Test iPhone", "Test iPhone "] {
            #expect(throws: NativeSessionContractError.invalidText) {
                try DeviceHubTransportConfiguration(
                    controllerDisplayName: displayName,
                    controllerModel: "iPhone18,2",
                    remoteTargetPolicy: .authenticatedDevices
                )
            }
        }
        for model in [" iPhone18,2", "iPhone18,2 "] {
            #expect(throws: NativeSessionContractError.invalidText) {
                try DeviceHubTransportConfiguration(
                    controllerDisplayName: "Test Phone",
                    controllerModel: model,
                    remoteTargetPolicy: .authenticatedDevices
                )
            }
        }

        let valid = try DeviceHubTransportConfiguration(
            controllerDisplayName: "Test Phone",
            controllerModel: "iPhone 18,2",
            remoteTargetPolicy: .authenticatedDevices
        )
        #expect(valid.controllerDisplayName == "Test Phone")
        #expect(valid.controllerModel == "iPhone 18,2")
    }

    @Test("connect rejects a non-target record before discovery")
    func connectRejectsNonTargetBeforeDiscovery() async throws {
        let operations = OperationProbe()
        let persistence = try PersistenceProbe(
            records: [
                fixtureRecord(
                    deviceID: unauthorizedDeviceID,
                    displayName: "Other iPhone"
                )
            ]
        )
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations
        )
        let client = try makeClient(
            nativeSessions: .unavailableForTests(
                capabilities: .requiredLiveControl
            ),
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        do {
            _ = try await client.connect(unauthorizedDeviceID)
            Issue.record("Connected to a target outside the allowlist.")
        } catch let error as DeviceHubError {
            #expect(error == .peerAuthenticationFailed)
        }
        let recordedOperations = await operations.values
        expectNoDifference(recordedOperations, [])
    }

    @Test("pairing and live control each fail closed on every required bit")
    func capabilityGates() async throws {
        let pairingBits: [NativeSessionCapabilities] = [
            .sessionLifecycle,
            .generationTaggedEvents,
            .sensitiveInputCopy,
            .pairableHost,
            .acknowledgedPairRecords
        ]
        let liveBits: [NativeSessionCapabilities] = [
            .sessionLifecycle,
            .generationTaggedEvents,
            .sensitiveInputCopy,
            .authenticatedReconnect,
            .rsdMetadata,
            .pngScreenshot,
            .developerReadiness,
            .controlStream,
            .videoNegotiation,
            .rawVideoDatagrams,
            .hevcAccessUnits,
            .touchInput,
            .keyboardInput,
            .hardwareButtonInput,
            .rotation,
            .splitMediaCallback,
            .releaseAllInput
        ]
        let persistence = try PersistenceProbe(
            records: [fixtureRecord()]
        )
        let bonjour = BonjourClientProbe(availability: [])

        for missing in pairingBits {
            let client = try makeClient(
                nativeSessions: .unavailableForTests(
                    capabilities: .requiredPairing.subtracting(missing)
                ),
                persistence: persistence.client,
                bonjour: bonjour.client
            )
            do {
                for try await _ in client.pair(PairingRequest()) {}
                Issue.record("Pairing accepted an incomplete capability set.")
            } catch let error as DeviceHubError {
                #expect(error == .unsupportedProtocolVersion)
            }
        }

        for missing in liveBits {
            let client = try makeClient(
                nativeSessions: .unavailableForTests(
                    capabilities: .requiredLiveControl.subtracting(missing)
                ),
                persistence: persistence.client,
                bonjour: bonjour.client
            )
            do {
                _ = try await client.connect(deviceID)
                Issue.record(
                    "Live control accepted an incomplete capability set."
                )
            } catch let error as DeviceHubError {
                #expect(error == .unsupportedProtocolVersion)
            }
        }
    }
}
