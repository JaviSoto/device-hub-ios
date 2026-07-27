import CryptoKit
import Foundation

/// Translates the local redaction-safe event buffer into server schema v1
/// envelopes of no more than 100 events.
public struct DiagnosticWireBatchEncoder: Sendable {
    public let context: DiagnosticWireContext

    public init(context: DiagnosticWireContext) {
        self.context = context
    }

    public func envelopes(
        from snapshot: DiagnosticSnapshot,
        now: Date
    ) throws(DiagnosticUploadFailure) -> [DiagnosticWireEnvelope] {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw .invalidPayload
        }

        var contextualEvents: [
            (context: DiagnosticWireContext, events: [DiagnosticWireEvent])
        ] = []
        var previousSequence: UInt64?
        let expirationThreshold = now.addingTimeInterval(
            -DiagnosticSnapshot.maximumUploadAge
        )
        for segment in snapshot.resolvedSegments(
            fallbackContext: context
        ) {
            var segmentEvents: [DiagnosticWireEvent] = []
            for localEvent in segment.events {
                guard let event = try DiagnosticWireEvent(localEvent) else {
                    continue
                }
                guard
                    event.sequence <= 1_000_000_000,
                    event.occurredAt <= now.addingTimeInterval(5 * 60),
                    previousSequence.map({ event.sequence > $0 }) ?? true
                else {
                    throw .invalidPayload
                }
                previousSequence = event.sequence
                guard event.occurredAt >= expirationThreshold else {
                    continue
                }
                segmentEvents.append(event)
            }
            if !segmentEvents.isEmpty {
                contextualEvents.append(
                    (context: segment.context, events: segmentEvents)
                )
            }
        }

        var envelopes: [DiagnosticWireEnvelope] = []
        for contextualEvent in contextualEvents {
            var startIndex = 0
            while startIndex < contextualEvent.events.count {
                let endIndex = min(
                    startIndex + 100,
                    contextualEvent.events.count
                )
                let chunk = Array(
                    contextualEvent.events[startIndex ..< endIndex]
                )
                guard let sentAt = chunk.map(\.occurredAt).max() else {
                    throw .invalidPayload
                }
                let draft = DiagnosticWireEnvelope(
                    batchID: Self.zeroUUID,
                    context: contextualEvent.context,
                    sentAt: sentAt,
                    events: chunk
                )
                let batchID = try Self.deterministicBatchID(
                    for: draft.canonicalJSON()
                )
                envelopes.append(
                    DiagnosticWireEnvelope(
                        batchID: batchID,
                        context: contextualEvent.context,
                        sentAt: sentAt,
                        events: chunk
                    )
                )
                startIndex = endIndex
            }
        }
        return envelopes
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    /// Produces an RFC 9562 version-8 UUID from the complete canonical draft.
    /// Identical envelope content therefore reuses the same server batch key.
    private static func deterministicBatchID(
        for canonicalDraft: Data
    ) throws(DiagnosticUploadFailure) -> UUID {
        let digest = SHA256.hash(data: canonicalDraft)
        var bytes = Array(digest.prefix(16))
        guard bytes.count == 16 else {
            throw .invalidPayload
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0],
                bytes[1],
                bytes[2],
                bytes[3],
                bytes[4],
                bytes[5],
                bytes[6],
                bytes[7],
                bytes[8],
                bytes[9],
                bytes[10],
                bytes[11],
                bytes[12],
                bytes[13],
                bytes[14],
                bytes[15]
            )
        )
    }
}

/// One complete server schema v1 request body.
public struct DiagnosticWireEnvelope: Encodable, Sendable {
    public let batchID: UUID

    let context: DiagnosticWireContext
    let sentAt: Date
    let events: [DiagnosticWireEvent]

    private enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case batchID = "batch_id"
        case buildNumber = "build_number"
        case events
        case installationID = "installation_id"
        case schemaVersion = "schema_version"
        case sentAt = "sent_at"
        case sessionID = "session_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context.appVersion, forKey: .appVersion)
        try container.encode(batchID.uuidString.lowercased(), forKey: .batchID)
        try container.encode(context.buildNumber, forKey: .buildNumber)
        try container.encode(events, forKey: .events)
        try container.encode(
            context.installationID.uuidString.lowercased(),
            forKey: .installationID
        )
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(
            context.sessionID.uuidString.lowercased(),
            forKey: .sessionID
        )
    }

    /// Returns canonical UTF-8 JSON compatible with the server's schema v1
    /// hashing and storage representation.
    public func canonicalJSON() throws(DiagnosticUploadFailure) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestamp(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw .invalidPayload
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date).replacingOccurrences(
            of: ".000Z",
            with: "Z"
        )
    }
}

struct DiagnosticWireEvent: Encodable, Sendable {
    let category: Category
    let occurredAt: Date
    let sequence: UInt64
    let phase: Phase
    let outcome: Outcome?
    let durationMilliseconds: UInt64?
    let attempt: UInt16?
    let errorCode: ErrorCode?
    let retryable: Bool?
    let codec: DiagnosticMediaCodec?
    let frameAgeMilliseconds: UInt64?
    let framesPerSecondMilli: UInt32?
    let droppedFrames: UInt32?
    let inputKind: DiagnosticInputKind?

    enum Category: String, Encodable, Sendable {
        case appLifecycle = "app_lifecycle"
        case connection
        case developerServices = "developer_services"
        case input
        case media
        case pairing
    }

    enum Phase: String, Encodable, Sendable {
        case advertising
        case applyingVideoAnswer = "applying_video_answer"
        case background
        case channelClosed = "channel_closed"
        case channelOpen = "channel_open"
        case checking
        case complete
        case decoder
        case disconnecting
        case disconnected
        case discoveringServices = "discovering_services"
        case displayReady = "display_ready"
        case displayStalled = "display_stalled"
        case displayStart = "display_start"
        case displayStopped = "display_stopped"
        case configuringVideoReceiver = "configuring_video_receiver"
        case creatingVideoReceiver = "creating_video_receiver"
        case firstVisual = "first_visual"
        case foreground
        case generatingVideoConfiguration = "generating_video_configuration"
        case generatingVideoOptions = "generating_video_options"
        case launched
        case locating
        case mounting
        case openingTunnel = "opening_tunnel"
        case preparingDeveloperServices = "preparing_developer_services"
        case ready
        case reconnecting
        case releaseAll = "release_all"
        case saving
        case send
        case startingDisplay = "starting_display"
        case startingVideoReceiver = "starting_video_receiver"
        case terminated
        case validatingVideoReceiver = "validating_video_receiver"
        case verifying
        case verifyingPairing = "verifying_pairing"
        case waitingForCode = "waiting_for_code"
    }

    enum Outcome: String, Encodable, Sendable {
        case cancelled
        case failed
        case started
        case succeeded
    }

    enum ErrorCode: String, Encodable, Sendable {
        case cancelled = "CANCELLED"
        case connectionLost = "CONNECTION_LOST"
        case decoderFailed = "DECODER_FAILED"
        case developerImageIncompatible = "DEVELOPER_IMAGE_INCOMPATIBLE"
        case developerImageUnavailable = "DEVELOPER_IMAGE_UNAVAILABLE"
        case developerModeDisabled = "DEVELOPER_MODE_DISABLED"
        case deviceBusy = "DEVICE_BUSY"
        case deviceLocked = "DEVICE_LOCKED"
        case deviceOffline = "DEVICE_OFFLINE"
        case inputChannelFailed = "INPUT_CHANNEL_FAILED"
        case internalError = "INTERNAL_ERROR"
        case localNetworkDenied = "LOCAL_NETWORK_DENIED"
        case malformedAdvertisement = "MALFORMED_ADVERTISEMENT"
        case mediaStalled = "MEDIA_STALLED"
        case needsPairing = "NEEDS_PAIRING"
        case pairingCodeRejected = "PAIRING_CODE_REJECTED"
        case pairingRejected = "PAIRING_REJECTED"
        case pairingStateCorrupt = "PAIRING_STATE_CORRUPT"
        case pairingTimeout = "PAIRING_TIMEOUT"
        case peerAuthenticationFailed = "PEER_AUTH_FAILED"
        case serviceDiscoveryFailed = "SERVICE_DISCOVERY_FAILED"
        case tunnelFailed = "TUNNEL_FAILED"
        case unsupportedProtocolVersion = "UNSUPPORTED_PROTOCOL_VERSION"
    }

    private enum CodingKeys: String, CodingKey {
        case attempt
        case category
        case codec
        case droppedFrames = "dropped_frames"
        case durationMilliseconds = "duration_ms"
        case errorCode = "error_code"
        case frameAgeMilliseconds = "frame_age_ms"
        case framesPerSecondMilli = "frames_per_second_milli"
        case inputKind = "kind"
        case occurredAt = "occurred_at"
        case outcome
        case phase
        case retryable
        case sequence
    }

    init?(_ event: DiagnosticEvent) throws(DiagnosticUploadFailure) {
        if event.category == .persistence || event.category == .flush {
            return nil
        }

        guard
            event.fields.durationMilliseconds.map({ $0 <= 600_000 }) ?? true,
            event.fields.frameAgeMilliseconds.map({ $0 <= 600_000 }) ?? true,
            event.fields.framesPerSecondMilli.map({ $0 <= 240_000 }) ?? true,
            event.fields.droppedFrameCount.map({ $0 <= 1_000_000 }) ?? true,
            event.fields.attempt.map({ (1 ... 50).contains($0) }) ?? true
        else {
            throw .invalidPayload
        }

        let mapping = try Self.categoryAndPhase(for: event)
        category = mapping.category
        phase = mapping.phase
        occurredAt = event.timestamp
        sequence = event.sequence
        outcome = category == .appLifecycle ? nil : Self.outcome(for: event)
        durationMilliseconds =
            category == .appLifecycle
                ? nil : event.fields.durationMilliseconds
        attempt = category == .connection ? event.fields.attempt : nil
        errorCode =
            category == .appLifecycle
                ? nil : event.fields.failureCode.map(Self.errorCode)
        retryable = Self.retryable(for: event)
        codec = category == .media ? event.fields.mediaCodec : nil
        frameAgeMilliseconds =
            category == .media ? event.fields.frameAgeMilliseconds : nil
        framesPerSecondMilli =
            category == .media ? event.fields.framesPerSecondMilli : nil
        droppedFrames =
            category == .media ? event.fields.droppedFrameCount : nil
        inputKind = category == .input ? event.fields.inputKind : nil
    }

    private static func categoryAndPhase(
        for event: DiagnosticEvent
    ) throws(DiagnosticUploadFailure) -> (category: Category, phase: Phase) {
        switch event.category {
        case .lifecycle:
            return try (
                .appLifecycle,
                lifecyclePhase(event.fields.lifecycleState)
            )

        case .pairing:
            return try (.pairing, pairingPhase(event.stage))

        case .connection, .discovery, .tunnel:
            return try (.connection, connectionPhase(event.stage))

        case .developerServices:
            return try (
                .developerServices,
                developerServicesPhase(event.stage)
            )

        case .media:
            return try (.media, mediaPhase(event.stage))

        case .input:
            return try (.input, inputPhase(event.stage))

        case .flush, .persistence:
            throw .invalidPayload
        }
    }

    private static func lifecyclePhase(
        _ state: DiagnosticLifecycleState?
    ) throws(DiagnosticUploadFailure) -> Phase {
        switch state {
        case .launched:
            .launched
        case .foreground:
            .foreground
        case .background:
            .background
        case .terminated:
            .terminated
        case .inactive, nil:
            throw .invalidPayload
        }
    }

    private static func pairingPhase(
        _ stage: DiagnosticStage
    ) throws(DiagnosticUploadFailure) -> Phase {
        switch stage {
        case .advertisingPairing:
            .advertising
        case .pairing, .waitingForPairingCode:
            .waitingForCode
        case .savingPairing:
            .saving
        case .pairingComplete, .ready:
            .complete
        default:
            throw .invalidPayload
        }
    }

    private static func connectionPhase(
        _ stage: DiagnosticStage
    ) throws(DiagnosticUploadFailure) -> Phase {
        switch stage {
        case .locating:
            .locating
        case .verifyingPairing:
            .verifyingPairing
        case .openingTunnel:
            .openingTunnel
        case .discoveringServices:
            .discoveringServices
        case .preparingDeveloperServices:
            .preparingDeveloperServices
        case .startingDisplay:
            .startingDisplay
        case .ready:
            .ready
        case .disconnecting:
            .disconnecting
        case .disconnected:
            .disconnected
        default:
            throw .invalidPayload
        }
    }

    private static func developerServicesPhase(
        _ stage: DiagnosticStage
    ) throws(DiagnosticUploadFailure) -> Phase {
        switch stage {
        case .checkingDeveloperServices, .preparingDeveloperServices:
            .checking
        case .mountingDeveloperServices:
            .mounting
        case .reconnectingDeveloperServices:
            .reconnecting
        case .verifyingDeveloperServices:
            .verifying
        case .ready:
            .ready
        default:
            throw .invalidPayload
        }
    }

    private static func mediaPhase(
        _ stage: DiagnosticStage
    ) throws(DiagnosticUploadFailure) -> Phase {
        switch stage {
        case .capturingScreenshot, .firstVisual:
            .firstVisual
        case .startingDisplay:
            .displayStart
        case .ready:
            .displayReady
        case .displayStalled:
            .displayStalled
        case .displayStopped:
            .displayStopped
        case .decoding:
            .decoder
        case .applyingVideoAnswer:
            .applyingVideoAnswer
        case .generatingVideoConfiguration:
            .generatingVideoConfiguration
        case .generatingVideoOptions:
            .generatingVideoOptions
        case .validatingVideoReceiver:
            .validatingVideoReceiver
        case .creatingVideoReceiver:
            .creatingVideoReceiver
        case .configuringVideoReceiver:
            .configuringVideoReceiver
        case .startingVideoReceiver:
            .startingVideoReceiver
        default:
            throw .invalidPayload
        }
    }

    private static func inputPhase(
        _ stage: DiagnosticStage
    ) throws(DiagnosticUploadFailure) -> Phase {
        switch stage {
        case .openingInputChannel:
            .channelOpen
        case .sendingInput:
            .send
        case .releasingInput:
            .releaseAll
        case .closingInputChannel:
            .channelClosed
        default:
            throw .invalidPayload
        }
    }

    private static func outcome(for event: DiagnosticEvent) -> Outcome {
        switch event.fields.outcome {
        case .cancelled:
            .cancelled
        case .failed, .dropped:
            .failed
        case .started, .deferred:
            .started
        case .succeeded:
            .succeeded
        case nil:
            switch event.kind {
            case .operationFailed:
                .failed
            case .operationSucceeded:
                .succeeded
            case .stateChanged:
                .started
            }
        }
    }

    private static func retryable(for event: DiagnosticEvent) -> Bool? {
        guard
            event.category == .pairing
            || event.category == .connection
            || event.category == .discovery
            || event.category == .tunnel
            || event.category == .developerServices,
            let retryability = event.fields.retryability
        else {
            return nil
        }
        switch retryability {
        case .never:
            return false
        case .afterRemedy, .automatic, .userInitiated:
            return true
        }
    }

    private static func errorCode(
        _ error: DiagnosticFailureCode
    ) -> ErrorCode {
        guard let code = errorCodes[error] else {
            preconditionFailure(
                "Every closed diagnostics failure must have a wire code."
            )
        }
        return code
    }

    private static let errorCodes: [
        DiagnosticFailureCode: ErrorCode
    ] = [
        .cancelled: .cancelled,
        .connectionLost: .connectionLost,
        .corruptPairingRecord: .pairingStateCorrupt,
        .decoderFailed: .decoderFailed,
        .developerImageIncompatible: .developerImageIncompatible,
        .developerImageUnavailable: .developerImageUnavailable,
        .developerModeDisabled: .developerModeDisabled,
        .deviceBusy: .deviceBusy,
        .deviceLocked: .deviceLocked,
        .deviceOffline: .deviceOffline,
        .incorrectPairingCode: .pairingCodeRejected,
        .inputChannelFailed: .inputChannelFailed,
        .internalError: .internalError,
        .localNetworkDenied: .localNetworkDenied,
        .malformedAnnouncement: .malformedAdvertisement,
        .mediaStalled: .mediaStalled,
        .needsPairing: .needsPairing,
        .pairingRejected: .pairingRejected,
        .pairingTimedOut: .pairingTimeout,
        .peerAuthenticationFailed: .peerAuthenticationFailed,
        .persistenceFailed: .internalError,
        .secureConnectionFailed: .tunnelFailed,
        .serviceDiscoveryFailed: .serviceDiscoveryFailed,
        .tunnelFailed: .tunnelFailed,
        .unsupportedProtocolVersion: .unsupportedProtocolVersion,
        .uploadFailed: .internalError
    ]
}
