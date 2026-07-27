import DeviceHubClient
import DeviceHubCore
import DeviceHubTransport
import Foundation

public extension NativeSessionClient {
    /// Builds the artifact-backed native session factory used by the app.
    ///
    /// Construction only validates the linked ABI. It does not read or change
    /// pairing records, credentials, profiles, signing state, or any device.
    @MainActor
    static func deviceHubLive() throws -> Self {
        try DeviceHubNativeSessionFactory(environment: .live).client
    }
}

/// Main-actor composition for per-generation native sessions.
@MainActor
final class DeviceHubNativeSessionFactory {
    private typealias PersistenceOperation =
        @Sendable (
            NativePersistenceRequestID,
            NativePersistenceOutcome
        ) async throws(NativeSessionFailure) -> Void

    /// Describes a native session that uses only the ordered control callback
    /// plane and therefore does not construct a video bridge.
    private enum ControlOnlySessionCreation {
        case pairing(NativePairingSessionRequest)
        case pairVerify(NativeRemoteSessionRequest)

        var generation: SessionGeneration {
            switch self {
            case let .pairing(request):
                request.generation
            case let .pairVerify(request):
                request.generation
            }
        }

        func create(
            using executor: DeviceHubNativeSessionExecutor
        ) async throws(NativeSessionFailure) {
            switch self {
            case let .pairing(request):
                try await executor.createPairing(request)
            case let .pairVerify(request):
                try await executor.createRemote(
                    request,
                    operation: .pairVerify
                )
            }
        }
    }

    struct Environment {
        let functions: DeviceHubNativeFunctionTable
        let makeVideoBridge:
            (SessionGeneration) throws -> NativeVideoEventBridge

        @MainActor
        static let live = Self(
            functions: .live,
            makeVideoBridge: { generation in
                try NativeVideoEventBridge(generation: generation)
            }
        )
    }

    private static let eventBufferCapacity = 64

    private let environment: Environment
    private let nativeCapabilities: NativeSessionCapabilities

    var client: NativeSessionClient {
        let factory = self
        let makePairing:
            @Sendable (NativePairingSessionRequest) async
            throws(NativeSessionFailure) -> NativeSession = { request in
                try await factory.makePairingSession(request)
            }
        let makeRemote:
            @Sendable (NativeRemoteSessionRequest) async
            throws(NativeSessionFailure) -> NativeSession = { request in
                try await factory.makeRemoteSession(request)
            }
        let verifyRemote:
            @Sendable (NativeRemoteSessionRequest) async
            throws(NativeSessionFailure) -> Void = { request in
                try await factory.verifyRemotePairing(request)
            }
        return NativeSessionClient(
            capabilities: nativeCapabilities,
            makePairingSession: makePairing,
            makeRemoteSession: makeRemote,
            verifyRemotePairing: verifyRemote
        )
    }

    init(environment: Environment) throws {
        let rawCapabilities = environment.functions.capabilities()
        _ = try DeviceHubNativeABI(
            version: environment.functions.abiVersion(),
            capabilities: DeviceHubNativeCapabilities(
                rawValue: rawCapabilities
            )
        )
        self.environment = environment
        nativeCapabilities = NativeSessionCapabilities(
            rawValue: rawCapabilities
        )
    }

    private func makePairingSession(
        _ request: NativePairingSessionRequest
    ) async throws(NativeSessionFailure) -> NativeSession {
        try await makeControlOnlySession(.pairing(request))
    }

    private func makeRemoteSession(
        _ request: NativeRemoteSessionRequest
    ) async throws(NativeSessionFailure) -> NativeSession {
        let relay = DeviceHubNativeSessionRelay()
        let videoBridge: NativeVideoEventBridge
        do {
            videoBridge = try environment.makeVideoBridge(
                request.generation
            )
        } catch {
            DeviceHubNativeTrace.emit(
                "remote_construct_failed stage=video_bridge_create"
            )
            throw Self.videoReceiverFailure
        }

        let pipe = makeEventPipe()
        let context = DeviceHubNativeCallbackContext(
            generation: request.generation,
            controlContinuation: pipe.continuation,
            relay: relay,
            videoBridge: videoBridge
        )
        let executor = makeExecutor(
            generation: request.generation,
            context: context,
            relay: relay,
            avConference: nil,
            cleanupSurface: {}
        )
        guard bind(relay, context: context, executor: executor) else {
            try await rollback(
                executor,
                preserving: Self.invalidStateFailure
            )
        }

        do {
            try await executor.createRemote(
                request,
                operation: .controlStream
            )
        } catch let failure {
            DeviceHubNativeTrace.emit(
                "remote_create_failed code=\(failure.code) "
                    + "stage=\(failure.stage)"
            )
            try await rollback(executor, preserving: failure)
        }
        DeviceHubNativeTrace.emit("remote_constructed")
        return makeSession(
            events: pipe.stream,
            videoEvents: videoBridge.events,
            executor: executor
        )
    }

    /// Authenticates one discovery candidate without constructing media, RSD,
    /// or input services and tears the native session down before returning.
    private func verifyRemotePairing(
        _ request: NativeRemoteSessionRequest
    ) async throws(NativeSessionFailure) {
        let session = try await makePairVerifySession(request)
        let verificationResult: Result<Void, NativeSessionFailure>
        do {
            try await session.start()
            try await awaitPairVerification(in: session.events)
            verificationResult = .success(())
        } catch let failure {
            verificationResult = .failure(failure)
        }

        let teardownFailure: NativeSessionFailure?
        do {
            try await session.cancel()
            teardownFailure = nil
        } catch let failure {
            teardownFailure = failure
        }

        switch verificationResult {
        case .success:
            if let teardownFailure {
                throw teardownFailure
            }
        case let .failure(failure):
            throw failure
        }
    }

    private func makePairVerifySession(
        _ request: NativeRemoteSessionRequest
    ) async throws(NativeSessionFailure) -> NativeSession {
        try await makeControlOnlySession(.pairVerify(request))
    }

    /// Builds a control-callback-only native session for operations that do not
    /// own a video callback plane.
    private func makeControlOnlySession(
        _ creation: ControlOnlySessionCreation
    ) async throws(NativeSessionFailure) -> NativeSession {
        let pipe = makeEventPipe()
        let relay = DeviceHubNativeSessionRelay()
        let context = DeviceHubNativeCallbackContext(
            generation: creation.generation,
            controlContinuation: pipe.continuation,
            relay: relay
        )
        let executor = makeExecutor(
            generation: creation.generation,
            context: context,
            relay: relay,
            avConference: nil,
            cleanupSurface: {}
        )
        guard bind(relay, context: context, executor: executor) else {
            try await rollback(
                executor,
                preserving: Self.invalidStateFailure
            )
        }

        do {
            try await creation.create(using: executor)
        } catch {
            try await rollback(executor, preserving: error)
        }
        return makeSession(
            events: pipe.stream,
            videoEvents: nil,
            executor: executor
        )
    }

    private func awaitPairVerification(
        in events: AsyncThrowingStream<NativeSessionEvent, Error>
    ) async throws(NativeSessionFailure) {
        var didAuthenticate = false
        do {
            for try await event in events {
                switch event {
                case .authenticated:
                    didAuthenticate = true

                case .completed:
                    guard didAuthenticate else {
                        throw Self.pairVerificationFailure
                    }
                    return

                case .cancelled,
                     .pairRecordCommitted,
                     .pairRecordProvisional:
                    throw Self.pairVerificationFailure

                case let .failed(failure):
                    throw failure

                case .displayFirstFrame,
                     .displayGeometry,
                     .inputReady,
                     .pairingCode,
                     .pairingListenerReady,
                     .phaseChanged,
                     .rsdReady,
                     .screenshot,
                     .started:
                    continue
                }
            }
        } catch let failure as NativeSessionFailure {
            throw failure
        } catch {
            throw Self.nativeBoundaryFailure
        }
        throw Self.pairVerificationFailure
    }

    private func makeExecutor(
        generation: SessionGeneration,
        context: DeviceHubNativeCallbackContext,
        relay: DeviceHubNativeSessionRelay,
        avConference: DeviceHubAVConferenceSession?,
        cleanupSurface: @escaping @Sendable () async -> Void
    ) -> DeviceHubNativeSessionExecutor {
        DeviceHubNativeSessionExecutor(
            generation: generation,
            functions: environment.functions,
            context: context,
            retainedContext: Unmanaged.passRetained(context),
            relay: relay,
            avConference: avConference,
            cleanupSurface: cleanupSurface
        )
    }

    private func bind(
        _ relay: DeviceHubNativeSessionRelay,
        context: DeviceHubNativeCallbackContext,
        executor: DeviceHubNativeSessionExecutor
    ) -> Bool {
        relay.bind(
            receiverEvent: { [weak context] event in
                context?.handleReceiverEvent(event)
            },
            videoControl: { [weak executor] datagram in
                executor?.enqueueVideoControl(datagram)
            },
            videoNegotiation: { [weak executor] succeeded in
                executor?.enqueueVideoNegotiationResult(
                    succeeded: succeeded
                )
            }
        )
    }

    private func makeEventPipe() -> (
        stream: AsyncThrowingStream<NativeSessionEvent, Error>,
        continuation:
        AsyncThrowingStream<NativeSessionEvent, Error>.Continuation
    ) {
        let pipe = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream(
            bufferingPolicy: .bufferingOldest(Self.eventBufferCapacity)
        )
        return (stream: pipe.stream, continuation: pipe.continuation)
    }

    private func makeSession(
        events: AsyncThrowingStream<NativeSessionEvent, Error>,
        videoEvents: NativeVideoEventStream?,
        executor: DeviceHubNativeSessionExecutor
    ) -> NativeSession {
        let start:
            @Sendable () async throws(NativeSessionFailure) -> Void = {
                try await executor.start()
            }
        let completePersistence: PersistenceOperation = { requestID, outcome in
            try await executor.completePersistence(
                requestID,
                outcome: outcome
            )
        }
        let send:
            @Sendable (DeviceCommand) async
            throws(NativeSessionFailure) -> Void = { command in
                try await executor.send(command)
            }
        let cancel:
            @Sendable () async throws(NativeSessionFailure) -> Void = {
                try await executor.cancel()
            }
        return NativeSession(
            events: events,
            videoEvents: videoEvents,
            start: start,
            completePersistence: completePersistence,
            send: send,
            cancel: cancel
        )
    }

    private func rollback(
        _ executor: DeviceHubNativeSessionExecutor,
        preserving failure: NativeSessionFailure
    ) async throws(NativeSessionFailure) -> Never {
        do {
            try await executor.cancel()
        } catch {
            throw error
        }
        throw failure
    }

    private static var invalidStateFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "invalid_state",
            stage: "session_lifecycle",
            retryable: false
        )
    }

    private static var nativeBoundaryFailure: NativeSessionFailure {
        DeviceHubNativeFailureDecoder.genericFailure
    }

    private static var pairVerificationFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "invalid_state",
            stage: "pair_verify",
            retryable: false
        )
    }

    private static var videoReceiverFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "video_receiver_rejected",
            stage: "video_negotiation",
            retryable: false
        )
    }
}
