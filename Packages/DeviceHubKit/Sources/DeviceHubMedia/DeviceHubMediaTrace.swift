import Foundation

/// Emits opt-in, payload-free decoder milestones for physical-device diagnosis.
enum DeviceHubMediaTrace {
    static func emit(_ message: String) {
        guard
            ProcessInfo.processInfo.environment[
                "DEVICE_HUB_BOOTSTRAP_TRACE"
            ] == "1"
        else {
            return
        }
        FileHandle.standardOutput.write(
            Data("devicehub.media \(message)\n".utf8)
        )
    }
}
