import DeviceHubCore
import Foundation

/// Complete input graph for one explicit Pairable Host attempt.
public struct NativePairingSessionRequest:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Sendable
{
    public let controller: NativeControllerIdentity
    public let displayName: String
    public let generation: SessionGeneration
    public let model: String
    public let requestedPort: UInt16

    public init(
        generation: SessionGeneration,
        controller: NativeControllerIdentity,
        displayName: String,
        model: String,
        requestedPort: UInt16 = 0
    ) throws {
        try NativeSessionValidation.requireText(
            displayName,
            maximumUTF8Length: 256
        )
        try NativeSessionValidation.requireText(
            model,
            maximumUTF8Length: 128
        )
        self.controller = controller
        self.displayName = displayName
        self.generation = generation
        self.model = model
        self.requestedPort = requestedPort
    }

    public var description: String {
        "<redacted-native-pairing-request>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["request": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Complete input graph for authenticated Pair Verify and RSD.
public struct NativeRemoteSessionRequest:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Sendable
{
    public let controller: NativeControllerIdentity
    public let generation: SessionGeneration
    public let service: NativeRemoteService
    public let target: NativeTargetPairingRecord

    public init(
        generation: SessionGeneration,
        controller: NativeControllerIdentity,
        target: NativeTargetPairingRecord,
        service: NativeRemoteService
    ) {
        self.controller = controller
        self.generation = generation
        self.service = service
        self.target = target
    }

    public var description: String {
        "<redacted-native-remote-request>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["request": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Nonzero native request identity for an acknowledged persistence barrier.
public struct NativePersistenceRequestID:
    Equatable,
    Hashable,
    RawRepresentable,
    Sendable
{
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Result returned to a native persistence barrier.
public enum NativePersistenceOutcome: Equatable, Sendable {
    case failed
    case succeeded
}

/// Native connection phases with no endpoint or protocol payload.
public enum NativeConnectionPhase: Equatable, Sendable {
    case awaitingPairingPeer
    case bindingPairingListener
    case capturingScreenshot
    case discoveringServices
    case idle
    case openingInput
    case openingTunnel
    case pairing
    case persistingPairRecord
    case preparingDevice
    case ready
    case startingDisplayStream
    case streaming
    case verifyingPairing
    case waitingForVideoReceiver
}

/// Authenticated values returned by Remote Service Discovery.
public struct NativeRSDMetadata:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let buildVersion: String?
    public let operatingSystemVersion: String?
    public let productType: String
    public let protocolVersion: UInt64
    public let screenshotServiceAvailable: Bool
    public let serviceCount: UInt64
    public let uniqueDeviceID: DeviceID
    public let uuid: UUID

    public init(
        uuid: UUID,
        operatingSystemVersion: String?,
        buildVersion: String?,
        uniqueDeviceID: DeviceID,
        productType: String,
        protocolVersion: UInt64,
        serviceCount: UInt64,
        screenshotServiceAvailable: Bool
    ) throws {
        if let operatingSystemVersion {
            try NativeSessionValidation.requireText(
                operatingSystemVersion,
                maximumUTF8Length: 64
            )
        }
        if let buildVersion {
            try NativeSessionValidation.requireText(
                buildVersion,
                maximumUTF8Length: 64
            )
        }
        try NativeSessionValidation.requireText(
            uniqueDeviceID.rawValue,
            maximumUTF8Length: 256
        )
        try NativeSessionValidation.requireText(
            productType,
            maximumUTF8Length: 128
        )
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.productType = productType
        self.protocolVersion = protocolVersion
        self.screenshotServiceAvailable = screenshotServiceAvailable
        self.serviceCount = serviceCount
        self.uniqueDeviceID = uniqueDeviceID
        self.uuid = uuid
    }

    public var description: String {
        "<redacted-native-rsd-metadata>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["metadata": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Authoritative device geometry retained only by the transport shell.
public struct NativeDisplayGeometry: Equatable, Sendable {
    public let orientation: ScreenOrientation
    public let pixelSize: PixelSize

    public init(
        pixelSize: PixelSize,
        orientation: ScreenOrientation
    ) throws {
        guard
            pixelSize.width > 0,
            pixelSize.height > 0,
            pixelSize.width <= 16384,
            pixelSize.height <= 16384
        else {
            throw NativeSessionContractError.invalidDisplayGeometry
        }
        self.orientation = orientation
        self.pixelSize = pixelSize
    }
}

/// Structurally validated PNG bytes copied before a native callback returns.
public struct NativeScreenshot:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    private static let maximumByteCount = 64 * 1024 * 1024
    private static let maximumDimension = 16384
    private static let maximumPixelCount = 128 * 1024 * 1024
    private static let pngSignature = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
    ])

    public let bytes: Data
    public let pixelSize: PixelSize

    public init(bytes: Data, pixelSize: PixelSize) throws {
        guard
            bytes.count >= 33,
            bytes.count <= Self.maximumByteCount,
            bytes.prefix(Self.pngSignature.count) == Self.pngSignature,
            pixelSize.width > 0,
            pixelSize.height > 0,
            pixelSize.width <= Self.maximumDimension,
            pixelSize.height <= Self.maximumDimension,
            pixelSize.width
            <= Self.maximumPixelCount / pixelSize.height,
            Self.readUInt32(bytes, at: 8) == 13,
            bytes[12 ..< 16].elementsEqual(
                [0x49, 0x48, 0x44, 0x52]
            ),
            Self.readUInt32(bytes, at: 16)
            == UInt32(pixelSize.width),
            Self.readUInt32(bytes, at: 20)
            == UInt32(pixelSize.height)
        else {
            throw NativeSessionContractError.invalidScreenshot
        }
        self.bytes = bytes
        self.pixelSize = pixelSize
    }

    public var description: String {
        "<redacted-native-screenshot>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["pixels": "<redacted>"],
            displayStyle: .struct
        )
    }

    private static func readUInt32(
        _ data: Data,
        at offset: Int
    ) -> UInt32 {
        data[offset ..< offset + 4].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
    }
}
