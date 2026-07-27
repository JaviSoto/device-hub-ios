import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct DiagnosticRecorderExpiryTests {
    @Test func foregroundFlushPrunesExpiredEventsBeforePersistenceAndUpload() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let persisted = try DiagnosticSnapshot(
            context: context,
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(
                        -(7 * 24 * 60 * 60) - 0.001
                    ),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                ),
                DiagnosticEvent(
                    sequence: 2,
                    timestamp: now.addingTimeInterval(-7 * 24 * 60 * 60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            ]
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persisted)
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        let result = try await recorder.flushOnForeground()

        let savedPayloads = await persistence.savedPayloads
        let uploadedPayloads = await uploader.uploadedPayloads
        let prunedPayload = try #require(savedPayloads.last)
        let uploadedPayload = try #require(uploadedPayloads.first)
        try expectNoDifference(
            DiagnosticSnapshot.decode(prunedPayload).events.map(\.sequence),
            [2]
        )
        expectNoDifference(uploadedPayload, prunedPayload)
        expectNoDifference(
            result,
            .flushed(
                eventCount: 1,
                expiredEventCount: 1,
                encodedByteCount: uploadedPayload.count
            )
        )
    }

    @Test func entirelyExpiredSnapshotIsRemovedWithoutStartingTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let persisted = try DiagnosticSnapshot(
            context: context,
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            ]
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persisted)
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        let result = try await recorder.flushOnForeground()
        let uploadedPayloads = await uploader.uploadedPayloads
        let savedPayloads = await persistence.savedPayloads
        let clearCount = await persistence.clearCount
        let retainedEvents = await recorder.snapshot().events

        expectNoDifference(
            result,
            .discardedExpiredEvents(eventCount: 1)
        )
        expectNoDifference(uploadedPayloads, [])
        expectNoDifference(savedPayloads, [])
        expectNoDifference(clearCount, 1)
        expectNoDifference(retainedEvents, [])
    }

    @Test func expiryPruningFailureRetainsTheOriginalSnapshotAndSkipsTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let events = [
            DiagnosticEvent(
                sequence: 1,
                timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                level: .info,
                category: .connection,
                stage: .ready,
                kind: .operationSucceeded
            ),
            DiagnosticEvent(
                sequence: 2,
                timestamp: now,
                level: .info,
                category: .connection,
                stage: .ready,
                kind: .operationSucceeded
            )
        ]
        let persistence = try PersistenceProbe(
            loadedPayload: DiagnosticSnapshot(
                context: context,
                events: events
            ).encoded(),
            saveFailure: .writingFailed
        )
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        await #expect(
            throws: DiagnosticError.persistence(.writingFailed)
        ) {
            try await recorder.flushOnForeground()
        }

        let retainedEvents = await recorder.snapshot().events
        let uploadedPayloads = await uploader.uploadedPayloads
        let clearCount = await persistence.clearCount
        expectNoDifference(retainedEvents, events)
        expectNoDifference(uploadedPayloads, [])
        expectNoDifference(clearCount, 0)
    }
}
