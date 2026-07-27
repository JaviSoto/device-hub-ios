// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "DeviceHubKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v27),
        .macOS(.v27)
    ],
    products: [
        .library(name: "DeviceHubCore", targets: ["DeviceHubCore"]),
        .library(name: "DeviceHubClient", targets: ["DeviceHubClient"]),
        .library(name: "DeviceHubDiagnostics", targets: ["DeviceHubDiagnostics"]),
        .library(name: "DeviceHubFeature", targets: ["DeviceHubFeature"]),
        .library(name: "DeviceHubMedia", targets: ["DeviceHubMedia"]),
        .library(name: "DeviceHubPersistence", targets: ["DeviceHubPersistence"]),
        .library(name: "DeviceHubTransport", targets: ["DeviceHubTransport"]),
        .library(name: "DeviceHubUI", targets: ["DeviceHubUI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            exact: "1.26.1"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-custom-dump",
            exact: "1.6.1"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies",
            exact: "1.14.1"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            exact: "1.19.3"
        ),
        .package(
            url: "https://github.com/pointfreeco/xctest-dynamic-overlay",
            exact: "1.11.0"
        )
    ],
    targets: [
        .target(name: "DeviceHubCore"),
        .target(
            name: "DeviceHubClient",
            dependencies: [
                "DeviceHubCore",
                .product(
                    name: "Dependencies",
                    package: "swift-dependencies"
                ),
                .product(
                    name: "DependenciesMacros",
                    package: "swift-dependencies"
                ),
                .product(
                    name: "IssueReporting",
                    package: "xctest-dynamic-overlay"
                )
            ]
        ),
        .target(name: "DeviceHubDiagnostics"),
        .target(
            name: "DeviceHubMedia",
            dependencies: [
                "DeviceHubClient",
                "DeviceHubCore"
            ]
        ),
        .target(
            name: "DeviceHubPersistence",
            dependencies: [
                "DeviceHubCore",
                .product(
                    name: "Dependencies",
                    package: "swift-dependencies"
                ),
                .product(
                    name: "DependenciesMacros",
                    package: "swift-dependencies"
                ),
                .product(
                    name: "IssueReporting",
                    package: "xctest-dynamic-overlay"
                )
            ]
        ),
        .target(
            name: "DeviceHubFeature",
            dependencies: [
                "DeviceHubClient",
                "DeviceHubCore",
                "DeviceHubDiagnostics",
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture"
                ),
                .product(
                    name: "Dependencies",
                    package: "swift-dependencies"
                )
            ]
        ),
        .target(
            name: "DeviceHubTransport",
            dependencies: [
                "DeviceHubClient",
                "DeviceHubCore",
                "DeviceHubDiagnostics",
                "DeviceHubMedia",
                "DeviceHubPersistence"
            ]
        ),
        .target(
            name: "DeviceHubUI",
            dependencies: [
                "DeviceHubClient",
                "DeviceHubCore",
                "DeviceHubFeature",
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture"
                )
            ]
        ),
        .testTarget(
            name: "DeviceHubCoreTests",
            dependencies: [
                "DeviceHubCore",
                .product(name: "CustomDump", package: "swift-custom-dump")
            ]
        ),
        .testTarget(
            name: "DeviceHubUITests",
            dependencies: [
                "DeviceHubClient",
                "DeviceHubCore",
                "DeviceHubFeature",
                "DeviceHubUI",
                .product(
                    name: "ComposableArchitecture",
                    package: "swift-composable-architecture"
                ),
                .product(
                    name: "CustomDump",
                    package: "swift-custom-dump"
                ),
                .product(
                    name: "SnapshotTesting",
                    package: "swift-snapshot-testing"
                )
            ],
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "DeviceHubClientTests",
            dependencies: [
                "DeviceHubClient",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(
                    name: "DependenciesTestSupport",
                    package: "swift-dependencies"
                )
            ]
        ),
        .testTarget(
            name: "DeviceHubDiagnosticsTests",
            dependencies: [
                "DeviceHubDiagnostics",
                .product(name: "CustomDump", package: "swift-custom-dump")
            ]
        ),
        .testTarget(
            name: "DeviceHubFeatureTests",
            dependencies: [
                "DeviceHubFeature",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(
                    name: "DependenciesTestSupport",
                    package: "swift-dependencies"
                )
            ]
        ),
        .testTarget(
            name: "DeviceHubMediaTests",
            dependencies: [
                "DeviceHubMedia",
                .product(name: "CustomDump", package: "swift-custom-dump")
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "DeviceHubPersistenceTests",
            dependencies: [
                "DeviceHubPersistence",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(
                    name: "DependenciesTestSupport",
                    package: "swift-dependencies"
                )
            ]
        ),
        .testTarget(
            name: "DeviceHubTransportTests",
            dependencies: [
                "DeviceHubTransport",
                .product(name: "CustomDump", package: "swift-custom-dump")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
