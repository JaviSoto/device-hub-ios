// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "DeviceHubPreviewRenderer",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(
            name: "DeviceHubPreviewRenderer",
            targets: ["DeviceHubPreviewRenderer"]
        )
    ],
    dependencies: [
        .package(path: "../../Packages/DeviceHubKit"),
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            exact: "1.26.1"
        )
    ],
    targets: [
        .executableTarget(
            name: "DeviceHubPreviewRenderer",
            dependencies: [
                .product(
                    name: "DeviceHubClient",
                    package: "DeviceHubKit"
                ),
                .product(
                    name: "DeviceHubCore",
                    package: "DeviceHubKit"
                ),
                .product(
                    name: "DeviceHubFeature",
                    package: "DeviceHubKit"
                ),
                .product(
                    name: "DeviceHubUI",
                    package: "DeviceHubKit"
                ),
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture"
                )
            ]
        ),
        .testTarget(
            name: "DeviceHubPreviewRendererTests",
            dependencies: ["DeviceHubPreviewRenderer"]
        )
    ],
    swiftLanguageModes: [.v6]
)
