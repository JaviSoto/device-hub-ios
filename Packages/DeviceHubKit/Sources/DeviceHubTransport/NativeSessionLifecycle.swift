import DeviceHubCore
import Foundation

/// Ordered event copied from the native callback dispatcher.
public enum NativeSessionEvent:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case authenticated
    case cancelled
    case completed
    /// Authoritative target geometry retained by the transport shell.
    case displayGeometry(NativeDisplayGeometry)
    /// AVConference rendered its first decoded frame for this generation.
    ///
    /// This is a presentation activation signal only. It carries no frame
    /// metadata and must never authorize input or refresh stream freshness.
    case displayFirstFrame
    case failed(NativeSessionFailure)
    /// The authenticated remote HID service is ready for ordered input.
    case inputReady
    case pairingCode(PairingCode)
    case pairingListenerReady(port: UInt16)
    case pairRecordCommitted(
        requestID: NativePersistenceRequestID,
        peer: NativeVerifiedPeer
    )
    case pairRecordProvisional(
        requestID: NativePersistenceRequestID,
        peer: NativeVerifiedPeer
    )
    case phaseChanged(NativeConnectionPhase)
    case rsdReady(NativeRSDMetadata)
    case screenshot(NativeScreenshot)
    case started

    public var description: String {
        let kind = switch self {
        case .authenticated:
            "authenticated"
        case .cancelled:
            "cancelled"
        case .completed:
            "completed"
        case .displayGeometry:
            "display-geometry"
        case .displayFirstFrame:
            "display-first-frame"
        case .failed:
            "failed"
        case .inputReady:
            "input-ready"
        case .pairingCode:
            "pairing-code"
        case .pairingListenerReady:
            "pairing-listener-ready"
        case .pairRecordCommitted:
            "pair-record-committed"
        case .pairRecordProvisional:
            "pair-record-provisional"
        case .phaseChanged:
            "phase-changed"
        case .rsdReady:
            "rsd-ready"
        case .screenshot:
            "screenshot"
        case .started:
            "started"
        }
        return "<redacted-native-session-event \(kind)>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["event": description],
            displayStyle: .enum
        )
    }
}

/// One uniquely owned native session with explicit teardown.
///
/// `cancel()` must return only after callbacks can no longer begin and native
/// resources have been released. Implementations may emit only
/// ``NativeSessionFailure`` through `events` and the throwing operations.
public struct NativeSession: Sendable {
    public let events: AsyncThrowingStream<NativeSessionEvent, Error>
    /// Bounded compressed-media stream for live-control sessions.
    ///
    /// Pairing and screenshot-only sessions leave this `nil`. Access units are
    /// never decoded-frame or input-authorization evidence.
    public let videoEvents: NativeVideoEventStream?

    private let cancelOperation:
        @Sendable () async throws(NativeSessionFailure) -> Void
    private let completePersistenceOperation:
        @Sendable (
            NativePersistenceRequestID,
            NativePersistenceOutcome
        ) async throws(NativeSessionFailure) -> Void
    private let sendOperation:
        @Sendable (DeviceCommand) async throws(NativeSessionFailure) -> Void
    private let startOperation:
        @Sendable () async throws(NativeSessionFailure) -> Void

    public init(
        events: AsyncThrowingStream<NativeSessionEvent, Error>,
        videoEvents: NativeVideoEventStream? = nil,
        start:
        @escaping @Sendable () async throws(NativeSessionFailure) -> Void,
        completePersistence:
        @escaping @Sendable (
            NativePersistenceRequestID,
            NativePersistenceOutcome
        ) async throws(NativeSessionFailure) -> Void,
        send:
        @escaping @Sendable (DeviceCommand) async throws(NativeSessionFailure)
            -> Void,
        cancel:
        @escaping @Sendable () async throws(NativeSessionFailure) -> Void
    ) {
        cancelOperation = cancel
        completePersistenceOperation = completePersistence
        self.events = events
        self.videoEvents = videoEvents
        sendOperation = send
        startOperation = start
    }

    public func start() async throws(NativeSessionFailure) {
        try await startOperation()
    }

    public func completePersistence(
        _ requestID: NativePersistenceRequestID,
        outcome: NativePersistenceOutcome
    ) async throws(NativeSessionFailure) {
        try await completePersistenceOperation(requestID, outcome)
    }

    public func send(
        _ command: DeviceCommand
    ) async throws(NativeSessionFailure) {
        try await sendOperation(command)
    }

    public func cancel() async throws(NativeSessionFailure) {
        try await cancelOperation()
    }
}

/// Artifact-independent factory installed by the Xcode-only live target.
///
/// The Swift package owns all feature, persistence, Bonjour, and lifecycle
/// behavior. The adapter owns only C value conversion and native handles.
public struct NativeSessionClient: Sendable {
    public let capabilities: NativeSessionCapabilities

    private let makePairingSessionOperation:
        @Sendable (NativePairingSessionRequest) async
        throws(NativeSessionFailure) -> NativeSession
    private let makeRemoteSessionOperation:
        @Sendable (NativeRemoteSessionRequest) async
        throws(NativeSessionFailure) -> NativeSession
    private let verifyRemotePairingOperation:
        @Sendable (NativeRemoteSessionRequest) async
        throws(NativeSessionFailure) -> Void

    public init(
        capabilities: NativeSessionCapabilities,
        makePairingSession:
        @escaping @Sendable (NativePairingSessionRequest) async
            throws(NativeSessionFailure) -> NativeSession,
        makeRemoteSession:
        @escaping @Sendable (NativeRemoteSessionRequest) async
            throws(NativeSessionFailure) -> NativeSession,
        verifyRemotePairing:
        @escaping @Sendable (NativeRemoteSessionRequest) async
            throws(NativeSessionFailure) -> Void = { _ in
                throw NativeSessionFailure(
                    code: "invalid_state",
                    stage: "pair_verify",
                    retryable: false
                )
            }
    ) {
        self.capabilities = capabilities
        makePairingSessionOperation = makePairingSession
        makeRemoteSessionOperation = makeRemoteSession
        verifyRemotePairingOperation = verifyRemotePairing
    }

    public func makePairingSession(
        _ request: NativePairingSessionRequest
    ) async throws(NativeSessionFailure) -> NativeSession {
        try await makePairingSessionOperation(request)
    }

    public func makeRemoteSession(
        _ request: NativeRemoteSessionRequest
    ) async throws(NativeSessionFailure) -> NativeSession {
        try await makeRemoteSessionOperation(request)
    }

    /// Authenticates one validated candidate without opening RSD, media, or
    /// input services.
    public func verifyRemotePairing(
        _ request: NativeRemoteSessionRequest
    ) async throws(NativeSessionFailure) {
        guard capabilities.contains(.pairVerifyDiscovery) else {
            throw NativeSessionFailure(
                code: "invalid_state",
                stage: "pair_verify",
                retryable: false
            )
        }
        try await verifyRemotePairingOperation(request)
    }
}
