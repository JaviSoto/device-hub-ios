import DeviceHubCore
import SwiftUI

/// Dimensions shared by the phone's compact remote-control rail.
enum RemoteControlBarMetrics {
    static let minimumTargetDimension: CGFloat = 44
}

/// Icon-only controls that adapt to the phone's unused canvas space.
struct RemoteControlBar: View {
    enum Layout {
        case horizontalDock
        case verticalRail
    }

    let layout: Layout
    let acceptsInput: Bool
    let isViewingStopped: Bool
    let hasActiveSession: Bool
    let aboutButtonTapped: () -> Void
    let buttonTapped: (DeviceButton) -> Void
    let detailsButtonTapped: () -> Void
    let keyboardButtonTapped: () -> Void
    let reconnectButtonTapped: () -> Void
    let rotateButtonTapped: () -> Void
    let startViewingButtonTapped: () -> Void
    let stopViewingButtonTapped: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            switch layout {
            case .horizontalDock:
                HStack(spacing: 6) {
                    controlButtons
                }
                .padding(6)
                .background(.black.opacity(0.5), in: .capsule)
                .glassEffect(.regular, in: .capsule)

            case .verticalRail:
                VStack(spacing: 6) {
                    controlButtons
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var controlButtons: some View {
        controlButton(
            title: "Home",
            systemImage: "house",
            action: homeButtonTapped
        )
        controlButton(
            title: "Lock",
            systemImage: "lock",
            action: lockButtonTapped
        )
        controlButton(
            title: "Keyboard",
            systemImage: "keyboard",
            action: keyboardButtonTapped
        )
        controlButton(
            title: "Rotate",
            systemImage: "rotate.right",
            action: rotateButtonTapped
        )
        RemoteSessionMenu(
            labelStyle: .floating,
            acceptsInput: acceptsInput,
            isViewingStopped: isViewingStopped,
            hasActiveSession: hasActiveSession,
            aboutButtonTapped: aboutButtonTapped,
            buttonTapped: buttonTapped,
            detailsButtonTapped: detailsButtonTapped,
            reconnectButtonTapped: reconnectButtonTapped,
            startViewingButtonTapped: startViewingButtonTapped,
            stopViewingButtonTapped: stopViewingButtonTapped
        )
    }

    private func controlButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(
                    width: RemoteControlBarMetrics.minimumTargetDimension,
                    height: RemoteControlBarMetrics.minimumTargetDimension
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .modifier(
            RemoteFloatingControlSurface(isEnabled: acceptsInput)
        )
        .disabled(!acceptsInput)
        .accessibilityLabel(title)
        .accessibilityHint(
            acceptsInput
                ? ""
                : "Available when the remote screen is live."
        )
    }

    private func homeButtonTapped() {
        buttonTapped(.home)
    }

    private func lockButtonTapped() {
        buttonTapped(.lock)
    }
}

/// Shared secondary controls for both the phone rail and native iPad toolbar.
struct RemoteSessionMenu: View {
    enum LabelStyle {
        case floating
        case toolbar
    }

    let labelStyle: LabelStyle
    let acceptsInput: Bool
    let isViewingStopped: Bool
    let hasActiveSession: Bool
    let aboutButtonTapped: () -> Void
    let buttonTapped: (DeviceButton) -> Void
    let detailsButtonTapped: () -> Void
    let reconnectButtonTapped: () -> Void
    let startViewingButtonTapped: () -> Void
    let stopViewingButtonTapped: () -> Void

    var body: some View {
        switch labelStyle {
        case .floating:
            menu
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .modifier(RemoteFloatingControlSurface(isEnabled: true))

        case .toolbar:
            menu
        }
    }

    private var menu: some View {
        Menu {
            Section("Device Hub") {
                Button(
                    "About Device Hub",
                    systemImage: "info.circle",
                    action: aboutButtonTapped
                )
            }

            if acceptsInput {
                Section("Hardware") {
                    Button("Volume Up", systemImage: "speaker.plus") {
                        buttonTapped(.volumeUp)
                    }
                    Button("Volume Down", systemImage: "speaker.minus") {
                        buttonTapped(.volumeDown)
                    }
                    Button("Mute", systemImage: "speaker.slash") {
                        buttonTapped(.mute)
                    }
                    Button("Siri", systemImage: "waveform") {
                        buttonTapped(.siri)
                    }
                }
            }

            Section("Session") {
                Button(
                    "Device Details",
                    systemImage: "info.circle",
                    action: detailsButtonTapped
                )

                if isViewingStopped {
                    Button(
                        "Start Viewing",
                        systemImage: "play",
                        action: startViewingButtonTapped
                    )
                } else if hasActiveSession {
                    Button(
                        "Reconnect",
                        systemImage: "arrow.clockwise",
                        action: reconnectButtonTapped
                    )
                    Button(
                        "Stop Viewing",
                        systemImage: "stop",
                        role: .destructive,
                        action: stopViewingButtonTapped
                    )
                }
            }
        } label: {
            switch labelStyle {
            case .floating:
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(
                        width: RemoteControlBarMetrics.minimumTargetDimension,
                        height: RemoteControlBarMetrics.minimumTargetDimension
                    )
                    .contentShape(.circle)

            case .toolbar:
                Label("More Controls", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityLabel("More Controls")
    }
}

private struct RemoteFloatingControlSurface: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.38)
            .background(.black.opacity(0.58), in: .circle)
            .glassEffect(
                .regular.interactive(isEnabled),
                in: .circle
            )
    }
}
