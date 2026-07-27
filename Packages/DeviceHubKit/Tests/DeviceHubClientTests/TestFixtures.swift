import CoreGraphics
import DeviceHubClient
import DeviceHubCore
import Foundation

extension DeviceSummary {
    static func fixture(
        id: DeviceID = DeviceID(rawValue: "test-device"),
        name: String = "Test iPhone"
    ) -> Self {
        Self(
            id: id,
            name: name,
            productType: "iPhone99,1",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .reachable
        )
    }
}

extension DeviceSession {
    static func fixture(
        id: DeviceSessionID = DeviceSessionID(
            rawValue: UUID(
                uuid: (
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 1
                )
            )
        ),
        device: DeviceSummary = .fixture(),
        events: AsyncThrowingStream<SessionUpdate, Error> = AsyncThrowingStream {
            $0.finish()
        },
        frames: AsyncStream<RemoteDisplayFrame> = AsyncStream {
            $0.finish()
        },
        command: @escaping @Sendable (DeviceCommand) async throws -> Void = { _ in },
        disconnect: @escaping @Sendable () async -> Void = {}
    ) -> Self {
        Self(
            id: id,
            device: device,
            events: events,
            frames: frames,
            command: command,
            disconnect: disconnect
        )
    }
}

extension SessionGeneration {
    static func fixture() -> Self {
        Self(
            rawValue: UUID(
                uuid: (
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 2
                )
            )
        )
    }
}

extension RemoteDisplayFrame {
    static func fixture(
        generation: SessionGeneration = .fixture(),
        sequenceNumber: UInt64,
        image: CGImage
    ) -> Self {
        Self(
            metadata: .videoFrame(
                FrameMetadata(
                    generation: generation,
                    sequenceNumber: sequenceNumber,
                    receivedAt: Date(timeIntervalSince1970: TimeInterval(sequenceNumber)),
                    pixelSize: PixelSize(width: image.width, height: image.height),
                    orientation: .portrait
                )
            ),
            image: image
        )
    }
}
