import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import Foundation

extension RemoteSessionFeature {
    func reduceMedia(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case let .frameReceived(attemptID, sessionID, frame):
            receiveFrame(
                state: &state,
                attemptID: attemptID,
                sessionID: sessionID,
                frame: frame
            )
            return .none

        case let .frameStreamFinished(attemptID, sessionID):
            guard state.session?.attemptID == attemptID,
                  state.session?.sessionID == sessionID
            else {
                return .none
            }
            return .none

        default:
            return .none
        }
    }

    private func receiveFrame(
        state: inout State,
        attemptID: UUID,
        sessionID: DeviceSessionID,
        frame: RemoteDisplayFrame
    ) {
        guard var session = state.session,
              session.attemptID == attemptID,
              session.sessionID == sessionID
        else {
            return
        }

        var remoteState = session.remoteState
            ?? RemoteSessionState(
                deviceID: session.device.id,
                generation: frame.metadata.generation,
                reachability: session.device.reachability
            )
        let previousScreen = remoteState.latestScreen
        let update = SessionUpdate(
            generation: frame.metadata.generation,
            event: frame.metadata.sessionEvent
        )
        let disposition = remoteState.apply(update)
        if disposition != .accepted {
            DeviceHubFeatureTrace.emit(
                "frame_rejected disposition=\(String(describing: disposition)) "
                    + "kind=\(String(describing: frame.metadata.kind))"
            )
        } else if previousScreen?.kind != .videoFrame,
                  case let .videoFrame(metadata) = frame.metadata
        {
            DeviceHubFeatureTrace.emit(
                "first_video_frame sequence=\(metadata.sequenceNumber)"
            )
        }
        guard disposition == .accepted
            || remoteState.latestScreen == frame.metadata
        else {
            return
        }

        let now = date.now
        session.connectionError = nil
        session.evaluatedAt = now
        session.frame = frame
        session.remoteState = remoteState
        state.remediation = nil
        state.session = session
        if previousScreen?.kind != .videoFrame,
           frame.metadata.kind == .videoFrame
        {
            DeviceHubFeatureTrace.emit(
                "input_authorization_after_first_frame "
                    + "accepted=\(session.acceptsInput) "
                    + "hid=\(remoteState.hidReadiness) "
                    + "connection=\(remoteState.connection) "
                    + "revoked=\(session.revokedInputMetadata != nil)"
            )
        }
    }
}
