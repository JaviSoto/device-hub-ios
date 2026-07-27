/// Press or release edge for keys and physical buttons.
public enum InputPhase: Equatable, Sendable {
    case press
    case release
}

/// Touch lifecycle in target-pixel coordinates.
public enum TouchPhase: Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

/// One contact update in native target-pixel coordinates.
public struct TouchCommand: Equatable, Sendable {
    public let contactID: UInt8
    public let phase: TouchPhase
    public let point: TargetPixelPoint

    public init(
        contactID: UInt8,
        point: TargetPixelPoint,
        phase: TouchPhase
    ) {
        self.contactID = contactID
        self.phase = phase
        self.point = point
    }
}

/// Semantic keyboard key translated to device-specific HID only in the shell.
public enum DeviceKey: Equatable, Sendable {
    case character(Character)
    case delete
    case downArrow
    case escape
    case leftArrow
    case `return`
    case rightArrow
    case space
    case tab
    case upArrow
}

/// Platform-neutral modifier set translated only at the HID boundary.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

/// One keyboard edge with the complete modifier state for that edge.
public struct KeyCommand: Equatable, Sendable {
    public let key: DeviceKey
    public let modifiers: KeyModifiers
    public let phase: InputPhase

    public init(
        key: DeviceKey,
        phase: InputPhase,
        modifiers: KeyModifiers = []
    ) {
        self.key = key
        self.modifiers = modifiers
        self.phase = phase
    }
}

/// Semantic hardware controls supported by the remote device.
public enum DeviceButton: Equatable, Sendable {
    case home
    case lock
    case mute
    case siri
    case volumeDown
    case volumeUp
}

/// Relative display rotation supported by the remote device.
public enum DeviceRotation: CaseIterable, Equatable, Sendable {
    case rotateLeft
    case rotateRight
}

/// Semantic input command with no transport or device-service details.
///
/// Commands are intentionally not `Codable`: character input may be sensitive
/// and interaction history must never enter persistence or diagnostics.
public enum DeviceCommand: Equatable, Sendable {
    case tap(TargetPixelPoint)
    case touch(TouchCommand)
    case key(KeyCommand)
    /// One transport-atomic keyboard tap with identical press/release modifiers.
    case keyTap(DeviceKey, modifiers: KeyModifiers)
    case button(DeviceButton, phase: InputPhase)
    /// One transport-atomic hardware-button tap.
    case buttonTap(DeviceButton)
    case rotation(DeviceRotation)
    /// Cleanup-only barrier that releases every input held by this session.
    ///
    /// Ordinary input authorization must never accept this command. Session
    /// owners issue it while revoking authorization or before teardown.
    case releaseAllInput
}

/// A command tagged to the only session generation allowed to execute it.
public struct SessionCommand: Equatable, Sendable {
    public let command: DeviceCommand
    public let generation: SessionGeneration

    public init(
        generation: SessionGeneration,
        command: DeviceCommand
    ) {
        self.command = command
        self.generation = generation
    }
}

/// Ephemeral six-digit code shown only while a target requests pairing.
///
/// This type intentionally does not conform to `Codable`. Its standard and
/// reflected descriptions are redacted so logging a value cannot reveal it.
public struct PairingCode: CustomDebugStringConvertible, CustomReflectable, CustomStringConvertible, Equatable, Sendable {
    private let digits: String

    public init?(_ digits: String) {
        guard digits.utf8.count == 6,
              digits.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
              })
        else {
            return nil
        }
        self.digits = digits
    }

    /// The short-lived value the pairing UI must render.
    ///
    /// Callers must not persist, diagnose, or copy this value automatically.
    public var displayValue: String {
        digits
    }

    public var description: String {
        "<redacted pairing code>"
    }

    public var debugDescription: String {
        "PairingCode(<redacted>)"
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["value": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Progress events from the explicit, user-initiated pairing flow.
///
/// The code is ephemeral and redacts itself. Long-lived credentials never
/// enter this application-domain surface.
public enum PairingEvent: Equatable, Sendable {
    case advertising
    case waitingForCodeEntry(code: PairingCode)
    case saving
    case paired(DeviceSummary)
}
