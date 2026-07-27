#if os(iOS)
    import ComposableArchitecture
    import CoreGraphics
    import DeviceHubClient
    import DeviceHubCore
    import DeviceHubFeature
    @testable import DeviceHubUI
    import Foundation
    import SnapshotTesting
    import SwiftUI
    import Testing
    import UIKit

    #if DEVICE_HUB_RECORD_SNAPSHOTS
        private let visualSnapshotRecordMode:
            SnapshotTestingConfiguration.Record = .all
    #else
        private let visualSnapshotRecordMode:
            SnapshotTestingConfiguration.Record = .never
    #endif

    @MainActor
    @Suite(
        "Device Hub visual states",
        .serialized,
        .snapshots(record: visualSnapshotRecordMode)
    )
    struct DeviceHubVisualSnapshotTests {
        @Test("Screen-first state and viewport matrix")
        func visualMatrix() throws {
            for scenario in VisualScenario.allCases {
                let fixture = try VisualFixture(scenario: scenario)
                let traits = fixture.traits

                assertSnapshot(
                    of: fixture.view,
                    as: .image(
                        precision: 0.99,
                        perceptualPrecision: 0.98,
                        layout: .fixed(
                            width: fixture.size.width,
                            height: fixture.size.height
                        ),
                        traits: traits
                    ),
                    named: scenario.rawValue
                )
            }
        }
    }

    enum VisualScenario: String, CaseIterable {
        case emptyIPhoneLight
        case pairingIPhoneDark
        case connectingIPhoneLight
        case liveIPhoneDark
        case liveLandscapeIPadTargetIPhoneDark
        case offlineIPhoneDark
        case lockedIPhoneAccessibility
        case developerModeIPadAccessibility
        case localNetworkDeniedIPadDark
        case deviceBusyIPhoneDark
        case developerImageUnavailableIPadLight
        case developerImageIncompatibleIPhoneDark
        case xcodePreparationIPadLight
        case deviceDetailsPendingVersionIPadLight
        case aboutNoticesIPadLight
        case noticesUnavailableIPhoneDark
        case viewingOnlyIPadLight
    }

    @MainActor
    private struct VisualFixture {
        static let controlledDeviceName = "Test iPhone"

        let size: CGSize
        let traits: UITraitCollection
        let view: AnyView

        init(scenario: VisualScenario) throws {
            let appearance = scenario.appearance
            let idiom = scenario.idiom
            size = scenario.size
            traits = UITraitCollection { traits in
                traits.userInterfaceIdiom = idiom
                traits.horizontalSizeClass =
                    scenario == .liveLandscapeIPadTargetIPhoneDark
                        ? .regular
                        : idiom == .pad
                        ? .regular
                        : .compact
                traits.verticalSizeClass =
                    scenario == .liveLandscapeIPadTargetIPhoneDark
                        ? .compact
                        : .regular
                traits.displayScale = 2
                traits.userInterfaceStyle = appearance
                traits.preferredContentSizeCategory =
                    scenario.usesAccessibilityText
                        ? .accessibilityExtraLarge
                        : .large
            }

            if scenario == .pairingIPhoneDark {
                guard let code = PairingCode("135790") else {
                    throw VisualFixtureError.invalidPairingCode
                }
                let pairingStore = Store(
                    initialState: PairingFeature.State(
                        phase: .waitingForCodeEntry(code)
                    )
                ) {
                    PairingFeature()
                }
                view = AnyView(
                    PairDeviceView(store: pairingStore)
                        .preferredColorScheme(.dark)
                        .environment(\.dynamicTypeSize, .large)
                )
                return
            }

            if scenario == .deviceDetailsPendingVersionIPadLight {
                view = AnyView(
                    DeviceDetailsView(
                        device: DeviceSummary(
                            id: DeviceID(rawValue: "test-phone"),
                            name: Self.controlledDeviceName,
                            productType: "iPhone",
                            operatingSystemVersion: nil,
                            pairingState: .paired,
                            reachability: .reachable
                        ),
                        aboutContent: Self.availableAboutContent
                    )
                    .preferredColorScheme(.light)
                    .environment(\.dynamicTypeSize, .large)
                )
                return
            }

            if scenario == .aboutNoticesIPadLight {
                view = AnyView(
                    AboutDeviceHubView(
                        content: Self.availableAboutContent
                    )
                    .preferredColorScheme(.light)
                    .environment(\.dynamicTypeSize, .large)
                )
                return
            }

            if scenario == .noticesUnavailableIPhoneDark {
                view = AnyView(
                    NavigationStack {
                        OpenSourceNoticesView(
                            content: Self.unavailableAboutContent
                        )
                    }
                    .preferredColorScheme(.dark)
                    .environment(\.dynamicTypeSize, .large)
                )
                return
            }

            if scenario == .xcodePreparationIPadLight {
                view = AnyView(
                    ExternalRemediationView(remedy: .prepareWithXcode)
                        .preferredColorScheme(.light)
                        .environment(\.dynamicTypeSize, .large)
                )
                return
            }

            let state = try Self.state(for: scenario)
            let store = Store(initialState: state) {
                RemoteSessionFeature()
            }
            view = AnyView(
                DeviceHubView(
                    store: store,
                    startsFeatureTask: false
                )
                .preferredColorScheme(
                    appearance == .dark ? .dark : .light
                )
                .environment(
                    \.dynamicTypeSize,
                    scenario.usesAccessibilityText
                        ? .accessibility3
                        : .large
                )
            )
        }
    }

    private extension VisualFixture {
        private static func state(
            for scenario: VisualScenario
        ) throws -> RemoteSessionFeature.State {
            if scenario == .emptyIPhoneLight {
                return RemoteSessionFeature.State()
            }

            let devices = fixtureDevices()
            let reachableDevice = devices.reachable
            let roster = devices.roster

            switch scenario {
            case .connectingIPhoneLight:
                return try sessionState(
                    roster: roster,
                    device: reachableDevice,
                    presentation: .connecting
                )

            case .liveIPhoneDark:
                return try sessionState(
                    roster: roster,
                    device: reachableDevice,
                    presentation: .live
                )

            case .liveLandscapeIPadTargetIPhoneDark:
                return try sessionState(
                    roster: roster,
                    device: devices.landscapeIPad,
                    presentation: .live,
                    remoteScreen: .tabletLandscape
                )

            case .offlineIPhoneDark:
                return RemoteSessionFeature.State(
                    roster: roster,
                    selectedDeviceID: devices.offline.id
                )

            case .lockedIPhoneAccessibility:
                return remediationState(
                    error: .deviceLocked,
                    roster: roster,
                    device: reachableDevice
                )

            case .developerModeIPadAccessibility:
                return remediationState(
                    error: .developerModeDisabled,
                    roster: roster,
                    device: reachableDevice
                )

            case .localNetworkDeniedIPadDark:
                return remediationState(
                    error: .localNetworkDenied,
                    roster: roster,
                    device: reachableDevice
                )

            case .deviceBusyIPhoneDark:
                return remediationState(
                    error: .deviceBusy,
                    roster: roster,
                    device: reachableDevice
                )

            case .developerImageUnavailableIPadLight:
                return remediationState(
                    error: .developerImageUnavailable,
                    roster: roster,
                    device: reachableDevice
                )

            case .developerImageIncompatibleIPhoneDark:
                return remediationState(
                    error: .developerImageIncompatible,
                    roster: roster,
                    device: reachableDevice
                )

            case .viewingOnlyIPadLight:
                return try sessionState(
                    roster: roster,
                    device: reachableDevice,
                    presentation: .viewingOnly
                )

            case .deviceDetailsPendingVersionIPadLight,
                 .aboutNoticesIPadLight,
                 .noticesUnavailableIPhoneDark,
                 .xcodePreparationIPadLight,
                 .emptyIPhoneLight,
                 .pairingIPhoneDark:
                throw VisualFixtureError.unexpectedScenario
            }
        }

        private static func fixtureDevices() -> FixtureDevices {
            let reachable = DeviceSummary(
                id: DeviceID(rawValue: "test-phone"),
                name: controlledDeviceName,
                productType: "iPhone",
                operatingSystemVersion: "27.0",
                pairingState: .paired,
                reachability: .reachable
            )
            let offline = DeviceSummary(
                id: DeviceID(rawValue: "travel-phone"),
                name: "Travel iPhone",
                productType: "iPhone",
                operatingSystemVersion: "27.0",
                pairingState: .paired,
                reachability: .unavailable
            )
            let landscapeIPad = DeviceSummary(
                id: DeviceID(rawValue: "studio-ipad"),
                name: "Studio iPad",
                productType: "iPad16,6",
                operatingSystemVersion: "27.0",
                pairingState: .paired,
                reachability: .reachable
            )
            return FixtureDevices(
                reachable: reachable,
                offline: offline,
                landscapeIPad: landscapeIPad,
                roster: DeviceRoster(
                    devices: [reachable, landscapeIPad, offline]
                )
            )
        }

        private static func remediationState(
            error: DeviceHubError,
            roster: DeviceRoster,
            device: DeviceSummary
        ) -> RemoteSessionFeature.State {
            RemoteSessionFeature.State(
                remediation: DeviceHubRemediation(error: error),
                roster: roster,
                selectedDeviceID: device.id
            )
        }

        private static func sessionState(
            roster: DeviceRoster,
            device: DeviceSummary,
            presentation: FixturePresentation,
            remoteScreen: FixtureRemoteScreen = .phonePortrait
        ) throws -> RemoteSessionFeature.State {
            try RemoteSessionFeature.State(
                roster: roster,
                selectedDeviceID: device.id,
                session: activeSession(
                    device: device,
                    presentation: presentation,
                    remoteScreen: remoteScreen
                )
            )
        }

        private static func activeSession(
            device: DeviceSummary,
            presentation: FixturePresentation,
            remoteScreen: FixtureRemoteScreen
        ) throws -> ActiveRemoteSession {
            let generation = try SessionGeneration(
                rawValue: uuid(
                    "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1"
                )
            )
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let geometry = remoteScreen.geometry
            let metadata = FrameMetadata(
                generation: generation,
                sequenceNumber: 42,
                receivedAt: now,
                pixelSize: geometry.pixelSize,
                orientation: geometry.orientation
            )
            let screenMetadata = ScreenMetadata.videoFrame(metadata)
            var remoteState = RemoteSessionState(
                deviceID: device.id,
                generation: generation
            )
            guard remoteState.apply(
                SessionUpdate(
                    generation: generation,
                    event: .phaseChanged(.ready)
                )
            ) == .accepted,
                remoteState.apply(
                    SessionUpdate(
                        generation: generation,
                        event: .videoFrame(metadata)
                    )
                ) == .accepted,
                remoteState.apply(
                    SessionUpdate(
                        generation: generation,
                        event: .hidReadinessChanged(
                            presentation == .viewingOnly
                                ? .connecting
                                : .ready
                        )
                    )
                ) == .accepted
            else {
                throw VisualFixtureError.invalidRemoteState
            }

            var session = try ActiveRemoteSession(
                attemptID: uuid(
                    "B2B2B2B2-B2B2-B2B2-B2B2-B2B2B2B2B2B2"
                ),
                device: device,
                evaluatedAt: now
            )
            session.frame = try RemoteDisplayFrame(
                metadata: screenMetadata,
                image: abstractScreenImage(
                    width: geometry.imageWidth,
                    height: geometry.imageHeight
                )
            )
            session.evaluatedAt = switch presentation {
            case .connecting, .live, .viewingOnly:
                now
            }
            session.remoteState = remoteState
            session.sessionID = DeviceSessionID(
                rawValue: generation.rawValue
            )
            if presentation == .connecting {
                session.frame = nil
                session.remoteState = nil
                session.sessionID = nil
            }
            return session
        }

        private static func abstractScreenImage(
            width: Int,
            height: Int
        ) throws -> CGImage {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw VisualFixtureError.imageContextCreationFailed
            }

            context.setFillColor(
                CGColor(
                    red: 0.055,
                    green: 0.075,
                    blue: 0.15,
                    alpha: 1
                )
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            context.setFillColor(
                CGColor(
                    red: 0.34,
                    green: 0.25,
                    blue: 0.82,
                    alpha: 1
                )
            )
            context.fill(
                CGRect(
                    x: Double(width) * 0.056,
                    y: Double(height) * 0.763,
                    width: Double(width) * 0.888,
                    height: Double(height) * 0.176
                )
            )

            context.setFillColor(
                CGColor(
                    red: 0.12,
                    green: 0.15,
                    blue: 0.26,
                    alpha: 1
                )
            )
            for index in 0 ..< 3 {
                context.fill(
                    CGRect(
                        x: Double(width) * 0.056,
                        y: Double(height) * 0.502
                            - Double(index) * Double(height) * 0.127,
                        width: Double(width) * 0.888,
                        height: Double(height) * 0.099
                    )
                )
            }

            context.setFillColor(
                CGColor(
                    red: 0.86,
                    green: 0.9,
                    blue: 1,
                    alpha: 0.92
                )
            )
            context.fill(
                CGRect(
                    x: Double(width) * 0.056,
                    y: Double(height) * 0.96,
                    width: Double(width) * 0.483,
                    height: Double(height) * 0.012
                )
            )

            guard let image = context.makeImage() else {
                throw VisualFixtureError.imageCreationFailed
            }
            return image
        }

        private static func uuid(_ value: String) throws -> UUID {
            guard let uuid = UUID(uuidString: value) else {
                throw VisualFixtureError.invalidUUID
            }
            return uuid
        }

        private static let availableAboutContent = DeviceHubAboutContent(
            applicationName: "Device Hub",
            version: "1.0",
            build: "27",
            legalDocuments: [
                DeviceHubLegalDocument(
                    id: "third-party-notices",
                    title: "Third-Party Notices",
                    body: "Device Hub includes open-source software."
                ),
                DeviceHubLegalDocument(
                    id: "license/idevice-MIT.txt",
                    title: "idevice MIT License",
                    body: "Copyright 2026 Jackson Coxson"
                )
            ],
            legalNoticeFailure: nil
        )

        private static let unavailableAboutContent = DeviceHubAboutContent(
            applicationName: "Device Hub",
            version: "1.0",
            build: "27",
            legalDocuments: [],
            legalNoticeFailure:
            "The embedded open-source notices are missing from this build."
        )
    }

#endif
