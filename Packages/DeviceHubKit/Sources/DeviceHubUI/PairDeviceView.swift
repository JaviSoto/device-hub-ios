import ComposableArchitecture
import DeviceHubCore
import DeviceHubFeature
import SwiftUI

struct PairDeviceView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let store: StoreOf<PairingFeature>

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let remediation = store.remediation {
                        pairingError(remediation)
                    } else {
                        phaseContent
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Pair Device")
            .deviceHubInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.send(.cancelButtonTapped)
                    }
                }
            }
        }
        .presentationDetents(
            PairingSheetPresentation.detents(for: dynamicTypeSize)
        )
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch store.phase {
        case .preparing:
            PairingPreparingView()

        case .advertising:
            PairingInstructionsView()

        case .saving:
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityHidden(true)
                Text("Saving Pairing")
                    .font(.title2.weight(.semibold))
                Text(
                    "Creating a secure identity for this device. "
                        + "Keep both devices nearby."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

        case let .waitingForCodeEntry(code):
            PairingCodeView(code: code)
        }
    }

    private func pairingError(
        _ remediation: DeviceHubRemediation
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(remediation.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(remediation.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle = store.remediationActionTitle {
                Button(actionTitle) {
                    store.send(.remediationButtonTapped)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }
}

/// Keeps the pairing sheet readable without forcing its regular-text design
/// to occupy the full screen.
enum PairingSheetPresentation {
    static func detents(
        for dynamicTypeSize: DynamicTypeSize
    ) -> Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize
            ? [.large]
            : [.medium, .large]
    }
}

/// Device-neutral pairing copy shared across iPhone and iPad controllers.
enum PairingCopy {
    static let preparingMessage = """
    Starting a secure pairing service. Keep this sheet open, then select this \
    Device Hub App under Other Devices on the target's Developer Mode screen. \
    A code appears after you select it.
    """
    static let readySteps = [
        "Open Settings.",
        "Choose Privacy & Security, then Developer Mode.",
        "Under Other Devices, choose the Pair with Device Hub App entry."
    ]
    static let readyTitle = "Ready on This Device"
}

private struct PairingPreparingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 88, height: 88)
                Image(
                    systemName:
                    "iphone.gen3.radiowaves.left.and.right"
                )
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Preparing Pairing")
                    .font(.title2.weight(.semibold))
                Text(PairingCopy.preparingMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Making Device Hub discoverable…")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PairingInstructionsView: View {
    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(PairingCopy.readyTitle)
                    .font(.title2.weight(.semibold))
                Text(
                    "On the device you want to control, follow these steps:"
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 20) {
                ForEach(
                    Array(PairingCopy.readySteps.enumerated()),
                    id: \.offset
                ) { offset, text in
                    PairingStep(
                        number: offset + 1,
                        text: text
                    )
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Waiting for the other device…")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct PairingStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(number, format: .number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.tint, in: .circle)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}

private struct PairingCodeView: View {
    let code: PairingCode

    private var spacedDigits: String {
        code.displayValue.map(String.init).joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "number")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Enter This Code")
                    .font(.title2.weight(.semibold))
                Text("Type it on the other device to confirm pairing.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(spacedDigits)
                .font(
                    .system(
                        .largeTitle,
                        design: .monospaced,
                        weight: .bold
                    )
                )
                .tracking(2)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.quaternary, in: .rect(cornerRadius: 18))
                .accessibilityLabel("Pairing code \(spacedDigits)")

            Label(
                "This code expires when you cancel.",
                systemImage: "clock"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}
