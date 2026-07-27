import ComposableArchitecture
import DeviceHubCore

extension RemoteSessionFeature {
    func reducePresentation(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case .detailsButtonTapped:
            state.detailsDeviceID = state.selectedDeviceID
            return .none

        case .detailsDismissed:
            state.detailsDeviceID = nil
            return .none

        case let .externalRemediationHandled(id):
            guard state.externalRemediation?.id == id else {
                return .none
            }
            state.externalRemediation = nil
            return .none

        case .pairDeviceButtonTapped:
            state.pairing = PairingFeature.State()
            return .send(.pairing(.presented(.task)))

        case let .pairing(.presented(.delegate(delegate))):
            return handlePairingDelegate(
                state: &state,
                delegate: delegate
            )

        case .pairing:
            return .none

        case .remediationButtonTapped:
            return handleRemediation(state: &state)

        case .remediationDismissed:
            state.remediation = nil
            return .none

        default:
            return .none
        }
    }

    private func handlePairingDelegate(
        state: inout State,
        delegate: PairingDelegate
    ) -> Effect<Action> {
        switch delegate {
        case .cancelled:
            state.pairing = nil
            return .none

        case let .paired(device):
            state.pairing = nil
            var devices = state.roster.devices.filter {
                $0.id != device.id
            }
            devices.append(device)
            state.roster = DeviceRoster(devices: devices)
            state.selectedDeviceID = device.id
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case let .remediationRequested(remedy):
            state.pairing = nil
            state.externalRemediation = ExternalRemediationRequest(
                id: uuid(),
                remedy: remedy
            )
            return .none
        }
    }

    private func handleRemediation(
        state: inout State
    ) -> Effect<Action> {
        guard let remediation = state.remediation else {
            return .none
        }

        switch remediation.error.remedy {
        case .pairAgain:
            state.remediation = nil
            state.pairing = PairingFeature.State()
            return .send(.pairing(.presented(.task)))

        case .retry,
             .unlockDevice,
             .stopOtherRemoteSession,
             .bringDeviceNearby:
            state.remediation = nil
            return .send(.retrySelectedDevice)

        case .grantLocalNetworkAccess,
             .enableDeveloperMode,
             .prepareWithXcode,
             .updateApp:
            state.externalRemediation = ExternalRemediationRequest(
                id: uuid(),
                remedy: remediation.error.remedy
            )
            return .none

        case .none:
            state.remediation = nil
            return .none
        }
    }
}
