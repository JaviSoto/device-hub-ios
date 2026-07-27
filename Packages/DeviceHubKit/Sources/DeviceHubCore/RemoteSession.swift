import Foundation

/// Identity of one connection generation.
///
/// Every reconnect must use a new value so callbacks and input from an old
/// connection can be rejected deterministically.
public struct SessionGeneration: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Calm, user-visible progress through remote-session setup.
public enum ConnectionPhase: String, CaseIterable, Codable, Equatable, Sendable {
    case locating
    case verifyingPairing
    case openingTunnel
    case discoveringServices
    case preparingDeveloperServices
    case capturingScreenshot
    case startingDisplay
    case ready

    public var title: String {
        switch self {
        case .locating:
            "Locating device…"
        case .verifyingPairing:
            "Verifying pairing…"
        case .openingTunnel:
            "Opening secure connection…"
        case .discoveringServices:
            "Discovering capabilities…"
        case .preparingDeveloperServices:
            "Preparing device…"
        case .capturingScreenshot:
            "Loading screen…"
        case .startingDisplay:
            "Starting live view…"
        case .ready:
            "Live"
        }
    }
}

/// Metadata for the initial still image; image bytes remain in the media layer.
public struct ScreenshotMetadata: Codable, Equatable, Sendable {
    public let generation: SessionGeneration
    public let orientation: ScreenOrientation
    public let pixelSize: PixelSize
    public let receivedAt: Date

    public init(
        generation: SessionGeneration,
        receivedAt: Date,
        pixelSize: PixelSize,
        orientation: ScreenOrientation
    ) {
        self.generation = generation
        self.orientation = orientation
        self.pixelSize = pixelSize
        self.receivedAt = receivedAt
    }
}

/// Metadata for a decoded live frame; frame buffers remain in the media layer.
public struct FrameMetadata: Codable, Equatable, Sendable {
    public let generation: SessionGeneration
    public let orientation: ScreenOrientation
    public let pixelSize: PixelSize
    public let receivedAt: Date
    public let sequenceNumber: UInt64

    public init(
        generation: SessionGeneration,
        sequenceNumber: UInt64,
        receivedAt: Date,
        pixelSize: PixelSize,
        orientation: ScreenOrientation
    ) {
        self.generation = generation
        self.orientation = orientation
        self.pixelSize = pixelSize
        self.receivedAt = receivedAt
        self.sequenceNumber = sequenceNumber
    }
}

/// Latest renderable screen metadata without ownership of sensitive pixels.
public enum ScreenMetadata: Codable, Equatable, Sendable {
    case screenshot(ScreenshotMetadata)
    case videoFrame(FrameMetadata)

    public enum Kind: Codable, Equatable, Sendable {
        case screenshot
        case videoFrame
    }

    /// Local controller time when the media layer received this image.
    ///
    /// Freshness must never use a target-generated timestamp because the two
    /// devices' clocks can differ or change independently.
    public var receivedAt: Date {
        switch self {
        case let .screenshot(metadata):
            metadata.receivedAt
        case let .videoFrame(metadata):
            metadata.receivedAt
        }
    }

    public var generation: SessionGeneration {
        switch self {
        case let .screenshot(metadata):
            metadata.generation
        case let .videoFrame(metadata):
            metadata.generation
        }
    }

    public var kind: Kind {
        switch self {
        case .screenshot:
            .screenshot
        case .videoFrame:
            .videoFrame
        }
    }

    public var orientation: ScreenOrientation {
        switch self {
        case let .screenshot(metadata):
            metadata.orientation
        case let .videoFrame(metadata):
            metadata.orientation
        }
    }

    public var pixelSize: PixelSize {
        switch self {
        case let .screenshot(metadata):
            metadata.pixelSize
        case let .videoFrame(metadata):
            metadata.pixelSize
        }
    }
}

/// Whether the owned session has produced a decoded live-video frame.
///
/// A screenshot is only a provisional first visual. Native transport timeout
/// and termination events own liveness because both initial video startup and
/// a static encoder may legitimately emit no new pixels for several seconds.
public enum ScreenFreshness: Codable, Equatable, Sendable {
    case awaitingFirstImage
    case live

    public static func evaluate(
        metadata: ScreenMetadata?,
        at _: Date
    ) -> Self {
        guard metadata?.kind == .videoFrame else {
            return .awaitingFirstImage
        }
        return .live
    }
}

/// Whether input channels are ready for serialized semantic commands.
///
/// The transport may enter `.ready` only after its explicit authenticated
/// input-ready signal. Connection phase and display geometry never imply HID
/// readiness.
public enum HIDReadiness: Codable, Equatable, Sendable {
    case connecting
    case ready
    case unavailable
}

/// Connection lifecycle separate from screen freshness and input readiness.
public enum SessionConnection: Codable, Equatable, Sendable {
    case connecting(ConnectionPhase)
    case connected
    case ended(DeviceHubError?)
}

/// Small status vocabulary presented above the remote canvas.
public enum RemoteSessionPresentation: Equatable, Sendable {
    case connecting(ConnectionPhase)
    case live
    case offline
    case viewingOnly
    case ended(DeviceHubError?)

    public var title: String {
        switch self {
        case let .connecting(phase):
            phase.title
        case .live:
            "Live"
        case .offline:
            "Offline"
        case .viewingOnly:
            "Viewing only"
        case let .ended(error):
            error?.userFacing.title ?? "Session ended"
        }
    }
}

/// Events emitted by the session shell into the pure application domain.
public enum DeviceSessionEvent: Equatable, Sendable {
    case phaseChanged(ConnectionPhase)
    case deviceInfoUpdated(DeviceSummary)
    case screenshot(ScreenshotMetadata)
    case displayReady
    case videoFrame(FrameMetadata)
    case hidReadinessChanged(HIDReadiness)
    case reachabilityChanged(DeviceReachability)
    case reconnected(SessionGeneration)
    case ended(DeviceHubError?)
}

/// Generation-tagged event used to reject callbacks from torn-down sessions.
public struct SessionUpdate: Equatable, Sendable {
    public let event: DeviceSessionEvent
    public let generation: SessionGeneration

    public init(
        generation: SessionGeneration,
        event: DeviceSessionEvent
    ) {
        self.event = event
        self.generation = generation
    }
}

/// Why a session state machine accepted or rejected an incoming update.
public enum SessionUpdateDisposition: Equatable, Sendable {
    case accepted
    case rejectedOutOfOrderMedia
    case rejectedStaleGeneration
    case rejectedWrongDevice
}

/// Pure state machine for one selected remote device.
public struct RemoteSessionState: Equatable, Sendable {
    public let deviceID: DeviceID
    public private(set) var connection: SessionConnection
    public private(set) var deviceSummary: DeviceSummary?
    public private(set) var generation: SessionGeneration
    public private(set) var hidReadiness: HIDReadiness
    public private(set) var latestScreen: ScreenMetadata?
    public private(set) var reachability: DeviceReachability

    public init(
        deviceID: DeviceID,
        generation: SessionGeneration,
        reachability: DeviceReachability = .reachable
    ) {
        connection = .connecting(.locating)
        self.deviceID = deviceID
        deviceSummary = nil
        self.generation = generation
        hidReadiness = .connecting
        latestScreen = nil
        self.reachability = reachability
    }

    /// Applies an event only when its generation and embedded metadata match.
    @discardableResult
    public mutating func apply(
        _ update: SessionUpdate
    ) -> SessionUpdateDisposition {
        guard update.generation == generation else {
            return .rejectedStaleGeneration
        }

        switch update.event {
        case let .phaseChanged(phase):
            connection = phase == .ready ? .connected : .connecting(phase)

        case let .deviceInfoUpdated(summary):
            guard summary.id == deviceID else {
                return .rejectedWrongDevice
            }
            deviceSummary = summary
            reachability = summary.reachability

        case let .screenshot(metadata):
            guard metadata.generation == generation else {
                return .rejectedStaleGeneration
            }
            if let latestScreen {
                guard latestScreen.kind == .screenshot,
                      metadata.receivedAt >= latestScreen.receivedAt
                else {
                    return .rejectedOutOfOrderMedia
                }
            }
            latestScreen = .screenshot(metadata)

        case .displayReady:
            connection = .connected

        case let .videoFrame(metadata):
            guard metadata.generation == generation else {
                return .rejectedStaleGeneration
            }
            if let latestScreen {
                guard metadata.receivedAt >= latestScreen.receivedAt else {
                    return .rejectedOutOfOrderMedia
                }
                if case let .videoFrame(currentFrame) = latestScreen {
                    guard metadata.sequenceNumber > currentFrame.sequenceNumber
                    else {
                        return .rejectedOutOfOrderMedia
                    }
                }
            }
            latestScreen = .videoFrame(metadata)

        case let .hidReadinessChanged(readiness):
            hidReadiness = readiness

        case let .reachabilityChanged(reachability):
            self.reachability = reachability

        case let .reconnected(nextGeneration):
            guard nextGeneration != generation else {
                return .rejectedStaleGeneration
            }
            generation = nextGeneration
            connection = .connecting(.locating)
            hidReadiness = .connecting
            latestScreen = nil
            reachability = .reachable

        case let .ended(error):
            connection = .ended(error)
            hidReadiness = .unavailable
        }

        return .accepted
    }

    /// Derives display copy while ensuring old pixels are never called live.
    public func presentation(at now: Date) -> RemoteSessionPresentation {
        if reachability == .unavailable {
            return .offline
        }

        switch connection {
        case let .connecting(phase):
            return .connecting(phase)
        case let .ended(error):
            return .ended(error)
        case .connected:
            break
        }

        return switch ScreenFreshness.evaluate(
            metadata: latestScreen,
            at: now
        ) {
        case .awaitingFirstImage:
            .connecting(.startingDisplay)
        case .live:
            latestScreen?.kind == .videoFrame
                && hidReadiness == .ready
                ? .live
                : .viewingOnly
        }
    }

    /// Accepts input only for this generation, a live frame, and ready HID.
    public func acceptsInput(
        _ command: SessionCommand,
        at now: Date
    ) -> Bool {
        guard command.generation == generation,
              reachability == .reachable,
              connection == .connected,
              hidReadiness == .ready,
              latestScreen?.kind == .videoFrame
        else {
            return false
        }
        guard command.command != .releaseAllInput else {
            return false
        }
        return ScreenFreshness.evaluate(
            metadata: latestScreen,
            at: now
        ) == .live
    }
}
