import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubPersistence
@testable import DeviceHubTransport
import Testing

@Suite("Transport diagnostics isolation")
struct TransportDiagnosticsIsolationTests {
    @Test("diagnostic sink failure preserves pairing error and cleanup")
    func pairingCleanup() async throws {
        let diagnostics = TransportDiagnosticFailureProbe()
        let operations = OperationProbe()
        let persistence = try PersistenceProbe(
            records: [],
            operations: operations
        )
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations
        )
        let native = try NativeClientProbe(
            operations: operations,
            peerDisplayName: "Other iPhone"
        )
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: persistence.client,
            bonjour: bonjour.client,
            diagnosticSink: diagnostics.record,
            reportDiagnosticsFailure: diagnostics.report
        )

        do {
            for try await _ in client.pair(PairingRequest()) {}
            Issue.record("Pairing accepted a target outside the allowlist.")
        } catch let error as DeviceHubError {
            #expect(error == .peerAuthenticationFailed)
        }

        expectNoDifference(
            diagnostics.attempts.map(\.error),
            [.peerAuthenticationFailed]
        )
        expectNoDifference(diagnostics.attempts.map(\.stage), [.pairing])
        expectNoDifference(diagnostics.reportedStages, [.pairing])
        let recordedOperations = await operations.values
        #expect(recordedOperations.last == .nativeCancelled)
        #expect(try await persistence.client.pairingRecords().isEmpty)
    }

    @Test("diagnostic sink failure preserves session error and cleanup")
    func sessionCleanup() async throws {
        let diagnostics = TransportDiagnosticFailureProbe()
        let operations = OperationProbe()
        let persistence = try PersistenceProbe(
            records: [fixtureRecord()],
            operations: operations
        )
        let bonjour = try BonjourClientProbe(
            availability: [],
            operations: operations,
            resolvedService: fixtureRemoteService()
        )
        let native = RemoteNativeClientProbe(operations: operations)
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: persistence.client,
            bonjour: bonjour.client,
            diagnosticSink: diagnostics.record,
            reportDiagnosticsFailure: diagnostics.report
        )

        let session = try await client.connect(deviceID)
        var iterator = session.events.makeAsyncIterator()
        do {
            while try await iterator.next() != nil {}
            Issue.record("The native session failure was not surfaced.")
        } catch let error as DeviceHubError {
            #expect(error == .deviceOffline)
        }

        expectNoDifference(
            diagnostics.attempts.map(\.error),
            [.deviceOffline]
        )
        expectNoDifference(diagnostics.attempts.map(\.stage), [.ready])
        expectNoDifference(diagnostics.reportedStages, [.ready])
        await operations.wait(
            for: .availabilityReleased(deviceID)
        )
        let recordedOperations = await operations.values
        #expect(recordedOperations.contains(.nativeCancelled))
        #expect(
            recordedOperations.last == .availabilityReleased(deviceID)
        )
    }
}
