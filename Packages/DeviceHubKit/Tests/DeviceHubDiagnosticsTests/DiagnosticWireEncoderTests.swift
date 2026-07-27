import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

private struct PhaseMapping {
    let category: DiagnosticCategory
    let stage: DiagnosticStage
    let lifecycleState: DiagnosticLifecycleState?
    let wireCategory: String
    let wirePhase: String

    init(
        _ category: DiagnosticCategory,
        _ stage: DiagnosticStage,
        _ lifecycleState: DiagnosticLifecycleState?,
        _ wireCategory: String,
        _ wirePhase: String
    ) {
        self.category = category
        self.stage = stage
        self.lifecycleState = lifecycleState
        self.wireCategory = wireCategory
        self.wirePhase = wirePhase
    }
}

private struct OutcomeMapping {
    let outcome: DiagnosticOutcome?
    let kind: DiagnosticEventKind
    let wireOutcome: String

    init(
        _ outcome: DiagnosticOutcome?,
        _ kind: DiagnosticEventKind,
        _ wireOutcome: String
    ) {
        self.outcome = outcome
        self.kind = kind
        self.wireOutcome = wireOutcome
    }
}

struct DiagnosticWireEncoderTests {
    private let now = Date(timeIntervalSince1970: 1_753_207_200)

    @Test func connectionEventMatchesServerSchemaV1CanonicalJSON() throws {
        let context = try Self.context()
        let encoder = DiagnosticWireBatchEncoder(context: context)
        let snapshot = DiagnosticSnapshot(
            events: [
                DiagnosticEvent(
                    sequence: 7,
                    timestamp: now,
                    level: .info,
                    category: .connection,
                    stage: .openingTunnel,
                    kind: .operationSucceeded,
                    fields: DiagnosticFields(
                        attempt: 1,
                        durationMilliseconds: 145,
                        outcome: .succeeded,
                        retryability: .automatic
                    )
                )
            ]
        )

        let envelope = try #require(
            encoder.envelopes(from: snapshot, now: now).first
        )
        let data = try envelope.canonicalJSON()
        let json = try #require(String(bytes: data, encoding: .utf8))
        let batchID = envelope.batchID.uuidString.lowercased()
        let expectedJSON =
            #"{"app_version":"1.0.0","batch_id":""#
                + batchID
                + "\""
                + #","build_number":"42""#
                + #","events":[{"attempt":1,"category":"connection","duration_ms":145"#
                + #","occurred_at":"2025-07-22T18:00:00Z","outcome":"succeeded""#
                + #","phase":"opening_tunnel","retryable":true,"sequence":7}]"#
                + #","installation_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb""#
                + #","schema_version":1,"sent_at":"2025-07-22T18:00:00Z""#
                + #","session_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}"#

        expectNoDifference(json, expectedJSON)
    }

    private static func context() throws -> DiagnosticWireContext {
        try DiagnosticWireContext(
            installationID: #require(
                UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            ),
            sessionID: #require(
                UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            ),
            appVersion: "1.0.0",
            buildNumber: "42"
        )
    }
}

struct DiagnosticWireMappingTests {
    private let now = Date(timeIntervalSince1970: 1_753_207_200)

    @Test func mapsEveryServerCategoryAndPhaseExactly() throws {
        let mappings = Self.phaseMappings
        let events = mappings.enumerated().map { offset, mapping in
            DiagnosticEvent(
                sequence: UInt64(offset),
                timestamp: now,
                level: .info,
                category: mapping.category,
                stage: mapping.stage,
                kind: .stateChanged,
                fields: DiagnosticFields(
                    outcome: .started,
                    lifecycleState: mapping.lifecycleState
                )
            )
        }

        let wireEvents = try encodedEvents(events)
        expectNoDifference(
            wireEvents.compactMap { $0["category"] as? String },
            mappings.map(\.wireCategory)
        )
        expectNoDifference(
            wireEvents.compactMap { $0["phase"] as? String },
            mappings.map(\.wirePhase)
        )
    }

    private static let phaseMappings: [PhaseMapping] = [
        .init(.lifecycle, .inactive, .launched, "app_lifecycle", "launched"),
        .init(.lifecycle, .inactive, .foreground, "app_lifecycle", "foreground"),
        .init(.lifecycle, .inactive, .background, "app_lifecycle", "background"),
        .init(.lifecycle, .inactive, .terminated, "app_lifecycle", "terminated"),
        .init(.pairing, .advertisingPairing, nil, "pairing", "advertising"),
        .init(.pairing, .waitingForPairingCode, nil, "pairing", "waiting_for_code"),
        .init(.pairing, .savingPairing, nil, "pairing", "saving"),
        .init(.pairing, .pairingComplete, nil, "pairing", "complete"),
        .init(.connection, .locating, nil, "connection", "locating"),
        .init(.connection, .verifyingPairing, nil, "connection", "verifying_pairing"),
        .init(.connection, .openingTunnel, nil, "connection", "opening_tunnel"),
        .init(.connection, .discoveringServices, nil, "connection", "discovering_services"),
        .init(
            .connection,
            .preparingDeveloperServices,
            nil,
            "connection",
            "preparing_developer_services"
        ),
        .init(.connection, .startingDisplay, nil, "connection", "starting_display"),
        .init(.connection, .ready, nil, "connection", "ready"),
        .init(.connection, .disconnecting, nil, "connection", "disconnecting"),
        .init(.connection, .disconnected, nil, "connection", "disconnected"),
        .init(.developerServices, .checkingDeveloperServices, nil, "developer_services", "checking"),
        .init(.developerServices, .mountingDeveloperServices, nil, "developer_services", "mounting"),
        .init(
            .developerServices,
            .reconnectingDeveloperServices,
            nil,
            "developer_services",
            "reconnecting"
        ),
        .init(
            .developerServices,
            .verifyingDeveloperServices,
            nil,
            "developer_services",
            "verifying"
        ),
        .init(.developerServices, .ready, nil, "developer_services", "ready"),
        .init(.media, .firstVisual, nil, "media", "first_visual"),
        .init(.media, .startingDisplay, nil, "media", "display_start"),
        .init(.media, .ready, nil, "media", "display_ready"),
        .init(.media, .displayStalled, nil, "media", "display_stalled"),
        .init(.media, .displayStopped, nil, "media", "display_stopped"),
        .init(.media, .decoding, nil, "media", "decoder"),
        .init(.media, .applyingVideoAnswer, nil, "media", "applying_video_answer"),
        .init(
            .media,
            .generatingVideoConfiguration,
            nil,
            "media",
            "generating_video_configuration"
        ),
        .init(.media, .generatingVideoOptions, nil, "media", "generating_video_options"),
        .init(.media, .validatingVideoReceiver, nil, "media", "validating_video_receiver"),
        .init(.media, .creatingVideoReceiver, nil, "media", "creating_video_receiver"),
        .init(.media, .configuringVideoReceiver, nil, "media", "configuring_video_receiver"),
        .init(.media, .startingVideoReceiver, nil, "media", "starting_video_receiver"),
        .init(.input, .openingInputChannel, nil, "input", "channel_open"),
        .init(.input, .sendingInput, nil, "input", "send"),
        .init(.input, .releasingInput, nil, "input", "release_all"),
        .init(.input, .closingInputChannel, nil, "input", "channel_closed")
    ]

    @Test func mapsEveryClosedFailureCodeExactly() throws {
        let expected = [
            "CANCELLED",
            "CONNECTION_LOST",
            "PAIRING_STATE_CORRUPT",
            "DECODER_FAILED",
            "DEVELOPER_IMAGE_INCOMPATIBLE",
            "DEVELOPER_IMAGE_UNAVAILABLE",
            "DEVELOPER_MODE_DISABLED",
            "DEVICE_BUSY",
            "DEVICE_LOCKED",
            "DEVICE_OFFLINE",
            "PAIRING_CODE_REJECTED",
            "INPUT_CHANNEL_FAILED",
            "INTERNAL_ERROR",
            "LOCAL_NETWORK_DENIED",
            "MALFORMED_ADVERTISEMENT",
            "MEDIA_STALLED",
            "NEEDS_PAIRING",
            "PAIRING_REJECTED",
            "PAIRING_TIMEOUT",
            "PEER_AUTH_FAILED",
            "INTERNAL_ERROR",
            "TUNNEL_FAILED",
            "SERVICE_DISCOVERY_FAILED",
            "TUNNEL_FAILED",
            "UNSUPPORTED_PROTOCOL_VERSION",
            "INTERNAL_ERROR"
        ]
        let events = DiagnosticFailureCode.allCases.enumerated().map { offset, failureCode in
            DiagnosticEvent(
                sequence: UInt64(offset),
                timestamp: now,
                level: .error,
                category: .connection,
                stage: .openingTunnel,
                kind: .operationFailed,
                fields: DiagnosticFields(
                    outcome: .failed,
                    failureCode: failureCode
                )
            )
        }

        try expectNoDifference(
            encodedEvents(events).compactMap {
                $0["error_code"] as? String
            },
            expected
        )
    }

    @Test func mapsEveryOutcomeAndRetryabilityExactly() throws {
        let outcomes: [OutcomeMapping] = [
            .init(.cancelled, .stateChanged, "cancelled"),
            .init(.deferred, .stateChanged, "started"),
            .init(.dropped, .stateChanged, "failed"),
            .init(.failed, .stateChanged, "failed"),
            .init(.started, .stateChanged, "started"),
            .init(.succeeded, .stateChanged, "succeeded"),
            .init(nil, .operationFailed, "failed"),
            .init(nil, .operationSucceeded, "succeeded"),
            .init(nil, .stateChanged, "started")
        ]
        let retryabilities: [(DiagnosticRetryability, Bool)] = [
            (.afterRemedy, true),
            (.automatic, true),
            (.never, false),
            (.userInitiated, true)
        ]
        var events = outcomes.enumerated().map { offset, mapping in
            DiagnosticEvent(
                sequence: UInt64(offset),
                timestamp: now,
                level: .info,
                category: .connection,
                stage: .ready,
                kind: mapping.kind,
                fields: DiagnosticFields(outcome: mapping.outcome)
            )
        }
        events += retryabilities.enumerated().map { offset, mapping in
            DiagnosticEvent(
                sequence: UInt64(outcomes.count + offset),
                timestamp: now,
                level: .info,
                category: .connection,
                stage: .ready,
                kind: .stateChanged,
                fields: DiagnosticFields(
                    outcome: .started,
                    retryability: mapping.0
                )
            )
        }

        let wireEvents = try encodedEvents(events)
        expectNoDifference(
            wireEvents.prefix(outcomes.count).compactMap {
                $0["outcome"] as? String
            },
            outcomes.map(\.wireOutcome)
        )
        expectNoDifference(
            wireEvents.suffix(retryabilities.count).compactMap {
                $0["retryable"] as? Bool
            },
            retryabilities.map(\.1)
        )
    }

    @Test func emitsOnlyFieldsPermittedForEachCategory() throws {
        let events = [
            DiagnosticEvent(
                sequence: 0,
                timestamp: now,
                level: .info,
                category: .lifecycle,
                stage: .inactive,
                kind: .stateChanged,
                fields: DiagnosticFields(
                    durationMilliseconds: 100,
                    outcome: .failed,
                    failureCode: .internalError,
                    lifecycleState: .foreground
                )
            ),
            DiagnosticEvent(
                sequence: 1,
                timestamp: now,
                level: .info,
                category: .media,
                stage: .decoding,
                kind: .operationSucceeded,
                fields: DiagnosticFields(
                    durationMilliseconds: 101,
                    frameAgeMilliseconds: 102,
                    framesPerSecondMilli: 60000,
                    droppedFrameCount: 3,
                    outcome: .succeeded,
                    failureCode: .decoderFailed,
                    retryability: .automatic,
                    mediaCodec: .hevc,
                    inputKind: .keyboard
                )
            ),
            DiagnosticEvent(
                sequence: 2,
                timestamp: now,
                level: .info,
                category: .input,
                stage: .sendingInput,
                kind: .operationSucceeded,
                fields: DiagnosticFields(
                    durationMilliseconds: 103,
                    frameAgeMilliseconds: 104,
                    outcome: .succeeded,
                    failureCode: .inputChannelFailed,
                    retryability: .automatic,
                    mediaCodec: .h264,
                    inputKind: .touch
                )
            )
        ]

        let wireEvents = try encodedEvents(events)
        expectNoDifference(
            Set(wireEvents[0].keys),
            ["category", "occurred_at", "phase", "sequence"]
        )
        expectNoDifference(wireEvents[1]["codec"] as? String, "hevc")
        expectNoDifference(
            wireEvents[1]["frames_per_second_milli"] as? Int,
            60000
        )
        #expect(wireEvents[1]["kind"] == nil)
        #expect(wireEvents[1]["retryable"] == nil)
        expectNoDifference(wireEvents[2]["kind"] as? String, "touch")
        #expect(wireEvents[2]["codec"] == nil)
        #expect(wireEvents[2]["frame_age_ms"] == nil)
        #expect(wireEvents[2]["retryable"] == nil)
    }

    private func encodedEvents(
        _ events: [DiagnosticEvent]
    ) throws -> [[String: Any]] {
        let envelope = try #require(
            DiagnosticWireBatchEncoder(context: Self.context())
                .envelopes(
                    from: DiagnosticSnapshot(events: events),
                    now: now
                )
                .first
        )
        return try encodedEvents(in: envelope)
    }

    private func encodedEvents(
        in envelope: DiagnosticWireEnvelope
    ) throws -> [[String: Any]] {
        let object = try #require(
            JSONSerialization.jsonObject(
                with: envelope.canonicalJSON()
            ) as? [String: Any]
        )
        return try #require(object["events"] as? [[String: Any]])
    }

    private static func context() throws -> DiagnosticWireContext {
        try DiagnosticWireContext(
            installationID: #require(
                UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            ),
            sessionID: #require(
                UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            ),
            appVersion: "1.0.0",
            buildNumber: "42"
        )
    }
}

struct DiagnosticWireBatchingTests {
    private let now = Date(timeIntervalSince1970: 1_753_207_200)

    @Test func filtersInternalEventsAndUsesStablePerChunkIdentifiers() throws {
        let safeEvents = (2 ... 202).map { sequence in
            DiagnosticEvent(
                sequence: UInt64(sequence),
                timestamp: now,
                level: .info,
                category: .connection,
                stage: .ready,
                kind: .operationSucceeded
            )
        }
        let snapshot = DiagnosticSnapshot(
            events: [
                DiagnosticEvent(
                    sequence: 0,
                    timestamp: now,
                    level: .info,
                    category: .persistence,
                    stage: .ready,
                    kind: .stateChanged
                ),
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now,
                    level: .info,
                    category: .flush,
                    stage: .ready,
                    kind: .stateChanged
                )
            ] + safeEvents
        )
        let encoder = try DiagnosticWireBatchEncoder(context: Self.context())

        let first = try encoder.envelopes(from: snapshot, now: now)
        let replay = try encoder.envelopes(from: snapshot, now: now)

        expectNoDifference(first.map(\.batchID), replay.map(\.batchID))
        try expectNoDifference(
            first.map { try encodedEvents(in: $0).count },
            [100, 100, 1]
        )
        #expect(Set(first.map(\.batchID)).count == 3)
    }

    @Test func dropsExpiredEventsWithoutChangingTheRemainingOrder() throws {
        let encoder = try DiagnosticWireBatchEncoder(context: Self.context())
        let snapshot = DiagnosticSnapshot(
            events: [
                eventWithSequence(
                    1,
                    timestamp: now.addingTimeInterval(
                        -(7 * 24 * 60 * 60) - 0.001
                    )
                ),
                eventWithSequence(
                    2,
                    timestamp: now.addingTimeInterval(-7 * 24 * 60 * 60)
                ),
                eventWithSequence(3)
            ]
        )

        let envelopes = try encoder.envelopes(from: snapshot, now: now)

        let envelope = try #require(envelopes.first)
        expectNoDifference(envelopes.count, 1)
        try expectNoDifference(
            encodedEvents(in: envelope).compactMap {
                $0["sequence"] as? Int
            },
            [2, 3]
        )
    }

    @Test func anEntirelyExpiredSnapshotProducesNoUploadEnvelope() throws {
        let encoder = try DiagnosticWireBatchEncoder(context: Self.context())
        let snapshot = DiagnosticSnapshot(
            events: [
                eventWithSequence(
                    1,
                    timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60)
                )
            ]
        )

        #expect(
            try encoder.envelopes(from: snapshot, now: now).isEmpty
        )
    }

    @Test func rejectsInvalidFutureTimelinesFieldsAndCompositionMetadata() throws {
        let encoder = try DiagnosticWireBatchEncoder(context: Self.context())
        let event = DiagnosticEvent(
            sequence: 1,
            timestamp: now,
            level: .info,
            category: .connection,
            stage: .ready,
            kind: .stateChanged,
            fields: DiagnosticFields(attempt: 51)
        )

        #expect(throws: DiagnosticUploadFailure.invalidPayload) {
            try encoder.envelopes(
                from: DiagnosticSnapshot(events: [event]),
                now: now
            )
        }
        #expect(throws: DiagnosticUploadFailure.invalidPayload) {
            try encoder.envelopes(
                from: DiagnosticSnapshot(
                    events: [
                        eventWithSequence(2),
                        eventWithSequence(1)
                    ]
                ),
                now: now
            )
        }
        #expect(throws: DiagnosticUploadFailure.invalidPayload) {
            try encoder.envelopes(
                from: DiagnosticSnapshot(
                    events: [
                        eventWithSequence(
                            1,
                            timestamp: now.addingTimeInterval(5 * 60 + 0.001)
                        )
                    ]
                ),
                now: now
            )
        }
        #expect(throws: DiagnosticUploadFailure.invalidConfiguration) {
            try DiagnosticWireContext(
                installationID: #require(
                    UUID(uuidString: "bbbbbbbb-bbbb-1bbb-8bbb-bbbbbbbbbbbb")
                ),
                sessionID: #require(
                    UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
                ),
                appVersion: "1",
                buildNumber: "not-digits"
            )
        }
    }

    private func encodedEvents(
        in envelope: DiagnosticWireEnvelope
    ) throws -> [[String: Any]] {
        let object = try #require(
            JSONSerialization.jsonObject(
                with: envelope.canonicalJSON()
            ) as? [String: Any]
        )
        return try #require(object["events"] as? [[String: Any]])
    }

    private func eventWithSequence(
        _ sequence: UInt64,
        timestamp: Date? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            sequence: sequence,
            timestamp: timestamp ?? now,
            level: .info,
            category: .connection,
            stage: .ready,
            kind: .stateChanged
        )
    }

    private static func context() throws -> DiagnosticWireContext {
        try DiagnosticWireContext(
            installationID: #require(
                UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            ),
            sessionID: #require(
                UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            ),
            appVersion: "1.0.0",
            buildNumber: "42"
        )
    }
}
