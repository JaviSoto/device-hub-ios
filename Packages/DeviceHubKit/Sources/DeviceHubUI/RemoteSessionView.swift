import ComposableArchitecture
import DeviceHubCore
import DeviceHubFeature
import SwiftUI

struct RemoteSessionView: View {
    @Bindable var store: StoreOf<RemoteSessionFeature>
    @Binding var isKeyboardPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHeaderVisible = true

    let aboutButtonTapped: () -> Void
    let detailsButtonTapped: () -> Void
    let pairButtonTapped: () -> Void

    var body: some View {
        ZStack {
            canvas.ignoresSafeArea(.container)

            sessionOverlays
        }
        .background {
            RemoteCanvasColor.value.ignoresSafeArea()
        }
        .deviceHubHiddenNavigationBar()
        .onChange(of: store.selectedDeviceID, selectedDeviceIDChanged)
        .onChange(of: store.acceptsInput, acceptsInputChanged)
        .task(id: store.toolbarPresentation) {
            isHeaderVisible = true
            guard let delay = store.toolbarPresentation.headerDismissalDelay else {
                return
            }
            do {
                try await Task.sleep(for: delay)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                    isHeaderVisible = false
                }
            } catch is CancellationError {
                // A target/status change cancels the old header's dismissal.
            } catch {
                assertionFailure("Header dismissal failed: \(error)")
            }
        }
    }

    private var canvas: some View {
        ZStack {
            RemoteCanvas(
                acceptsInput: store.acceptsInput,
                device: store.selectedDevice,
                frame: store.session?.frame,
                isViewingStopped: store.isViewingStopped,
                presentation: store.sessionPresentation,
                remediation: store.remediation,
                pairButtonTapped: pairButtonTapped,
                remediationButtonTapped: remediationButtonTapped,
                remediationDismissed: remediationDismissed,
                startViewingButtonTapped: startViewingButtonTapped,
                tap: tap,
                touch: touch
            )
            .id(store.selectedDeviceID)

            if isKeyboardPresented {
                DeviceKeyboardReceiver(
                    isPresented: $isKeyboardPresented,
                    keyChanged: keyChanged,
                    keyTapped: keyTapped
                )
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityHidden(true)
            }
        }
    }

    private var sessionOverlays: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                floatingHeader
                    .padding(.horizontal, 56)
                    .padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                RemoteSessionMenu(
                    acceptsInput: store.acceptsInput,
                    isViewingStopped: store.isViewingStopped,
                    hasActiveSession: store.session != nil,
                    devices: store.roster.devices,
                    selectedDeviceID: store.selectedDeviceID,
                    aboutButtonTapped: aboutButtonTapped,
                    buttonTapped: hardwareButtonTapped,
                    deviceSelected: deviceSelected,
                    detailsButtonTapped: detailsButtonTapped,
                    keyboardButtonTapped: keyboardButtonTapped,
                    pairButtonTapped: pairButtonTapped,
                    reconnectButtonTapped: reconnectButtonTapped,
                    rotateButtonTapped: rotateButtonTapped,
                    startViewingButtonTapped: startViewingButtonTapped,
                    stopViewingButtonTapped: stopViewingButtonTapped
                )
                .padding(6)
            }
    }

    @ViewBuilder
    private var floatingHeader: some View {
        let content = DeviceTitleContent(presentation: store.toolbarPresentation)

        VStack(spacing: 2) {
            Text(content.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Label(content.status.label, systemImage: content.status.symbolName)
                .font(.caption2)
                .foregroundStyle(content.status.tone.overlayColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .opacity(isHeaderVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote-session-status")
        .accessibilityHidden(!isHeaderVisible)
    }

    private func acceptsInputChanged(_ oldValue: Bool, _ newValue: Bool) {
        if oldValue, !newValue {
            isKeyboardPresented = false
        }
    }

    private func deviceSelected(_ deviceID: DeviceID) {
        store.send(.deviceSelected(deviceID))
    }

    private func hardwareButtonTapped(_ button: DeviceButton) {
        DeviceHubHaptics.hardwareControl()
        store.send(.buttonTapped(button))
    }

    private func keyboardButtonTapped() {
        isKeyboardPresented.toggle()
    }

    private func keyChanged(_ command: KeyCommand) {
        store.send(.keyChanged(command))
    }

    private func keyTapped(_ key: DeviceKey, _ modifiers: KeyModifiers) {
        store.send(.keyTapped(key, modifiers: modifiers))
    }

    private func reconnectButtonTapped() {
        store.send(.retrySelectedDevice)
    }

    private func remediationButtonTapped() {
        store.send(.remediationButtonTapped)
    }

    private func remediationDismissed() {
        store.send(.remediationDismissed)
    }

    private func rotateButtonTapped() {
        DeviceHubHaptics.hardwareControl()
        store.send(.rotateRightButtonTapped)
    }

    private func selectedDeviceIDChanged(_ oldValue: DeviceID?, _ newValue: DeviceID?) {
        if oldValue != newValue {
            isKeyboardPresented = false
        }
    }

    private func startViewingButtonTapped() {
        store.send(.startViewingButtonTapped)
    }

    private func stopViewingButtonTapped() {
        isKeyboardPresented = false
        store.send(.stopViewingButtonTapped)
    }

    private func tap(_ point: Point2D, _ viewport: Viewport) {
        store.send(.tap(point: point, viewport: viewport))
    }

    private func touch(_ contactID: UInt8, _ phase: TouchPhase, _ point: Point2D, _ viewport: Viewport) {
        store.send(.touch(contactID: contactID, phase: phase, point: point, viewport: viewport))
    }
}

extension RemoteSessionToolbarPresentation {
    /// Hide healthy connection identity after three seconds. Trouble stays visible.
    var headerDismissalDelay: Duration? {
        switch self {
        case .session(_, .live): .seconds(3)
        case .noSelection, .pairingRequired, .viewingStopped, .session: nil
        }
    }
}

private extension RemoteStatusTone {
    var overlayColor: Color {
        switch self {
        case .neutral: .white.opacity(0.85)
        case .positive: Color(red: 0.24, green: 0.95, blue: 0.48)
        case .warning: Color(red: 1, green: 0.66, blue: 0.22)
        }
    }
}

private extension View {
    @ViewBuilder
    func deviceHubHiddenNavigationBar() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .navigationBar)
        #else
            self
        #endif
    }
}

enum RemoteCanvasColor {
    static let value = Color(red: 0.025, green: 0.027, blue: 0.035)
}

@MainActor
enum DeviceHubHaptics {
    static func hardwareControl() {
        #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.55)
        #endif
    }
}

#if os(iOS)
    import UIKit
#endif
