import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubMedia
import DeviceHubPersistence
import Foundation
import ImageIO

/// Breaks the construction cycle between a session value and its actor owner.
private actor RemoteSessionControl {
    private weak var operation: RemoteSessionOperation?

    func bind(_ operation: RemoteSessionOperation) {
        self.operation = operation
    }

    func send(_ command: DeviceCommand) async throws {
        guard let operation else {
            throw DeviceHubError.connectionLost
        }
        try await operation.send(command)
    }

    func disconnect() async {
        await operation?.disconnect()
    }
}

actor RemoteSessionOperation {
    typealias Observation = DeviceHubTransportEnvironment.Observation

    nonisolated let deviceSession: DeviceSession

    private let bonjour: RemotePairingBonjourClient
    private let claimedDeviceID: DeviceID
    private let commands: NativeCommandExecutor
    var cleanupTask: Task<NativeSessionFailure?, Never>?
    var decoder: HEVCVideoDecoder?
    var decoderConfiguration: HEVCConfiguration?
    private var didEmitHIDReadiness = false
    private var displayGeometry: NativeDisplayGeometry?
    private let eventContinuation:
        AsyncThrowingStream<SessionUpdate, Error>.Continuation
    let frameContinuation:
        AsyncStream<RemoteDisplayFrame>.Continuation
    let generation: SessionGeneration
    private var nativeSession: NativeSession?
    private let now: @Sendable () -> Date
    private let observe: Observation
    private let persistence: PairingPersistenceClient
    var frameTask: Task<Void, Never>?
    var mediaTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var summary: DeviceSummary

    static func make(
        nativeSession: NativeSession,
        generation: SessionGeneration,
        initialDevice: DeviceSummary,
        claimedDeviceID: DeviceID,
        environment: DeviceHubTransportEnvironment
    ) async -> RemoteSessionOperation {
        let eventPipe = AsyncThrowingStream<
            SessionUpdate,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(64))
        let framePipe = AsyncStream<RemoteDisplayFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let control = RemoteSessionControl()
        let commands = NativeCommandExecutor { command async throws(
            NativeSessionFailure
        ) in
            try await nativeSession.send(command)
        }
        let operation = RemoteSessionOperation(
            nativeSession: nativeSession,
            generation: generation,
            initialDevice: initialDevice,
            claimedDeviceID: claimedDeviceID,
            persistence: environment.persistence,
            bonjour: environment.bonjour,
            observe: environment.observe,
            now: environment.now,
            commands: commands,
            eventContinuation: eventPipe.continuation,
            frameContinuation: framePipe.continuation,
            deviceSession: DeviceSession(
                id: DeviceSessionID(rawValue: generation.rawValue),
                device: initialDevice,
                events: eventPipe.stream,
                frames: framePipe.stream,
                command: { command in
                    try await control.send(command)
                },
                disconnect: {
                    await control.disconnect()
                }
            )
        )
        await control.bind(operation)
        return operation
    }

    private init(
        nativeSession: NativeSession,
        generation: SessionGeneration,
        initialDevice: DeviceSummary,
        claimedDeviceID: DeviceID,
        persistence: PairingPersistenceClient,
        bonjour: RemotePairingBonjourClient,
        observe: @escaping Observation,
        now: @escaping @Sendable () -> Date,
        commands: NativeCommandExecutor,
        eventContinuation:
        AsyncThrowingStream<SessionUpdate, Error>.Continuation,
        frameContinuation: AsyncStream<RemoteDisplayFrame>.Continuation,
        deviceSession: DeviceSession
    ) {
        self.bonjour = bonjour
        self.claimedDeviceID = claimedDeviceID
        self.commands = commands
        self.deviceSession = deviceSession
        self.eventContinuation = eventContinuation
        self.frameContinuation = frameContinuation
        self.generation = generation
        self.nativeSession = nativeSession
        self.now = now
        self.observe = observe
        self.persistence = persistence
        summary = initialDevice
    }

    func start() async throws {
        guard let nativeSession else {
            throw DeviceHubError.connectionLost
        }
        if let videoEvents = nativeSession.videoEvents {
            startDecoder()
            mediaTask = Task {
                await consumeVideo(videoEvents)
            }
        }
        processingTask = Task {
            await consume(nativeSession.events)
        }
        if let videoEvents = nativeSession.videoEvents {
            await videoEvents.waitUntilConsumerReady()
        }
        do {
            try await nativeSession.start()
        } catch {
            throw mapNativeFailure(error)
        }
    }

    func send(_ command: DeviceCommand) async throws {
        try validate(command)
        do {
            let submission = try await commands.submit(command)
            try await submission.value()
        } catch {
            switch error {
            case .disconnected:
                throw DeviceHubError.connectionLost
            case .saturated:
                throw DeviceHubError.deviceBusy
            case let .native(failure):
                throw mapNativeFailure(failure)
            }
        }
    }

    func disconnect() async {
        processingTask?.cancel()
        processingTask = nil
        mediaTask?.cancel()
        mediaTask = nil
        frameTask?.cancel()
        frameTask = nil
        await cleanup()
    }

    private func consume(
        _ events: AsyncThrowingStream<NativeSessionEvent, Error>
    ) async {
        do {
            for try await event in events {
                try Task.checkCancellation()
                try await handle(event)
                if case .completed = event {
                    break
                }
            }
            finishEvents(with: nil)
            await cleanup()
        } catch is CancellationError {
            await cleanup()
        } catch let error as DeviceHubError {
            finishEvents(with: error)
            await record(error, stage: .ready)
            await cleanup()
        } catch let failure as NativeSessionFailure {
            let error = mapNativeFailure(failure)
            finishEvents(with: error)
            await record(
                error,
                stage: nativeFailureDiagnosticStage(failure)
            )
            await cleanup()
        } catch {
            let error = DeviceHubError.secureConnectionFailed
            finishEvents(with: error)
            await record(error, stage: .ready)
            await cleanup()
        }
    }

    private func handle(_ event: NativeSessionEvent) async throws {
        switch event {
        case .started, .authenticated:
            break

        case let .phaseChanged(phase):
            guard let mapped = phase.connectionPhase else {
                return
            }
            try emit(.phaseChanged(mapped))

        case .inputReady:
            if !didEmitHIDReadiness {
                didEmitHIDReadiness = true
                try emit(.hidReadinessChanged(.ready))
            }

        case let .displayGeometry(geometry):
            displayGeometry = geometry

        case let .pairRecordCommitted(requestID, peer):
            guard peer.deviceID == summary.id, let nativeSession else {
                throw DeviceHubError.peerAuthenticationFailed
            }
            let record: TargetPairingRecord
            do {
                record = try await persistence.commitM6(peer.deviceID, now())
                try await nativeSession.completePersistence(
                    requestID,
                    outcome: .succeeded
                )
                try await bonjour.refreshKnownDevices()
            } catch let failure as NativeSessionFailure {
                throw mapNativeFailure(failure)
            } catch {
                do {
                    try await nativeSession.completePersistence(
                        requestID,
                        outcome: .failed
                    )
                } catch {
                    throw DeviceHubError.secureConnectionFailed
                }
                throw DeviceHubError.corruptPairingRecord
            }
            summary = record.deviceSummary(reachability: .reachable)
            try emit(.deviceInfoUpdated(summary))

        case let .rsdReady(metadata):
            guard
                metadata.uniqueDeviceID == summary.id,
                metadata.productType == summary.productType
            else {
                throw DeviceHubError.peerAuthenticationFailed
            }
            guard let operatingSystemVersion =
                metadata.operatingSystemVersion
            else {
                return
            }
            do {
                let authenticated = try AuthenticatedRSDMetadata(
                    operatingSystemVersion: operatingSystemVersion
                )
                let record = try await persistence
                    .enrichFromAuthenticatedRSD(authenticated, summary.id)
                summary = record.deviceSummary(reachability: .reachable)
                try emit(.deviceInfoUpdated(summary))
            } catch {
                throw DeviceHubError.corruptPairingRecord
            }

        case let .screenshot(screenshot):
            let image = try decode(screenshot)
            let orientation: ScreenOrientation =
                screenshot.pixelSize.height >= screenshot.pixelSize.width
                    ? .portrait
                    : .landscapeLeft
            let metadata = ScreenshotMetadata(
                generation: generation,
                receivedAt: now(),
                pixelSize: screenshot.pixelSize,
                orientation: orientation
            )
            frameContinuation.yield(RemoteDisplayFrame(
                metadata: .screenshot(metadata),
                image: image
            ))
            try emit(.screenshot(metadata))

        case let .failed(failure):
            throw failure

        case .cancelled:
            throw CancellationError()

        case .completed:
            break

        case .displayFirstFrame:
            try emit(.displayReady)

        case .pairingCode,
             .pairingListenerReady,
             .pairRecordProvisional:
            throw DeviceHubError.secureConnectionFailed
        }
    }

    private func update(_ event: DeviceSessionEvent) -> SessionUpdate {
        SessionUpdate(generation: generation, event: event)
    }

    private func emit(_ event: DeviceSessionEvent) throws {
        switch eventContinuation.yield(update(event)) {
        case .enqueued:
            return
        case .dropped:
            let error = DeviceHubError.secureConnectionFailed
            eventContinuation.finish(throwing: error)
            throw error
        case .terminated:
            throw CancellationError()
        @unknown default:
            let error = DeviceHubError.secureConnectionFailed
            eventContinuation.finish(throwing: error)
            throw error
        }
    }

    func finishEvents(with error: DeviceHubError?) {
        let terminalUpdate = update(.ended(error))
        switch eventContinuation.yield(terminalUpdate) {
        case .enqueued:
            if let error {
                eventContinuation.finish(throwing: error)
            } else {
                eventContinuation.finish()
            }
        case .dropped:
            eventContinuation.finish(
                throwing: error ?? DeviceHubError.secureConnectionFailed
            )
        case .terminated:
            break
        @unknown default:
            eventContinuation.finish(
                throwing: error ?? DeviceHubError.secureConnectionFailed
            )
        }
    }

    func cleanup() async {
        if let cleanupTask {
            _ = await cleanupTask.value
            return
        }
        frameContinuation.finish()
        eventContinuation.finish()
        mediaTask?.cancel()
        mediaTask = nil
        frameTask?.cancel()
        frameTask = nil
        let decoder = decoder
        self.decoder = nil
        decoderConfiguration = nil
        let commands = commands
        let bonjour = bonjour
        let claimedDeviceID = claimedDeviceID
        let nativeSession = nativeSession
        self.nativeSession = nil
        let cleanupTask = Task<NativeSessionFailure?, Never> {
            if let decoder {
                do {
                    try await decoder.stop()
                } catch {
                    // Decoder failures are surfaced by the media task.
                }
            }
            let commandFailure = await commands.shutdown()
            let cancellationFailure: NativeSessionFailure?
            if let nativeSession {
                do {
                    try await nativeSession.cancel()
                    cancellationFailure = nil
                } catch {
                    cancellationFailure = error as? NativeSessionFailure
                        ?? NativeSessionFailure(
                            code: "native_failure",
                            stage: "native_boundary",
                            retryable: false
                        )
                }
            } else {
                cancellationFailure = nil
            }
            await bonjour.releaseDevice(claimedDeviceID)
            return commandFailure ?? cancellationFailure
        }
        self.cleanupTask = cleanupTask
        if let failure = await cleanupTask.value {
            await record(
                mapNativeFailure(failure),
                stage: .disconnecting
            )
        }
    }

    func record(
        _ error: DeviceHubError,
        stage: DiagnosticStage
    ) async {
        await observe(error, stage)
    }
}

private extension RemoteSessionOperation {
    func decode(
        _ screenshot: NativeScreenshot
    ) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithData(
                screenshot.bytes as CFData,
                nil
            ),
            CGImageSourceGetCount(source) == 1,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == screenshot.pixelSize.width,
            image.height == screenshot.pixelSize.height
        else {
            throw DeviceHubError.decoderFailed
        }
        return image
    }
}

private extension RemoteSessionOperation {
    func validate(_ command: DeviceCommand) throws {
        switch command {
        case .releaseAllInput:
            return

        case let .tap(point):
            try validate(point)

        case let .touch(command):
            try validate(command.point)

        case .button,
             .buttonTap,
             .key,
             .keyTap,
             .rotation:
            guard didEmitHIDReadiness else {
                throw DeviceHubError.deviceBusy
            }
        }
    }

    func validate(_ point: TargetPixelPoint) throws {
        guard
            didEmitHIDReadiness,
            let displayGeometry,
            point.x.isFinite,
            point.y.isFinite,
            point.x >= 0,
            point.y >= 0,
            point.x < Double(displayGeometry.pixelSize.width),
            point.y < Double(displayGeometry.pixelSize.height)
        else {
            throw DeviceHubError.deviceBusy
        }
    }
}

/// Preserves native media setup progress as a finite diagnostics phase while
/// keeping AVConference messages and protocol payloads outside telemetry.
func nativeFailureDiagnosticStage(
    _ failure: NativeSessionFailure
) -> DiagnosticStage {
    switch failure.stage {
    case "video_answer_extraction",
         "video_answer_parse",
         "video_negotiation":
        .startingDisplay
    case "video_apply_answer":
        .applyingVideoAnswer
    case "video_generate_configuration":
        .generatingVideoConfiguration
    case "video_generate_options":
        .generatingVideoOptions
    case "video_validate_receiver":
        .validatingVideoReceiver
    case "video_create_receiver":
        .creatingVideoReceiver
    case "video_configure_receiver":
        .configuringVideoReceiver
    case "video_start_receiver":
        .startingVideoReceiver
    case "video_stream_group_missing",
         "video_stream_payload_encrypted",
         "video_stream_payload_invalid",
         "video_stream_payload_missing",
         "video_stream_selection_ambiguous",
         "video_stream_ssrc_invalid",
         "video_stream_ssrc_missing",
         "video_stream_ssrc_zero":
        .startingDisplay
    case "video_stream_ssrc_mismatch",
         "video_stream":
        .decoding
    default:
        .ready
    }
}
