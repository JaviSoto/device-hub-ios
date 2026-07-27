import CoreGraphics
import DeviceHubCore

/// Immutable decoded pixels paired with generation-tagged display metadata.
///
/// Frames are intentionally not `Codable`; descriptions and reflection redact
/// their pixel payload. `CGImage` is an immutable Core Graphics object, which
/// makes sharing this wrapper across tasks safe despite its imported type
/// lacking a native `Sendable` conformance.
public struct RemoteDisplayFrame: @unchecked Sendable {
    public let image: CGImage
    public let metadata: ScreenMetadata

    public init(
        metadata: ScreenMetadata,
        image: CGImage
    ) {
        self.image = image
        self.metadata = metadata
    }

    public var description: String {
        "<redacted remote display frame>"
    }

    public var debugDescription: String {
        "RemoteDisplayFrame(<redacted>)"
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "metadata": metadata,
                "pixels": "<redacted>"
            ],
            displayStyle: .struct
        )
    }
}

extension RemoteDisplayFrame: CustomDebugStringConvertible {}
extension RemoteDisplayFrame: CustomReflectable {}
extension RemoteDisplayFrame: CustomStringConvertible {}
