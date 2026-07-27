import CustomDump
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubTransport
import Testing

@Suite("Live pairing advertisement failures")
struct DeviceHubClientLiveBonjourFailureTests {
    @Test(
        "pairing reports Local Network denial from Bonjour publication",
        arguments: [
            RemotePairingBonjourError.publisherStartFailed(code: -65570),
            RemotePairingBonjourError.publisherFailed(code: -65570)
        ]
    )
    func pairingReportsLocalNetworkPublicationDenial(
        _ bonjourFailure: RemotePairingBonjourError
    ) async throws {
        try await expectPairingAdvertisementFailure(
            bonjourFailure,
            as: .localNetworkDenied
        )
    }

    @Test(
        "pairing keeps unrelated Bonjour publication failures generic",
        arguments: [
            RemotePairingBonjourError.publisherStartFailed(code: -65537),
            RemotePairingBonjourError.publisherFailed(code: -65537)
        ]
    )
    func pairingKeepsUnrelatedPublicationFailuresGeneric(
        _ bonjourFailure: RemotePairingBonjourError
    ) async throws {
        try await expectPairingAdvertisementFailure(
            bonjourFailure,
            as: .secureConnectionFailed
        )
    }

    private func expectPairingAdvertisementFailure(
        _ bonjourFailure: RemotePairingBonjourError,
        as expectedError: DeviceHubError
    ) async throws {
        let operations = OperationProbe()
        let persistence = try PersistenceProbe(
            records: [],
            operations: operations
        )
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations,
            advertisementFailure: bonjourFailure
        )
        let native = try NativeClientProbe(operations: operations)
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: persistence.client,
            bonjour: bonjour.client
        )

        var events: [PairingEvent] = []
        do {
            for try await event in client.pair(PairingRequest()) {
                events.append(event)
            }
            Issue.record("Pairing completed after Bonjour publication failed.")
        } catch let error as DeviceHubError {
            #expect(error == expectedError)
        }

        #expect(events.isEmpty)
        let recordedOperations = await operations.values
        expectNoDifference(
            recordedOperations,
            [
                .nativePairingCreated,
                .nativeStarted,
                .advertised(port: 49155),
                .advertisementStopped,
                .nativeCancelled
            ]
        )
        #expect(try await persistence.client.pairingRecords().isEmpty)
    }
}
