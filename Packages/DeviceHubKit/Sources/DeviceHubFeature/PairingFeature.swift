import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore

/// Pairing progress that is safe for a regular product UI.
public enum PairingPhase: Equatable, Sendable {
    case preparing
    case advertising
    case saving
    case waitingForCodeEntry(PairingCode)
}

/// Terminal pairing outcomes consumed by the root feature.
@CasePathable
public enum PairingDelegate: Sendable {
    case cancelled
    case paired(DeviceSummary)
    /// Platform or physical recovery work that cannot run inside this reducer.
    case remediationRequested(DeviceHubError.Remedy)
}

/// Explicit, cancellable pairing presentation.
///
/// The six-digit code exists only in this short-lived state. Every terminal
/// action removes it before dismissing or presenting an error.
@Reducer
public struct PairingFeature {
    /// Ephemeral presentation state for one pairing attempt.
    @ObservableState
    public struct State: Equatable {
        /// Sanitized progress currently rendered by the pairing sheet.
        public var phase: PairingPhase
        /// Latest pairing failure and its safe recovery action.
        public var remediation: DeviceHubRemediation?

        public init(
            phase: PairingPhase = .preparing,
            remediation: DeviceHubRemediation? = nil
        ) {
            self.phase = phase
            self.remediation = remediation
        }

        /// The value rendered by the code view and nowhere else.
        public var pairingCode: PairingCode? {
            guard case let .waitingForCodeEntry(code) = phase else {
                return nil
            }
            return code
        }

        /// Button title for the current recovery action, or `nil` when the
        /// failure has no safe user action.
        public var remediationActionTitle: String? {
            remediation?.actionButtonTitle
        }
    }

    /// Pairing intents and sanitized progress responses.
    public enum Action {
        case cancelButtonTapped
        case delegate(PairingDelegate)
        case pairingEventReceived(PairingEvent)
        case pairingFailed(DeviceHubError)
        case preparationTimedOut
        case pairingStreamFinished
        case remediationButtonTapped
        case task
    }

    private enum CancelID {
        case pairing
        case preparationTimeout
    }

    @Dependency(\.continuousClock) private var clock
    @Dependency(\.deviceHub) private var deviceHub

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .cancelButtonTapped:
                state.phase = .preparing
                state.remediation = nil
                return .concatenate(
                    .merge(
                        .cancel(id: CancelID.pairing),
                        .cancel(id: CancelID.preparationTimeout)
                    ),
                    .send(.delegate(.cancelled))
                )

            case .delegate:
                return .none

            case let .pairingEventReceived(event):
                switch event {
                case .advertising:
                    state.phase = .advertising
                    state.remediation = nil
                    return .cancel(id: CancelID.preparationTimeout)

                case let .waitingForCodeEntry(code):
                    state.phase = .waitingForCodeEntry(code)
                    state.remediation = nil
                    return .cancel(id: CancelID.preparationTimeout)

                case .saving:
                    state.phase = .saving
                    return .cancel(id: CancelID.preparationTimeout)

                case let .paired(device):
                    state.phase = .preparing
                    state.remediation = nil
                    return .concatenate(
                        .cancel(id: CancelID.preparationTimeout),
                        .send(.delegate(.paired(device)))
                    )
                }

            case let .pairingFailed(error):
                state.phase = .preparing
                state.remediation = DeviceHubRemediation(error: error)
                return .cancel(id: CancelID.preparationTimeout)

            case .preparationTimedOut:
                guard
                    state.phase == .preparing,
                    state.remediation == nil
                else {
                    return .none
                }
                state.remediation = DeviceHubRemediation(
                    error: .pairingTimedOut
                )
                return .merge(
                    .cancel(id: CancelID.pairing),
                    .cancel(id: CancelID.preparationTimeout)
                )

            case .pairingStreamFinished:
                state.phase = .preparing
                guard state.remediation == nil else {
                    return .cancel(id: CancelID.preparationTimeout)
                }
                state.remediation = DeviceHubRemediation(
                    error: .pairingTimedOut
                )
                return .cancel(id: CancelID.preparationTimeout)

            case .remediationButtonTapped:
                guard let remedy = state.remediation?.error.remedy else {
                    return .none
                }
                switch remedy {
                case .bringDeviceNearby,
                     .pairAgain,
                     .retry,
                     .stopOtherRemoteSession,
                     .unlockDevice:
                    state.phase = .preparing
                    state.remediation = nil
                    return pairingEffects()

                case .enableDeveloperMode,
                     .grantLocalNetworkAccess,
                     .prepareWithXcode,
                     .updateApp:
                    state.phase = .preparing
                    state.remediation = nil
                    return .concatenate(
                        .merge(
                            .cancel(id: CancelID.pairing),
                            .cancel(id: CancelID.preparationTimeout)
                        ),
                        .send(
                            .delegate(
                                .remediationRequested(remedy)
                            )
                        )
                    )

                case .none:
                    return .none
                }

            case .task:
                state.phase = .preparing
                state.remediation = nil
                return pairingEffects()
            }
        }
    }

    private func pairingEffects() -> Effect<Action> {
        .merge(
            pairingEffect(),
            .run { [clock] send in
                try await clock.sleep(for: .seconds(15))
                await send(.preparationTimedOut)
            }
            .cancellable(
                id: CancelID.preparationTimeout,
                cancelInFlight: true
            )
        )
    }

    private func pairingEffect() -> Effect<Action> {
        .run { [deviceHub] send in
            do {
                for try await event in deviceHub.pair(PairingRequest()) {
                    try Task.checkCancellation()
                    await send(.pairingEventReceived(event))
                }
                try Task.checkCancellation()
                await send(.pairingStreamFinished)
            } catch is CancellationError {
                return
            } catch let error as DeviceHubError {
                await send(.pairingFailed(error))
            } catch {
                await send(.pairingFailed(.secureConnectionFailed))
            }
        }
        .cancellable(id: CancelID.pairing, cancelInFlight: true)
    }
}
