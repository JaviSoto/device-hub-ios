import ComposableArchitecture
import DeviceHubCore

extension RemoteSessionFeature {
    func reduceLifecycle(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case let .appLifecycleChanged(lifecycle):
            let previousLifecycle = state.lifecycle
            state.lifecycle = lifecycle
            DeviceHubFeatureTrace.emit(
                "lifecycle_changed previous=\(previousLifecycle) "
                    + "current=\(lifecycle)"
            )

            switch lifecycle {
            case .active:
                guard previousLifecycle == .background else {
                    return .none
                }
                return .send(.task)

            case .background:
                let previousSession = state.session
                state.activeContactIDs.removeAll()
                state.isLoadingRoster = false
                state.isObservingAvailability = false
                state.pairing = nil
                state.session = nil
                guard let previousSession else {
                    return cancelAllEffects()
                }
                return .concatenate(
                    closeSessionEffect(session: previousSession),
                    cancelAllEffects()
                )

            case .inactive:
                guard previousLifecycle == .active else {
                    return .none
                }
                return .concatenate(
                    revokeInput(state: &state),
                    .cancel(id: CancelID.commands)
                )
            }

        case .availabilityObservationFinished:
            state.isObservingAvailability = false
            return .none

        case .task:
            guard state.lifecycle == .active else {
                return .none
            }
            state.isLoadingRoster = true
            return loadRosterEffect()

        case let .pairedDevicesResponse(.success(devices)):
            return beginAvailabilityObservationIfNeeded(
                state: &state,
                hasPairedDevice: !devices.isEmpty
            )

        case .pairing(.presented(.delegate(.paired))):
            return beginAvailabilityObservationIfNeeded(
                state: &state,
                hasPairedDevice: true
            )

        default:
            return .none
        }
    }

    private func beginAvailabilityObservationIfNeeded(
        state: inout State,
        hasPairedDevice: Bool
    ) -> Effect<Action> {
        guard hasPairedDevice,
              state.lifecycle == .active,
              !state.isObservingAvailability
        else {
            return .none
        }
        state.isObservingAvailability = true
        return observeAvailabilityEffect()
    }

    func cancelAllEffects() -> Effect<Action> {
        .merge(
            cancelSessionEffects(),
            .cancel(id: CancelID.availability),
            .cancel(id: CancelID.rosterLoad)
        )
    }

    func loadRosterEffect() -> Effect<Action> {
        .run { [deviceHub] send in
            do {
                try await send(
                    .pairedDevicesResponse(
                        .success(deviceHub.pairedDevices())
                    )
                )
            } catch is CancellationError {
                return
            } catch let error as DeviceHubError {
                await send(.pairedDevicesResponse(.failure(error)))
            } catch {
                await send(
                    .pairedDevicesResponse(
                        .failure(.secureConnectionFailed)
                    )
                )
            }
        }
        .cancellable(id: CancelID.rosterLoad, cancelInFlight: true)
    }

    func observeAvailabilityEffect() -> Effect<Action> {
        .run { [deviceHub] send in
            for await snapshot in deviceHub.availability() {
                if Task.isCancelled {
                    return
                }
                await send(.availabilitySnapshotReceived(snapshot))
            }
            guard !Task.isCancelled else {
                return
            }
            await send(.availabilityObservationFinished)
        }
        .cancellable(id: CancelID.availability, cancelInFlight: true)
    }
}
