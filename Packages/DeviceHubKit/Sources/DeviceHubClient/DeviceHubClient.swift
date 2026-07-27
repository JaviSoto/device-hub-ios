import Dependencies
import DependenciesMacros
import DeviceHubCore
import IssueReporting

/// Dependency-controlled boundary between application features and the live
/// CoreDevice transport.
///
/// The public surface deliberately contains no pair records, cryptographic
/// material, network addresses, service ports, packet details, or native
/// handles. A live implementation must be installed by the application at
/// launch. The built-in values report every invocation as unimplemented rather
/// than pretending that a device exists or silently doing nothing.
///
/// Swift's standard `AsyncThrowingStream` constructors currently expose
/// `Error` as their failure type. Live implementations must still translate
/// every protocol failure to `DeviceHubError` before it crosses this boundary.
@DependencyClient
public struct DeviceHubClient: Sendable {
    /// Loads the durable, user-visible records known to this controller.
    public var pairedDevices: @Sendable () async throws -> [DeviceSummary]

    /// Observes complete availability snapshots.
    ///
    /// This is a latest-value stream: producers should use
    /// `bufferingNewest(1)`, and cancellation of iteration must stop discovery.
    public var availability: @Sendable () -> AsyncStream<[DeviceSummary]> = {
        IssueReporting.unimplemented(
            "DeviceHubClient.availability",
            placeholder: AsyncStream { continuation in
                continuation.finish()
            }
        )
    }

    /// Starts one explicit pairing attempt.
    ///
    /// Events are ordered and low volume. Cancelling iteration must stop
    /// advertising, erase provisional session secrets, and terminate the
    /// attempt without emitting further events. Stream failures from a live
    /// implementation must be `DeviceHubError` values.
    public var pair:
        @Sendable (PairingRequest) -> AsyncThrowingStream<PairingEvent, Error> = { _ in
            IssueReporting.unimplemented(
                "DeviceHubClient.pair",
                placeholder: AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            )
        }

    /// Opens a session for a paired device.
    public var connect:
        @Sendable (DeviceID) async throws -> DeviceSession

    /// Removes durable pairing state for exactly one target.
    public var forget: @Sendable (DeviceID) async throws -> Void
}

extension DeviceHubClient: DependencyKey {
    public static var liveValue: Self {
        Self()
    }

    public static var previewValue: Self {
        Self()
    }

    public static var testValue: Self {
        Self()
    }
}

public extension DependencyValues {
    var deviceHub: DeviceHubClient {
        get { self[DeviceHubClient.self] }
        set { self[DeviceHubClient.self] = newValue }
    }
}
