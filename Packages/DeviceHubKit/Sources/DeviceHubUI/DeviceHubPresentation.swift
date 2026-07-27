import DeviceHubCore
import DeviceHubFeature
import SwiftUI

/// Stable grouping for the native device picker.
///
/// "Available" means both paired and reachable. Every other known target stays
/// visible under "Needs Attention" with a textual reason.
struct DeviceListSections: Equatable {
    let available: [DeviceSummary]
    let needsAttention: [DeviceSummary]

    init(devices: [DeviceSummary]) {
        available = devices.filter {
            $0.pairingState == .paired
                && $0.reachability == .reachable
        }
        needsAttention = devices.filter {
            $0.pairingState != .paired
                || $0.reachability != .reachable
        }
    }
}

enum RemoteStatusTone: Equatable {
    case neutral
    case positive
    case warning
}

/// User-visible title and status derived from one explicit feature projection.
struct DeviceTitleContent: Equatable {
    let name: String
    let selectedDeviceID: DeviceID?
    let status: RemoteStatusContent

    init(
        name: String,
        selectedDeviceID: DeviceID?,
        status: RemoteStatusContent
    ) {
        self.name = name
        self.selectedDeviceID = selectedDeviceID
        self.status = status
    }

    init(presentation: RemoteSessionToolbarPresentation) {
        switch presentation {
        case .noSelection:
            self.init(
                name: "Device Hub",
                selectedDeviceID: nil,
                status: RemoteStatusContent(
                    label: "No device selected",
                    symbolName: "iphone.slash",
                    tone: .neutral
                )
            )

        case let .pairingRequired(device):
            self.init(
                name: device.name,
                selectedDeviceID: device.id,
                status: RemoteStatusContent(
                    label: "Pairing required",
                    symbolName: "link.badge.plus",
                    tone: .warning
                )
            )

        case let .session(device, presentation):
            self.init(
                name: device.name,
                selectedDeviceID: device.id,
                status: RemoteStatusContent(
                    presentation: presentation
                )
            )

        case let .viewingStopped(device):
            self.init(
                name: device.name,
                selectedDeviceID: device.id,
                status: RemoteStatusContent(
                    label: "Viewing stopped",
                    symbolName: "pause.circle",
                    tone: .neutral
                )
            )
        }
    }
}

/// Human status shown above and, when needed, over the remote screen.
struct RemoteStatusContent: Equatable {
    let label: String
    let symbolName: String
    let tone: RemoteStatusTone

    init(
        label: String,
        symbolName: String,
        tone: RemoteStatusTone
    ) {
        self.label = label
        self.symbolName = symbolName
        self.tone = tone
    }

    init(presentation: RemoteSessionPresentation?) {
        switch presentation {
        case let .connecting(phase):
            self.init(
                label: phase.title,
                symbolName: "progress.indicator",
                tone: .neutral
            )
        case .live:
            self.init(
                label: "Live",
                symbolName: "circle.fill",
                tone: .positive
            )
        case .offline:
            self.init(
                label: "Offline",
                symbolName: "wifi.slash",
                tone: .neutral
            )
        case .viewingOnly:
            self.init(
                label: "Viewing only",
                symbolName: "eye",
                tone: .neutral
            )
        case let .ended(error):
            self.init(
                label: error?.userFacing.title ?? "Session ended",
                symbolName: "exclamationmark.circle",
                tone: .warning
            )
        case nil:
            self.init(
                label: "No device selected",
                symbolName: "iphone.slash",
                tone: .neutral
            )
        }
    }
}

extension DeviceSummary {
    var deviceHubAvailabilityLabel: String {
        if pairingState == .requiresPairing {
            return "Pairing required"
        }
        return reachability == .reachable ? "Available" : "Offline"
    }

    var deviceHubAvailabilitySymbol: String {
        if pairingState == .requiresPairing {
            return "link.badge.plus"
        }
        return reachability == .reachable
            ? "wifi"
            : "wifi.slash"
    }

    /// Truthful software copy before authenticated device metadata arrives.
    var deviceHubOperatingSystemLabel: String {
        operatingSystemVersion ?? "Available after connection"
    }
}

extension View {
    @ViewBuilder
    func deviceHubInlineNavigationTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
