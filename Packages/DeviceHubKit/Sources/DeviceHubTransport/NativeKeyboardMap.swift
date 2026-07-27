import DeviceHubCore

/// Standard left-side USB HID keyboard modifier bits.
///
/// These values intentionally match the USB HID boot-keyboard modifier byte:
/// Control is `0x01`, Shift is `0x02`, Option/Alt is `0x04`, and Command/GUI
/// is `0x08`.
public struct NativeKeyboardModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 0x01)
    public static let shift = Self(rawValue: 0x02)
    public static let option = Self(rawValue: 0x04)
    public static let command = Self(rawValue: 0x08)
}

/// One semantic keyboard edge translated to the USB Keyboard/Keypad page.
///
/// Descriptions are redacted because a usage can reveal typed text.
public struct NativeKeyboardTranslation:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let modifiers: NativeKeyboardModifiers
    public let phase: InputPhase
    public let usage: UInt16

    fileprivate init(
        usage: UInt16,
        modifiers: NativeKeyboardModifiers,
        phase: InputPhase
    ) {
        self.modifiers = modifiers
        self.phase = phase
        self.usage = usage
    }

    public var description: String {
        "<redacted-native-keyboard-translation>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["input": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Sanitized local mapping failure that never retains the attempted key.
public enum NativeKeyboardMapError:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Error,
    Equatable,
    Sendable
{
    /// The character is not one printable US-ASCII keyboard character.
    case unsupportedCharacter

    /// The caller supplied a modifier bit outside ``KeyModifiers``' known set.
    case unsupportedModifiers

    public var description: String {
        "<redacted-native-keyboard-map-failure>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["failure": "<redacted>"],
            displayStyle: .enum
        )
    }
}

/// Pure translation from app-domain keyboard commands to USB HID usages.
public enum NativeKeyboardMap {
    /// Translates one key edge using standard US-layout Keyboard/Keypad usages.
    ///
    /// Caller modifiers are converted by semantic meaning, not copied from
    /// `KeyModifiers.rawValue`. Uppercase letters and shifted punctuation
    /// add Shift without removing any caller-supplied modifier.
    public static func translate(
        _ command: KeyCommand
    ) throws(NativeKeyboardMapError) -> NativeKeyboardTranslation {
        let mapping: (usage: UInt16, requiresShift: Bool) = switch command.key {
        case let .character(character):
            try printableASCIIMapping(for: character)
        case .delete:
            (0x2A, false)
        case .downArrow:
            (0x51, false)
        case .escape:
            (0x29, false)
        case .leftArrow:
            (0x50, false)
        case .return:
            (0x28, false)
        case .rightArrow:
            (0x4F, false)
        case .space:
            (0x2C, false)
        case .tab:
            (0x2B, false)
        case .upArrow:
            (0x52, false)
        }

        var modifiers = try nativeModifiers(for: command.modifiers)
        if mapping.requiresShift {
            modifiers.insert(.shift)
        }
        return NativeKeyboardTranslation(
            usage: mapping.usage,
            modifiers: modifiers,
            phase: command.phase
        )
    }

    private static func nativeModifiers(
        for modifiers: KeyModifiers
    ) throws(NativeKeyboardMapError) -> NativeKeyboardModifiers {
        let supportedRawValue =
            KeyModifiers.command.rawValue
                | KeyModifiers.control.rawValue
                | KeyModifiers.option.rawValue
                | KeyModifiers.shift.rawValue
        guard modifiers.rawValue & ~supportedRawValue == 0 else {
            throw .unsupportedModifiers
        }

        var native: NativeKeyboardModifiers = []
        if modifiers.contains(.control) {
            native.insert(.control)
        }
        if modifiers.contains(.shift) {
            native.insert(.shift)
        }
        if modifiers.contains(.option) {
            native.insert(.option)
        }
        if modifiers.contains(.command) {
            native.insert(.command)
        }
        return native
    }

    private static func printableASCIIMapping(
        for character: Character
    ) throws(NativeKeyboardMapError) -> (
        usage: UInt16,
        requiresShift: Bool
    ) {
        guard let ascii = character.asciiValue else {
            throw .unsupportedCharacter
        }

        switch ascii {
        case 0x61 ... 0x7A:
            return (UInt16(ascii - 0x61) + 0x04, false)
        case 0x41 ... 0x5A:
            return (UInt16(ascii - 0x41) + 0x04, true)
        default:
            if let usage = unshiftedASCIIUsages[ascii] {
                return (usage, false)
            }
            if let usage = shiftedASCIIUsages[ascii] {
                return (usage, true)
            }
            throw NativeKeyboardMapError.unsupportedCharacter
        }
    }

    private static let unshiftedASCIIUsages: [UInt8: UInt16] = [
        0x20: 0x2C,
        0x27: 0x34,
        0x2C: 0x36,
        0x2D: 0x2D,
        0x2E: 0x37,
        0x2F: 0x38,
        0x30: 0x27,
        0x31: 0x1E,
        0x32: 0x1F,
        0x33: 0x20,
        0x34: 0x21,
        0x35: 0x22,
        0x36: 0x23,
        0x37: 0x24,
        0x38: 0x25,
        0x39: 0x26,
        0x3B: 0x33,
        0x3D: 0x2E,
        0x5B: 0x2F,
        0x5C: 0x31,
        0x5D: 0x30,
        0x60: 0x35
    ]

    private static let shiftedASCIIUsages: [UInt8: UInt16] = [
        0x21: 0x1E,
        0x22: 0x34,
        0x23: 0x20,
        0x24: 0x21,
        0x25: 0x22,
        0x26: 0x24,
        0x28: 0x26,
        0x29: 0x27,
        0x2A: 0x25,
        0x2B: 0x2E,
        0x3A: 0x33,
        0x3C: 0x36,
        0x3E: 0x37,
        0x3F: 0x38,
        0x40: 0x1F,
        0x5E: 0x23,
        0x5F: 0x2D,
        0x7B: 0x2F,
        0x7C: 0x31,
        0x7D: 0x30,
        0x7E: 0x35
    ]
}
