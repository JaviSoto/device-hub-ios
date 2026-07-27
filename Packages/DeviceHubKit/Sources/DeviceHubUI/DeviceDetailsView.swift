import DeviceHubCore
import SwiftUI

struct DeviceDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    let device: DeviceSummary
    let aboutContent: DeviceHubAboutContent

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent(
                        "Availability",
                        value: device.deviceHubAvailabilityLabel
                    )
                    LabeledContent(
                        "Pairing",
                        value: device.pairingState == .paired
                            ? "Paired"
                            : "Pairing required"
                    )
                }

                Section("Software") {
                    LabeledContent(
                        "System Version",
                        value: device.deviceHubOperatingSystemLabel
                    )
                }

                Section {
                    Text(
                        "Connection diagnostics never include screen contents, "
                            + "pairing codes, or keys."
                    )
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }

                Section("Device Hub") {
                    NavigationLink {
                        OpenSourceNoticesView(content: aboutContent)
                    } label: {
                        Label(
                            "Open Source Notices",
                            systemImage: "doc.text"
                        )
                    }
                }
            }
            .navigationTitle(device.name)
            .deviceHubInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
