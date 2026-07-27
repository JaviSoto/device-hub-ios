import ComposableArchitecture
import DeviceHubCore
import DeviceHubFeature
import SwiftUI

struct RemoteSessionView: View {
    @Bindable var store: StoreOf<RemoteSessionFeature>
    @Binding var isKeyboardPresented: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let aboutButtonTapped: () -> Void
    let detailsButtonTapped: () -> Void
    let pairButtonTapped: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let chromeLayout = RemoteSessionChromeLayout(
                containerSize: geometry.size,
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass
            )

            configuredContent(chromeLayout)
        }
        .background {
            RemoteCanvasColor.value
                .ignoresSafeArea()
        }
        .onChange(
            of: store.selectedDeviceID,
            selectedDeviceIDChanged
        )
        .onChange(of: store.acceptsInput, acceptsInputChanged)
    }

    @ViewBuilder
    private func sessionContent(
        _ chromeLayout: RemoteSessionChromeLayout
    ) -> some View {
        switch chromeLayout {
        case .nativeToolbar:
            canvas(screenInset: chromeLayout.screenInset)

        case .floatingTrailingRail:
            canvas(screenInset: chromeLayout.screenInset)
                .overlay(alignment: .topLeading) {
                    floatingHeader
                        .padding(.leading, 8)
                        .padding(.top, 8)
                }
                .overlay(alignment: .trailing) {
                    if store.selectedDevice != nil {
                        controls()
                            .padding(.trailing, 8)
                    }
                }

        case .portraitBottomDock:
            VStack(spacing: 6) {
                floatingHeader
                    .frame(maxWidth: .infinity)

                canvas(screenInset: chromeLayout.screenInset)

                if store.selectedDevice != nil {
                    controls(layout: .horizontalDock)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.top, chromeLayout.topChromePadding)
            .padding(.bottom, 8)
        }
    }

    private func canvas(screenInset: CGFloat) -> some View {
        ZStack {
            RemoteCanvas(
                acceptsInput: store.acceptsInput,
                device: store.selectedDevice,
                frame: store.session?.frame,
                isViewingStopped: store.isViewingStopped,
                presentation: store.sessionPresentation,
                remediation: store.remediation,
                screenInset: screenInset,
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

    private var floatingHeader: some View {
        deviceTitleMenu(
            usesCompactLabel: true,
            usesHighContrastForeground: true
        )
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
        .background(.black.opacity(0.62), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func deviceTitleMenu(
        usesCompactLabel: Bool = false,
        usesHighContrastForeground: Bool
    ) -> some View {
        DeviceTitleMenu(
            devices: store.roster.devices,
            presentation: store.toolbarPresentation,
            usesCompactLabel: usesCompactLabel,
            usesHighContrastForeground: usesHighContrastForeground,
            deviceSelected: deviceSelected,
            pairButtonTapped: pairButtonTapped
        )
    }

    private func controls(
        layout: RemoteControlBar.Layout = .verticalRail
    ) -> some View {
        RemoteControlBar(
            layout: layout,
            acceptsInput: store.acceptsInput,
            isViewingStopped: store.isViewingStopped,
            hasActiveSession: store.session != nil,
            aboutButtonTapped: aboutButtonTapped,
            buttonTapped: hardwareButtonTapped,
            detailsButtonTapped: detailsButtonTapped,
            keyboardButtonTapped: keyboardButtonTapped,
            reconnectButtonTapped: reconnectButtonTapped,
            rotateButtonTapped: rotateButtonTapped,
            startViewingButtonTapped: startViewingButtonTapped,
            stopViewingButtonTapped: stopViewingButtonTapped
        )
    }

    @ViewBuilder
    private func configuredContent(
        _ chromeLayout: RemoteSessionChromeLayout
    ) -> some View {
        #if os(iOS)
            switch chromeLayout {
            case .nativeToolbar:
                sessionContent(chromeLayout)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        nativeToolbar
                    }
                    .toolbar(.visible, for: .navigationBar)
                    .toolbarBackground(
                        RemoteCanvasColor.value,
                        for: .navigationBar
                    )
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)

            case .floatingTrailingRail,
                 .portraitBottomDock:
                sessionContent(chromeLayout)
                    .toolbar(.hidden, for: .navigationBar)
            }
        #else
            sessionContent(chromeLayout)
        #endif
    }

    @ToolbarContentBuilder
    private var nativeToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            deviceTitleMenu(usesHighContrastForeground: true)
        }

        if store.selectedDevice != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                nativeToolbarButton(
                    title: "Home",
                    systemImage: "house",
                    symbolPointSize: 13,
                    action: homeButtonTapped
                )

                nativeToolbarButton(
                    title: "Lock",
                    systemImage: "lock",
                    action: lockButtonTapped
                )

                nativeToolbarButton(
                    title: "Keyboard",
                    systemImage: "keyboard",
                    action: keyboardButtonTapped
                )

                nativeToolbarButton(
                    title: "Rotate",
                    systemImage: "rotate.right",
                    action: rotateButtonTapped
                )

                RemoteSessionMenu(
                    labelStyle: .toolbar,
                    acceptsInput: store.acceptsInput,
                    isViewingStopped: store.isViewingStopped,
                    hasActiveSession: store.session != nil,
                    aboutButtonTapped: aboutButtonTapped,
                    buttonTapped: hardwareButtonTapped,
                    detailsButtonTapped: detailsButtonTapped,
                    reconnectButtonTapped: reconnectButtonTapped,
                    startViewingButtonTapped: startViewingButtonTapped,
                    stopViewingButtonTapped: stopViewingButtonTapped
                )
            }
        }
    }

    private func nativeToolbarButton(
        title: String,
        systemImage: String,
        symbolPointSize: CGFloat = 17,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolPointSize, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .disabled(!store.acceptsInput)
        .accessibilityLabel(title)
    }

    private func acceptsInputChanged(
        _ oldValue: Bool,
        _ newValue: Bool
    ) {
        guard oldValue, !newValue else {
            return
        }
        isKeyboardPresented = false
    }

    private func deviceSelected(_ deviceID: DeviceID) {
        store.send(.deviceSelected(deviceID))
    }

    private func hardwareButtonTapped(_ button: DeviceButton) {
        DeviceHubHaptics.hardwareControl()
        store.send(.buttonTapped(button))
    }

    private func homeButtonTapped() {
        hardwareButtonTapped(.home)
    }

    private func keyboardButtonTapped() {
        isKeyboardPresented.toggle()
    }

    private func keyChanged(_ command: KeyCommand) {
        store.send(.keyChanged(command))
    }

    private func keyTapped(
        _ key: DeviceKey,
        _ modifiers: KeyModifiers
    ) {
        store.send(.keyTapped(key, modifiers: modifiers))
    }

    private func lockButtonTapped() {
        hardwareButtonTapped(.lock)
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

    private func selectedDeviceIDChanged(
        _ oldValue: DeviceID?,
        _ newValue: DeviceID?
    ) {
        guard oldValue != newValue else {
            return
        }
        isKeyboardPresented = false
    }

    private func startViewingButtonTapped() {
        store.send(.startViewingButtonTapped)
    }

    private func stopViewingButtonTapped() {
        isKeyboardPresented = false
        store.send(.stopViewingButtonTapped)
    }

    private func tap(
        _ point: Point2D,
        _ viewport: Viewport
    ) {
        store.send(.tap(point: point, viewport: viewport))
    }

    private func touch(
        _ contactID: UInt8,
        _ phase: TouchPhase,
        _ point: Point2D,
        _ viewport: Viewport
    ) {
        store.send(
            .touch(
                contactID: contactID,
                phase: phase,
                point: point,
                viewport: viewport
            )
        )
    }
}

/// Width bounds for the compact device picker shown over the remote canvas.
enum DeviceTitleMenuMetrics {
    static let compactMaximumWidth: CGFloat = 180
}

private struct DeviceTitleMenu: View {
    let devices: [DeviceSummary]
    let presentation: RemoteSessionToolbarPresentation
    let usesCompactLabel: Bool
    let usesHighContrastForeground: Bool
    let deviceSelected: (DeviceID) -> Void
    let pairButtonTapped: () -> Void

    private var content: DeviceTitleContent {
        DeviceTitleContent(presentation: presentation)
    }

    var body: some View {
        Menu {
            if !devices.isEmpty {
                ForEach(devices) { device in
                    Button {
                        deviceSelected(device.id)
                    } label: {
                        Label(
                            device.name,
                            systemImage: device.id
                                == content.selectedDeviceID
                                ? "checkmark"
                                : device.deviceHubAvailabilitySymbol
                        )
                    }
                }
                Divider()
            }

            Button(
                "Pair Nearby Device",
                systemImage: "plus",
                action: pairButtonTapped
            )
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text("\(content.name)  ▾")
                        .font(
                            usesCompactLabel
                                ? .caption.weight(.semibold)
                                : .headline
                        )
                        .foregroundStyle(
                            usesHighContrastForeground
                                ? Color.white
                                : Color.indigo
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(
                            usesCompactLabel ? 0.75 : 1
                        )
                }

                if content.selectedDeviceID == nil {
                    Text(content.status.label)
                        .font(.caption2)
                        .foregroundStyle(headerStatusColor)
                        .lineLimit(1)
                } else {
                    Label(
                        content.status.label,
                        systemImage: content.status.symbolName
                    )
                    .font(.caption2)
                    .foregroundStyle(headerStatusColor)
                    .lineLimit(1)
                }
            }
            .frame(minHeight: 44)
            .frame(
                maxWidth: usesCompactLabel
                    ? DeviceTitleMenuMetrics.compactMaximumWidth
                    : nil
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(
            "\(content.name), \(content.status.label)"
        )
        .accessibilityHint("Shows known devices and pairing options.")
    }

    private var headerStatusColor: Color {
        if usesHighContrastForeground {
            return switch content.status.tone {
            case .neutral:
                .white.opacity(0.82)
            case .positive:
                Color(
                    red: 0.24,
                    green: 0.95,
                    blue: 0.48
                )
            case .warning:
                Color(
                    red: 1,
                    green: 0.66,
                    blue: 0.22
                )
            }
        }

        return switch content.status.tone {
        case .neutral:
            .white.opacity(0.62)
        case .positive:
            .green
        case .warning:
            .orange
        }
    }
}

enum RemoteCanvasColor {
    static let value = Color(
        red: 0.025,
        green: 0.027,
        blue: 0.035
    )
}

@MainActor
enum DeviceHubHaptics {
    static func hardwareControl() {
        #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft)
                .impactOccurred(intensity: 0.55)
        #endif
    }
}

#if os(iOS)
    import UIKit
#endif
