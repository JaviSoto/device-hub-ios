import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct DiagnosticWireReplayTests {
    @Test func persistedCaptureContextWinsAcrossRelaunchAndKeepsTheBatchIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let captureContext = try diagnosticContext()
        let relaunchedContext = try diagnosticContext(
            sessionID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            appVersion: "2.0.0",
            buildNumber: "84"
        )
        let snapshot = DiagnosticSnapshot(
            context: captureContext,
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now,
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .stateChanged
                )
            ]
        )

        let capturedEnvelope = try #require(
            DiagnosticWireBatchEncoder(context: captureContext)
                .envelopes(from: snapshot, now: now)
                .first
        )
        let replayedEnvelope = try #require(
            DiagnosticWireBatchEncoder(context: relaunchedContext)
                .envelopes(from: snapshot, now: now)
                .first
        )
        let replayedObject = try #require(
            JSONSerialization.jsonObject(
                with: replayedEnvelope.canonicalJSON()
            ) as? [String: Any]
        )
        let replayedData = try replayedEnvelope.canonicalJSON()
        let capturedData = try capturedEnvelope.canonicalJSON()

        expectNoDifference(
            replayedEnvelope.batchID,
            capturedEnvelope.batchID
        )
        expectNoDifference(replayedData, capturedData)
        expectNoDifference(
            replayedObject["session_id"] as? String,
            captureContext.sessionID.uuidString.lowercased()
        )
        expectNoDifference(
            replayedObject["app_version"] as? String,
            captureContext.appVersion
        )
        expectNoDifference(
            replayedObject["build_number"] as? String,
            captureContext.buildNumber
        )
    }
}
