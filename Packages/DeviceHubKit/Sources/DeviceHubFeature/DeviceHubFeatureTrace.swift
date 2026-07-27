import Foundation

/// Emits opt-in, identity-free reducer milestones for physical-device diagnosis.
enum DeviceHubFeatureTrace {
    enum Milestone {
        case touchTap

        var message: String {
            switch self {
            case .touchTap:
                "input_geometry kind=touch_tap"
            }
        }
    }

    static func emit(_ milestone: Milestone) {
        emit(milestone.message)
    }

    static func emit(_ message: String) {
        guard
            ProcessInfo.processInfo.environment[
                "DEVICE_HUB_BOOTSTRAP_TRACE"
            ] == "1"
        else {
            return
        }
        FileHandle.standardOutput.write(
            Data("devicehub.feature \(message)\n".utf8)
        )
    }
}
