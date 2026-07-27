#if os(iOS)
    import DeviceHubCore
    @testable import DeviceHubUI
    import Testing
    import UIKit

    @MainActor
    @Suite("Device keyboard pressed-key ownership")
    struct DeviceKeyboardReceiverTests {
        @Test("hidden keyboard responder never enters the accessibility tree")
        func responderIsAccessibilityHidden() {
            let textField = DeviceKeyboardTextField()

            #expect(!textField.isAccessibilityElement)
            #expect(textField.accessibilityElementsHidden)
        }

        @Test("software text emits semantic taps without synthetic key edges")
        func softwareTextTaps() {
            let textField = DeviceKeyboardTextField()
            var edgeCommands: [KeyCommand] = []
            var tappedKeys: [DeviceKey] = []
            var tappedModifiers: [KeyModifiers] = []
            textField.onKeyChanged = {
                edgeCommands.append($0)
            }
            textField.onKeyTapped = { key, modifiers in
                tappedKeys.append(key)
                tappedModifiers.append(modifiers)
            }

            textField.insertText("a ")
            textField.deleteBackward()

            #expect(
                tappedKeys
                    == [
                        .character("a"),
                        .space,
                        .delete
                    ]
            )
            let modifiersAreEmpty = tappedModifiers.allSatisfy(\.isEmpty)
            #expect(modifiersAreEmpty)
            #expect(edgeCommands.isEmpty)
        }

        @Test("closing releases held keys once in reverse press order")
        func releaseAll() {
            var ledger = DeviceKeyboardPressedKeyLedger()

            let escapePress = ledger.press(
                usage: .keyboardEscape,
                key: .escape,
                modifiers: [.command]
            )
            #expect(
                escapePress
                    == KeyCommand(
                        key: .escape,
                        phase: .press,
                        modifiers: [.command]
                    )
            )
            let tabPress = ledger.press(
                usage: .keyboardTab,
                key: .tab,
                modifiers: [.shift]
            )
            #expect(
                tabPress
                    == KeyCommand(
                        key: .tab,
                        phase: .press,
                        modifiers: [.shift]
                    )
            )
            let releases = ledger.releaseAll()
            #expect(
                releases
                    == [
                        KeyCommand(
                            key: .tab,
                            phase: .release,
                            modifiers: [.shift]
                        ),
                        KeyCommand(
                            key: .escape,
                            phase: .release,
                            modifiers: [.command]
                        )
                    ]
            )
            let repeatedReleases = ledger.releaseAll()
            #expect(repeatedReleases.isEmpty)
        }

        @Test("duplicate presses and already-released keys never double-send")
        func duplicateAndIndividualRelease() {
            var ledger = DeviceKeyboardPressedKeyLedger()

            _ = ledger.press(
                usage: .keyboardLeftArrow,
                key: .leftArrow,
                modifiers: []
            )
            let duplicatePress = ledger.press(
                usage: .keyboardLeftArrow,
                key: .leftArrow,
                modifiers: []
            )
            #expect(duplicatePress == nil)
            let release = ledger.release(usage: .keyboardLeftArrow)
            #expect(
                release
                    == KeyCommand(
                        key: .leftArrow,
                        phase: .release,
                        modifiers: []
                    )
            )
            let repeatedRelease = ledger.release(
                usage: .keyboardLeftArrow
            )
            #expect(repeatedRelease == nil)
            let trailingReleases = ledger.releaseAll()
            #expect(trailingReleases.isEmpty)
        }
    }
#endif
