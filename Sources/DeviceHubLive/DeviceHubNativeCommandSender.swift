import DeviceHubCore
import DeviceHubFFI
import DeviceHubTransport

/// Marshals validated semantic input into one closure-scoped FFI call.
enum DeviceHubNativeCommandSender {
    static func send(
        _ command: DeviceHubEncodedCommand,
        to handle: OpaquePointer,
        generation: SessionGeneration,
        functions: DeviceHubNativeFunctionTable
    ) throws(NativeSessionFailure) {
        let nativeGeneration =
            DeviceHubNativeInputMarshaller.generation(generation)
        switch command {
        case let .touch(phase, x, y):
            try sendTouch(
                phase: phase,
                x: x,
                y: y,
                generation: nativeGeneration,
                to: handle,
                functions: functions
            )
        case let .keyboard(phase, usage, modifiers):
            try sendKeyboard(
                phase: phase,
                usage: usage,
                modifiers: modifiers,
                generation: nativeGeneration,
                to: handle,
                functions: functions
            )
        case let .button(button, phase):
            try sendButton(
                button: button,
                phase: phase,
                generation: nativeGeneration,
                to: handle,
                functions: functions
            )
        case let .rotation(direction):
            try sendRotation(
                direction,
                generation: nativeGeneration,
                to: handle,
                functions: functions
            )
        case .releaseAll:
            try releaseAll(
                generation: nativeGeneration,
                on: handle,
                functions: functions
            )
        }
    }

    private static func sendTouch(
        phase: DeviceHubEncodedTouchPhase,
        x: UInt16,
        y: UInt16,
        generation: DhGeneration,
        to handle: OpaquePointer,
        functions: DeviceHubNativeFunctionTable
    ) throws(NativeSessionFailure) {
        var input = DhTouchInput()
        input.struct_size = UInt32(MemoryLayout<DhTouchInput>.size)
        input.abi_version = DeviceHubNativeABI.expectedVersion
        input.generation = generation
        input.phase = switch phase {
        case .cancel:
            DH_TOUCH_PHASE_CANCEL
        case .down:
            DH_TOUCH_PHASE_DOWN
        case .move:
            DH_TOUCH_PHASE_MOVE
        case .tap:
            DH_TOUCH_PHASE_TAP
        case .up:
            DH_TOUCH_PHASE_UP
        }
        input.x = x
        input.y = y
        try invoke(&input, functions: functions) { pointer, error in
            functions.sessionSendTouch(handle, pointer, error)
        }
    }

    private static func sendKeyboard(
        phase: DeviceHubEncodedKeyboardPhase,
        usage: UInt16,
        modifiers: UInt8,
        generation: DhGeneration,
        to handle: OpaquePointer,
        functions: DeviceHubNativeFunctionTable
    ) throws(NativeSessionFailure) {
        var input = DhKeyboardInput()
        input.struct_size = UInt32(MemoryLayout<DhKeyboardInput>.size)
        input.abi_version = DeviceHubNativeABI.expectedVersion
        input.generation = generation
        input.phase = switch phase {
        case .down:
            DH_KEYBOARD_PHASE_DOWN
        case .tap:
            DH_KEYBOARD_PHASE_TAP
        case .up:
            DH_KEYBOARD_PHASE_UP
        }
        input.usage = usage
        input.modifiers = modifiers
        try invoke(&input, functions: functions) { pointer, error in
            functions.sessionSendKeyboard(handle, pointer, error)
        }
    }

    private static func sendButton(
        button: DeviceHubEncodedButton,
        phase: DeviceHubEncodedButtonPhase,
        generation: DhGeneration,
        to handle: OpaquePointer,
        functions: DeviceHubNativeFunctionTable
    ) throws(NativeSessionFailure) {
        var input = DhHardwareButtonInput()
        input.struct_size = UInt32(
            MemoryLayout<DhHardwareButtonInput>.size
        )
        input.abi_version = DeviceHubNativeABI.expectedVersion
        input.generation = generation
        input.button = switch button {
        case .home:
            DH_HARDWARE_BUTTON_HOME
        case .lock:
            DH_HARDWARE_BUTTON_LOCK
        case .mute:
            DH_HARDWARE_BUTTON_MUTE
        case .siri:
            DH_HARDWARE_BUTTON_SIRI
        case .volumeDown:
            DH_HARDWARE_BUTTON_VOLUME_DOWN
        case .volumeUp:
            DH_HARDWARE_BUTTON_VOLUME_UP
        }
        input.phase = switch phase {
        case .down:
            DH_BUTTON_PHASE_DOWN
        case .tap:
            DH_BUTTON_PHASE_TAP
        case .up:
            DH_BUTTON_PHASE_UP
        }
        try invoke(&input, functions: functions) { pointer, error in
            functions.sessionSendHardwareButton(handle, pointer, error)
        }
    }

    private static func sendRotation(
        _ direction: DeviceHubEncodedRotation,
        generation: DhGeneration,
        to handle: OpaquePointer,
        functions: DeviceHubNativeFunctionTable
    ) throws(NativeSessionFailure) {
        var input = DhRotationInput()
        input.struct_size = UInt32(MemoryLayout<DhRotationInput>.size)
        input.abi_version = DeviceHubNativeABI.expectedVersion
        input.generation = generation
        input.direction = switch direction {
        case .left:
            DH_ROTATION_DIRECTION_LEFT
        case .right:
            DH_ROTATION_DIRECTION_RIGHT
        }
        try invoke(&input, functions: functions) { pointer, error in
            functions.sessionRotate(handle, pointer, error)
        }
    }

    private static func releaseAll(
        generation: DhGeneration,
        on handle: OpaquePointer,
        functions: DeviceHubNativeFunctionTable
    ) throws(NativeSessionFailure) {
        var input = DhReleaseAllInput()
        input.struct_size = UInt32(MemoryLayout<DhReleaseAllInput>.size)
        input.abi_version = DeviceHubNativeABI.expectedVersion
        input.generation = generation
        try invoke(&input, functions: functions) { pointer, error in
            functions.sessionReleaseAllInput(handle, pointer, error)
        }
    }

    private static func invoke<Input>(
        _ input: inout Input,
        functions: DeviceHubNativeFunctionTable,
        operation: (
            UnsafePointer<Input>,
            UnsafeMutablePointer<OpaquePointer?>?
        ) -> DhStatus
    ) throws(NativeSessionFailure) {
        let result: Result<Void, NativeSessionFailure> =
            withUnsafePointer(to: &input) { pointer in
                do {
                    try DeviceHubNativeCall.invoke(
                        functions: functions
                    ) { error in
                        operation(pointer, error)
                    }
                    return .success(())
                } catch let failure as NativeSessionFailure {
                    return .failure(failure)
                } catch {
                    return .failure(
                        DeviceHubNativeFailureDecoder.genericFailure
                    )
                }
            }
        switch result {
        case .success:
            return
        case let .failure(failure):
            throw failure
        }
    }
}
