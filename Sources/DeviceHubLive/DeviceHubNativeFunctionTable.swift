import DeviceHubFFI
import DeviceHubTransport
import Foundation

/// Injectable projection of every C symbol used by the live session adapter.
///
/// Keeping raw functions behind one value lets lifecycle tests prove handle
/// ownership and call ordering without manufacturing a real protocol session.
struct DeviceHubNativeFunctionTable: @unchecked Sendable {
    typealias CreatePairingSession = (
        UnsafePointer<DhPairingSessionConfig>?,
        UnsafeMutablePointer<OpaquePointer?>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    typealias CreateRemoteSession = (
        UnsafePointer<DhRemoteSessionConfig>?,
        UnsafeMutablePointer<OpaquePointer?>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    typealias SessionCall = (
        OpaquePointer?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus

    let abiVersion: () -> UInt32
    let capabilities: () -> DhCapabilities
    let createPairingSession: CreatePairingSession
    let createRemoteSession: CreateRemoteSession
    let errorFree: (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    let errorJSON: (OpaquePointer?) -> UnsafePointer<CChar>?
    let sessionCancel: SessionCall
    let sessionCompletePersistence: (
        OpaquePointer?,
        UInt64,
        DhPersistenceOutcome,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionCompleteVideoNegotiation: (
        OpaquePointer?,
        DhGeneration,
        DhVideoNegotiationOutcome,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionFree: (UnsafeMutablePointer<OpaquePointer?>?) -> DhStatus
    let sessionReleaseAllInput: (
        OpaquePointer?,
        UnsafePointer<DhReleaseAllInput>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionRotate: (
        OpaquePointer?,
        UnsafePointer<DhRotationInput>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionSendHardwareButton: (
        OpaquePointer?,
        UnsafePointer<DhHardwareButtonInput>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionSendKeyboard: (
        OpaquePointer?,
        UnsafePointer<DhKeyboardInput>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionSendTouch: (
        OpaquePointer?,
        UnsafePointer<DhTouchInput>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionSendVideoControlDatagram: (
        OpaquePointer?,
        UnsafePointer<DhVideoControlDatagram>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> DhStatus
    let sessionStart: SessionCall

    static let live = Self(
        abiVersion: dh_ffi_abi_version,
        capabilities: dh_ffi_capabilities,
        createPairingSession: dh_pairing_session_create,
        createRemoteSession: dh_remote_session_create,
        errorFree: dh_error_free,
        errorJSON: dh_error_json,
        sessionCancel: dh_session_cancel,
        sessionCompletePersistence: dh_session_complete_persistence,
        sessionCompleteVideoNegotiation:
        dh_session_complete_video_negotiation,
        sessionFree: dh_session_free,
        sessionReleaseAllInput: dh_session_release_all_input,
        sessionRotate: dh_session_rotate,
        sessionSendHardwareButton: dh_session_send_hardware_button,
        sessionSendKeyboard: dh_session_send_keyboard,
        sessionSendTouch: dh_session_send_touch,
        sessionSendVideoControlDatagram:
        dh_session_send_video_control_datagram,
        sessionStart: dh_session_start
    )
}

/// Copies and releases the uniquely owned error returned by one FFI call.
enum DeviceHubNativeCall {
    private static let maximumErrorJSONByteCount = 16 * 1024

    static func invoke(
        functions: DeviceHubNativeFunctionTable,
        _ operation: (UnsafeMutablePointer<OpaquePointer?>) -> DhStatus
    ) throws(NativeSessionFailure) {
        var error: OpaquePointer?
        let status = operation(&error)
        guard status == DH_STATUS_OK, error == nil else {
            throw consumeFailure(&error, functions: functions)
        }
    }

    static func consumeFailure(
        _ error: inout OpaquePointer?,
        functions: DeviceHubNativeFunctionTable
    ) -> NativeSessionFailure {
        defer {
            functions.errorFree(&error)
        }
        guard
            let error,
            let json = functions.errorJSON(error)
        else {
            return DeviceHubNativeFailureDecoder.genericFailure
        }

        let byteCount = strnlen(
            json,
            maximumErrorJSONByteCount + 1
        )
        guard byteCount <= maximumErrorJSONByteCount else {
            return DeviceHubNativeFailureDecoder.genericFailure
        }
        return DeviceHubNativeFailureDecoder.decode(
            Data(bytes: json, count: byteCount)
        )
    }
}
