import DeviceHubCore
import DeviceHubTransport

/// Sanitized failures produced before an input command reaches the FFI.
enum DeviceHubNativeCommandEncodingError:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Error,
    Equatable,
    Sendable
{
    case invalidCoordinate
    case invalidGeometry
    case missingGeometry
    case unsupportedContact
    case unsupportedKeyboard

    var description: String {
        "<redacted-native-command-encoding-failure>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: ["failure": "<redacted>"],
            displayStyle: .enum
        )
    }
}

/// Touch phases represented by Device Hub FFI ABI version 2.
enum DeviceHubEncodedTouchPhase: Equatable, Sendable {
    case cancel
    case down
    case move
    case tap
    case up
}

/// Keyboard phases represented by Device Hub FFI ABI version 2.
enum DeviceHubEncodedKeyboardPhase: Equatable, Sendable {
    case down
    case tap
    case up
}

/// Confirmed hardware buttons represented by Device Hub FFI ABI version 2.
enum DeviceHubEncodedButton: Equatable, Sendable {
    case home
    case lock
    case mute
    case siri
    case volumeDown
    case volumeUp
}

/// Hardware-button phases represented by Device Hub FFI ABI version 2.
enum DeviceHubEncodedButtonPhase: Equatable, Sendable {
    case down
    case tap
    case up
}

/// Relative rotations represented by Device Hub FFI ABI version 2.
enum DeviceHubEncodedRotation: Equatable, Sendable {
    case left
    case right
}

/// One validated, transport-ready input command without an attached session.
///
/// Descriptions are redacted because keyboard usages and coordinates can
/// reveal private interaction history.
enum DeviceHubEncodedCommand:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case button(
        button: DeviceHubEncodedButton,
        phase: DeviceHubEncodedButtonPhase
    )
    case keyboard(
        phase: DeviceHubEncodedKeyboardPhase,
        usage: UInt16,
        modifiers: UInt8
    )
    case releaseAll
    case rotation(DeviceHubEncodedRotation)
    case touch(
        phase: DeviceHubEncodedTouchPhase,
        x: UInt16,
        y: UInt16
    )

    var description: String {
        "<redacted-native-command>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: ["input": "<redacted>"],
            displayStyle: .enum
        )
    }
}

/// Pure conversion from semantic app commands to validated FFI values.
enum DeviceHubNativeCommandEncoder {
    /// Encodes one command, normalizing target pixels across the full `UInt16`
    /// touch range used by Device Hub FFI ABI version 2.
    static func encode(
        _ command: DeviceCommand,
        pixelSize: PixelSize?
    ) throws(DeviceHubNativeCommandEncodingError) -> DeviceHubEncodedCommand {
        switch command {
        case let .tap(point):
            let normalized = try normalize(
                point,
                pixelSize: pixelSize
            )
            return .touch(
                phase: .tap,
                x: normalized.x,
                y: normalized.y
            )

        case let .touch(command):
            guard command.contactID == 0 else {
                throw .unsupportedContact
            }
            if command.phase == .cancelled {
                return .touch(phase: .cancel, x: 0, y: 0)
            }

            let normalized = try normalize(
                command.point,
                pixelSize: pixelSize
            )
            let phase: DeviceHubEncodedTouchPhase = switch command.phase {
            case .began:
                .down
            case .moved:
                .move
            case .ended:
                .up
            case .cancelled:
                .cancel
            }
            return .touch(
                phase: phase,
                x: normalized.x,
                y: normalized.y
            )

        case let .key(command):
            let translation = try translate(command)
            let phase: DeviceHubEncodedKeyboardPhase =
                switch translation.phase {
                case .press:
                    .down
                case .release:
                    .up
                }
            return .keyboard(
                phase: phase,
                usage: translation.usage,
                modifiers: translation.modifiers.rawValue
            )

        case let .keyTap(key, modifiers):
            let translation = try translate(
                KeyCommand(
                    key: key,
                    phase: .press,
                    modifiers: modifiers
                )
            )
            return .keyboard(
                phase: .tap,
                usage: translation.usage,
                modifiers: translation.modifiers.rawValue
            )

        case let .button(button, phase):
            let encodedPhase: DeviceHubEncodedButtonPhase =
                switch phase {
                case .press:
                    .down
                case .release:
                    .up
                }
            return .button(
                button: encode(button),
                phase: encodedPhase
            )

        case let .buttonTap(button):
            return .button(
                button: encode(button),
                phase: .tap
            )

        case let .rotation(rotation):
            let encodedRotation: DeviceHubEncodedRotation =
                switch rotation {
                case .rotateLeft:
                    .left
                case .rotateRight:
                    .right
                }
            return .rotation(encodedRotation)

        case .releaseAllInput:
            return .releaseAll
        }
    }

    private static func encode(
        _ button: DeviceButton
    ) -> DeviceHubEncodedButton {
        switch button {
        case .home:
            .home
        case .lock:
            .lock
        case .mute:
            .mute
        case .siri:
            .siri
        case .volumeDown:
            .volumeDown
        case .volumeUp:
            .volumeUp
        }
    }

    private static func normalize(
        _ point: TargetPixelPoint,
        pixelSize: PixelSize?
    ) throws(DeviceHubNativeCommandEncodingError) -> (
        x: UInt16,
        y: UInt16
    ) {
        guard let pixelSize else {
            throw .missingGeometry
        }
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw .invalidGeometry
        }

        let maximumX = Double(pixelSize.width - 1)
        let maximumY = Double(pixelSize.height - 1)
        guard
            point.x.isFinite,
            point.y.isFinite,
            point.x >= 0,
            point.y >= 0,
            point.x <= maximumX,
            point.y <= maximumY
        else {
            throw .invalidCoordinate
        }

        return (
            normalize(point.x, maximum: maximumX),
            normalize(point.y, maximum: maximumY)
        )
    }

    private static func normalize(
        _ coordinate: Double,
        maximum: Double
    ) -> UInt16 {
        guard maximum > 0 else {
            return 0
        }
        let scaled =
            coordinate / maximum * Double(UInt16.max)
        return UInt16(scaled.rounded(.towardZero))
    }

    private static func translate(
        _ command: KeyCommand
    ) throws(DeviceHubNativeCommandEncodingError) -> NativeKeyboardTranslation {
        do {
            return try NativeKeyboardMap.translate(command)
        } catch {
            throw .unsupportedKeyboard
        }
    }
}
