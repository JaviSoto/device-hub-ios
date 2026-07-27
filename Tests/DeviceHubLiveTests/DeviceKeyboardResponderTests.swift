import DeviceHubCore
@testable import DeviceHubUI
import ObjectiveC.runtime
import Testing
import UIKit

@MainActor
@Suite("Device keyboard responder lifecycle")
struct DeviceKeyboardResponderTests {
    @Test("Software-keyboard edits are intercepted without retaining text")
    func softwareKeyboardEditInterception() {
        let textField = DeviceKeyboardTextField()
        var tappedKeys: [DeviceKey] = []
        textField.onKeyTapped = { key, _ in
            tappedKeys.append(key)
        }

        let inserted = textField.delegate?.textField?(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "1"
        )
        let deleted = textField.delegate?.textField?(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: ""
        )
        textField.deleteBackward()

        #expect(inserted == false)
        #expect(deleted == false)
        #expect(tappedKeys == [.character("1"), .delete])
        #expect(textField.text?.isEmpty != false)
    }

    @Test("The delegate owns insertion and the subclass owns deletion")
    func uiKeyInputOwnership() throws {
        let insertSelector = #selector(UIKeyInput.insertText(_:))
        let deleteSelector = #selector(UIKeyInput.deleteBackward)
        let baseInsert = try #require(
            class_getInstanceMethod(UITextField.self, insertSelector)
        )
        let concreteInsert = try #require(
            class_getInstanceMethod(DeviceKeyboardTextField.self, insertSelector)
        )
        let baseDelete = try #require(
            class_getInstanceMethod(UITextField.self, deleteSelector)
        )
        let concreteDelete = try #require(
            class_getInstanceMethod(DeviceKeyboardTextField.self, deleteSelector)
        )

        #expect(method_getImplementation(baseInsert) == method_getImplementation(concreteInsert))
        #expect(method_getImplementation(baseDelete) != method_getImplementation(concreteDelete))
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("A presentation request survives attachment to the window")
    func presentationBeforeAttachment() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = UIViewController()
        let textField = DeviceKeyboardTextField()
        window.rootViewController = viewController

        textField.setPresented(true)
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        await Task.yield()

        #expect(textField.isFirstResponder)

        textField.setPresented(false)
        #expect(!textField.isFirstResponder)
        window.isHidden = true
    }
}
