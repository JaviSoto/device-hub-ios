#if DEBUG
    import ComposableArchitecture
    import CoreGraphics
    import DeviceHubClient
    import DeviceHubCore
    import DeviceHubFeature
    import DeviceHubUI
    import SwiftUI
    import UIKit

    /// DEBUG-only fixture routes through the app's real store and screen root.
    enum DeviceHubAppFixture: String, CaseIterable, Sendable {
        case home
        case live
    }

    @MainActor
    struct DeviceHubDebugFixtureRoot: View {
        @State private var store: StoreOf<RemoteSessionFeature>

        init(fixture: DeviceHubAppFixture) {
            _store = State(
                initialValue: DeviceHubAppComposition.makeStore(
                    deviceHub: DeviceHubDebugFixtureClient.make(for: fixture)
                )
            )
        }

        var body: some View {
            DeviceHubLiveContentView(store: store, diagnostics: nil)
        }
    }

    private struct DeviceHubSettingsRow {
        enum TrailingContent {
            case toggle
            case value(String)
            case chevron
        }

        let title: String
        let symbol: String
        let tint: UIColor
        let trailing: TrailingContent
    }

    /// Service-level fixture data. These closures never read persistence,
    /// discover devices, or open a network connection.
    private enum DeviceHubDebugFixtureClient {
        private static let mockDevice = DeviceSummary(
            id: DeviceID(rawValue: "duo-preview-device"),
            name: "Test iPhone",
            productType: "iPhone17,2",
            operatingSystemVersion: "27.1",
            pairingState: .paired,
            reachability: .reachable
        )

        static func make(for fixture: DeviceHubAppFixture) -> DeviceHubClient {
            DeviceHubClient(
                pairedDevices: {
                    fixture == .live ? [mockDevice] : []
                },
                availability: {
                    AsyncStream { continuation in
                        if fixture == .live {
                            continuation.yield([mockDevice])
                        } else {
                            continuation.yield([])
                        }
                    }
                },
                pair: { _ in
                    AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                },
                connect: { deviceID in
                    guard fixture == .live, deviceID == mockDevice.id else {
                        throw DeviceHubError.connectionLost
                    }
                    return try makeSession(for: mockDevice)
                },
                forget: { _ in }
            )
        }

        private static func makeSession(
            for device: DeviceSummary
        ) throws -> DeviceSession {
            let generation = SessionGeneration(rawValue: UUID())
            let sessionID = DeviceSessionID(rawValue: generation.rawValue)
            let receivedAt = Date()
            let pixelSize = PixelSize(width: 1179, height: 2556)
            let metadata = FrameMetadata(
                generation: generation,
                sequenceNumber: 1,
                receivedAt: receivedAt,
                pixelSize: pixelSize,
                orientation: .portrait
            )
            let eventSource = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
            for event in [
                DeviceSessionEvent.phaseChanged(.ready),
                .videoFrame(metadata),
                .hidReadinessChanged(.ready)
            ] {
                eventSource.continuation.yield(
                    SessionUpdate(generation: generation, event: event)
                )
            }

            let frameSource = AsyncStream<RemoteDisplayFrame>.makeStream()
            try frameSource.continuation.yield(
                RemoteDisplayFrame(
                    metadata: .videoFrame(metadata),
                    image: makeRemoteScreenImage(
                        width: pixelSize.width,
                        height: pixelSize.height
                    )
                )
            )

            return DeviceSession(
                id: sessionID,
                device: device,
                events: eventSource.stream,
                frames: frameSource.stream,
                command: { _ in },
                disconnect: {
                    eventSource.continuation.finish()
                    frameSource.continuation.finish()
                }
            )
        }

        private static func makeRemoteScreenImage(
            width: Int,
            height: Int
        ) throws -> CGImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height),
                format: format
            )
            let image = renderer.image { rendererContext in
                let context = rendererContext.cgContext
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1).cgColor)
                context.fill(bounds)

                drawText("9:41", at: CGPoint(x: 72, y: 52), size: 46, weight: .semibold, color: .black)
                let island = CGRect(x: CGFloat(width) * 0.37, y: 35, width: CGFloat(width) * 0.26, height: 112)
                context.setFillColor(UIColor.black.cgColor)
                context.fill(rounded: island, radius: 56)
                drawText("●  ●  ●", at: CGPoint(x: CGFloat(width) - 250, y: 64), size: 34, color: .black)

                drawText("Settings", at: CGPoint(x: 64, y: 218), size: 86, weight: .bold, color: .black)
                let search = CGRect(x: 52, y: 350, width: CGFloat(width) - 104, height: 98)
                context.setFillColor(UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1).cgColor)
                context.fill(rounded: search, radius: 26)
                drawSymbol("magnifyingglass", in: CGRect(x: 82, y: 376, width: 46, height: 46), color: .secondaryLabel)
                drawText("Search", at: CGPoint(x: 146, y: 372), size: 42, color: .secondaryLabel)

                let firstGroup = CGRect(x: 48, y: 492, width: CGFloat(width) - 96, height: 648)
                drawGroupBackground(firstGroup, context: context)
                let firstRows = [
                    DeviceHubSettingsRow(title: "Airplane Mode", symbol: "airplane", tint: .systemOrange, trailing: .toggle),
                    DeviceHubSettingsRow(title: "Wi-Fi", symbol: "wifi", tint: .systemBlue, trailing: .value("Studio Wi-Fi")),
                    DeviceHubSettingsRow(title: "Bluetooth", symbol: "bluetooth", tint: .systemBlue, trailing: .value("On")),
                    DeviceHubSettingsRow(title: "Cellular", symbol: "antenna.radiowaves.left.and.right", tint: .systemGreen, trailing: .value("5G"))
                ]
                for (index, row) in firstRows.enumerated() {
                    drawSettingsRow(
                        row,
                        frame: CGRect(x: firstGroup.minX, y: firstGroup.minY + CGFloat(index) * 162, width: firstGroup.width, height: 162),
                        context: context,
                        showsSeparator: index < firstRows.count - 1
                    )
                }

                let secondGroup = CGRect(x: 48, y: 1192, width: CGFloat(width) - 96, height: 648)
                drawGroupBackground(secondGroup, context: context)
                let secondRows = [
                    DeviceHubSettingsRow(title: "General", symbol: "gearshape.fill", tint: .systemGray, trailing: .chevron),
                    DeviceHubSettingsRow(title: "Accessibility", symbol: "accessibility", tint: .systemBlue, trailing: .chevron),
                    DeviceHubSettingsRow(title: "Display & Brightness", symbol: "sun.max.fill", tint: .systemBlue, trailing: .chevron),
                    DeviceHubSettingsRow(title: "Privacy & Security", symbol: "hand.raised.fill", tint: .systemBlue, trailing: .chevron)
                ]
                for (index, row) in secondRows.enumerated() {
                    drawSettingsRow(
                        row,
                        frame: CGRect(x: secondGroup.minX, y: secondGroup.minY + CGFloat(index) * 162, width: secondGroup.width, height: 162),
                        context: context,
                        showsSeparator: index < secondRows.count - 1
                    )
                }
            }
            guard let cgImage = image.cgImage else {
                throw DeviceHubError.secureConnectionFailed
            }
            return cgImage
        }

        private static func drawSettingsRow(
            _ row: DeviceHubSettingsRow,
            frame: CGRect,
            context: CGContext,
            showsSeparator: Bool
        ) {
            let iconFrame = CGRect(x: frame.minX + 30, y: frame.minY + 40, width: 82, height: 82)
            context.setFillColor(row.tint.cgColor)
            context.fill(rounded: iconFrame, radius: 18)
            drawSymbol(row.symbol, in: iconFrame.insetBy(dx: 18, dy: 18), color: .white)
            drawText(row.title, at: CGPoint(x: iconFrame.maxX + 32, y: frame.minY + 54), size: 42, color: .black)
            switch row.trailing {
            case .toggle:
                let toggle = CGRect(x: frame.maxX - 152, y: frame.minY + 48, width: 104, height: 64)
                context.setFillColor(UIColor.systemGray4.cgColor)
                context.fill(rounded: toggle, radius: 32)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: CGRect(x: toggle.minX + 5, y: toggle.minY + 5, width: 54, height: 54))
            case let .value(value):
                drawText(value, at: CGPoint(x: frame.maxX - 310, y: frame.minY + 58), size: 36, color: .secondaryLabel)
                drawSymbol("chevron.right", in: CGRect(x: frame.maxX - 84, y: frame.minY + 59, width: 26, height: 40), color: .tertiaryLabel)
            case .chevron:
                drawSymbol("chevron.right", in: CGRect(x: frame.maxX - 84, y: frame.minY + 59, width: 26, height: 40), color: .tertiaryLabel)
            }
            if showsSeparator {
                context.setStrokeColor(UIColor.separator.cgColor)
                context.setLineWidth(2)
                context.move(to: CGPoint(x: iconFrame.maxX + 30, y: frame.maxY))
                context.addLine(to: CGPoint(x: frame.maxX - 28, y: frame.maxY))
                context.strokePath()
            }
        }

        private static func drawGroupBackground(_ frame: CGRect, context: CGContext) {
            context.setFillColor(UIColor.white.cgColor)
            context.fill(rounded: frame, radius: 32)
        }

        private static func drawSymbol(_ name: String, in frame: CGRect, color: UIColor) {
            guard let symbol = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: frame.height * 0.76, weight: .medium)
            )?.withTintColor(color, renderingMode: .alwaysOriginal)
            else { return }
            symbol.draw(in: frame)
        }

        private static func drawText(
            _ text: String,
            at point: CGPoint,
            size: CGFloat,
            weight: UIFont.Weight = .regular,
            color: UIColor
        ) {
            (text as NSString).draw(
                at: point,
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight),
                    .foregroundColor: color
                ]
            )
        }
    }

    private extension CGContext {
        func fill(rounded rect: CGRect, radius: CGFloat) {
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            addPath(path)
            fillPath()
        }
    }
#endif
