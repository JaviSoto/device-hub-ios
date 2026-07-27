import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct DiagnosticRecorderTests {
    @Test func recordingPersistsTheRetainedSnapshot() async throws {
        let persistence = PersistenceProbe()
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { Date(timeIntervalSince1970: 1234) }
        )

        let result = try await recorder.record(
            level: .notice,
            category: .connection,
            stage: .openingTunnel,
            kind: .stateChanged
        )

        let savedPayloads = await persistence.savedPayloads
        let persisted = try DiagnosticSnapshot.decode(
            #require(savedPayloads.last)
        )
        expectNoDifference(result.event, persisted.events.first)
        expectNoDifference(
            result.retention,
            DiagnosticRetentionResult(
                evictedEventCount: 0,
                droppedIncomingEvent: false
            )
        )
        expectNoDifference(result.event.sequence, 1)
        expectNoDifference(
            result.event.timestamp,
            Date(timeIntervalSince1970: 1234)
        )
    }

    @Test func rotationFailureIsSurfacedAndTheEventRemainsRetryable() async throws {
        let persistence = PersistenceProbe(saveFailure: .rotationFailed)
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { Date(timeIntervalSince1970: 1234) }
        )

        await #expect(throws: DiagnosticError.persistence(.rotationFailed)) {
            try await recorder.record(
                level: .error,
                category: .persistence,
                stage: .inactive,
                kind: .operationFailed,
                fields: DiagnosticFields(
                    failureCode: .persistenceFailed,
                    retryability: .automatic
                )
            )
        }

        let snapshot = await recorder.snapshot()
        expectNoDifference(snapshot.events.map(\.sequence), [1])
    }

    @Test func restoringContinuesThePersistedSequence() async throws {
        let persistedEvent = DiagnosticEvent.fixture(sequence: 7)
        let persistedData = try DiagnosticSnapshot(
            events: [persistedEvent]
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persistedData)
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { Date(timeIntervalSince1970: 1234) }
        )

        try await recorder.restore()
        let result = try await recorder.record(
            level: .info,
            category: .lifecycle,
            stage: .inactive,
            kind: .stateChanged
        )

        let snapshot = await recorder.snapshot()
        expectNoDifference(snapshot.events.map(\.sequence), [7, 8])
        expectNoDifference(result.event.sequence, 8)
    }

    @Test func loadingFailureIsSurfacedWithoutChangingMemory() async throws {
        let persistence = PersistenceProbe(loadFailure: .loadingFailed)
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { Date(timeIntervalSince1970: 1234) }
        )

        await #expect(throws: DiagnosticError.persistence(.loadingFailed)) {
            try await recorder.restore()
        }

        let snapshot = await recorder.snapshot()
        expectNoDifference(snapshot.events, [])
    }

    @Test func corruptPersistedDataIsRejectedWithoutChangingMemory() async throws {
        let persistence = PersistenceProbe(
            loadedPayload: Data("not-json".utf8)
        )
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: DiagnosticUploadClient { _ in },
            now: { Date(timeIntervalSince1970: 1234) }
        )

        await #expect(throws: DiagnosticError.decodingFailed) {
            try await recorder.restore()
        }

        let snapshot = await recorder.snapshot()
        expectNoDifference(snapshot.events, [])
    }

    @Test func foregroundFlushUploadsThenClearsTheSameSnapshot() async throws {
        let persistence = PersistenceProbe()
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { Date(timeIntervalSince1970: 1234) }
        )
        _ = try await recorder.record(
            level: .info,
            category: .connection,
            stage: .ready,
            kind: .operationSucceeded
        )

        let result = try await recorder.flushOnForeground()

        let uploadedPayloads = await uploader.uploadedPayloads
        let uploaded = try DiagnosticSnapshot.decode(
            #require(uploadedPayloads.first)
        )
        let retained = await recorder.snapshot()
        let clearCount = await persistence.clearCount
        expectNoDifference(uploaded.events.map(\.sequence), [1])
        expectNoDifference(retained.events, [])
        expectNoDifference(clearCount, 1)
        expectNoDifference(
            result,
            DiagnosticFlushResult.flushed(
                eventCount: 1,
                expiredEventCount: 0,
                encodedByteCount: uploadedPayloads[0].count
            )
        )
    }

    @Test func uploadFailureRetainsTheSnapshotAndDoesNotClearPersistence() async throws {
        let persistence = PersistenceProbe()
        let uploader = UploadProbe(failure: .transportFailed)
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { Date(timeIntervalSince1970: 1234) }
        )
        _ = try await recorder.record(
            level: .warning,
            category: .flush,
            stage: .ready,
            kind: .operationFailed
        )

        await #expect(throws: DiagnosticError.upload(.transportFailed)) {
            try await recorder.flushOnForeground()
        }

        let retained = await recorder.snapshot()
        let clearCount = await persistence.clearCount
        expectNoDifference(retained.events.map(\.sequence), [1])
        expectNoDifference(clearCount, 0)
    }

    @Test func clearingFailureAfterUploadRetainsTheSnapshotForAtLeastOnceDelivery() async throws {
        let persistence = PersistenceProbe(clearFailure: .clearingFailed)
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { Date(timeIntervalSince1970: 1234) }
        )
        _ = try await recorder.record(
            level: .warning,
            category: .flush,
            stage: .ready,
            kind: .operationFailed
        )

        await #expect(throws: DiagnosticError.persistence(.clearingFailed)) {
            try await recorder.flushOnForeground()
        }

        let retained = await recorder.snapshot()
        let uploadCount = await uploader.uploadedPayloads.count
        expectNoDifference(retained.events.map(\.sequence), [1])
        expectNoDifference(uploadCount, 1)
    }

    @Test func emptyForegroundFlushPerformsNoIO() async throws {
        let persistence = PersistenceProbe()
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { Date(timeIntervalSince1970: 1234) }
        )

        let result = try await recorder.flushOnForeground()

        let uploadCount = await uploader.uploadedPayloads.count
        let clearCount = await persistence.clearCount
        expectNoDifference(result, .nothingToFlush)
        expectNoDifference(uploadCount, 0)
        expectNoDifference(clearCount, 0)
    }

    @Test func cancellingAnInFlightForegroundFlushRetainsTheSnapshot() async throws {
        let persistence = PersistenceProbe()
        let (uploadStarted, uploadStartedContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        let uploader = DiagnosticUploadClient { _ async throws(DiagnosticUploadFailure) in
            uploadStartedContinuation.yield()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .transportFailed
            }
        }
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: uploader,
            now: { Date(timeIntervalSince1970: 1234) }
        )
        _ = try await recorder.record(
            level: .notice,
            category: .flush,
            stage: .ready,
            kind: .stateChanged
        )

        let flushTask = Task {
            try await recorder.flushOnForeground()
        }
        var uploadStartedIterator = uploadStarted.makeAsyncIterator()
        let didStart = await uploadStartedIterator.next() != nil
        #expect(didStart)
        flushTask.cancel()

        await #expect(
            throws: DiagnosticError.cancelled(.foregroundFlush)
        ) {
            try await flushTask.value
        }

        let retained = await recorder.snapshot()
        let clearCount = await persistence.clearCount
        expectNoDifference(retained.events.map(\.sequence), [1])
        expectNoDifference(clearCount, 0)
    }

    @Test func recordingDuringAFlushCannotResurrectTheUploadedBatch() async throws {
        let persistence = PersistenceProbe()
        let uploader = BlockingUploadProbe()
        let recorder = try DiagnosticRecorder(
            context: diagnosticContext(),
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 8192
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { Date(timeIntervalSince1970: 1234) }
        )
        _ = try await recorder.record(
            level: .info,
            category: .connection,
            stage: .ready,
            kind: .operationSucceeded
        )

        let flushTask = Task {
            try await recorder.flushOnForeground()
        }
        await uploader.waitUntilStarted()
        let recordTask = Task {
            try await recorder.record(
                level: .notice,
                category: .lifecycle,
                stage: .ready,
                kind: .stateChanged
            )
        }
        await Task.yield()
        let saveCountWhileFlushing = await persistence.savedPayloads.count
        expectNoDifference(saveCountWhileFlushing, 1)

        await uploader.release()
        _ = try await flushTask.value
        let secondRecord = try await recordTask.value

        let retained = await recorder.snapshot()
        let savedPayloads = await persistence.savedPayloads
        let lastSavedPayload = try #require(savedPayloads.last)
        let lastSaved = try DiagnosticSnapshot.decode(lastSavedPayload)
        expectNoDifference(secondRecord.event.sequence, 2)
        expectNoDifference(retained.events.map(\.sequence), [2])
        expectNoDifference(lastSaved.events.map(\.sequence), [2])
    }
}
