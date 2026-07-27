import ComposableArchitecture
import CoreGraphics
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import DeviceHubUI
import Foundation
import SwiftUI

/// A renderer-only root backed by explicit state and fail-fast dependencies.
///
/// This type is compiled into the command-line preview product, never the
/// shipping app. It intentionally makes any unexpected feature effect fail
/// closed so generation cannot contact a device, network service, or Keychain.
@MainActor
struct PreviewFixtureView: View {
    private let scenario: PreviewScenario
    private let store: StoreOf<RemoteSessionFeature>

    init(scenario: PreviewScenario) throws {
        let initialState = try PreviewFixture.state(for: scenario)
        self.scenario = scenario
        store = Store(
            initialState: initialState
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub = PreviewFixture.failFastClient
        }
    }

    var body: some View {
        DeviceHubView(
            store: store,
            aboutContent: PreviewFixture.aboutContent
        )
        .frame(
            width: Double(scenario.viewport.width),
            height: Double(scenario.viewport.height)
        )
        .preferredColorScheme(
            scenario.theme == .dark ? .dark : .light
        )
        .environment(
            \.dynamicTypeSize,
            scenario.dynamicType == .accessibility3
                ? .accessibility3
                : .large
        )
        .environment(
            \.horizontalSizeClass,
            scenario.deviceClass == .iPad ? .regular : .compact
        )
        .environment(\.verticalSizeClass, .regular)
        .environment(
            \.displayScale,
            Double(scenario.viewport.scale)
        )
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.calendar, PreviewFixture.calendar)
        .environment(\.timeZone, PreviewFixture.timeZone)
        .environment(\.layoutDirection, .leftToRight)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

enum PreviewFixtureError: Error {
    case imageContextCreationFailed
    case imageCreationFailed
    case invalidRemoteState
    case invalidUUID(String)
    case unexpectedLiveEffect(String)
}

private struct PreviewFrameGeometry {
    let imageHeight: Int
    let imageWidth: Int
    let orientation: ScreenOrientation
    let pixelSize: PixelSize
}

/// Deterministic fixture construction isolated from the shipping app.
enum PreviewFixture {
    static let aboutContent = DeviceHubAboutContent(
        applicationName: "Device Hub",
        version: "1.0",
        build: "27",
        legalDocuments: [
            DeviceHubLegalDocument(
                id: "third-party-notices",
                title: "Third-Party Notices",
                body: "Device Hub includes reviewed open-source software."
            )
        ],
        legalNoticeFailure: nil
    )

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }()

    static let timeZone: TimeZone = {
        guard let timeZone = TimeZone(secondsFromGMT: 0) else {
            preconditionFailure("Foundation must provide GMT.")
        }
        return timeZone
    }()

    static let failFastClient = DeviceHubClient(
        pairedDevices: {
            throw PreviewFixtureError.unexpectedLiveEffect(
                "pairedDevices"
            )
        },
        availability: {
            AsyncStream { continuation in
                continuation.finish()
            }
        },
        pair: { _ in
            AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: PreviewFixtureError.unexpectedLiveEffect(
                        "pair"
                    )
                )
            }
        },
        connect: { _ in
            throw PreviewFixtureError.unexpectedLiveEffect("connect")
        },
        forget: { _ in
            throw PreviewFixtureError.unexpectedLiveEffect("forget")
        }
    )

    static func state(
        for scenario: PreviewScenario
    ) throws -> RemoteSessionFeature.State {
        let controlledDevice = controlledDevice(for: scenario)
        let roster = DeviceRoster(
            devices: [controlledDevice]
                + auxiliaryDevices.filter {
                    $0.id != controlledDevice.id
                }
        )

        switch scenario.state {
        case .pairing:
            let device = DeviceSummary(
                id: DeviceID(rawValue: "new-phone"),
                name: "Nearby iPhone",
                productType: "iPhone17,4",
                operatingSystemVersion: "27.0",
                pairingState: .requiresPairing,
                reachability: .reachable
            )
            return RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            )

        case .availableIdle:
            return RemoteSessionFeature.State(
                isViewingStopped: true,
                roster: roster,
                selectedDeviceID: controlledDevice.id
            )

        case .connecting:
            return try RemoteSessionFeature.State(
                roster: roster,
                selectedDeviceID: controlledDevice.id,
                session: ActiveRemoteSession(
                    attemptID: uuid(
                        "11111111-1111-1111-1111-111111111111"
                    ),
                    device: controlledDevice,
                    evaluatedAt: now
                )
            )

        case .liveFreshFrame:
            return try RemoteSessionFeature.State(
                roster: roster,
                selectedDeviceID: controlledDevice.id,
                session: activeSession(
                    device: controlledDevice,
                    remoteScreen: scenario.remoteScreen
                )
            )

        case .actionableFailure:
            return RemoteSessionFeature.State(
                remediation: DeviceHubRemediation(
                    error: scenario.deviceClass == .iPad
                        ? .developerModeDisabled
                        : .deviceLocked
                ),
                roster: roster,
                selectedDeviceID: controlledDevice.id
            )
        }
    }

    private static let now = Date(
        timeIntervalSinceReferenceDate: 800_000_000
    )

    private static let primaryDevice = DeviceSummary(
        id: DeviceID(rawValue: "test-phone"),
        name: "Test iPhone",
        productType: "iPhone17,3",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: .reachable
    )

    private static let studioIPad = DeviceSummary(
        id: DeviceID(rawValue: "test-ipad"),
        name: "Test iPad",
        productType: "iPad16,6",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: .reachable
    )

    private static let auxiliaryDevices = [
        primaryDevice,
        studioIPad,
        DeviceSummary(
            id: DeviceID(rawValue: "travel-phone"),
            name: "Travel iPhone",
            productType: "iPhone17,2",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .unavailable
        ),
        DeviceSummary(
            id: DeviceID(rawValue: "lab-phone"),
            name: "Lab iPhone",
            productType: "iPhone16,1",
            operatingSystemVersion: "27.0",
            pairingState: .requiresPairing,
            reachability: .reachable
        )
    ]

    private static func controlledDevice(
        for scenario: PreviewScenario
    ) -> DeviceSummary {
        scenario.remoteScreen == .tabletLandscape
            ? studioIPad
            : primaryDevice
    }

    private static func activeSession(
        device: DeviceSummary,
        remoteScreen: PreviewRemoteScreen
    ) throws -> ActiveRemoteSession {
        let generation = try SessionGeneration(
            rawValue: uuid(
                "22222222-2222-2222-2222-222222222222"
            )
        )
        let geometry = frameGeometry(for: remoteScreen)
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
        let updates = [
            SessionUpdate(
                generation: generation,
                event: .phaseChanged(.ready)
            ),
            SessionUpdate(
                generation: generation,
                event: .videoFrame(metadata)
            ),
            SessionUpdate(
                generation: generation,
                event: .hidReadinessChanged(.ready)
            )
        ]
        guard updates.allSatisfy({
            remoteState.apply($0) == .accepted
        }) else {
            throw PreviewFixtureError.invalidRemoteState
        }

        var session = try ActiveRemoteSession(
            attemptID: uuid(
                "33333333-3333-3333-3333-333333333333"
            ),
            device: device,
            evaluatedAt: now
        )
        session.frame = try RemoteDisplayFrame(
            metadata: screenMetadata,
            image: remoteScreenImage(
                width: geometry.imageWidth,
                height: geometry.imageHeight
            )
        )
        session.remoteState = remoteState
        session.sessionID = try DeviceSessionID(
            rawValue: uuid(
                "44444444-4444-4444-4444-444444444444"
            )
        )
        return session
    }

    private static func frameGeometry(
        for remoteScreen: PreviewRemoteScreen
    ) -> PreviewFrameGeometry {
        switch remoteScreen {
        case .phonePortrait:
            PreviewFrameGeometry(
                imageHeight: 956,
                imageWidth: 440,
                orientation: .portrait,
                pixelSize: PixelSize(width: 1179, height: 2556)
            )

        case .tabletLandscape:
            PreviewFrameGeometry(
                imageHeight: 1024,
                imageWidth: 1366,
                orientation: .landscapeRight,
                pixelSize: PixelSize(width: 2064, height: 2752)
            )
        }
    }

    private static func remoteScreenImage(
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
            throw PreviewFixtureError.imageContextCreationFailed
        }

        let colors = [
            CGColor(
                red: 0.035,
                green: 0.055,
                blue: 0.14,
                alpha: 1
            ),
            CGColor(
                red: 0.24,
                green: 0.11,
                blue: 0.54,
                alpha: 1
            )
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, 1]
        ) else {
            throw PreviewFixtureError.imageCreationFailed
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: height),
            options: []
        )

        context.setFillColor(
            CGColor(
                red: 0.55,
                green: 0.43,
                blue: 1,
                alpha: 0.9
            )
        )
        context.fillEllipse(
            in: CGRect(
                x: Double(width) * 0.65,
                y: Double(height) * 0.75,
                width: Double(width) * 0.26,
                height: Double(width) * 0.26
            )
        )

        context.setFillColor(
            CGColor(
                red: 0.075,
                green: 0.095,
                blue: 0.19,
                alpha: 0.9
            )
        )
        for index in 0 ..< 3 {
            let path = CGPath(
                roundedRect: CGRect(
                    x: Double(width) * 0.064,
                    y: Double(height) * 0.408
                        - Double(index) * Double(height) * 0.117,
                    width: Double(width) * 0.873,
                    height: Double(height) * 0.088
                ),
                cornerWidth: 18,
                cornerHeight: 18,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
        }

        context.setFillColor(
            CGColor(
                red: 0.9,
                green: 0.92,
                blue: 1,
                alpha: 0.88
            )
        )
        let titlePath = CGPath(
            roundedRect: CGRect(
                x: Double(width) * 0.064,
                y: Double(height) * 0.912,
                width: Double(width) * 0.477,
                height: Double(height) * 0.019
            ),
            cornerWidth: 9,
            cornerHeight: 9,
            transform: nil
        )
        context.addPath(titlePath)
        context.fillPath()

        guard let image = context.makeImage() else {
            throw PreviewFixtureError.imageCreationFailed
        }
        return image
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw PreviewFixtureError.invalidUUID(value)
        }
        return uuid
    }
}
