import DeviceHubCore
import DeviceHubDiagnostics
import DeviceHubPersistence
import Foundation

/// Owns the cancellable system-Bonjour lifecycle for remote pairing.
///
/// The actor treats resolved announcements as candidates and emits availability
/// only after Pair Verify authenticates one against a durable record. Auth tags
/// prioritize candidates but never establish reachability by themselves.
public actor RemotePairingBonjourTransport {
    typealias Observation =
        @Sendable (BonjourTransportObservation) async -> Void
    typealias DiagnosticSink =
        @Sendable (BonjourTransportObservation) async throws -> Void
    typealias CandidateVerifier =
        @Sendable (
            DeviceID,
            ValidatedRemotePairingService
        ) async -> Bool

    struct BrowsingState {
        let continuation:
            AsyncThrowingStream<
                [RemotePairingAvailability],
                Error
            >.Continuation
        var didStart = false
        var knownDevices: [KnownRemotePairingDevice]
        var matchesByServiceName: [String: DeviceID] = [:]
        var nextCandidateRevision: UInt64 = 0
        var pendingEvents: [BonjourBrowserEvent] = []
        var pendingVerificationServiceNames: [String] = []
        var queuedVerificationServiceNames: Set<String> = []
        var rejectedServiceNames: Set<String> = []
        var revisionsByServiceName: [String: UInt64] = [:]
        var servicesByName: [
            String: ValidatedRemotePairingService
        ] = [:]
        let token: UUID
    }

    struct PublishingState {
        let continuation:
            AsyncThrowingStream<
                PairingAdvertisementEvent,
                Error
            >.Continuation
        var didPublish = false
        let token: UUID
    }

    private let browser: BonjourBrowserClient
    var activeCandidateDeviceID: DeviceID?
    var activeCandidateServiceKey: String?
    var browsingState: BrowsingState?
    var candidateVerificationTask: Task<Void, Never>?
    var candidateVerificationToken: UUID?
    var claimedDeviceIDs: Set<DeviceID> = []
    private var ignoredBrowsingTerminations: Set<UUID> = []
    var ignoredPublishingTerminations: Set<UUID> = []
    private let loadKnownDevices:
        @Sendable () async throws -> [KnownRemotePairingDevice]
    let loadPairableHostIdentity:
        @Sendable () async throws -> PairableHostIdentity
    private let observe: Observation
    let publisher: BonjourPublisherClient
    var publishingState: PublishingState?
    let verifyCandidate: CandidateVerifier

    init(
        loadKnownDevices:
        @escaping @Sendable () async throws
            -> [KnownRemotePairingDevice],
        loadPairableHostIdentity:
        @escaping @Sendable () async throws -> PairableHostIdentity,
        browser: BonjourBrowserClient,
        publisher: BonjourPublisherClient,
        verifyCandidate: @escaping CandidateVerifier,
        observe: @escaping DiagnosticSink,
        reportDiagnosticsFailure: @escaping @Sendable () -> Void = {}
    ) {
        self.browser = browser
        self.loadKnownDevices = loadKnownDevices
        self.loadPairableHostIdentity = loadPairableHostIdentity
        self.observe = { observation in
            do {
                try await observe(observation)
            } catch {
                reportDiagnosticsFailure()
            }
        }
        self.publisher = publisher
        self.verifyCandidate = verifyCandidate
    }

    /// Builds the live transport around Foundation Bonjour, Keychain-backed
    /// pairing state, and the bounded structured diagnostics recorder.
    @MainActor
    static func live(
        pairingPersistence: PairingPersistenceClient,
        diagnostics: DiagnosticRecorder,
        verifyCandidate: @escaping CandidateVerifier
    ) -> RemotePairingBonjourTransport {
        RemotePairingBonjourTransport(
            loadKnownDevices: {
                let records = try await pairingPersistence.pairingRecords()
                return try records.map { record in
                    try KnownRemotePairingDevice(
                        deviceID: record.deviceID,
                        alternateIRK: record.peerAlternateIRK
                            .withUnsafeBytes { Data($0) }
                    )
                }
            },
            loadPairableHostIdentity: {
                let identity = try await pairingPersistence
                    .loadOrCreateControllerIdentity()
                return try PairableHostIdentity(
                    identifier: identity.identifier.rawValue,
                    alternateIRK: identity.alternateIRK
                        .withUnsafeBytes { Data($0) }
                )
            },
            browser: .foundation(),
            publisher: .foundation(),
            verifyCandidate: verifyCandidate,
            observe: { observation in
                try await diagnostics.record(
                    level: .warning,
                    category: .discovery,
                    stage: .locating,
                    kind: .operationFailed,
                    fields: DiagnosticFields(
                        outcome: .dropped,
                        failureCode: observation.failureCode,
                        retryability: .automatic,
                        transport: .localNetwork,
                        service: .remotePairing
                    )
                )
            },
            reportDiagnosticsFailure: {
                reportTransportDiagnosticsFailure(.locating)
            }
        )
    }

    /// Starts a latest-value stream of authenticated availability snapshots.
    ///
    /// Cancelling iteration stops the Foundation browser exactly once.
    public func availability() -> AsyncThrowingStream<
        [RemotePairingAvailability],
        Error
    > {
        let token = UUID()
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.cancelAvailability(token: token)
                }
            }
            Task {
                await self.beginAvailability(
                    token: token,
                    continuation: continuation
                )
            }
        }
    }

    /// Stops the active browser, if any. Repeated calls are no-ops.
    public func stopAvailability() async {
        guard let token = browsingState?.token else {
            return
        }
        await finishAvailability(token: token, error: nil)
    }

    /// Claims one authenticated target for a live control session.
    ///
    /// While claimed, the active session is authoritative for reachability and
    /// Bonjour must not open a competing Pair Verify connection to that target.
    func claimDevice(_ deviceID: DeviceID) async {
        guard claimedDeviceIDs.insert(deviceID).inserted else {
            return
        }
        if activeCandidateDeviceID == deviceID {
            await stopCandidateVerification()
        }
        guard var state = browsingState else {
            return
        }
        removePendingVerification(
            for: deviceID,
            state: &state
        )
        browsingState = state
        yieldAvailability(state)
        startCandidateVerificationIfNeeded(token: state.token)
    }

    /// Releases live-session ownership and reauthenticates any retained
    /// announcement that changed while the target was claimed.
    func releaseDevice(_ deviceID: DeviceID) {
        guard claimedDeviceIDs.remove(deviceID) != nil,
              var state = browsingState
        else {
            return
        }
        for serviceKey in state.servicesByName.keys.sorted()
            where state.matchesByServiceName[serviceKey] != deviceID
            && resolvedDeviceID(
                for: serviceKey,
                state: state
            ) == deviceID
        {
            state.rejectedServiceNames.remove(serviceKey)
            enqueueCandidateVerification(
                serviceKey,
                state: &state
            )
        }
        browsingState = state
        yieldAvailability(state)
        startCandidateVerificationIfNeeded(token: state.token)
    }

    /// Reloads durable peer identities and reauthenticates every retained
    /// announcement without restarting the system Bonjour browser.
    ///
    /// This is called after M6 commit so a service discovered while the peer
    /// was still unknown can become reachable immediately.
    func refreshKnownDevices() async throws(RemotePairingBonjourError) {
        let knownDevices: [KnownRemotePairingDevice]
        do {
            knownDevices = try await loadKnownDevices()
            try KnownDeviceResolver.validate(knownDevices)
        } catch {
            throw .pairingRecordsUnavailable
        }
        guard let browsingToken = browsingState?.token else {
            return
        }

        await stopCandidateVerification()
        guard
            var state = browsingState,
            state.token == browsingToken
        else {
            return
        }
        state.knownDevices = knownDevices
        state.matchesByServiceName.removeAll()
        state.pendingVerificationServiceNames.removeAll()
        state.queuedVerificationServiceNames.removeAll()
        state.rejectedServiceNames.removeAll()
        var observations: [BonjourTransportObservation] = []
        for serviceName in state.servicesByName.keys.sorted() {
            guard let service = state.servicesByName[serviceName] else {
                continue
            }
            state.nextCandidateRevision &+= 1
            state.revisionsByServiceName[serviceName] =
                state.nextCandidateRevision
            do {
                guard try KnownDeviceResolver.resolve(
                    service,
                    among: knownDevices
                ) != nil else {
                    state.rejectedServiceNames.insert(serviceName)
                    observations.append(.unknownAnnouncement)
                    continue
                }
                enqueueCandidateVerification(
                    serviceName,
                    state: &state
                )
            } catch {
                observations.append(.ambiguousAnnouncement)
            }
        }
        browsingState = state
        yieldAvailability(state)
        startCandidateVerificationIfNeeded(token: state.token)

        for observation in observations {
            guard browsingState?.token == state.token else {
                return
            }
            await record(observation)
        }
    }

    /// Returns the current authenticated service for one durable target.
    func resolvedService(
        for deviceID: DeviceID
    ) -> ValidatedRemotePairingService? {
        guard let state = browsingState else {
            return nil
        }
        return state.matchesByServiceName
            .filter { $0.value == deviceID }
            .map(\.key)
            .sorted()
            .compactMap { state.servicesByName[$0] }
            .first
    }

    /// Advertises an already-bound native pairing listener.
    ///
    /// This method never asks `NetService` to create or own a listener. The
    /// caller-provided port must already belong to the cancellable Rust
    /// pairing session.
    public func pairingAdvertisement(
        listenerPort: UInt16,
        displayName: String,
        model: String
    ) -> AsyncThrowingStream<PairingAdvertisementEvent, Error> {
        let token = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.cancelPairingAdvertisement(token: token)
                }
            }
            Task {
                await self.beginPairingAdvertisement(
                    token: token,
                    continuation: continuation,
                    listenerPort: listenerPort,
                    displayName: displayName,
                    model: model
                )
            }
        }
    }

    /// Stops the active pairing advertisement, if any.
    public func stopPairingAdvertisement() async {
        guard let token = publishingState?.token else {
            return
        }
        await finishPairingAdvertisement(token: token, error: nil)
    }
}

extension RemotePairingBonjourTransport {
    private func beginAvailability(
        token: UUID,
        continuation:
        AsyncThrowingStream<
            [RemotePairingAvailability],
            Error
        >.Continuation
    ) async {
        if ignoredBrowsingTerminations.remove(token) != nil {
            return
        }
        if let existingToken = browsingState?.token {
            await finishAvailability(token: existingToken, error: nil)
        }

        let knownDevices: [KnownRemotePairingDevice]
        do {
            knownDevices = try await loadKnownDevices()
            try KnownDeviceResolver.validate(knownDevices)
        } catch {
            continuation.finish(
                throwing: RemotePairingBonjourError
                    .pairingRecordsUnavailable
            )
            return
        }
        guard ignoredBrowsingTerminations.remove(token) == nil else {
            return
        }

        browsingState = BrowsingState(
            continuation: continuation,
            knownDevices: knownDevices,
            token: token
        )

        do {
            try await browser.start { [weak self] event in
                Task {
                    await self?.receiveBrowserEvent(event, token: token)
                }
            }
        } catch {
            await finishAvailability(
                token: token,
                error: .browserStartFailed(code: error.code)
            )
            return
        }

        guard var state = browsingState, state.token == token else {
            return
        }
        state.didStart = true
        let pendingEvents = state.pendingEvents
        state.pendingEvents.removeAll()
        browsingState = state
        state.continuation.yield(
            availabilitySnapshot(
                knownDevices: state.knownDevices,
                reachableDeviceIDs: claimedDeviceIDs
            )
        )
        for event in pendingEvents {
            await receiveBrowserEvent(event, token: token)
        }
    }

    private func receiveBrowserEvent(
        _ event: BonjourBrowserEvent,
        token: UUID
    ) async {
        guard var state = browsingState, state.token == token else {
            return
        }
        guard state.didStart else {
            state.pendingEvents.append(event)
            browsingState = state
            return
        }

        switch event {
        case let .failed(failure):
            await finishAvailability(
                token: token,
                error: .browserFailed(code: failure.code)
            )

        case let .removed(serviceName):
            guard
                var state = browsingState,
                state.token == token
            else {
                return
            }
            let serviceKey = serviceName.lowercased()
            let removedMatch = state.matchesByServiceName.removeValue(
                forKey: serviceKey
            )
            state.servicesByName.removeValue(forKey: serviceKey)
            state.pendingVerificationServiceNames.removeAll {
                $0 == serviceKey
            }
            state.queuedVerificationServiceNames.remove(serviceKey)
            state.rejectedServiceNames.remove(serviceKey)
            state.nextCandidateRevision &+= 1
            state.revisionsByServiceName[serviceKey] =
                state.nextCandidateRevision
            browsingState = state
            if activeCandidateServiceKey == serviceKey {
                await stopCandidateVerification()
                startCandidateVerificationIfNeeded(token: token)
            }
            guard removedMatch != nil else {
                return
            }
            yieldAvailability(state)

        case .resolutionFailed:
            await record(
                .resolutionFailed
            )

        case let .resolved(snapshot):
            await handleResolved(snapshot, token: token)
        }
    }

    private func handleResolved(
        _ snapshot: BonjourResolvedServiceSnapshot,
        token: UUID
    ) async {
        guard var state = browsingState, state.token == token else {
            return
        }

        let service: ValidatedRemotePairingService
        do {
            service = try ValidatedRemotePairingService(
                serviceName: snapshot.serviceName,
                hostName: snapshot.hostName,
                port: snapshot.port,
                resolvedEndpoints: snapshot.resolvedEndpoints,
                txtRecord: snapshot.txtRecord
            )
        } catch {
            await record(
                .malformedAnnouncement
            )
            return
        }
        let serviceKey = snapshot.serviceName.lowercased()
        if state.servicesByName[serviceKey] == service {
            return
        }
        guard
            state.servicesByName[serviceKey] != nil
            || state.servicesByName.count < 64
        else {
            await record(.unknownAnnouncement)
            return
        }

        let needsActiveCancellation =
            activeCandidateServiceKey == serviceKey
        let removedMatch =
            state.matchesByServiceName.removeValue(forKey: serviceKey) != nil
        state.pendingVerificationServiceNames.removeAll {
            $0 == serviceKey
        }
        state.queuedVerificationServiceNames.remove(serviceKey)
        state.rejectedServiceNames.remove(serviceKey)
        state.nextCandidateRevision &+= 1
        state.revisionsByServiceName[serviceKey] =
            state.nextCandidateRevision
        state.servicesByName[serviceKey] = service
        browsingState = state
        if needsActiveCancellation {
            await stopCandidateVerification()
            guard
                let currentState = browsingState,
                currentState.token == token,
                currentState.servicesByName[serviceKey] == service
            else {
                return
            }
            state = currentState
        }

        guard var currentState = browsingState, currentState.token == token else {
            return
        }
        do {
            guard try KnownDeviceResolver.resolve(
                service,
                among: currentState.knownDevices
            ) != nil else {
                currentState.rejectedServiceNames.insert(serviceKey)
                browsingState = currentState
                if removedMatch {
                    yieldAvailability(currentState)
                }
                await record(.unknownAnnouncement)
                return
            }
            enqueueCandidateVerification(
                serviceKey,
                state: &currentState
            )
        } catch {
            browsingState = currentState
            await record(.ambiguousAnnouncement)
            return
        }
        browsingState = currentState
        if removedMatch {
            yieldAvailability(currentState)
        }
        startCandidateVerificationIfNeeded(token: token)
    }

    func record(
        _ observation: BonjourTransportObservation
    ) async {
        await observe(observation)
    }

    private func cancelAvailability(token: UUID) async {
        guard let state = browsingState, state.token == token else {
            if ignoredBrowsingTerminations.remove(token) == nil {
                ignoredBrowsingTerminations.insert(token)
            }
            return
        }
        browsingState = nil
        await stopCandidateVerification()
        await browser.stop()
    }

    private func finishAvailability(
        token: UUID,
        error: RemotePairingBonjourError?
    ) async {
        guard let state = browsingState, state.token == token else {
            return
        }
        browsingState = nil
        await stopCandidateVerification()
        ignoredBrowsingTerminations.insert(token)
        if let error {
            state.continuation.finish(throwing: error)
        } else {
            state.continuation.finish()
        }
        await browser.stop()
    }
}

private extension BonjourTransportObservation {
    var failureCode: DiagnosticFailureCode {
        switch self {
        case .ambiguousAnnouncement:
            .peerAuthenticationFailed
        case .malformedAnnouncement:
            .malformedAnnouncement
        case .resolutionFailed:
            .connectionLost
        case .unknownAnnouncement:
            .peerAuthenticationFailed
        }
    }
}
