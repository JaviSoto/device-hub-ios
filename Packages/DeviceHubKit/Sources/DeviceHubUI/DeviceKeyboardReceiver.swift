import DeviceHubCore
import SwiftUI

/// Zero-content responder that forwards keyboard edges without retaining text.
///
/// Software and hardware keyboard input is emitted directly as semantic key
/// commands. Typed characters never enter SwiftUI state, persistence, logs, or
/// automatic clipboard synchronization.
struct DeviceKeyboardReceiver: View {
    @Binding var isPresented: Bool

    let keyChanged: (KeyCommand) -> Void
    let keyTapped: (DeviceKey, KeyModifiers) -> Void

    var body: some View {
        #if os(iOS)
            DeviceKeyboardTextFieldRepresentable(
                isPresented: $isPresented,
                keyChanged: keyChanged,
                keyTapped: keyTapped
            )
        #else
            EmptyView()
        #endif
    }
}

#if os(iOS)
    import UIKit

    private struct DeviceKeyboardTextFieldRepresentable: UIViewRepresentable {
        @Binding var isPresented: Bool

        let keyChanged: (KeyCommand) -> Void
        let keyTapped: (DeviceKey, KeyModifiers) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                isPresented: $isPresented,
                keyChanged: keyChanged,
                keyTapped: keyTapped
            )
        }

        func makeUIView(context: Context) -> DeviceKeyboardTextField {
            let textField = DeviceKeyboardTextField()
            textField.onDone = context.coordinator.doneButtonTapped
            textField.onKeyChanged = context.coordinator.keyChanged
            textField.onKeyTapped = context.coordinator.keyTapped
            return textField
        }

        func updateUIView(
            _ textField: DeviceKeyboardTextField,
            context: Context
        ) {
            context.coordinator.isPresented = $isPresented
            context.coordinator.keyChanged = keyChanged
            context.coordinator.keyTapped = keyTapped

            textField.setPresented(isPresented)
        }

        static func dismantleUIView(
            _ textField: DeviceKeyboardTextField,
            coordinator: Coordinator
        ) {
            textField.setPresented(false)
        }

        @MainActor
        final class Coordinator {
            var isPresented: Binding<Bool>
            var keyChanged: (KeyCommand) -> Void
            var keyTapped: (DeviceKey, KeyModifiers) -> Void

            init(
                isPresented: Binding<Bool>,
                keyChanged: @escaping (KeyCommand) -> Void,
                keyTapped: @escaping (DeviceKey, KeyModifiers) -> Void
            ) {
                self.isPresented = isPresented
                self.keyChanged = keyChanged
                self.keyTapped = keyTapped
            }

            func doneButtonTapped() {
                isPresented.wrappedValue = false
            }
        }
    }

    @MainActor
    final class DeviceKeyboardTextField: UITextField, UITextFieldDelegate {
        var onDone: () -> Void = {}
        var onKeyChanged: (KeyCommand) -> Void = { _ in }
        var onKeyTapped: (DeviceKey, KeyModifiers) -> Void = { _, _ in }

        private var isPresentationRequested = false
        private var pressedSpecialKeys = DeviceKeyboardPressedKeyLedger()

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("DeviceKeyboardTextField is created programmatically.")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronizePresentation()
        }

        override func deleteBackward() {
            tap(.delete)
        }

        override func resignFirstResponder() -> Bool {
            releasePressedSpecialKeys()
            return super.resignFirstResponder()
        }

        override func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            var unhandledPresses: Set<UIPress> = []

            for press in presses {
                guard let key = press.key,
                      let deviceKey = specialKey(for: key.keyCode)
                else {
                    unhandledPresses.insert(press)
                    continue
                }
                let modifiers = key.modifierFlags.deviceHubModifiers
                if let command = pressedSpecialKeys.press(
                    usage: key.keyCode,
                    key: deviceKey,
                    modifiers: modifiers
                ) {
                    onKeyChanged(command)
                }
            }

            if !unhandledPresses.isEmpty {
                super.pressesBegan(unhandledPresses, with: event)
            }
        }

        override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            release(presses)
            super.pressesCancelled(presses, with: event)
        }

        override func pressesEnded(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            release(presses)
            super.pressesEnded(presses, with: event)
        }

        func releasePressedSpecialKeys() {
            for command in pressedSpecialKeys.releaseAll() {
                onKeyChanged(command)
            }
        }

        /// Retains keyboard intent until UIKit attaches the responder to a window.
        func setPresented(_ isPresented: Bool) {
            isPresentationRequested = isPresented
            synchronizePresentation()
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn _: NSRange,
            replacementString string: String
        ) -> Bool {
            guard textField === self else {
                return false
            }
            if !string.isEmpty {
                forward(string)
            }
            return false
        }

        private func configure() {
            accessibilityElementsHidden = true
            isAccessibilityElement = false
            autocapitalizationType = .none
            autocorrectionType = .no
            backgroundColor = .clear
            borderStyle = .none
            isSecureTextEntry = false
            keyboardType = .default
            smartDashesType = .no
            smartInsertDeleteType = .no
            smartQuotesType = .no
            spellCheckingType = .no
            textColor = .clear
            tintColor = .clear
            inputAccessoryView = makeAccessoryToolbar()
            delegate = self
        }

        private func forward(_ text: String) {
            for character in text {
                switch character {
                case "\n", "\r":
                    tap(.return)
                case " ":
                    tap(.space)
                default:
                    tap(.character(character))
                }
            }
        }

        private func tap(
            _ key: DeviceKey,
            modifiers: KeyModifiers = []
        ) {
            onKeyTapped(key, modifiers)
        }

        private func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.items = [
                accessoryButton("Done") { [weak self] in
                    self?.releasePressedSpecialKeys()
                    self?.onDone()
                    _ = self?.resignFirstResponder()
                },
                UIBarButtonItem(systemItem: .flexibleSpace),
                accessoryButton("Esc") { [weak self] in
                    self?.tap(.escape)
                },
                accessoryButton("Tab") { [weak self] in
                    self?.tap(.tab)
                },
                accessorySymbolButton(
                    "arrow.left",
                    accessibilityLabel: "Left Arrow"
                ) { [weak self] in
                    self?.tap(.leftArrow)
                },
                accessorySymbolButton(
                    "arrow.up",
                    accessibilityLabel: "Up Arrow"
                ) { [weak self] in
                    self?.tap(.upArrow)
                },
                accessorySymbolButton(
                    "arrow.down",
                    accessibilityLabel: "Down Arrow"
                ) { [weak self] in
                    self?.tap(.downArrow)
                },
                accessorySymbolButton(
                    "arrow.right",
                    accessibilityLabel: "Right Arrow"
                ) { [weak self] in
                    self?.tap(.rightArrow)
                }
            ]
            toolbar.sizeToFit()
            return toolbar
        }

        private func accessoryButton(
            _ title: String,
            action: @escaping @MainActor () -> Void
        ) -> UIBarButtonItem {
            UIBarButtonItem(
                title: title,
                primaryAction: UIAction { _ in
                    action()
                }
            )
        }

        private func accessorySymbolButton(
            _ systemName: String,
            accessibilityLabel: String,
            action: @escaping @MainActor () -> Void
        ) -> UIBarButtonItem {
            let item = UIBarButtonItem(
                image: UIImage(systemName: systemName),
                primaryAction: UIAction { _ in
                    action()
                }
            )
            item.accessibilityLabel = accessibilityLabel
            return item
        }

        private func release(_ presses: Set<UIPress>) {
            for press in presses {
                guard let keyCode = press.key?.keyCode,
                      let command = pressedSpecialKeys.release(
                          usage: keyCode
                      )
                else {
                    continue
                }
                onKeyChanged(command)
            }
        }

        private func specialKey(
            for keyCode: UIKeyboardHIDUsage
        ) -> DeviceKey? {
            switch keyCode {
            case .keyboardDownArrow:
                .downArrow
            case .keyboardEscape:
                .escape
            case .keyboardLeftArrow:
                .leftArrow
            case .keyboardRightArrow:
                .rightArrow
            case .keyboardTab:
                .tab
            case .keyboardUpArrow:
                .upArrow
            default:
                nil
            }
        }

        private func synchronizePresentation() {
            guard isPresentationRequested, window != nil else {
                releasePressedSpecialKeys()
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
                return
            }
            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
        }
    }

    struct DeviceKeyboardPressedKeyLedger {
        private struct Entry {
            let key: DeviceKey
            let modifiers: KeyModifiers
            let usage: UIKeyboardHIDUsage
        }

        private var entries: [Entry] = []

        mutating func press(
            usage: UIKeyboardHIDUsage,
            key: DeviceKey,
            modifiers: KeyModifiers
        ) -> KeyCommand? {
            guard !entries.contains(where: { $0.usage == usage }) else {
                return nil
            }
            entries.append(
                Entry(key: key, modifiers: modifiers, usage: usage)
            )
            return KeyCommand(
                key: key,
                phase: .press,
                modifiers: modifiers
            )
        }

        mutating func release(
            usage: UIKeyboardHIDUsage
        ) -> KeyCommand? {
            guard let index = entries.firstIndex(
                where: { $0.usage == usage }
            ) else {
                return nil
            }
            let entry = entries.remove(at: index)
            return KeyCommand(
                key: entry.key,
                phase: .release,
                modifiers: entry.modifiers
            )
        }

        mutating func releaseAll() -> [KeyCommand] {
            defer {
                entries.removeAll(keepingCapacity: true)
            }
            return entries.reversed().map {
                KeyCommand(
                    key: $0.key,
                    phase: .release,
                    modifiers: $0.modifiers
                )
            }
        }
    }

    private extension UIKeyModifierFlags {
        var deviceHubModifiers: KeyModifiers {
            var modifiers: KeyModifiers = []
            if contains(.command) {
                modifiers.insert(.command)
            }
            if contains(.control) {
                modifiers.insert(.control)
            }
            if contains(.alternate) {
                modifiers.insert(.option)
            }
            if contains(.shift) {
                modifiers.insert(.shift)
            }
            return modifiers
        }
    }
#endif
