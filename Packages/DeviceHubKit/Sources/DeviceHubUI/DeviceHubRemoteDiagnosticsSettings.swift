import Foundation
import Observation

/// Presentation state for the app's explicit remote-diagnostics choice.
///
/// An absent destination represents a local-only build. The model never owns
/// credentials or diagnostic contents; it only displays the configured host
/// and forwards the user's choice to the application composition layer.
@MainActor
@Observable
public final class DeviceHubRemoteDiagnosticsSettings {
    public let destinationHost: String?
    public private(set) var isEnabled: Bool

    @ObservationIgnored
    private let applyChoice: @MainActor (Bool) -> Void

    public init(
        destinationHost: String?,
        isEnabled: Bool,
        setEnabled: @escaping @MainActor (Bool) -> Void
    ) {
        let normalizedHost = destinationHost?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.destinationHost = normalizedHost.flatMap {
            $0.isEmpty ? nil : $0
        }
        self.isEnabled = self.destinationHost == nil
            ? false
            : isEnabled
        applyChoice = setEnabled
    }

    /// Applies a user-initiated choice when a destination is configured.
    public func setEnabled(_ isEnabled: Bool) {
        guard destinationHost != nil else {
            self.isEnabled = false
            return
        }
        guard self.isEnabled != isEnabled else {
            return
        }
        self.isEnabled = isEnabled
        applyChoice(isEnabled)
    }
}
