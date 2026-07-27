import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Testing

@Suite("Native keyboard map")
struct NativeKeyboardMapTests {
    @Test("every printable ASCII character maps to its USB HID usage")
    func printableASCII() throws {
        let expectations =
            unshiftedLetterExpectations
                + shiftedLetterExpectations
                + unshiftedNumberRowExpectations
                + shiftedNumberRowExpectations
                + unshiftedPunctuationExpectations
                + shiftedPunctuationExpectations

        #expect(expectations.count == 95)
        #expect(Set(expectations.map(\.character)).count == 95)
        #expect(
            Set(expectations.map(\.character))
                == Set((32 ... 126).compactMap {
                    UnicodeScalar($0).map(Character.init)
                })
        )

        for expectation in expectations {
            let translation = try NativeKeyboardMap.translate(
                KeyCommand(
                    key: .character(expectation.character),
                    phase: .press
                )
            )

            #expect(
                translation.usage == expectation.usage,
                "Unexpected usage for ASCII value \(expectation.character.asciiValue ?? 0)."
            )
            #expect(
                translation.modifiers.rawValue == expectation.modifiers,
                "Unexpected modifiers for ASCII value \(expectation.character.asciiValue ?? 0)."
            )
            #expect(translation.phase == .press)
        }
    }

    @Test("caller modifiers use standard HID bits and combine with intrinsic Shift")
    func modifiers() throws {
        let callerModifiers: [KeyModifiers] = [
            .control,
            .shift,
            .option,
            .command,
            [.control, .option, .command]
        ]
        let expectedLowercaseMasks: [UInt8] = [
            0x01,
            0x02,
            0x04,
            0x08,
            0x0D
        ]
        let expectedUppercaseMasks: [UInt8] = [
            0x03,
            0x02,
            0x06,
            0x0A,
            0x0F
        ]

        let lowercaseMasks = try callerModifiers.map {
            try NativeKeyboardMap.translate(
                KeyCommand(
                    key: .character("a"),
                    phase: .release,
                    modifiers: $0
                )
            )
        }
        let uppercaseMasks = try callerModifiers.map {
            try NativeKeyboardMap.translate(
                KeyCommand(
                    key: .character("A"),
                    phase: .press,
                    modifiers: $0
                )
            )
        }

        expectNoDifference(
            lowercaseMasks.map(\.modifiers.rawValue),
            expectedLowercaseMasks
        )
        expectNoDifference(
            uppercaseMasks.map(\.modifiers.rawValue),
            expectedUppercaseMasks
        )
        #expect(lowercaseMasks.allSatisfy { $0.phase == .release })
        #expect(uppercaseMasks.allSatisfy { $0.phase == .press })
    }

    @Test("modeled special keys map to standard USB HID usages")
    func specialKeys() throws {
        let expectations: [(key: DeviceKey, usage: UInt16)] = [
            (.delete, 0x2A),
            (.downArrow, 0x51),
            (.escape, 0x29),
            (.leftArrow, 0x50),
            (.return, 0x28),
            (.rightArrow, 0x4F),
            (.space, 0x2C),
            (.tab, 0x2B),
            (.upArrow, 0x52)
        ]

        let translations = try expectations.map {
            try NativeKeyboardMap.translate(
                KeyCommand(
                    key: $0.key,
                    phase: .release,
                    modifiers: [.control, .command]
                )
            )
        }

        expectNoDifference(
            translations.map(\.usage),
            expectations.map(\.usage)
        )
        #expect(
            translations.allSatisfy {
                $0.modifiers == [.control, .command]
            }
        )
        #expect(translations.allSatisfy { $0.phase == .release })
    }

    @Test("unsupported characters fail without retaining or describing text")
    func unsupportedCharactersAreSanitized() {
        let unsupported: [Character] = [
            "\0",
            "\t",
            "\n",
            "\u{7F}",
            "é",
            "👨‍👩‍👧‍👦"
        ]

        for character in unsupported {
            do {
                _ = try NativeKeyboardMap.translate(
                    KeyCommand(
                        key: .character(character),
                        phase: .press
                    )
                )
                Issue.record("An unsupported character was translated.")
            } catch {
                expectNoDifference(
                    error,
                    NativeKeyboardMapError.unsupportedCharacter
                )
                let descriptions = [
                    String(describing: error),
                    String(reflecting: error),
                    String(customDumping: error)
                ]
                for description in descriptions {
                    #expect(description.lowercased().contains("redacted"))
                    #expect(!description.contains(String(character)))
                }
            }
        }
    }

    @Test("unknown modifier bits fail instead of being silently dropped")
    func unknownModifiersFail() {
        do {
            _ = try NativeKeyboardMap.translate(
                KeyCommand(
                    key: .character("a"),
                    phase: .press,
                    modifiers: KeyModifiers(rawValue: 0x90)
                )
            )
            Issue.record("Unknown modifier bits were silently dropped.")
        } catch {
            expectNoDifference(
                error,
                NativeKeyboardMapError.unsupportedModifiers
            )
            #expect(
                String(customDumping: error)
                    .lowercased()
                    .contains("redacted")
            )
        }
    }

    @Test("translated key material is redacted from descriptions")
    func translationsAreRedacted() throws {
        let translation = try NativeKeyboardMap.translate(
            KeyCommand(
                key: .character("q"),
                phase: .press,
                modifiers: [.command]
            )
        )

        let descriptions = [
            String(describing: translation),
            String(reflecting: translation),
            String(customDumping: translation)
        ]
        for description in descriptions {
            #expect(description.lowercased().contains("redacted"))
            #expect(!description.contains("usage"))
            #expect(!description.contains("20"))
        }
    }
}

private struct KeyboardExpectation {
    let character: Character
    let modifiers: UInt8
    let usage: UInt16
}

private let unshiftedLetterExpectations = zip(
    "abcdefghijklmnopqrstuvwxyz",
    UInt16(0x04) ... UInt16(0x1D)
).map {
    KeyboardExpectation(
        character: $0,
        modifiers: 0,
        usage: $1
    )
}

private let shiftedLetterExpectations = zip(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    UInt16(0x04) ... UInt16(0x1D)
).map {
    KeyboardExpectation(
        character: $0,
        modifiers: 0x02,
        usage: $1
    )
}

private let unshiftedNumberRowExpectations = zip(
    "1234567890",
    [
        UInt16(0x1E),
        0x1F,
        0x20,
        0x21,
        0x22,
        0x23,
        0x24,
        0x25,
        0x26,
        0x27
    ]
).map {
    KeyboardExpectation(
        character: $0,
        modifiers: 0,
        usage: $1
    )
}

private let shiftedNumberRowExpectations = zip(
    "!@#$%^&*()",
    [
        UInt16(0x1E),
        0x1F,
        0x20,
        0x21,
        0x22,
        0x23,
        0x24,
        0x25,
        0x26,
        0x27
    ]
).map {
    KeyboardExpectation(
        character: $0,
        modifiers: 0x02,
        usage: $1
    )
}

private let unshiftedPunctuationExpectations: [KeyboardExpectation] = [
    .init(character: " ", modifiers: 0, usage: 0x2C),
    .init(character: "-", modifiers: 0, usage: 0x2D),
    .init(character: "=", modifiers: 0, usage: 0x2E),
    .init(character: "[", modifiers: 0, usage: 0x2F),
    .init(character: "]", modifiers: 0, usage: 0x30),
    .init(character: "\\", modifiers: 0, usage: 0x31),
    .init(character: ";", modifiers: 0, usage: 0x33),
    .init(character: "'", modifiers: 0, usage: 0x34),
    .init(character: "`", modifiers: 0, usage: 0x35),
    .init(character: ",", modifiers: 0, usage: 0x36),
    .init(character: ".", modifiers: 0, usage: 0x37),
    .init(character: "/", modifiers: 0, usage: 0x38)
]

private let shiftedPunctuationExpectations: [KeyboardExpectation] = [
    .init(character: "_", modifiers: 0x02, usage: 0x2D),
    .init(character: "+", modifiers: 0x02, usage: 0x2E),
    .init(character: "{", modifiers: 0x02, usage: 0x2F),
    .init(character: "}", modifiers: 0x02, usage: 0x30),
    .init(character: "|", modifiers: 0x02, usage: 0x31),
    .init(character: ":", modifiers: 0x02, usage: 0x33),
    .init(character: "\"", modifiers: 0x02, usage: 0x34),
    .init(character: "~", modifiers: 0x02, usage: 0x35),
    .init(character: "<", modifiers: 0x02, usage: 0x36),
    .init(character: ">", modifiers: 0x02, usage: 0x37),
    .init(character: "?", modifiers: 0x02, usage: 0x38)
]
