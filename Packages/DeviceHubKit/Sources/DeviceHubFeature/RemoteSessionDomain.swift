import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import Foundation

public extension RemoteSessionFeature {
    /// Complete, renderable state for the screen-first device hub experience.
    ///
    /// Transport handles and durable pairing secrets deliberately live outside
    /// this value. The only pixel ownership is the short-lived active frame.
    @ObservableState
    struct State: Equatable {
        /// Touch contacts whose begin event was accepted by the current session.
        public var activeContactIDs: Set<UInt8>
        /// Device whose detail presentation is currently visible.
        public var detailsDeviceID: DeviceID?
        /// Platform work the app shell must complete outside the reducer.
        public var externalRemediation: ExternalRemediationRequest?
        /// Whether the initial durable roster request is outstanding.
        public var isLoadingRoster: Bool
        /// Whether a continuous availability stream is being observed.
        public var isObservingAvailability: Bool
        /// Explicit user preference to keep the selected device disconnected.
        public var isViewingStopped: Bool
        /// App lifecycle used to enforce session and input ownership.
        public var lifecycle: DeviceHubAppLifecycle
        /// Short-lived explicit pairing presentation.
        @Presents public var pairing: PairingFeature.State?
        /// Sanitized recovery guidance for the latest user-visible failure.
        public var remediation: DeviceHubRemediation?
        /// Canonical sorted roster of known paired devices.
        public var roster: DeviceRoster
        /// Stable selection retained across temporary availability loss.
        public var selectedDeviceID: DeviceID?
        /// Ephemeral state for the one connection attempt owned by the feature.
        public var session: ActiveRemoteSession?

        public init(
            activeContactIDs: Set<UInt8> = [],
            detailsDeviceID: DeviceID? = nil,
            externalRemediation: ExternalRemediationRequest? = nil,
            isLoadingRoster: Bool = false,
            isObservingAvailability: Bool = false,
            isViewingStopped: Bool = false,
            lifecycle: DeviceHubAppLifecycle = .active,
            pairing: PairingFeature.State? = nil,
            remediation: DeviceHubRemediation? = nil,
            roster: DeviceRoster = DeviceRoster(),
            selectedDeviceID: DeviceID? = nil,
            session: ActiveRemoteSession? = nil
        ) {
            self.activeContactIDs = activeContactIDs
            self.detailsDeviceID = detailsDeviceID
            self.externalRemediation = externalRemediation
            self.isLoadingRoster = isLoadingRoster
            self.isObservingAvailability = isObservingAvailability
            self.isViewingStopped = isViewingStopped
            self.lifecycle = lifecycle
            self.pairing = pairing
            self.remediation = remediation
            self.roster = roster
            self.selectedDeviceID = selectedDeviceID
            self.session = session
        }

        public var selectedDevice: DeviceSummary? {
            guard let selectedDeviceID else {
                return nil
            }
            return roster.devices.first { $0.id == selectedDeviceID }
        }

        /// Explicit title-menu state derived with the same precedence as the
        /// remote canvas.
        public var toolbarPresentation: RemoteSessionToolbarPresentation {
            guard let selectedDevice else {
                return .noSelection
            }
            if let remediation {
                return .session(
                    device: selectedDevice,
                    presentation: .ended(remediation.error)
                )
            }
            if isViewingStopped {
                return .viewingStopped(selectedDevice)
            }
            if selectedDevice.pairingState == .requiresPairing {
                return .pairingRequired(selectedDevice)
            }
            return .session(
                device: selectedDevice,
                presentation: session?.presentation
                    ?? (
                        selectedDevice.reachability == .reachable
                            ? .connecting(.locating)
                            : .offline
                    )
            )
        }

        public var sessionPresentation: RemoteSessionPresentation? {
            switch toolbarPresentation {
            case .noSelection,
                 .pairingRequired,
                 .viewingStopped:
                nil
            case let .session(_, presentation):
                presentation
            }
        }

        /// Central UI gate used by every touch, key, and hardware-button action.
        public var acceptsInput: Bool {
            lifecycle == .active && session?.acceptsInput == true
        }
    }

    /// User intents and dependency responses understood by the root feature.
    @CasePathable
    enum Action {
        case appLifecycleChanged(DeviceHubAppLifecycle)
        case availabilityObservationFinished
        case availabilitySnapshotReceived([DeviceSummary])
        case buttonTapped(DeviceButton)
        case commandFailed(
            attemptID: UUID,
            sessionID: DeviceSessionID,
            error: DeviceHubError
        )
        case commandFinished(
            attemptID: UUID,
            sessionID: DeviceSessionID,
            sequenceNumber: UInt64
        )
        case connectionResponse(
            attemptID: UUID,
            deviceID: DeviceID,
            result: Result<DeviceSession, DeviceHubError>
        )
        case detailsButtonTapped
        case detailsDismissed
        case deviceSelected(DeviceID)
        case externalRemediationHandled(UUID)
        case frameReceived(
            attemptID: UUID,
            sessionID: DeviceSessionID,
            frame: RemoteDisplayFrame
        )
        case frameStreamFinished(
            attemptID: UUID,
            sessionID: DeviceSessionID
        )
        case inputCleanupFailed(
            attemptID: UUID,
            sessionID: DeviceSessionID?,
            error: DeviceHubError
        )
        case keyChanged(KeyCommand)
        case keyTapped(DeviceKey, modifiers: KeyModifiers)
        case pairDeviceButtonTapped
        case pairedDevicesResponse(
            Result<[DeviceSummary], DeviceHubError>
        )
        case pairing(PresentationAction<PairingFeature.Action>)
        case remediationButtonTapped
        case remediationDismissed
        case retrySelectedDevice
        case rotateRightButtonTapped
        case sessionEventsFinished(
            attemptID: UUID,
            sessionID: DeviceSessionID
        )
        case sessionStreamFailed(
            attemptID: UUID,
            sessionID: DeviceSessionID,
            error: DeviceHubError
        )
        case sessionUpdateReceived(
            attemptID: UUID,
            sessionID: DeviceSessionID,
            update: SessionUpdate
        )
        case startViewingButtonTapped
        case stopViewingButtonTapped
        case tap(point: Point2D, viewport: Viewport)
        case task
        case touch(
            contactID: UInt8,
            phase: TouchPhase,
            point: Point2D,
            viewport: Viewport
        )
    }
}
