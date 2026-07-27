import CryptoKit
import Foundation

enum PreviewDeviceClass: String, CaseIterable, Codable, Hashable {
    case iPad
    case iPhone
}

enum PreviewDynamicType: String, CaseIterable, Codable, Hashable {
    case accessibility3
    case large
}

enum PreviewLayout: String, CaseIterable, Codable, Hashable {
    case singleColumn = "single-column"
    case twoColumn = "two-column"
}

enum PreviewOrientation: String, CaseIterable, Codable, Hashable {
    case landscape
    case portrait
}

enum PreviewRemoteScreen: String, CaseIterable, Codable, Hashable {
    case phonePortrait = "phone-portrait"
    case tabletLandscape = "tablet-landscape"
}

enum PreviewState: String, CaseIterable, Codable, Hashable {
    case actionableFailure = "actionable-failure"
    case availableIdle = "available-idle"
    case connecting
    case liveFreshFrame = "live-fresh-frame"
    case pairing
}

enum PreviewTheme: String, CaseIterable, Codable, Hashable {
    case dark
    case light
}

/// Fixed logical and pixel geometry for one deterministic artifact.
struct PreviewViewport: Codable, Equatable, Hashable {
    let height: Int
    let scale: Int
    let width: Int

    var pixelHeight: Int {
        height * scale
    }

    var pixelWidth: Int {
        width * scale
    }
}

/// One renderer-only product state and the environment used to display it.
struct PreviewScenario: Equatable, Hashable {
    let deviceClass: PreviewDeviceClass
    let dynamicType: PreviewDynamicType
    let id: String
    let layout: PreviewLayout
    let orientation: PreviewOrientation
    let remoteScreen: PreviewRemoteScreen
    let state: PreviewState
    let theme: PreviewTheme
    let viewport: PreviewViewport

    var filename: String {
        "\(id).png"
    }

    static let required: [Self] = [
        phone(
            "iphone-pairing-light",
            state: .pairing,
            theme: .light
        ),
        phone(
            "iphone-available-idle-dark",
            state: .availableIdle,
            theme: .dark
        ),
        phone(
            "iphone-connecting-light",
            state: .connecting,
            theme: .light
        ),
        phone(
            "iphone-live-fresh-dark",
            state: .liveFreshFrame,
            theme: .dark
        ),
        phone(
            "iphone-landscape-tablet-live-dark",
            state: .liveFreshFrame,
            theme: .dark,
            orientation: .landscape,
            remoteScreen: .tabletLandscape
        ),
        phone(
            "iphone-actionable-failure-accessibility-light",
            state: .actionableFailure,
            theme: .light,
            dynamicType: .accessibility3
        ),
        tablet(
            "ipad-available-idle-light",
            state: .availableIdle,
            theme: .light
        ),
        tablet(
            "ipad-live-fresh-dark",
            state: .liveFreshFrame,
            theme: .dark
        ),
        tablet(
            "ipad-actionable-failure-accessibility-dark",
            state: .actionableFailure,
            theme: .dark,
            dynamicType: .accessibility3
        )
    ]

    private static func phone(
        _ id: String,
        state: PreviewState,
        theme: PreviewTheme,
        dynamicType: PreviewDynamicType = .large,
        orientation: PreviewOrientation = .portrait,
        remoteScreen: PreviewRemoteScreen = .phonePortrait
    ) -> Self {
        Self(
            deviceClass: .iPhone,
            dynamicType: dynamicType,
            id: id,
            layout: .singleColumn,
            orientation: orientation,
            remoteScreen: remoteScreen,
            state: state,
            theme: theme,
            viewport: orientation == .portrait
                ? PreviewViewport(
                    height: 956,
                    scale: 2,
                    width: 440
                )
                : PreviewViewport(
                    height: 440,
                    scale: 2,
                    width: 956
                )
        )
    }

    private static func tablet(
        _ id: String,
        state: PreviewState,
        theme: PreviewTheme,
        dynamicType: PreviewDynamicType = .large
    ) -> Self {
        Self(
            deviceClass: .iPad,
            dynamicType: dynamicType,
            id: id,
            layout: .twoColumn,
            orientation: .landscape,
            remoteScreen: .phonePortrait,
            state: state,
            theme: theme,
            viewport: PreviewViewport(
                height: 820,
                scale: 2,
                width: 1180
            )
        )
    }
}

/// Stable, machine-readable identity for one rendered PNG.
struct PreviewCatalogEntry: Codable, Equatable {
    let byteCount: Int
    let deviceClass: PreviewDeviceClass
    let dynamicType: PreviewDynamicType
    let layout: PreviewLayout
    let orientation: PreviewOrientation
    let path: String
    let pixelHeight: Int
    let pixelWidth: Int
    let pngSHA256: String
    let remoteScreen: PreviewRemoteScreen
    let scale: Int
    let state: PreviewState
    let surface: String
    let theme: PreviewTheme
    let viewportHeight: Int
    let viewportWidth: Int

    enum CodingKeys: String, CodingKey {
        case byteCount = "byte_count"
        case deviceClass = "device_class"
        case dynamicType = "dynamic_type"
        case layout
        case orientation
        case path
        case pixelHeight = "pixel_height"
        case pixelWidth = "pixel_width"
        case pngSHA256 = "png_sha256"
        case remoteScreen = "remote_screen"
        case scale
        case state
        case surface
        case theme
        case viewportHeight = "viewport_height"
        case viewportWidth = "viewport_width"
    }
}

/// Pure catalog construction kept separate from filesystem and rendering IO.
enum PreviewCatalog {
    static func entries(
        scenarios: [PreviewScenario],
        loadPNG: (String) throws -> Data
    ) throws -> [PreviewCatalogEntry] {
        try scenarios.map { scenario in
            let data = try loadPNG(scenario.filename)
            return PreviewCatalogEntry(
                byteCount: data.count,
                deviceClass: scenario.deviceClass,
                dynamicType: scenario.dynamicType,
                layout: scenario.layout,
                orientation: scenario.orientation,
                path: scenario.filename,
                pixelHeight: scenario.viewport.pixelHeight,
                pixelWidth: scenario.viewport.pixelWidth,
                pngSHA256: sha256(data),
                remoteScreen: scenario.remoteScreen,
                scale: scenario.viewport.scale,
                state: scenario.state,
                surface:
                "\(scenario.deviceClass.rawValue) "
                    + scenario.orientation.rawValue,
                theme: scenario.theme,
                viewportHeight: scenario.viewport.height,
                viewportWidth: scenario.viewport.width
            )
        }
    }

    static func encoded(_ entries: [PreviewCatalogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        var data = try encoder.encode(entries)
        data.append(contentsOf: "\n".utf8)
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
