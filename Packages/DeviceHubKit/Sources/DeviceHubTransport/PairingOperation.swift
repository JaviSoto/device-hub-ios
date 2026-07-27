import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubPersistence
import Foundation

/// Owns one explicitly initiated Pairable Host protocol generation.
actor PairingOperation {
    typealias Observation = DeviceHubTransportEnvironment.Observation
    typealias MilestoneObservation =
        DeviceHubTransportEnvironment.PairingMilestoneObservation

    /// Tracks publisher ownership so a failed start is still torn down.
    private enum AdvertisementState {
        case inactive
        case peerConnected
        case startAttempted
        case published
    }

    /// Retains the Bonjour stream after publication because releasing its
    /// iterator terminates the stream and tears down the underlying service.
    /// Ownership ends only after the native peer connects or during cleanup.
    private var advertisementIterator: AsyncThrowingStream<
        PairingAdvertisementEvent,
        Error
    >.Iterator?
    private var advertisementState = AdvertisementState.inactive
    private let bonjour: RemotePairingBonjourClient
    private let configuration: DeviceHubTransportConfiguration
    private var didCleanUp = false
    private var didPair = false
    private let generation: SessionGeneration
    private let nativeSessions: NativeSessionClient
    private var nativeSession: NativeSession?
    private let now: @Sendable () -> Date
    private let observe: Observation
    private let observeMilestone: MilestoneObservation
    private let persistence: PairingPersistenceClient
    private var provisionalDeviceID: DeviceID?

    init(
        nativeSessions: NativeSessionClient,
        configuration: DeviceHubTransportConfiguration,
        persistence: PairingPersistenceClient,
        bonjour: RemotePairingBonjourClient,
        observe: @escaping Observation,
        observeMilestone: @escaping MilestoneObservation,
        now: @escaping @Sendable () -> Date,
        generation: SessionGeneration
    ) {
        self.bonjour = bonjour
        self.configuration = configuration
        self.generation = generation
        self.nativeSessions = nativeSessions
        self.now = now
        self.observe = observe
        self.observeMilestone = observeMilestone
        self.persistence = persistence
    }

    func run(
        continuation: AsyncThrowingStream<
            PairingEvent,
            Error
        >.Continuation
    ) async {
        do {
            guard
                nativeSessions.capabilities.contains(.requiredPairing)
            else {
                throw DeviceHubError.unsupportedProtocolVersion
            }
            let controller: ControllerIdentity
            do {
                controller = try await persistence
                    .loadOrCreateControllerIdentity()
            } catch {
                throw DeviceHubError.corruptPairingRecord
            }
            let request: NativePairingSessionRequest
            do {
                request = try NativePairingSessionRequest(
                    generation: generation,
                    controller: nativeController(controller),
                    displayName: configuration.controllerDisplayName,
                    model: configuration.controllerModel,
                    requestedPort: configuration.requestedPairingPort
                )
            } catch {
                throw DeviceHubError.corruptPairingRecord
            }
            do {
                nativeSession = try await nativeSessions
                    .makePairingSession(request)
                try await nativeSession?.start()
            } catch let failure {
                throw mapNativeFailure(failure)
            }
            guard let nativeSession else {
                throw DeviceHubError.secureConnectionFailed
            }

            for try await event in nativeSession.events {
                try Task.checkCancellation()
                try await handle(event, continuation: continuation)
                if case .completed = event {
                    break
                }
            }
            guard didPair else {
                throw DeviceHubError.pairingRejected
            }
            if let cleanupError = await cleanup() {
                throw cleanupError
            }
            continuation.finish()
        } catch is CancellationError {
            _ = await cleanup()
            continuation.finish()
        } catch let error as DeviceHubError {
            await record(error, stage: .pairing)
            _ = await cleanup()
            continuation.finish(throwing: error)
        } catch let failure as NativeSessionFailure {
            let error = mapNativeFailure(failure)
            await record(error, stage: .pairing)
            _ = await cleanup()
            continuation.finish(throwing: error)
        } catch {
            let error = DeviceHubError.secureConnectionFailed
            await record(error, stage: .pairing)
            _ = await cleanup()
            continuation.finish(throwing: error)
        }
    }

    func cancelFromConsumer() async {
        _ = await cleanup()
    }

    private func handle(
        _ event: NativeSessionEvent,
        continuation: AsyncThrowingStream<
            PairingEvent,
            Error
        >.Continuation
    ) async throws {
        switch event {
        case .started, .authenticated:
            break

        case let .phaseChanged(phase):
            if phase == .pairing {
                switch advertisementState {
                case .published:
                    advertisementState = .peerConnected
                    await observeMilestone(.peerConnected)

                case .inactive, .peerConnected, .startAttempted:
                    break
                }
            }

        case let .pairingListenerReady(port):
            guard case .inactive = advertisementState else {
                throw DeviceHubError.secureConnectionFailed
            }
            advertisementState = .startAttempted
            await observeMilestone(.listenerReady)
            let events = await bonjour.pairingAdvertisement(
                port,
                configuration.controllerDisplayName,
                configuration.controllerModel
            )
            var iterator = events.makeAsyncIterator()
            do {
                while let advertisementEvent = try await iterator.next() {
                    guard advertisementEvent == .published else {
                        continue
                    }
                    advertisementState = .published
                    advertisementIterator = iterator
                    break
                }
            } catch let error as RemotePairingBonjourError {
                throw mapBonjourPublicationFailure(error)
            }
            guard case .published = advertisementState else {
                throw DeviceHubError.localNetworkDenied
            }
            await observeMilestone(.advertisementPublished)
            continuation.yield(.advertising)

        case let .pairingCode(code):
            await observeMilestone(.waitingForPairingCode)
            continuation.yield(.waitingForCodeEntry(code: code))

        case let .pairRecordProvisional(requestID, peer):
            guard provisionalDeviceID == nil else {
                throw DeviceHubError.peerAuthenticationFailed
            }
            guard configuration.remoteTargetPolicy.permits(
                displayName: peer.displayName
            ) else {
                try await acknowledgeRejectedPersistence(requestID)
                throw DeviceHubError.peerAuthenticationFailed
            }
            await observeMilestone(.savingPairing)
            continuation.yield(.saving)
            let pairing = try verifiedM5(peer, verifiedAt: now())
            let record = try await persist(
                requestID: requestID,
                operation: {
                    try await persistence.saveVerifiedM5(pairing)
                }
            )
            provisionalDeviceID = record.deviceID

        case let .pairRecordCommitted(requestID, peer):
            guard
                let provisionalDeviceID,
                provisionalDeviceID == peer.deviceID,
                !didPair
            else {
                throw DeviceHubError.peerAuthenticationFailed
            }
            let record = try await persist(
                requestID: requestID,
                operation: {
                    try await persistence.commitM6(
                        peer.deviceID,
                        now()
                    )
                }
            )
            do {
                try await bonjour.refreshKnownDevices()
            } catch {
                throw DeviceHubError.corruptPairingRecord
            }
            let reachable =
                await bonjour.resolvedService(peer.deviceID) != nil
            continuation.yield(.paired(record.deviceSummary(
                reachability: reachable ? .reachable : .unavailable
            )))
            didPair = true
            await observeMilestone(.pairingCompleted)

        case let .failed(failure):
            throw mapNativeFailure(failure)

        case .cancelled:
            throw CancellationError()

        case .completed:
            break

        case .displayFirstFrame,
             .displayGeometry,
             .inputReady,
             .rsdReady,
             .screenshot:
            throw DeviceHubError.secureConnectionFailed
        }
    }

    private func acknowledgeRejectedPersistence(
        _ requestID: NativePersistenceRequestID
    ) async throws {
        guard let nativeSession else {
            throw DeviceHubError.secureConnectionFailed
        }
        do {
            try await nativeSession.completePersistence(
                requestID,
                outcome: .failed
            )
        } catch {
            throw mapNativeFailure(error)
        }
    }

    private func persist(
        requestID: NativePersistenceRequestID,
        operation: () async throws -> TargetPairingRecord
    ) async throws -> TargetPairingRecord {
        guard let nativeSession else {
            throw DeviceHubError.secureConnectionFailed
        }
        do {
            let record = try await operation()
            try await nativeSession.completePersistence(
                requestID,
                outcome: .succeeded
            )
            return record
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
    }

    private func cleanup() async -> DeviceHubError? {
        guard !didCleanUp else {
            return nil
        }
        didCleanUp = true
        switch advertisementState {
        case .inactive:
            break
        case .peerConnected, .startAttempted, .published:
            await bonjour.stopPairingAdvertisement()
            releaseAdvertisementLifetime()
            advertisementState = .inactive
        }
        guard let nativeSession else {
            return nil
        }
        self.nativeSession = nil
        do {
            try await nativeSession.cancel()
            return nil
        } catch {
            return mapNativeFailure(error)
        }
    }

    private func releaseAdvertisementLifetime() {
        guard let advertisementIterator else {
            return
        }
        self.advertisementIterator = nil
        withExtendedLifetime(advertisementIterator) {}
    }

    private func mapBonjourPublicationFailure(
        _ error: RemotePairingBonjourError
    ) -> DeviceHubError {
        switch error {
        case let .publisherFailed(code),
             let .publisherStartFailed(code):
            code == -65570
                ? .localNetworkDenied
                : .secureConnectionFailed

        case .browserFailed,
             .browserStartFailed,
             .invalidPairableHostConfiguration,
             .pairingRecordsUnavailable:
            .secureConnectionFailed
        }
    }

    private func record(
        _ error: DeviceHubError,
        stage: DiagnosticStage
    ) async {
        await observe(error, stage)
    }
}
