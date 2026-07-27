import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubMedia
import DeviceHubPersistence
@testable import DeviceHubTransport
import Foundation
import Testing

extension DeviceHubClientLiveTests {
    @Test("developer-readiness wire failures retain unsupported-protocol semantics")
    func developerReadinessWireFailureMappings() {
        for code in [
            "developer_mode_status_unsupported",
            "developer_image_lookup_unsupported",
            "developer_image_lookup_presence_malformed",
            "developer_image_lookup_signature_array_malformed",
            "developer_image_lookup_signature_malformed",
            "developer_image_lookup_signature_empty",
            "developer_image_lookup_signature_array_empty",
            "developer_image_lookup_signature_type_unsupported",
            "developer_image_lookup_signature_missing"
        ] {
            #expect(
                mapNativeFailure(
                    NativeSessionFailure(
                        code: code,
                        stage: "developer_readiness",
                        retryable: false
                    )
                ) == .unsupportedProtocolVersion
            )
        }
    }

    @Test("native video failures retain their exact redacted wire phase")
    func nativeVideoFailurePhases() {
        let mappings: [(String, DiagnosticStage)] = [
            ("video_answer_extraction", .startingDisplay),
            ("video_answer_parse", .startingDisplay),
            ("video_apply_answer", .applyingVideoAnswer),
            ("video_generate_configuration", .generatingVideoConfiguration),
            ("video_generate_options", .generatingVideoOptions),
            ("video_validate_receiver", .validatingVideoReceiver),
            ("video_create_receiver", .creatingVideoReceiver),
            ("video_configure_receiver", .configuringVideoReceiver),
            ("video_start_receiver", .startingVideoReceiver),
            ("video_negotiation", .startingDisplay),
            ("video_stream_group_missing", .startingDisplay),
            ("video_stream_payload_encrypted", .startingDisplay),
            ("video_stream_payload_invalid", .startingDisplay),
            ("video_stream_payload_missing", .startingDisplay),
            ("video_stream_selection_ambiguous", .startingDisplay),
            ("video_stream_ssrc_mismatch", .decoding),
            ("video_stream_ssrc_invalid", .startingDisplay),
            ("video_stream_ssrc_missing", .startingDisplay),
            ("video_stream_ssrc_zero", .startingDisplay),
            ("video_stream", .decoding)
        ]

        for (stage, expected) in mappings {
            #expect(
                nativeFailureDiagnosticStage(
                    NativeSessionFailure(
                        code: "video_receiver_rejected",
                        stage: stage,
                        retryable: false
                    )
                ) == expected
            )
        }
    }

    @Test("decoder failures retain a useful redacted wire phase")
    func decoderFailurePhases() {
        #expect(
            mediaDiagnosticStage(for: .decodedDimensionsMismatch)
                == .firstVisual
        )
        #expect(
            mediaDiagnosticStage(
                for: .systemFailure(.createDecompressionSession, .invalidated)
            ) == .startingDisplay
        )
        #expect(
            mediaDiagnosticStage(
                for: .systemFailure(.submitFrame, .malformedCompressedData)
            ) == .decoding
        )
        #expect(
            mediaDiagnosticStage(for: .outputFrameDropped)
                == .displayStalled
        )
        #expect(
            mediaDiagnosticStage(for: .outputFrameMissing)
                == .displayStopped
        )
    }

    @Test(
        "blocked diagnostics I/O cannot delay pairing",
        arguments: DiagnosticPipelineBlock.allCases
    )
    func blockedDiagnosticsDoNotDelayPairing(
        _ block: DiagnosticPipelineBlock
    ) async throws {
        let operations = OperationProbe()
        let pairingPersistence = try PersistenceProbe(records: [])
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations
        )
        let native = try NativeClientProbe(operations: operations)
        let gate = DiagnosticPipelineGate()
        let diagnosticsPersistence = DiagnosticPersistenceProbe(
            saveGate: block == .recorder ? gate : nil
        )
        let recorder = try makeDiagnosticRecorder(
            persistence: diagnosticsPersistence.client
        )
        let pipeline = DeviceHubTransportDiagnosticsPipeline(
            recorder: recorder,
            requestUpload: {
                guard block == .uploader else {
                    return
                }
                await gate.block()
            }
        )
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: pairingPersistence.client,
            bonjour: bonjour.client,
            diagnosticSink: { error, stage in
                pipeline.submit(.failure(error, stage: stage))
            },
            pairingMilestoneSink: { milestone in
                pipeline.submit(.milestone(milestone))
            }
        )

        let pairingTask = Task {
            try await collectPairingEvents(from: client)
        }
        await gate.waitUntilBlocked()

        let events = try await pairingTask.value
        let diagnosticsStillBlocked = await gate.isBlocked
        #expect(diagnosticsStillBlocked)
        try expectNoDifference(events, successfulPairingEvents())

        await gate.release()
    }

    @Test("pairing milestone order is preserved into diagnostics")
    func pairingMilestoneOrderIsPreserved() async throws {
        let persistence = DiagnosticPersistenceProbe()
        let recorder = try makeDiagnosticRecorder(
            persistence: persistence.client
        )
        let pipeline = DeviceHubTransportDiagnosticsPipeline(
            recorder: recorder,
            requestUpload: {}
        )

        pipeline.submit(.milestone(.listenerReady))
        pipeline.submit(.milestone(.advertisementPublished))
        pipeline.submit(.milestone(.peerConnected))
        pipeline.submit(.milestone(.waitingForPairingCode))
        pipeline.submit(.milestone(.savingPairing))
        pipeline.submit(.milestone(.pairingCompleted))

        await persistence.waitForSaveCount(6)
        let snapshot = await recorder.snapshot()
        expectNoDifference(
            snapshot.events,
            expectedPairingDiagnosticEvents()
        )
    }

    @Test("diagnostic recording failure does not change pairing outcome")
    func diagnosticRecordingFailureDoesNotChangePairingOutcome() async throws {
        let operations = OperationProbe()
        let pairingPersistence = try PersistenceProbe(records: [])
        let bonjour = BonjourClientProbe(
            availability: [],
            operations: operations
        )
        let native = try NativeClientProbe(operations: operations)
        let diagnosticsPersistence = DiagnosticPersistenceProbe(
            saveFailure: .writingFailed
        )
        let recorder = try makeDiagnosticRecorder(
            persistence: diagnosticsPersistence.client
        )
        let failures = DiagnosticPipelineFailureProbe()
        let pipeline = DeviceHubTransportDiagnosticsPipeline(
            recorder: recorder,
            requestUpload: {},
            reportFailure: failures.record
        )
        let client = try makeClient(
            nativeSessions: native.client,
            persistence: pairingPersistence.client,
            bonjour: bonjour.client,
            diagnosticSink: { error, stage in
                pipeline.submit(.failure(error, stage: stage))
            },
            pairingMilestoneSink: { milestone in
                pipeline.submit(.milestone(milestone))
            }
        )

        let events = try await collectPairingEvents(from: client)
        await failures.wait(forCount: 6)

        try expectNoDifference(events, successfulPairingEvents())
        expectNoDifference(
            failures.values,
            [
                .advertisingPairing,
                .advertisingPairing,
                .pairing,
                .waitingForPairingCode,
                .savingPairing,
                .pairingComplete
            ]
        )
    }
}

private func collectPairingEvents(
    from client: DeviceHubClient
) async throws -> [PairingEvent] {
    var events: [PairingEvent] = []
    for try await event in client.pair(PairingRequest()) {
        events.append(event)
    }
    return events
}

private func successfulPairingEvents() throws -> [PairingEvent] {
    try [
        .advertising,
        .waitingForCodeEntry(
            code: #require(PairingCode("123456"))
        ),
        .saving,
        .paired(
            DeviceSummary(
                id: deviceID,
                name: "Test iPhone",
                productType: "iPhone17,1",
                operatingSystemVersion: nil,
                pairingState: .paired,
                reachability: .unavailable
            )
        )
    ]
}

private func makeDiagnosticRecorder(
    persistence: DiagnosticPersistenceClient
) throws -> DiagnosticRecorder {
    try DiagnosticRecorder(
        context: DiagnosticWireContext(
            installationID: #require(
                UUID(
                    uuidString:
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                )
            ),
            sessionID: #require(
                UUID(
                    uuidString:
                    "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
                )
            ),
            appVersion: "1.0.0",
            buildNumber: "42"
        ),
        policy: DiagnosticRetentionPolicy(
            maximumEventCount: 32,
            maximumEncodedByteCount: 65536
        ),
        persistence: persistence,
        uploader: DiagnosticUploadClient { _ in },
        now: { now }
    )
}

private func expectedPairingDiagnosticEvents() -> [DiagnosticEvent] {
    [
        pairingDiagnosticEvent(
            sequence: 1,
            stage: .advertisingPairing,
            kind: .stateChanged,
            outcome: .started
        ),
        pairingDiagnosticEvent(
            sequence: 2,
            stage: .advertisingPairing,
            kind: .operationSucceeded,
            outcome: .succeeded
        ),
        pairingDiagnosticEvent(
            sequence: 3,
            stage: .pairing,
            kind: .stateChanged,
            outcome: .started
        ),
        pairingDiagnosticEvent(
            sequence: 4,
            stage: .waitingForPairingCode,
            kind: .stateChanged,
            outcome: .started
        ),
        pairingDiagnosticEvent(
            sequence: 5,
            stage: .savingPairing,
            kind: .stateChanged,
            outcome: .started
        ),
        pairingDiagnosticEvent(
            sequence: 6,
            stage: .pairingComplete,
            kind: .operationSucceeded,
            outcome: .succeeded
        )
    ]
}

private func pairingDiagnosticEvent(
    sequence: UInt64,
    stage: DiagnosticStage,
    kind: DiagnosticEventKind,
    outcome: DiagnosticOutcome
) -> DiagnosticEvent {
    DiagnosticEvent(
        sequence: sequence,
        timestamp: now,
        level: .info,
        category: .pairing,
        stage: stage,
        kind: kind,
        fields: DiagnosticFields(
            outcome: outcome,
            transport: .localNetwork,
            service: .remotePairing
        )
    )
}

/// Selects the diagnostics I/O boundary held open during a pairing test.
enum DiagnosticPipelineBlock: CaseIterable, Sendable {
    case recorder
    case uploader
}

/// Suspends one diagnostics operation while exposing deterministic entry and
/// release checkpoints to the test.
private actor DiagnosticPipelineGate {
    private var didEnter = false
    private var didRelease = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var isBlocked: Bool {
        didEnter && !didRelease
    }

    func block() async {
        if !didEnter {
            didEnter = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
        }
        guard !didRelease else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !didEnter else {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !didRelease else {
            return
        }
        didRelease = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// In-memory diagnostic persistence with deterministic blocking, failure, and
/// save-count observation.
private actor DiagnosticPersistenceProbe {
    private let saveFailure: DiagnosticPersistenceFailure?
    private let saveGate: DiagnosticPipelineGate?
    private var savedPayloads: [Data] = []
    private var saveWaiters: [
        (
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []

    init(
        saveGate: DiagnosticPipelineGate? = nil,
        saveFailure: DiagnosticPersistenceFailure? = nil
    ) {
        self.saveFailure = saveFailure
        self.saveGate = saveGate
    }

    nonisolated var client: DiagnosticPersistenceClient {
        DiagnosticPersistenceClient(
            load: { nil },
            save: { data async throws(DiagnosticPersistenceFailure) in
                try await self.save(data)
            },
            clear: {}
        )
    }

    func waitForSaveCount(_ count: Int) async {
        guard savedPayloads.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            saveWaiters.append((count: count, continuation: continuation))
        }
    }

    private func save(
        _ data: Data
    ) async throws(DiagnosticPersistenceFailure) {
        if let saveGate {
            await saveGate.block()
        }
        if let saveFailure {
            throw saveFailure
        }
        savedPayloads.append(data)
        let ready = saveWaiters.filter {
            savedPayloads.count >= $0.count
        }
        saveWaiters.removeAll {
            savedPayloads.count >= $0.count
        }
        ready.forEach { $0.continuation.resume() }
    }
}

/// Thread-safe probe for the pipeline's synchronous, observational failure
/// callback.
private final class DiagnosticPipelineFailureProbe: @unchecked Sendable {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var recordedValues: [DiagnosticStage] = []
    private var waiters: [Waiter] = []

    var values: [DiagnosticStage] {
        lock.withLock { recordedValues }
    }

    func record(_ stage: DiagnosticStage) {
        let ready = lock.withLock { () -> [Waiter] in
            recordedValues.append(stage)
            let ready = waiters.filter {
                recordedValues.count >= $0.count
            }
            waiters.removeAll {
                recordedValues.count >= $0.count
            }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(forCount count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard recordedValues.count < count else {
                    return true
                }
                waiters.append(
                    Waiter(
                        count: count,
                        continuation: continuation
                    )
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}
