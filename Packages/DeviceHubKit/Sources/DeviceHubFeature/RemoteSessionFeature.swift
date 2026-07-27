import ComposableArchitecture
import DeviceHubClient
import Foundation

/// Screen-first product logic for discovering, pairing, viewing, and
/// controlling exactly one nearby device.
@Reducer
public struct RemoteSessionFeature {
    enum CancelID {
        case availability
        case commands
        case connect
        case frames
        case lifecycle
        case rosterLoad
    }

    @Dependency(\.date) var date
    @Dependency(\.deviceHub) var deviceHub
    @Dependency(\.uuid) var uuid

    let sessionCoordinator: DeviceSessionCoordinator

    public init() {
        sessionCoordinator = DeviceSessionCoordinator()
    }

    public var body: some ReducerOf<Self> {
        CombineReducers {
            Reduce(reduceLifecycle)
            Reduce(reduceSelection)
            Reduce(reducePresentation)
            Reduce(reduceConnection)
            Reduce(reduceMedia)
            Reduce(reduceInput)
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
