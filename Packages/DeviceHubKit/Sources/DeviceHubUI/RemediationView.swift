import DeviceHubCore
import DeviceHubFeature
import SwiftUI

struct RemediationPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let remediation: DeviceHubRemediation
    let actionButtonTapped: () -> Void
    let dismissButtonTapped: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            card

            ScrollView {
                card
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        remediationIcon
                        Spacer()
                        dismissButton
                    }
                    remediationText
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    remediationIcon
                    remediationText
                    Spacer(minLength: 0)
                    dismissButton
                }
            }

            if let actionTitle = remediation.actionButtonTitle {
                Button(
                    actionTitle,
                    action: actionButtonTapped
                )
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .foregroundStyle(.white)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(
            Color(
                red: 0.09,
                green: 0.095,
                blue: 0.115
            ),
            in: .rect(cornerRadius: 22)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
    }

    private var dismissButton: some View {
        Button(
            "Dismiss",
            systemImage: "xmark",
            action: dismissButtonTapped
        )
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .foregroundStyle(.white.opacity(0.72))
        .contentShape(.rect)
    }

    private var remediationIcon: some View {
        Image(systemName: remediationSymbol)
            .font(.title2)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var remediationText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(remediation.title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(remediation.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remediationSymbol: String {
        switch remediation.error {
        case .deviceLocked:
            "lock"
        case .deviceOffline, .connectionLost:
            "wifi.slash"
        case .developerModeDisabled:
            "hammer"
        case .deviceBusy:
            "person.crop.circle.badge.clock"
        case .localNetworkDenied:
            "network.slash"
        default:
            "exclamationmark.circle"
        }
    }
}

struct ExternalRemediationView: View {
    @Environment(\.dismiss) private var dismiss

    let remedy: DeviceHubError.Remedy

    private var content: ExternalRemediationContent {
        ExternalRemediationContent(remedy: remedy)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: content.symbolName)
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(content.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(content.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Next Step")
            .deviceHubInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// Truthful platform-work instructions for remedies handled outside TCA.
struct ExternalRemediationContent: Equatable {
    let message: String
    let symbolName: String
    let title: String

    init(remedy: DeviceHubError.Remedy) {
        switch remedy {
        case .grantLocalNetworkAccess:
            message = "Open System Settings → Privacy & Security → "
                + "Local Network, then allow Device Hub to find devices "
                + "on your local network."
            symbolName = "network"
            title = "Allow Local Network Access"

        case .enableDeveloperMode:
            message = "On the other device, open Settings → Privacy & Security "
                + "→ Developer Mode. Turn it on, restart when asked, and "
                + "confirm after the device starts."
            symbolName = "hammer"
            title = "Enable Developer Mode"

        case .prepareWithXcode:
            message = "Connect the other device to a Mac with a compatible Xcode. "
                + "Unlock it, trust the Mac if asked, then open Xcode → "
                + "Window → Devices and Simulators. Select the device and "
                + "wait until Xcode finishes preparing it before reconnecting."
            symbolName = "wrench.and.screwdriver"
            title = "Prepare with Xcode"

        case .updateApp:
            message =
                "Install a newer signed Device Hub build using the same private "
                    + "installation method used for this copy, then reconnect."
            symbolName = "arrow.down.app"
            title = "Update Device Hub"

        default:
            message = "Complete the requested step, then return to Device Hub."
            symbolName = "checklist"
            title = "Finish Setup"
        }
    }
}
