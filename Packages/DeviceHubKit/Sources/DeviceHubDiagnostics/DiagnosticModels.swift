import Foundation

/// The severity assigned to a structured diagnostic event.
public enum DiagnosticLevel: String, Codable, Equatable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

/// The subsystem that emitted a diagnostic event.
public enum DiagnosticCategory: String, Codable, Equatable, Sendable {
    case connection
    case developerServices
    case discovery
    case flush
    case input
    case lifecycle
    case media
    case pairing
    case persistence
    case tunnel
}

/// A safe, user-meaningful phase of the Device Hub connection lifecycle.
///
/// Protocol secrets and low-level endpoint details intentionally have no
/// representation in this type.
public enum DiagnosticStage: String, Codable, Equatable, Sendable {
    case advertisingPairing
    case applyingVideoAnswer
    case capturingScreenshot
    case checkingDeveloperServices
    case closingInputChannel
    case configuringVideoReceiver
    case creatingVideoReceiver
    case decoding
    case discoveringServices
    case disconnecting
    case disconnected
    case displayStalled
    case displayStopped
    case firstVisual
    case generatingVideoConfiguration
    case generatingVideoOptions
    case inactive
    case locating
    case mountingDeveloperServices
    case openingTunnel
    case openingInputChannel
    case pairing
    case pairingComplete
    case preparingDeveloperServices
    case ready
    case reconnectingDeveloperServices
    case releasingInput
    case savingPairing
    case sendingInput
    case startingDisplay
    case startingVideoReceiver
    case validatingVideoReceiver
    case verifyingPairing
    case verifyingDeveloperServices
    case waitingForPairingCode
}

/// A finite event vocabulary that prevents callers from placing arbitrary,
/// potentially sensitive text in diagnostics.
public enum DiagnosticEventKind: String, Codable, Equatable, Sendable {
    case operationFailed
    case operationSucceeded
    case stateChanged
}

/// The bounded set of outcomes a diagnostic operation can report.
public enum DiagnosticOutcome: String, Codable, Equatable, Sendable {
    case cancelled
    case deferred
    case dropped
    case failed
    case started
    case succeeded
}

/// Stable, non-sensitive failure identifiers shared by the app and backend.
public enum DiagnosticFailureCode:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case cancelled
    case connectionLost
    case corruptPairingRecord
    case decoderFailed
    case developerImageIncompatible
    case developerImageUnavailable
    case developerModeDisabled
    case deviceBusy
    case deviceLocked
    case deviceOffline
    case incorrectPairingCode
    case inputChannelFailed
    case internalError
    case localNetworkDenied
    case malformedAnnouncement
    case mediaStalled
    case needsPairing
    case pairingRejected
    case pairingTimedOut
    case peerAuthenticationFailed
    case persistenceFailed
    case secureConnectionFailed
    case serviceDiscoveryFailed
    case tunnelFailed
    case unsupportedProtocolVersion
    case uploadFailed
}

/// Whether and how a failed operation may be attempted again.
public enum DiagnosticRetryability: String, Codable, Equatable, Sendable {
    case afterRemedy
    case automatic
    case never
    case userInitiated
}

/// A coarse transport classification that never includes an endpoint.
public enum DiagnosticTransport: String, Codable, Equatable, Sendable {
    case localNetwork
    case peerToPeerWiFi
    case wired
    case wifi
}

/// An address family without the corresponding raw network address.
public enum DiagnosticAddressFamily: String, Codable, Equatable, Sendable {
    case ipv4
    case ipv6
    case unknown
}

/// The media codec selected for a remote-display session.
public enum DiagnosticMediaCodec: String, Codable, Equatable, Sendable {
    case h264
    case hevc
}

/// The app lifecycle state associated with a diagnostic event.
public enum DiagnosticLifecycleState: String, Codable, Equatable, Sendable {
    case background
    case foreground
    case inactive
    case launched
    case terminated
}

/// A coarse service identifier that excludes ports and protocol payloads.
public enum DiagnosticService: String, Codable, Equatable, Sendable {
    case developerImageMounter
    case humanInterfaceDevice
    case remotePairing
    case remoteServiceDiscovery
    case screenSharing
    case screenshot
    case tunnel
}

/// The aggregate input channel involved in an event, never its content.
public enum DiagnosticInputKind: String, Codable, Equatable, Sendable {
    case button
    case keyboard
    case touch
}

/// A deliberately closed set of aggregate metadata. There is no string or
/// binary value channel, so callers cannot attach PINs, credentials, pairing
/// material, packet bodies, screen contents, or raw network addresses.
public struct DiagnosticFields: Codable, Equatable, Sendable {
    public var attempt: UInt16?
    public var durationMilliseconds: UInt64?
    public var retryAfterMilliseconds: UInt64?
    public var frameAgeMilliseconds: UInt64?
    public var sampleCount: UInt32?
    public var framesPerSecondMilli: UInt32?
    public var droppedFrameCount: UInt32?
    public var deviceSlot: UInt16?
    public var outcome: DiagnosticOutcome?
    public var failureCode: DiagnosticFailureCode?
    public var retryability: DiagnosticRetryability?
    public var transport: DiagnosticTransport?
    public var addressFamily: DiagnosticAddressFamily?
    public var mediaCodec: DiagnosticMediaCodec?
    public var lifecycleState: DiagnosticLifecycleState?
    public var service: DiagnosticService?
    public var inputKind: DiagnosticInputKind?

    public init(
        attempt: UInt16? = nil,
        durationMilliseconds: UInt64? = nil,
        retryAfterMilliseconds: UInt64? = nil,
        frameAgeMilliseconds: UInt64? = nil,
        sampleCount: UInt32? = nil,
        framesPerSecondMilli: UInt32? = nil,
        droppedFrameCount: UInt32? = nil,
        deviceSlot: UInt16? = nil,
        outcome: DiagnosticOutcome? = nil,
        failureCode: DiagnosticFailureCode? = nil,
        retryability: DiagnosticRetryability? = nil,
        transport: DiagnosticTransport? = nil,
        addressFamily: DiagnosticAddressFamily? = nil,
        mediaCodec: DiagnosticMediaCodec? = nil,
        lifecycleState: DiagnosticLifecycleState? = nil,
        service: DiagnosticService? = nil,
        inputKind: DiagnosticInputKind? = nil
    ) {
        self.attempt = attempt
        self.durationMilliseconds = durationMilliseconds
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.frameAgeMilliseconds = frameAgeMilliseconds
        self.sampleCount = sampleCount
        self.framesPerSecondMilli = framesPerSecondMilli
        self.droppedFrameCount = droppedFrameCount
        self.deviceSlot = deviceSlot
        self.outcome = outcome
        self.failureCode = failureCode
        self.retryability = retryability
        self.transport = transport
        self.addressFamily = addressFamily
        self.mediaCodec = mediaCodec
        self.lifecycleState = lifecycleState
        self.service = service
        self.inputKind = inputKind
    }
}

/// One structured, redaction-safe diagnostic event.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var timestamp: Date
    public var level: DiagnosticLevel
    public var category: DiagnosticCategory
    public var stage: DiagnosticStage
    public var kind: DiagnosticEventKind
    public var fields: DiagnosticFields

    public init(
        sequence: UInt64,
        timestamp: Date,
        level: DiagnosticLevel,
        category: DiagnosticCategory,
        stage: DiagnosticStage,
        kind: DiagnosticEventKind,
        fields: DiagnosticFields = DiagnosticFields()
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.stage = stage
        self.kind = kind
        self.fields = fields
    }
}

/// Limits the amount of diagnostic state retained in memory or persisted.
public struct DiagnosticRetentionPolicy: Equatable, Sendable {
    public var maximumEventCount: Int
    public var maximumEncodedByteCount: Int

    public init(maximumEventCount: Int, maximumEncodedByteCount: Int) {
        self.maximumEventCount = maximumEventCount
        self.maximumEncodedByteCount = maximumEncodedByteCount
    }
}

/// Describes the retention work performed while appending an event.
public struct DiagnosticRetentionResult: Equatable, Sendable {
    public var evictedEventCount: Int
    public var droppedIncomingEvent: Bool

    public init(evictedEventCount: Int, droppedIncomingEvent: Bool) {
        self.evictedEventCount = evictedEventCount
        self.droppedIncomingEvent = droppedIncomingEvent
    }
}

/// The observable outcome of recording one event.
public struct DiagnosticRecordResult: Equatable, Sendable {
    public var event: DiagnosticEvent
    public var retention: DiagnosticRetentionResult

    public init(event: DiagnosticEvent, retention: DiagnosticRetentionResult) {
        self.event = event
        self.retention = retention
    }
}

/// The result of a foreground-triggered diagnostics upload.
public enum DiagnosticFlushResult: Equatable, Sendable {
    case discardedExpiredEvents(eventCount: Int)
    case flushed(
        eventCount: Int,
        expiredEventCount: Int,
        encodedByteCount: Int
    )
    case nothingToFlush
}

/// Safe error classifications emitted by a persistence implementation.
public enum DiagnosticPersistenceFailure: Error, Equatable, Sendable {
    case clearingFailed
    case directoryCreationFailed
    case fileSecurityConfigurationFailed
    case invalidFileRetentionPolicy
    case loadingFailed
    case rotationFailed
    case writingFailed
}

/// Safe error classifications emitted by a diagnostics uploader.
public enum DiagnosticUploadFailure: Error, Equatable, Sendable {
    case bodyTooLarge
    case cancelled
    case insecureEndpoint
    case invalidConfiguration
    case invalidPayload
    case rejected(statusCode: Int)
    case responseTooLarge
    case timedOut
    case transportFailed
}

/// A cancellable actor operation, used to retain cancellation context.
public enum DiagnosticOperation: Equatable, Sendable {
    case foregroundFlush
    case recording
    case restoration
}

/// Failures surfaced by the diagnostics subsystem without retaining an
/// underlying error string that could itself contain sensitive data.
public enum DiagnosticError: Error, Equatable, Sendable {
    case cancelled(DiagnosticOperation)
    case decodingFailed
    case encodingFailed
    case invalidRetentionPolicy
    case persistence(DiagnosticPersistenceFailure)
    case sequenceExhausted
    case upload(DiagnosticUploadFailure)
}

/// A versioned local outbox whose contiguous segments retain the exact
/// capture-time upload context needed for stable attribution and replay.
public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion = 2

    /// All retained events in their original append order.
    public var events: [DiagnosticEvent] {
        segments.flatMap(\.events)
    }

    static let maximumUploadAge: TimeInterval = 7 * 24 * 60 * 60

    private(set) var segments: [Segment]

    private enum CodingKeys: String, CodingKey {
        case events
        case schemaVersion
        case segments
    }

    public init(events: [DiagnosticEvent]) {
        segments =
            events.isEmpty
                ? []
                : [Segment(context: nil, events: events)]
    }

    /// Creates a snapshot whose events retain their capture-time upload
    /// attribution across process restarts.
    public init(
        context: DiagnosticWireContext,
        events: [DiagnosticEvent]
    ) {
        segments =
            events.isEmpty
                ? []
                : [Segment(context: context, events: events)]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        switch decodedVersion {
        case 1:
            let events = try container.decode(
                [DiagnosticEvent].self,
                forKey: .events
            )
            segments =
                events.isEmpty
                    ? []
                    : [Segment(context: nil, events: events)]

        case 2:
            segments = try container.decode(
                [Segment].self,
                forKey: .segments
            )
            guard segments.allSatisfy({ !$0.events.isEmpty }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .segments,
                    in: container,
                    debugDescription: "Empty diagnostics segment."
                )
            }

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported diagnostics schema."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(segments, forKey: .segments)
    }

    /// Encodes the snapshot deterministically so retention can enforce the
    /// exact size of the payload that will be persisted.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        do {
            return try encoder.encode(self)
        } catch {
            throw DiagnosticError.encodingFailed
        }
    }

    /// Decodes a persisted snapshot while collapsing decoder implementation
    /// details into a safe diagnostics-domain error.
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        do {
            return try decoder.decode(Self.self, from: data)
        } catch {
            throw DiagnosticError.decodingFailed
        }
    }

    func appending(
        _ event: DiagnosticEvent,
        context: DiagnosticWireContext?
    ) -> Self {
        var copy = self
        if
            let lastIndex = copy.segments.indices.last,
            copy.segments[lastIndex].context == context
        {
            copy.segments[lastIndex].events.append(event)
        } else {
            copy.segments.append(
                Segment(context: context, events: [event])
            )
        }
        return copy
    }

    func droppingFirstEvent() -> Self {
        guard !segments.isEmpty else {
            return self
        }
        var copy = self
        copy.segments[0].events.removeFirst()
        if copy.segments[0].events.isEmpty {
            copy.segments.removeFirst()
        }
        return copy
    }

    func retainingEvents(
        where shouldRetain: (DiagnosticEvent) -> Bool
    ) -> Self {
        var retainedSegments: [Segment] = []
        for segment in segments {
            let events = segment.events.filter(shouldRetain)
            guard !events.isEmpty else {
                continue
            }
            if
                let lastIndex = retainedSegments.indices.last,
                retainedSegments[lastIndex].context == segment.context
            {
                retainedSegments[lastIndex].events.append(
                    contentsOf: events
                )
            } else {
                retainedSegments.append(
                    Segment(context: segment.context, events: events)
                )
            }
        }
        var copy = self
        copy.segments = retainedSegments
        return copy
    }

    func resolvedSegments(
        fallbackContext: DiagnosticWireContext
    ) -> [(context: DiagnosticWireContext, events: [DiagnosticEvent])] {
        segments.map { segment in
            (
                context: segment.context ?? fallbackContext,
                events: segment.events
            )
        }
    }

    struct Segment: Codable, Equatable, Sendable {
        var context: DiagnosticWireContext?
        var events: [DiagnosticEvent]
    }
}
