#if DEBUG
    import ComposableArchitecture
    import CoreGraphics
    import DeviceHubClient
    import DeviceHubCore
    import DeviceHubFeature
    import Foundation

    /// Deterministic, simulator-only product states for visual validation.
    ///
    /// The application may expose these only through a `#if DEBUG`
    /// launch-argument branch. Fixture views never start the feature task, so
    /// they cannot discover, pair with, or control a physical device.
    public enum DeviceHubPreviewFixture: String, CaseIterable, Sendable {
        case connecting
        case empty
        case live
        case liveLandscape = "live-landscape"
        case lockedError = "locked-error"
        case pairing

        /// Creates the complete app view without starting live dependencies.
        @MainActor
        public func makeView(
            aboutContent: DeviceHubAboutContent? = nil
        ) throws -> DeviceHubView {
            let initialState = try state()
            let store = Store(initialState: initialState) {
                RemoteSessionFeature()
            }
            return DeviceHubView(
                store: store,
                aboutContent: aboutContent ?? .previewFixture,
                startsFeatureTask: false
            )
        }

        @MainActor
        func state() throws -> RemoteSessionFeature.State {
            switch self {
            case .empty:
                RemoteSessionFeature.State()

            case .pairing:
                RemoteSessionFeature.State(
                    pairing: PairingFeature.State()
                )

            case .connecting:
                RemoteSessionFeature.State(
                    roster: roster,
                    selectedDeviceID: controlledDevice.id,
                    session: ActiveRemoteSession(
                        attemptID: Self.attemptID,
                        device: controlledDevice,
                        evaluatedAt: Self.referenceDate
                    )
                )

            case .live:
                try sessionState(
                    evaluatedAt: Self.referenceDate,
                    remoteScreen: .phonePortrait
                )

            case .liveLandscape:
                try sessionState(
                    evaluatedAt: Self.referenceDate,
                    remoteScreen: .tabletLandscape
                )

            case .lockedError:
                RemoteSessionFeature.State(
                    remediation: DeviceHubRemediation(error: .deviceLocked),
                    roster: roster,
                    selectedDeviceID: controlledDevice.id
                )
            }
        }

        private var controlledDevice: DeviceSummary {
            let isLandscapeFixture = self == .liveLandscape
            return DeviceSummary(
                id: DeviceID(
                    rawValue: isLandscapeFixture
                        ? "test-ipad"
                        : "test-phone"
                ),
                name: isLandscapeFixture
                    ? "Test iPad"
                    : "Test iPhone",
                productType: isLandscapeFixture
                    ? "iPad16,6"
                    : "iPhone",
                operatingSystemVersion: "27.0",
                pairingState: .paired,
                reachability: .reachable
            )
        }

        private var roster: DeviceRoster {
            DeviceRoster(devices: [controlledDevice])
        }

        @MainActor
        private func sessionState(
            evaluatedAt: Date,
            remoteScreen: PreviewRemoteScreen
        ) throws -> RemoteSessionFeature.State {
            let metadata = FrameMetadata(
                generation: Self.generation,
                sequenceNumber: 42,
                receivedAt: Self.referenceDate,
                pixelSize: remoteScreen.pixelSize,
                orientation: remoteScreen.orientation
            )
            var remoteState = RemoteSessionState(
                deviceID: controlledDevice.id,
                generation: Self.generation
            )
            guard remoteState.apply(
                SessionUpdate(
                    generation: Self.generation,
                    event: .phaseChanged(.ready)
                )
            ) == .accepted,
                remoteState.apply(
                    SessionUpdate(
                        generation: Self.generation,
                        event: .videoFrame(metadata)
                    )
                ) == .accepted,
                remoteState.apply(
                    SessionUpdate(
                        generation: Self.generation,
                        event: .hidReadinessChanged(.ready)
                    )
                ) == .accepted
            else {
                throw DeviceHubPreviewFixtureError.invalidRemoteState
            }

            var session = ActiveRemoteSession(
                attemptID: Self.attemptID,
                device: controlledDevice,
                evaluatedAt: evaluatedAt
            )
            session.frame = try RemoteDisplayFrame(
                metadata: .videoFrame(metadata),
                image: Self.abstractScreenImage(
                    width: remoteScreen.imageWidth,
                    height: remoteScreen.imageHeight
                )
            )
            session.remoteState = remoteState
            session.sessionID = DeviceSessionID(
                rawValue: Self.generation.rawValue
            )
            return RemoteSessionFeature.State(
                roster: roster,
                selectedDeviceID: controlledDevice.id,
                session: session
            )
        }

        private static let attemptID = UUID(
            uuid: (
                0xB2, 0xB2, 0xB2, 0xB2,
                0xB2, 0xB2, 0xB2, 0xB2,
                0xB2, 0xB2, 0xB2, 0xB2,
                0xB2, 0xB2, 0xB2, 0xB2
            )
        )

        private static let generation = SessionGeneration(
            rawValue: UUID(
                uuid: (
                    0xA1, 0xA1, 0xA1, 0xA1,
                    0xA1, 0xA1, 0xA1, 0xA1,
                    0xA1, 0xA1, 0xA1, 0xA1,
                    0xA1, 0xA1, 0xA1, 0xA1
                )
            )
        )

        private static let referenceDate = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )

        private static func abstractScreenImage(
            width: Int,
            height: Int
        ) throws -> CGImage {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw DeviceHubPreviewFixtureError.imageContextCreationFailed
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
                    x: CGFloat(width) * 0.056,
                    y: CGFloat(height) * 0.763,
                    width: CGFloat(width) * 0.888,
                    height: CGFloat(height) * 0.176
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
                        x: CGFloat(width) * 0.056,
                        y: CGFloat(height)
                            * (0.502 - CGFloat(index) * 0.127),
                        width: CGFloat(width) * 0.888,
                        height: CGFloat(height) * 0.099
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
                    x: CGFloat(width) * 0.056,
                    y: CGFloat(height) * 0.96,
                    width: CGFloat(width) * 0.484,
                    height: max(4, CGFloat(height) * 0.012)
                )
            )

            guard let image = context.makeImage() else {
                throw DeviceHubPreviewFixtureError.imageCreationFailed
            }
            return image
        }

        private enum PreviewRemoteScreen {
            case phonePortrait
            case tabletLandscape

            var imageWidth: Int {
                switch self {
                case .phonePortrait:
                    393
                case .tabletLandscape:
                    1366
                }
            }

            var imageHeight: Int {
                switch self {
                case .phonePortrait:
                    852
                case .tabletLandscape:
                    1024
                }
            }

            var orientation: ScreenOrientation {
                switch self {
                case .phonePortrait:
                    .portrait
                case .tabletLandscape:
                    .landscapeRight
                }
            }

            var pixelSize: PixelSize {
                switch self {
                case .phonePortrait:
                    PixelSize(width: 1179, height: 2556)
                case .tabletLandscape:
                    PixelSize(width: 2064, height: 2752)
                }
            }
        }
    }

    private enum DeviceHubPreviewFixtureError: Error {
        case imageContextCreationFailed
        case imageCreationFailed
        case invalidRemoteState
    }

    private extension DeviceHubAboutContent {
        static let previewFixture = Self(
            applicationName: "Device Hub",
            version: "1.0",
            build: "27",
            legalDocuments: [
                DeviceHubLegalDocument(
                    id: "third-party-notices",
                    title: "Third-Party Notices",
                    body: "Device Hub includes open-source software."
                )
            ],
            legalNoticeFailure: nil
        )
    }
#endif
