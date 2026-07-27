import ComposableArchitecture
import DeviceHubCore

extension RemoteSessionFeature {
    func reduceInput(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case let .buttonTapped(button):
            return sendCommandIfAllowed(
                .buttonTap(button),
                state: &state
            )

        case let .commandFailed(attemptID, sessionID, error):
            guard var session = state.session,
                  session.attemptID == attemptID,
                  session.sessionID == sessionID
            else {
                return .none
            }
            session.pendingCommands.removeAll(keepingCapacity: false)
            session.connectionError = error
            state.session = session
            state.remediation = DeviceHubRemediation(error: error)
            return .concatenate(
                revokeInput(state: &state),
                .cancel(id: CancelID.commands)
            )

        case let .commandFinished(
            attemptID,
            sessionID,
            sequenceNumber
        ):
            guard var session = state.session,
                  session.attemptID == attemptID,
                  session.sessionID == sessionID,
                  session.pendingCommands.first?.sequenceNumber
                  == sequenceNumber
            else {
                return .none
            }
            session.pendingCommands.removeFirst()
            let nextCommand = session.pendingCommands.first
            state.session = session
            guard let nextCommand else {
                return .none
            }
            return sendPendingCommand(nextCommand)

        case let .inputCleanupFailed(attemptID, sessionID, error):
            guard var session = state.session,
                  session.attemptID == attemptID,
                  sessionID == nil || session.sessionID == sessionID
            else {
                return .none
            }
            session.connectionError = error
            state.session = session
            state.remediation = DeviceHubRemediation(error: error)
            return .none

        case let .keyChanged(command):
            return sendCommandIfAllowed(
                .key(command),
                state: &state
            )

        case let .keyTapped(key, modifiers):
            return sendCommandIfAllowed(
                .keyTap(key, modifiers: modifiers),
                state: &state
            )

        case .rotateRightButtonTapped:
            return sendCommandIfAllowed(
                .rotation(.rotateRight),
                state: &state
            )

        case let .tap(point, viewport):
            DeviceHubFeatureTrace.emit(.touchTap)
            guard let session = state.session,
                  let metadata = session.frame?.metadata,
                  let mappedPoint = RemoteCoordinateMapper.mapInitialTouch(
                      point,
                      in: viewport,
                      targetPixels: metadata.pixelSize,
                      orientation: metadata.orientation
                  )
            else {
                return .none
            }
            return sendCommandIfAllowed(
                .tap(mappedPoint),
                state: &state
            )

        case let .touch(contactID, phase, point, viewport):
            return handleTouch(
                state: &state,
                contactID: contactID,
                phase: phase,
                point: point,
                viewport: viewport
            )

        default:
            return .none
        }
    }

    private func handleTouch(
        state: inout State,
        contactID: UInt8,
        phase: TouchPhase,
        point: Point2D,
        viewport: Viewport
    ) -> Effect<Action> {
        guard state.acceptsInput,
              let metadata = state.session?.frame?.metadata
        else {
            return .none
        }

        let targetPoint: TargetPixelPoint?
        switch phase {
        case .began:
            targetPoint = RemoteCoordinateMapper.mapInitialTouch(
                point,
                in: viewport,
                targetPixels: metadata.pixelSize,
                orientation: metadata.orientation
            )
            guard targetPoint != nil else {
                return .none
            }
            state.activeContactIDs.insert(contactID)

        case .moved:
            guard state.activeContactIDs.contains(contactID) else {
                return .none
            }
            targetPoint = mappedPoint(
                point,
                viewport: viewport,
                metadata: metadata
            )

        case .cancelled, .ended:
            guard state.activeContactIDs.remove(contactID) != nil else {
                return .none
            }
            targetPoint = mappedPoint(
                point,
                viewport: viewport,
                metadata: metadata
            )
        }

        guard let targetPoint else {
            return .none
        }
        return sendCommandIfAllowed(
            .touch(
                TouchCommand(
                    contactID: contactID,
                    point: targetPoint,
                    phase: phase
                )
            ),
            state: &state
        )
    }

    private func mappedPoint(
        _ point: Point2D,
        viewport: Viewport,
        metadata: ScreenMetadata
    ) -> TargetPixelPoint? {
        RemoteCoordinateMapper.map(
            point,
            in: viewport,
            targetPixels: metadata.pixelSize,
            orientation: metadata.orientation
        )?.point
    }

    private func sendCommandIfAllowed(
        _ command: DeviceCommand,
        state: inout State
    ) -> Effect<Action> {
        let traceKind = command.traceKind
        let wasAcceptingInput = state.acceptsInput
        DeviceHubFeatureTrace.emit(
            "input_intent kind=\(traceKind) "
                + "authorized=\(wasAcceptingInput)"
        )
        let now = date.now
        if var session = state.session {
            session.evaluatedAt = now
            state.session = session
        }

        guard state.acceptsInput else {
            DeviceHubFeatureTrace.emit(
                "input_blocked kind=\(traceKind)"
            )
            guard wasAcceptingInput else {
                return .none
            }
            return .concatenate(
                revokeInput(state: &state),
                .cancel(id: CancelID.commands)
            )
        }
        guard let session = state.session,
              let sessionID = session.sessionID,
              let remoteState = session.remoteState,
              let authorization = session.frame?.metadata
        else {
            return .none
        }
        guard remoteState.acceptsInput(
            SessionCommand(
                generation: remoteState.generation,
                command: command
            ),
            at: now
        ) else {
            DeviceHubFeatureTrace.emit(
                "input_generation_rejected kind=\(traceKind)"
            )
            return .concatenate(
                revokeInput(state: &state),
                .cancel(id: CancelID.commands)
            )
        }

        var mutableSession = session
        let pendingCommand = PendingRemoteCommand(
            attemptID: session.attemptID,
            authorization: authorization,
            command: command,
            sequenceNumber: session.nextCommandSequenceNumber,
            sessionID: sessionID
        )
        mutableSession.nextCommandSequenceNumber &+= 1
        mutableSession.pendingCommands.append(pendingCommand)
        let shouldStartCommand = mutableSession.pendingCommands.count == 1
        state.session = mutableSession
        guard shouldStartCommand else {
            return .none
        }
        return sendPendingCommand(pendingCommand)
    }

    /// Executes only the head of the reducer-owned command queue.
    private func sendPendingCommand(
        _ pendingCommand: PendingRemoteCommand
    ) -> Effect<Action> {
        let traceKind = pendingCommand.command.traceKind
        let sessionCoordinator = sessionCoordinator
        return .run { send in
            do {
                try await sessionCoordinator.command(
                    pendingCommand.command,
                    attemptID: pendingCommand.attemptID,
                    sessionID: pendingCommand.sessionID,
                    authorization: pendingCommand.authorization
                )
                DeviceHubFeatureTrace.emit(
                    "input_enqueued kind=\(traceKind)"
                )
                await send(
                    .commandFinished(
                        attemptID: pendingCommand.attemptID,
                        sessionID: pendingCommand.sessionID,
                        sequenceNumber: pendingCommand.sequenceNumber
                    )
                )
            } catch is CancellationError {
                DeviceHubFeatureTrace.emit(
                    "input_cancelled kind=\(traceKind)"
                )
                return
            } catch let error as DeviceHubError {
                DeviceHubFeatureTrace.emit(
                    "input_failed kind=\(traceKind) "
                        + "error=\(String(describing: error))"
                )
                await send(
                    .commandFailed(
                        attemptID: pendingCommand.attemptID,
                        sessionID: pendingCommand.sessionID,
                        error: error
                    )
                )
            } catch {
                DeviceHubFeatureTrace.emit(
                    "input_failed kind=\(traceKind) "
                        + "error=secureConnectionFailed"
                )
                await send(
                    .commandFailed(
                        attemptID: pendingCommand.attemptID,
                        sessionID: pendingCommand.sessionID,
                        error: .secureConnectionFailed
                    )
                )
            }
        }
        .cancellable(id: CancelID.commands)
    }
}

private extension DeviceCommand {
    var traceKind: String {
        switch self {
        case let .button(button, _), let .buttonTap(button):
            "button_\(button)"
        case .key:
            "keyboard_edge"
        case .keyTap:
            "keyboard_tap"
        case .releaseAllInput:
            "release_all"
        case .rotation:
            "rotation"
        case .tap:
            "touch_tap"
        case .touch:
            "touch_edge"
        }
    }
}
