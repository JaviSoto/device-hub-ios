import DeviceHubFFI

/// Capabilities implemented by the linked native protocol runtime.
///
/// The option set mirrors the complete shipping contract of ABI version 2.
/// The process composition validates the union of pairing, screenshot, live
/// media, and input support before exposing any native session factory.
struct DeviceHubNativeCapabilities: OptionSet, Sendable {
    let rawValue: UInt64

    static let sessionLifecycle = Self(rawValue: 1 << 0)
    static let generationTaggedEvents = Self(rawValue: 1 << 1)
    static let sensitiveInputCopy = Self(rawValue: 1 << 2)
    static let pairableHost = Self(rawValue: 1 << 3)
    static let acknowledgedPairRecords = Self(rawValue: 1 << 4)
    static let authenticatedReconnect = Self(rawValue: 1 << 5)
    static let remoteServiceDiscoveryMetadata = Self(rawValue: 1 << 6)
    static let pngScreenshot = Self(rawValue: 1 << 7)
    static let developerReadiness = Self(rawValue: 1 << 8)
    static let controlStream = Self(rawValue: 1 << 9)
    static let videoNegotiation = Self(rawValue: 1 << 10)
    static let rawVideoDatagrams = Self(rawValue: 1 << 11)
    static let hevcAccessUnits = Self(rawValue: 1 << 12)
    static let touchInput = Self(rawValue: 1 << 13)
    static let keyboardInput = Self(rawValue: 1 << 14)
    static let hardwareButtonInput = Self(rawValue: 1 << 15)
    static let rotation = Self(rawValue: 1 << 16)
    static let splitMediaCallback = Self(rawValue: 1 << 17)
    static let releaseAllInput = Self(rawValue: 1 << 18)
    static let mediaGeometrySnapshots = Self(rawValue: 1 << 19)
    static let pairVerifyDiscovery = Self(rawValue: 1 << 20)

    static let requiredPairing: Self = [
        .sessionLifecycle,
        .generationTaggedEvents,
        .sensitiveInputCopy,
        .pairableHost,
        .acknowledgedPairRecords
    ]

    static let requiredScreenshot: Self = [
        .sessionLifecycle,
        .generationTaggedEvents,
        .sensitiveInputCopy,
        .authenticatedReconnect,
        .remoteServiceDiscoveryMetadata,
        .pngScreenshot,
        .developerReadiness
    ]

    static let requiredLiveControl: Self = [
        .sessionLifecycle,
        .generationTaggedEvents,
        .sensitiveInputCopy,
        .authenticatedReconnect,
        .remoteServiceDiscoveryMetadata,
        .pngScreenshot,
        .developerReadiness,
        .controlStream,
        .videoNegotiation,
        .rawVideoDatagrams,
        .hevcAccessUnits,
        .touchInput,
        .keyboardInput,
        .hardwareButtonInput,
        .rotation,
        .splitMediaCallback,
        .releaseAllInput,
        .mediaGeometrySnapshots,
        .pairVerifyDiscovery
    ]

    static let requiredShipping: Self = [
        .requiredPairing,
        .requiredScreenshot,
        .requiredLiveControl
    ]
}

/// A validated snapshot of the native runtime linked into this app build.
struct DeviceHubNativeABI: Sendable {
    static let expectedVersion: UInt32 = 3

    let capabilities: DeviceHubNativeCapabilities
    let version: UInt32

    init() throws(DeviceHubNativeABIError) {
        try self.init(
            version: dh_ffi_abi_version(),
            capabilities: DeviceHubNativeCapabilities(
                rawValue: dh_ffi_capabilities()
            )
        )
    }

    /// Validates an observed runtime contract independently of how it was
    /// obtained, keeping the fail-closed policy deterministic and testable.
    init(
        version: UInt32,
        capabilities: DeviceHubNativeCapabilities
    ) throws(DeviceHubNativeABIError) {
        guard version == Self.expectedVersion else {
            throw .unsupportedVersion
        }

        let missingCapabilities =
            DeviceHubNativeCapabilities.requiredShipping
                .subtracting(capabilities)
        guard missingCapabilities.isEmpty else {
            throw .missingRequiredCapabilities(missingCapabilities)
        }

        self.capabilities = capabilities
        self.version = version
    }
}

/// Fail-closed native runtime validation errors.
enum DeviceHubNativeABIError: Error, Equatable, Sendable {
    case missingRequiredCapabilities(DeviceHubNativeCapabilities)
    case unsupportedVersion
}
