import DeviceHubCore
import SwiftUI

/// The only persistent control; all device actions live inside its menu.
struct RemoteSessionMenu: View {
    let acceptsInput: Bool
    let isViewingStopped: Bool
    let hasActiveSession: Bool
    let devices: [DeviceSummary]
    let selectedDeviceID: DeviceID?
    let aboutButtonTapped: () -> Void
    let buttonTapped: (DeviceButton) -> Void
    let deviceSelected: (_ deviceID: DeviceID) -> Void
    let detailsButtonTapped: () -> Void
    let keyboardButtonTapped: () -> Void
    let pairButtonTapped: () -> Void
    let reconnectButtonTapped: () -> Void
    let rotateButtonTapped: () -> Void
    let startViewingButtonTapped: () -> Void
    let stopViewingButtonTapped: () -> Void

    var body: some View {
        menu
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .background(.black.opacity(0.58), in: .circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    private var menu: some View {
        Menu {
            if selectedDeviceID != nil {
                Section("Controls") {
                    Button("Home", systemImage: "house") {
                        buttonTapped(.home)
                    }

                    Button("Lock", systemImage: "lock") {
                        buttonTapped(.lock)
                    }

                    Button("Keyboard", systemImage: "keyboard", action: keyboardButtonTapped)

                    Button("Rotate", systemImage: "rotate.right", action: rotateButtonTapped)
                }
                .disabled(!acceptsInput)
            }

            Section("Devices") {
                if !devices.isEmpty {
                    Menu("Choose Device", systemImage: "iphone.and.ipad") {
                        ForEach(devices) { device in
                            Button {
                                deviceSelected(device.id)
                            } label: {
                                Label(
                                    device.name,
                                    systemImage: device.id == selectedDeviceID
                                        ? "checkmark"
                                        : device.deviceHubAvailabilitySymbol
                                )
                            }
                        }
                    }
                }

                Button("Pair Nearby Device", systemImage: "plus", action: pairButtonTapped)
            }

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
                if selectedDeviceID != nil {
                    Button(
                        "Device Details",
                        systemImage: "info.circle",
                        action: detailsButtonTapped
                    )
                }

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
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(
                    width: 44,
                    height: 44
                )
                .contentShape(.circle)
        }
        .accessibilityLabel("More Controls")
    }
}
