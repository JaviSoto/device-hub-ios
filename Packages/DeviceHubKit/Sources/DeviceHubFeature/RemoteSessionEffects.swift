import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import Foundation

extension RemoteSessionFeature {
    func cancelSessionEffects() -> Effect<Action> {
        .merge(
            .cancel(id: CancelID.commands),
            .cancel(id: CancelID.connect),
            .cancel(id: CancelID.frames),
            .cancel(id: CancelID.lifecycle)
        )
    }

    func connectEffect(
        attemptID: UUID,
        deviceID: DeviceID,
        cancelID: CancelID
    ) -> Effect<Action> {
        let sessionCoordinator = sessionCoordinator
        return .run { [deviceHub] send in
            do {
                try Task.checkCancellation()
                let session = try await sessionCoordinator.replace(
                    attemptID: attemptID,
                    deviceID: deviceID,
                    using: deviceHub
                )
                try Task.checkCancellation()
                await send(
                    .connectionResponse(
                        attemptID: attemptID,
                        deviceID: deviceID,
                        result: .success(session)
                    )
                )
            } catch is CancellationError {
                _ = await sessionCoordinator.close(
                    attemptID: attemptID
                )
                return
            } catch let error as DeviceHubError {
                await send(
                    .connectionResponse(
                        attemptID: attemptID,
                        deviceID: deviceID,
                        result: .failure(error)
                    )
                )
            } catch {
                await send(
                    .connectionResponse(
                        attemptID: attemptID,
                        deviceID: deviceID,
                        result: .failure(.secureConnectionFailed)
                    )
                )
            }
        }
        .cancellable(id: cancelID, cancelInFlight: true)
    }

    /// Revokes the current frame authorization before normal command effects
    /// are cancelled, placing one cleanup barrier in the ordered input lane.
    func releaseAllInputEffect(
        session: ActiveRemoteSession
    ) -> Effect<Action> {
        guard let sessionID = session.sessionID,
              let authorization = session.frame?.metadata
        else {
            return .none
        }
        let sessionCoordinator = sessionCoordinator
        return .run { send in
            guard let error = await sessionCoordinator.releaseAllInput(
                attemptID: session.attemptID,
                sessionID: sessionID,
                revoking: authorization
            ) else {
                return
            }
            await send(
                .inputCleanupFailed(
                    attemptID: session.attemptID,
                    sessionID: sessionID,
                    error: error
                )
            )
        }
    }

    /// Removes coordinator ownership synchronously, then releases input and
    /// disconnects the exact old attempt before any replacement may begin.
    func closeSessionEffect(
        session: ActiveRemoteSession
    ) -> Effect<Action> {
        let sessionCoordinator = sessionCoordinator
        return .run { send in
            guard let error = await sessionCoordinator.close(
                attemptID: session.attemptID
            ) else {
                return
            }
            await send(
                .inputCleanupFailed(
                    attemptID: session.attemptID,
                    sessionID: session.sessionID,
                    error: error
                )
            )
        }
    }

    /// Synchronously revokes the exact visible frame and clears local holds.
    func revokeInput(
        state: inout State
    ) -> Effect<Action> {
        state.activeContactIDs.removeAll()
        guard var session = state.session else {
            return .none
        }
        session.pendingCommands.removeAll(keepingCapacity: false)
        state.session = session
        guard
            let authorization = session.frame?.metadata,
            session.revokedInputMetadata != authorization
        else {
            return .none
        }
        session.revokedInputMetadata = authorization
        state.session = session
        return releaseAllInputEffect(session: session)
    }

    func observe(
        attemptID: UUID,
        session: DeviceSession
    ) -> Effect<Action> {
        .merge(
            observeLifecycle(attemptID: attemptID, session: session),
            observeFrames(attemptID: attemptID, session: session)
        )
    }

    private func observeLifecycle(
        attemptID: UUID,
        session: DeviceSession
    ) -> Effect<Action> {
        let sessionID = session.id
        return .run { send in
            do {
                for try await update in session.events {
                    try Task.checkCancellation()
                    await send(
                        .sessionUpdateReceived(
                            attemptID: attemptID,
                            sessionID: sessionID,
                            update: update
                        )
                    )
                }
                try Task.checkCancellation()
                await send(
                    .sessionEventsFinished(
                        attemptID: attemptID,
                        sessionID: sessionID
                    )
                )
            } catch is CancellationError {
                return
            } catch let error as DeviceHubError {
                await send(
                    .sessionStreamFailed(
                        attemptID: attemptID,
                        sessionID: sessionID,
                        error: error
                    )
                )
            } catch {
                await send(
                    .sessionStreamFailed(
                        attemptID: attemptID,
                        sessionID: sessionID,
                        error: .secureConnectionFailed
                    )
                )
            }
        }
        .cancellable(id: CancelID.lifecycle, cancelInFlight: true)
    }

    private func observeFrames(
        attemptID: UUID,
        session: DeviceSession
    ) -> Effect<Action> {
        let sessionID = session.id
        return .run { send in
            for await frame in session.frames {
                if Task.isCancelled {
                    return
                }
                await send(
                    .frameReceived(
                        attemptID: attemptID,
                        sessionID: sessionID,
                        frame: frame
                    )
                )
            }
            guard !Task.isCancelled else {
                return
            }
            await send(
                .frameStreamFinished(
                    attemptID: attemptID,
                    sessionID: sessionID
                )
            )
        }
        .cancellable(id: CancelID.frames, cancelInFlight: true)
    }
}

extension RemoteSessionFeature.State {
    mutating func replaceRosterDevice(_ device: DeviceSummary) {
        var devices = roster.devices.filter { $0.id != device.id }
        devices.append(device)
        roster = DeviceRoster(devices: devices)
    }
}

extension ScreenMetadata {
    var sessionEvent: DeviceSessionEvent {
        switch self {
        case let .screenshot(metadata):
            .screenshot(metadata)
        case let .videoFrame(metadata):
            .videoFrame(metadata)
        }
    }
}

extension DeviceSessionEvent {
    var endsSession: Bool {
        switch self {
        case .ended:
            true
        case .deviceInfoUpdated,
             .displayReady,
             .hidReadinessChanged,
             .phaseChanged,
             .reachabilityChanged,
             .reconnected,
             .screenshot,
             .videoFrame:
            false
        }
    }
}
