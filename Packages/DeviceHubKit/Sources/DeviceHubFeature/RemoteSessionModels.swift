import DeviceHubClient
import DeviceHubCore
import Foundation

/// App lifecycle states that affect ownership of a private device session.
public enum DeviceHubAppLifecycle: Equatable, Sendable {
    case active
    case background
    case inactive
}

/// A sanitized problem and the single recovery action the regular UI presents.
public struct DeviceHubRemediation: Equatable, Sendable {
    /// Sanitized failure that determines the available recovery action.
    public let error: DeviceHubError
    /// User-facing guidance with protocol and transport details removed.
    public let message: String
    /// User-facing summary with protocol and transport details removed.
    public let title: String

    public init(error: DeviceHubError) {
        self.error = error
        message = error.userFacing.message
        title = error.userFacing.title
    }

    /// A visible button title only when the error defines a safe action.
    public var actionButtonTitle: String? {
        switch error.remedy {
        case .none:
            nil
        case .updateApp:
            "Show Update Steps"
        default:
            error.remedy.actionTitle
        }
    }
}

/// Complete, non-optional meaning for the title-menu state.
///
/// Keeping selection context and status together prevents a selected device
/// from being labeled as though no device were selected.
public enum RemoteSessionToolbarPresentation: Equatable, Sendable {
    /// The device hub has no selected target.
    case noSelection
    /// A selected target is known but cannot connect until it is paired.
    case pairingRequired(DeviceSummary)
    /// A selected paired target is connecting, streaming, or unavailable.
    case session(
        device: DeviceSummary,
        presentation: RemoteSessionPresentation
    )
    /// The user explicitly stopped viewing the selected target.
    case viewingStopped(DeviceSummary)
}

/// A non-navigation side effect that the app shell must perform explicitly.
///
/// This keeps URLs and platform services out of the feature while ensuring a
/// remediation button never degrades into a silent no-op.
public struct ExternalRemediationRequest: Equatable, Identifiable, Sendable {
    /// Identity used to acknowledge exactly the request the shell handled.
    public let id: UUID
    /// Platform or physical work the shell must present or perform.
    public let remedy: DeviceHubError.Remedy

    public init(id: UUID, remedy: DeviceHubError.Remedy) {
        self.id = id
        self.remedy = remedy
    }
}

/// One reducer-ordered command awaiting the active session's transport lane.
///
/// The reducer assigns sequence numbers before crossing an asynchronous
/// boundary, so task scheduling can never reorder strict touch or key edges.
struct PendingRemoteCommand: Equatable, Sendable {
    let attemptID: UUID
    let authorization: ScreenMetadata
    let command: DeviceCommand
    let sequenceNumber: UInt64
    let sessionID: DeviceSessionID
}

/// Feature-owned state for one selected connection attempt.
///
/// Pixel buffers are intentionally ephemeral: they are never codable,
/// printable, persisted, or copied into diagnostics. Equality compares image
/// identity and sanitized render metadata. The non-rendering command lane is
/// intentionally omitted so its bookkeeping never invalidates SwiftUI views.
public struct ActiveRemoteSession: Equatable, Sendable {
    /// Generation token for rejecting callbacks from superseded attempts.
    public let attemptID: UUID
    /// Latest sanitized transport failure, when the connection has ended.
    public var connectionError: DeviceHubError?
    /// Current availability metadata for the selected device.
    public var device: DeviceSummary
    /// Local controller time used by deterministic freshness and input checks.
    public var evaluatedAt: Date
    /// Latest decoded pixels, discarded on every ownership transition.
    public var frame: RemoteDisplayFrame?
    /// Media authorization most recently revoked by fail-safe input cleanup.
    ///
    /// A newer decoded video frame creates a distinct authorization without
    /// requiring mutable readiness flags that can drift from media truth.
    public var revokedInputMetadata: ScreenMetadata?
    /// Pure state machine for the active transport generation.
    public var remoteState: RemoteSessionState?
    /// Identity of the transport session currently owned by the coordinator.
    public var sessionID: DeviceSessionID?
    /// Next reducer-assigned position in this attempt's strict command order.
    var nextCommandSequenceNumber: UInt64
    /// Commands accepted by the reducer but not yet completed by the transport.
    var pendingCommands: [PendingRemoteCommand]

    public init(
        attemptID: UUID,
        device: DeviceSummary,
        evaluatedAt: Date
    ) {
        self.attemptID = attemptID
        connectionError = nil
        self.device = device
        self.evaluatedAt = evaluatedAt
        frame = nil
        revokedInputMetadata = nil
        remoteState = nil
        sessionID = nil
        nextCommandSequenceNumber = 0
        pendingCommands = []
    }

    /// Time-derived confidence in canonical transport media metadata.
    public var freshness: ScreenFreshness {
        ScreenFreshness.evaluate(
            metadata: remoteState?.latestScreen,
            at: evaluatedAt
        )
    }

    /// Calm status shown above the screen, derived without reading wall time.
    public var presentation: RemoteSessionPresentation {
        guard device.reachability == .reachable else {
            return .offline
        }
        if let connectionError {
            return .ended(connectionError)
        }
        guard let remoteState else {
            return .connecting(.locating)
        }

        switch remoteState.connection {
        case let .connecting(phase):
            return .connecting(phase)
        case let .ended(error):
            return .ended(error)
        case .connected:
            break
        }

        return switch freshness {
        case .awaitingFirstImage:
            .connecting(.startingDisplay)
        case .live:
            remoteState.latestScreen?.kind == .videoFrame
                && remoteState.hidReadiness == .ready
                ? .live
                : .viewingOnly
        }
    }

    /// True only while a current-generation frame and HID channel are safe.
    public var acceptsInput: Bool {
        guard connectionError == nil,
              let frame,
              let remoteState,
              frame.metadata.kind == .videoFrame,
              frame.metadata == remoteState.latestScreen,
              frame.metadata != revokedInputMetadata
        else {
            return false
        }
        return remoteState.acceptsInput(
            SessionCommand(
                generation: remoteState.generation,
                command: .tap(TargetPixelPoint(x: 0, y: 0))
            ),
            at: evaluatedAt
        )
    }

    public static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.attemptID == rhs.attemptID
            && lhs.connectionError == rhs.connectionError
            && lhs.device == rhs.device
            && lhs.evaluatedAt == rhs.evaluatedAt
            && framesAreIdentical(lhs.frame, rhs.frame)
            && lhs.revokedInputMetadata == rhs.revokedInputMetadata
            && lhs.remoteState == rhs.remoteState
            && lhs.sessionID == rhs.sessionID
    }

    private static func framesAreIdentical(
        _ lhs: RemoteDisplayFrame?,
        _ rhs: RemoteDisplayFrame?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.metadata == rhs.metadata
                && ObjectIdentifier(lhs.image) == ObjectIdentifier(rhs.image)
        case (.some, nil), (nil, .some):
            false
        }
    }
}
