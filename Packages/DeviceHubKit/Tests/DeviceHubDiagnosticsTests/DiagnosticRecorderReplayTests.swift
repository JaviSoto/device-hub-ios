import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct DiagnosticRecorderReplayTests {
    @Test func relaunchPreservesPendingCaptureContextAndStartsANewContextSegment() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let firstContext = try diagnosticContext()
        let firstPersistence = PersistenceProbe()
        let firstRecorder = try DiagnosticRecorder(
            context: firstContext,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: firstPersistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { now }
        )
        _ = try await firstRecorder.record(
            level: .notice,
            category: .connection,
            stage: .openingTunnel,
            kind: .stateChanged
        )
        let firstSavedPayloads =
            await firstPersistence.savedPayloads
        let firstPayload = try #require(firstSavedPayloads.last)
        let firstEnvelope = try #require(
            DiagnosticWireBatchEncoder(context: firstContext)
                .envelopes(
                    from: DiagnosticSnapshot.decode(firstPayload),
                    now: now
                )
                .first
        )

        let relaunchedContext = try diagnosticContext(
            sessionID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            appVersion: "2.0.0",
            buildNumber: "84"
        )
        let relaunchedPersistence = PersistenceProbe(
            loadedPayload: firstPayload
        )
        let relaunchedRecorder = try DiagnosticRecorder(
            context: relaunchedContext,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: relaunchedPersistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { now.addingTimeInterval(1) }
        )
        try await relaunchedRecorder.restore()
        _ = try await relaunchedRecorder.record(
            level: .info,
            category: .lifecycle,
            stage: .inactive,
            kind: .stateChanged,
            fields: DiagnosticFields(lifecycleState: .launched)
        )

        let relaunchedSavedPayloads =
            await relaunchedPersistence.savedPayloads
        let relaunchedPayload = try #require(
            relaunchedSavedPayloads.last
        )
        let relaunchedEnvelopes = try DiagnosticWireBatchEncoder(
            context: relaunchedContext
        ).envelopes(
            from: DiagnosticSnapshot.decode(relaunchedPayload),
            now: now.addingTimeInterval(1)
        )
        let firstReplayedEnvelope = try #require(
            relaunchedEnvelopes.first
        )
        let newSessionEnvelope = try #require(
            relaunchedEnvelopes.last
        )
        let newSessionObject = try #require(
            JSONSerialization.jsonObject(
                with: newSessionEnvelope.canonicalJSON()
            ) as? [String: Any]
        )

        let firstReplayedData =
            try firstReplayedEnvelope.canonicalJSON()
        let firstData = try firstEnvelope.canonicalJSON()
        expectNoDifference(relaunchedEnvelopes.count, 2)
        expectNoDifference(firstReplayedData, firstData)
        expectNoDifference(
            newSessionObject["session_id"] as? String,
            relaunchedContext.sessionID.uuidString.lowercased()
        )
        expectNoDifference(
            newSessionObject["app_version"] as? String,
            "2.0.0"
        )
    }

    @Test func crashAfterPostReplaysTheIdenticalIdempotentBatchAfterRelaunch() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let captureContext = try diagnosticContext()
        let firstPersistence = PersistenceProbe(
            clearFailure: .clearingFailed
        )
        let firstUploader = WireUploadProbe(
            runtimeContext: captureContext,
            now: now
        )
        let firstRecorder = try DiagnosticRecorder(
            context: captureContext,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: firstPersistence.client,
            uploader: firstUploader.client,
            now: { now }
        )
        _ = try await firstRecorder.record(
            level: .info,
            category: .connection,
            stage: .ready,
            kind: .operationSucceeded
        )

        await #expect(
            throws: DiagnosticError.persistence(.clearingFailed)
        ) {
            try await firstRecorder.flushOnForeground()
        }

        let firstSavedPayloads =
            await firstPersistence.savedPayloads
        let persistedPayload = try #require(
            firstSavedPayloads.last
        )
        let relaunchedContext = try diagnosticContext(
            sessionID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            appVersion: "2.0.0",
            buildNumber: "84"
        )
        let relaunchedPersistence = PersistenceProbe(
            loadedPayload: persistedPayload
        )
        let relaunchedUploader = WireUploadProbe(
            runtimeContext: relaunchedContext,
            now: now
        )
        let relaunchedRecorder = try DiagnosticRecorder(
            context: relaunchedContext,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: relaunchedPersistence.client,
            uploader: relaunchedUploader.client,
            now: { now }
        )
        try await relaunchedRecorder.restore()
        _ = try await relaunchedRecorder.flushOnForeground()

        let firstBodies = await firstUploader.canonicalEnvelopes
        let replayedBodies = await relaunchedUploader.canonicalEnvelopes
        expectNoDifference(firstBodies.count, 1)
        expectNoDifference(replayedBodies, firstBodies)
    }
}
