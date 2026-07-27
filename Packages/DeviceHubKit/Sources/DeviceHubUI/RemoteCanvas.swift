import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import SwiftUI

struct RemoteCanvas: View {
    let acceptsInput: Bool
    let device: DeviceSummary?
    let frame: RemoteDisplayFrame?
    let isViewingStopped: Bool
    let presentation: RemoteSessionPresentation?
    let remediation: DeviceHubRemediation?
    let screenInset: CGFloat
    let pairButtonTapped: () -> Void
    let remediationButtonTapped: () -> Void
    let remediationDismissed: () -> Void
    let startViewingButtonTapped: () -> Void
    let tap: (Point2D, Viewport) -> Void
    let touch: (UInt8, TouchPhase, Point2D, Viewport) -> Void

    @State private var touchLedger = RemoteTouchLedger()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RemoteCanvasColor.value

                if hasScreenContent {
                    remoteScreen(in: geometry.size)
                } else {
                    canvasPlaceholder
                }

                if let remediation {
                    RemediationPanel(
                        remediation: remediation,
                        actionButtonTapped: remediationButtonTapped,
                        dismissButtonTapped: remediationDismissed
                    )
                    .padding(24)
                }
            }
            .contentShape(.rect)
            .onChange(
                of: acceptsInput,
                acceptsInputChanged
            )
            .onDisappear {
                cancelActiveTouch()
            }
        }
    }

    private var hasScreenContent: Bool {
        frame != nil
    }

    @ViewBuilder
    private var canvasPlaceholder: some View {
        if isViewingStopped {
            CanvasMessage(
                actionTitle: "Start Viewing",
                message: "The secure remote session is stopped.",
                symbolName: "pause.circle",
                title: "Viewing Stopped",
                action: startViewingButtonTapped
            )
        } else if let device {
            if device.pairingState == .requiresPairing {
                CanvasMessage(
                    actionTitle: "Pair This Device",
                    message: "Pair before starting a remote session.",
                    symbolName: "link.badge.plus",
                    title: device.name,
                    action: pairButtonTapped
                )
            } else if presentation == .offline {
                CanvasMessage(
                    message:
                    "Keep it awake and on the same network. "
                        + "Device Hub will reconnect automatically.",
                    symbolName: "wifi.slash",
                    title: "\(device.name) Is Offline"
                )
            } else {
                ConnectingCanvasMessage(
                    status: RemoteStatusContent(
                        presentation: presentation
                    )
                )
            }
        } else {
            CanvasMessage(
                actionTitle: "Pair Nearby Device",
                message:
                "Pair a nearby device to see and control its screen.",
                symbolName: nil,
                title: "Your Remote Screen Starts Here",
                action: pairButtonTapped
            )
        }
    }

    private func remoteScreen(in canvasSize: CGSize) -> some View {
        let status = RemoteStatusContent(presentation: presentation)
        let metadata = frame?.metadata
        let screenSize = metadata.map {
            RemoteScreenLayout.size(
                in: canvasSize,
                targetPixels: $0.pixelSize,
                orientation: $0.orientation,
                inset: screenInset
            )
        } ?? .zero
        let accessibilityLabel =
            "\(device?.name ?? "Remote device") screen, \(status.label)"
        let accessibilityHint = acceptsInput
            ? "Interact directly with the remote screen."
            : "Remote input is currently unavailable."

        return ZStack {
            Group {
                if let frame {
                    Image(
                        decorative: frame.image,
                        scale: 1,
                        orientation: .up
                    )
                    .resizable()
                    .scaledToFill()
                }
            }
            .frame(width: screenSize.width, height: screenSize.height)
            .clipShape(.rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 20, y: 8)
            .overlay {
                RemoteInputSurface(
                    touchLedger: $touchLedger,
                    acceptsInput: acceptsInput,
                    tap: tap,
                    touch: touch
                )
            }
            .overlay(alignment: .top) {
                if presentation != .live {
                    RemoteStatusBadge(status: status)
                        .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private func acceptsInputChanged(
        _ oldValue: Bool,
        _ newValue: Bool
    ) {
        guard let activeTouch = touchLedger.revokeInput(
            from: oldValue,
            to: newValue
        ) else {
            return
        }
        sendCancellation(for: activeTouch)
    }

    private func cancelActiveTouch() {
        guard let activeTouch = touchLedger.removeActiveTouch() else {
            return
        }
        sendCancellation(for: activeTouch)
    }

    private func sendCancellation(for activeTouch: RemoteActiveTouch) {
        touch(
            activeTouch.contactID,
            .cancelled,
            activeTouch.lastPoint,
            activeTouch.viewport
        )
    }
}

struct RemoteActiveTouch: Equatable {
    let contactID: UInt8
    var lastPoint: Point2D
    let viewport: Viewport
}

/// Local gesture ownership that cannot outlive remote input authorization.
struct RemoteTouchLedger {
    private(set) var activeTouch: RemoteActiveTouch?

    /// Starts a contact only when no gesture is currently owned.
    mutating func beginIfNeeded(
        contactID: UInt8,
        at point: Point2D,
        viewport: Viewport
    ) -> RemoteActiveTouch? {
        guard activeTouch == nil else {
            return nil
        }
        let touch = RemoteActiveTouch(
            contactID: contactID,
            lastPoint: point,
            viewport: viewport
        )
        activeTouch = touch
        return touch
    }

    mutating func updateLastPoint(_ point: Point2D) {
        activeTouch?.lastPoint = point
    }

    /// Ends local ownership and returns the contact to terminate remotely.
    mutating func removeActiveTouch() -> RemoteActiveTouch? {
        defer {
            activeTouch = nil
        }
        return activeTouch
    }

    /// Revokes a contact exactly when input transitions from allowed to denied.
    mutating func revokeInput(
        from oldValue: Bool,
        to newValue: Bool
    ) -> RemoteActiveTouch? {
        guard oldValue, !newValue else {
            return nil
        }
        return removeActiveTouch()
    }
}

/// Pure aspect-fit layout shared by the rendered screen and its input surface.
enum RemoteScreenLayout {
    static func size(
        in canvasSize: CGSize,
        targetPixels: PixelSize,
        orientation: ScreenOrientation,
        inset: CGFloat
    ) -> CGSize {
        guard canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              inset.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0,
              inset >= 0,
              targetPixels.width > 0,
              targetPixels.height > 0
        else {
            return .zero
        }

        let availableSize = CGSize(
            width: max(0, canvasSize.width - inset * 2),
            height: max(0, canvasSize.height - inset * 2)
        )
        let orientedPixels = orientation.orientedSize(for: targetPixels)
        let scale = min(
            availableSize.width / CGFloat(orientedPixels.width),
            availableSize.height / CGFloat(orientedPixels.height)
        )
        guard scale.isFinite, scale > 0 else {
            return .zero
        }
        return CGSize(
            width: CGFloat(orientedPixels.width) * scale,
            height: CGFloat(orientedPixels.height) * scale
        )
    }
}

/// Geometry contract for gestures attached directly to the rendered screen.
enum RemoteInputSurfaceGeometry {
    static func viewport(for size: CGSize) -> Viewport {
        Viewport(
            origin: Point2D(x: 0, y: 0),
            size: Size2D(
                width: Double(size.width),
                height: Double(size.height)
            )
        )
    }
}

private struct RemoteInputSurface: View {
    @Binding var touchLedger: RemoteTouchLedger

    let acceptsInput: Bool
    let tap: (Point2D, Viewport) -> Void
    let touch: (UInt8, TouchPhase, Point2D, Viewport) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(.rect)
                .modifier(
                    RemoteInputModifier(
                        touchLedger: $touchLedger,
                        acceptsInput: acceptsInput,
                        viewport: RemoteInputSurfaceGeometry.viewport(
                            for: geometry.size
                        ),
                        tap: tap,
                        touch: touch
                    )
                )
        }
        .allowsHitTesting(acceptsInput)
    }
}

private struct RemoteInputModifier: ViewModifier {
    @Binding var touchLedger: RemoteTouchLedger

    let acceptsInput: Bool
    let viewport: Viewport
    let tap: (Point2D, Viewport) -> Void
    let touch: (UInt8, TouchPhase, Point2D, Viewport) -> Void

    func body(content: Content) -> some View {
        if acceptsInput {
            content
                .simultaneousGesture(tapGesture)
                .simultaneousGesture(dragGesture)
        } else {
            content
        }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                tap(value.location.point2D, viewport)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let startPoint = value.startLocation.point2D
                if let activeTouch = touchLedger.beginIfNeeded(
                    contactID: 0,
                    at: startPoint,
                    viewport: viewport
                ) {
                    touch(
                        activeTouch.contactID,
                        .began,
                        activeTouch.lastPoint,
                        activeTouch.viewport
                    )
                }

                let point = value.location.point2D
                touchLedger.updateLastPoint(point)
                touch(0, .moved, point, viewport)
            }
            .onEnded { value in
                guard let activeTouch = touchLedger.removeActiveTouch()
                else {
                    return
                }
                let point = value.location.point2D
                touch(
                    activeTouch.contactID,
                    .ended,
                    point,
                    activeTouch.viewport
                )
            }
    }
}

private struct RemoteStatusBadge: View {
    let status: RemoteStatusContent

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

private struct ConnectingCanvasMessage: View {
    let status: RemoteStatusContent

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .colorScheme(.dark)
                .accessibilityHidden(true)
            Text(status.label)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

private struct CanvasMessage: View {
    let actionTitle: String?
    let message: String
    let symbolName: String?
    let title: String
    let action: (() -> Void)?

    init(
        actionTitle: String? = nil,
        message: String,
        symbolName: String?,
        title: String,
        action: (() -> Void)? = nil
    ) {
        self.actionTitle = actionTitle
        self.message = message
        self.symbolName = symbolName
        self.title = title
        self.action = action
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .accessibilityHidden(true)
                        .padding(.bottom, 8)
                }

                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(message)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .foregroundStyle(.white)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: 420)
        .padding(32)
    }
}

private extension CGPoint {
    var point2D: Point2D {
        Point2D(x: x, y: y)
    }
}
