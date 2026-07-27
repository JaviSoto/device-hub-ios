import CustomDump
import DeviceHubCore
import DeviceHubFeature
@testable import DeviceHubUI
import Foundation
import SwiftUI
import Testing

@Suite("Device Hub presentation")
struct DeviceHubUIPresentationTests {
    @Test("Compact windows make the remote session the navigation root")
    func adaptiveNavigation() {
        #expect(
            DeviceHubNavigationLayout(
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular
            )
                == .remoteSessionOnly
        )
        #expect(
            DeviceHubNavigationLayout(
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular
            )
                == .sidebarAndSession
        )
        #expect(
            DeviceHubNavigationLayout(
                horizontalSizeClass: .regular,
                verticalSizeClass: .compact
            )
                == .remoteSessionOnly
        )
    }

    @Test("Accessibility text opens pairing at the large detent")
    func pairingSheetDetents() {
        #expect(
            PairingSheetPresentation.detents(for: .large)
                == [.medium, .large]
        )
        #expect(
            PairingSheetPresentation.detents(for: .accessibility3)
                == [.large]
        )
    }

    @Test("Pairing copy is device-neutral and explains when the code appears")
    func pairingCopy() {
        expectNoDifference(
            PairingCopy.preparingMessage,
            """
            Starting a secure pairing service. Keep this sheet open, then \
            select this Device Hub App under Other Devices on the target's \
            Developer Mode screen. A code appears after you select it.
            """
        )
        expectNoDifference(
            PairingCopy.readyTitle,
            "Ready on This Device"
        )
        expectNoDifference(
            PairingCopy.readySteps,
            [
                "Open Settings.",
                "Choose Privacy & Security, then Developer Mode.",
                "Under Other Devices, choose the Pair with Device Hub App entry."
            ]
        )
    }

    @Test("Pairing keeps the controller awake only during an active attempt")
    func pairingScreenIdlePolicy() {
        #expect(
            PairingScreenIdlePolicy.isDisabled(
                isPairingPresented: true,
                hasRemediation: false,
                scenePhase: .active
            )
        )
        #expect(
            !PairingScreenIdlePolicy.isDisabled(
                isPairingPresented: false,
                hasRemediation: false,
                scenePhase: .active
            )
        )
        #expect(
            !PairingScreenIdlePolicy.isDisabled(
                isPairingPresented: true,
                hasRemediation: true,
                scenePhase: .active
            )
        )
        #expect(
            !PairingScreenIdlePolicy.isDisabled(
                isPairingPresented: true,
                hasRemediation: false,
                scenePhase: .inactive
            )
        )
        #expect(
            !PairingScreenIdlePolicy.isDisabled(
                isPairingPresented: true,
                hasRemediation: false,
                scenePhase: .background
            )
        )
    }

    @Test(
        "Toolbar copy represents every selection state without contradictions"
    )
    func toolbarCopy() {
        let paired = device(
            id: "paired",
            name: "Test iPhone",
            pairing: .paired,
            reachability: .reachable
        )
        let needsPairing = device(
            id: "needs-pairing",
            name: "Lab iPhone",
            pairing: .requiresPairing,
            reachability: .reachable
        )

        expectNoDifference(
            DeviceTitleContent(presentation: .noSelection),
            DeviceTitleContent(
                name: "Device Hub",
                selectedDeviceID: nil,
                status: RemoteStatusContent(
                    label: "No device selected",
                    symbolName: "iphone.slash",
                    tone: .neutral
                )
            )
        )
        expectNoDifference(
            DeviceTitleContent(
                presentation: .pairingRequired(needsPairing)
            ),
            DeviceTitleContent(
                name: "Lab iPhone",
                selectedDeviceID: needsPairing.id,
                status: RemoteStatusContent(
                    label: "Pairing required",
                    symbolName: "link.badge.plus",
                    tone: .warning
                )
            )
        )
        expectNoDifference(
            DeviceTitleContent(
                presentation: .viewingStopped(paired)
            ),
            DeviceTitleContent(
                name: "Test iPhone",
                selectedDeviceID: paired.id,
                status: RemoteStatusContent(
                    label: "Viewing stopped",
                    symbolName: "pause.circle",
                    tone: .neutral
                )
            )
        )
        expectNoDifference(
            DeviceTitleContent(
                presentation: .session(
                    device: paired,
                    presentation: .live
                )
            ),
            DeviceTitleContent(
                name: "Test iPhone",
                selectedDeviceID: paired.id,
                status: RemoteStatusContent(
                    label: "Live",
                    symbolName: "circle.fill",
                    tone: .positive
                )
            )
        )
    }

    @Test("Private updates promise instructions, not an in-app updater")
    func updateCopy() {
        let remediation = DeviceHubRemediation(
            error: .unsupportedProtocolVersion
        )

        expectNoDifference(
            remediation.actionButtonTitle,
            "Show Update Steps"
        )
        expectNoDifference(
            ExternalRemediationContent(
                remedy: .updateApp
            ).message,
            "Install a newer signed Device Hub build using the same private "
                + "installation method used for this copy, then reconnect."
        )
    }

    @Test(
        "Every platform remediation has dedicated instructions",
        arguments: [
            DeviceHubError.Remedy.grantLocalNetworkAccess,
            .enableDeveloperMode,
            .prepareWithXcode,
            .updateApp
        ]
    )
    func externalRemediationCopy(
        remedy: DeviceHubError.Remedy
    ) {
        let content = ExternalRemediationContent(remedy: remedy)

        #expect(content.title != "Finish Setup")
        #expect(!content.message.isEmpty)
    }

    @Test("Device picker separates available devices from anything requiring attention")
    func devicePickerSections() {
        let roster = DeviceRoster(
            devices: [
                device(
                    id: "offline",
                    name: "Travel iPhone",
                    pairing: .paired,
                    reachability: .unavailable
                ),
                device(
                    id: "available",
                    name: "Test iPhone",
                    pairing: .paired,
                    reachability: .reachable
                ),
                device(
                    id: "pair",
                    name: "Lab iPhone",
                    pairing: .requiresPairing,
                    reachability: .reachable
                )
            ]
        )
        let sections = DeviceListSections(devices: roster.devices)

        expectNoDifference(
            sections.available.map(\.id.rawValue),
            ["available"]
        )
        expectNoDifference(
            sections.needsAttention.map(\.id.rawValue),
            ["offline", "pair"]
        )
    }

    @Test(
        "Session status distinguishes control readiness",
        arguments: [
            (
                RemoteSessionPresentation.live,
                RemoteStatusContent(
                    label: "Live",
                    symbolName: "circle.fill",
                    tone: .positive
                )
            ),
            (
                RemoteSessionPresentation.viewingOnly,
                RemoteStatusContent(
                    label: "Viewing only",
                    symbolName: "eye",
                    tone: .neutral
                )
            ),
        ]
    )
    func freshnessCopy(
        presentation: RemoteSessionPresentation,
        expected: RemoteStatusContent
    ) {
        expectNoDifference(
            RemoteStatusContent(presentation: presentation),
            expected
        )
    }

    @Test(
        "System version copy never invents unauthenticated metadata",
        arguments: [
            (String?.none, "Available after connection"),
            (String?.some("27.0"), "27.0")
        ]
    )
    func operatingSystemVersionCopy(
        version: String?,
        expected: String
    ) {
        expectNoDifference(
            device(
                id: "device",
                name: "Test iPhone",
                pairing: .paired,
                reachability: .reachable,
                operatingSystemVersion: version
            ).deviceHubOperatingSystemLabel,
            expected
        )
    }
}

@Suite("Device Hub about content")
struct DeviceHubAboutContentTests {
    @Test("Bundle metadata and legal documents load deterministically")
    func bundledLegalDocuments() throws {
        let fixture = try TemporaryAboutBundle(
            resources: [
                "THIRD_PARTY_NOTICES.md":
                    "# Third-party notices\nDevice Hub notices.",
                "Licenses/Swift.md":
                    "# Swift package licenses\nSwift license text.",
                "Licenses/idevice-MIT.txt":
                    "Copyright 2026 Jackson Coxson"
            ]
        )
        defer {
            fixture.remove()
        }

        let content = DeviceHubAboutContent.load(from: fixture.bundle)

        expectNoDifference(content.applicationName, "Device Hub Test")
        expectNoDifference(content.versionLabel, "Version 1.2 (42)")
        expectNoDifference(
            content.legalDocuments.map(\.id),
            [
                "third-party-notices",
                "license/idevice-MIT.txt",
                "license/Swift.md"
            ]
        )
        expectNoDifference(
            content.legalDocuments.map(\.title),
            [
                "Third-Party Notices",
                "idevice MIT",
                "Swift package licenses"
            ]
        )
        #expect(content.legalNoticeFailure == nil)
    }

    @Test("Missing legal resources remain visibly unavailable")
    func missingLegalResources() throws {
        let fixture = try TemporaryAboutBundle(resources: [:])
        defer {
            fixture.remove()
        }

        let content = DeviceHubAboutContent.load(from: fixture.bundle)

        #expect(content.legalDocuments.isEmpty)
        expectNoDifference(
            content.legalNoticeFailure,
            "The embedded third-party notices are missing from this build. "
                + "The embedded open-source licenses are missing from this build."
        )
    }
}

private func device(
    id: String,
    name: String,
    pairing: DevicePairingState,
    reachability: DeviceReachability,
    operatingSystemVersion: String? = "27.0"
) -> DeviceSummary {
    DeviceSummary(
        id: DeviceID(rawValue: id),
        name: name,
        productType: "iPhone",
        operatingSystemVersion: operatingSystemVersion,
        pairingState: pairing,
        reachability: reachability
    )
}

private struct TemporaryAboutBundle {
    let bundle: Bundle
    let bundleURL: URL

    init(resources: [String: String]) throws {
        let fileManager = FileManager.default
        bundleURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")

        #if os(macOS)
            let contentsURL = bundleURL.appendingPathComponent(
                "Contents",
                isDirectory: true
            )
            let resourcesURL = contentsURL.appendingPathComponent(
                "Resources",
                isDirectory: true
            )
        #else
            let contentsURL = bundleURL
            let resourcesURL = bundleURL
        #endif

        try fileManager.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let information: [String: Any] = [
            "CFBundleDisplayName": "Device Hub Test",
            "CFBundleIdentifier": "com.example.devicehub.tests",
            "CFBundleName": "DeviceHubTests",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "42"
        ]
        let informationData = try PropertyListSerialization.data(
            fromPropertyList: information,
            format: .xml,
            options: 0
        )
        try informationData.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )

        for (relativePath, body) in resources {
            let resourceURL = resourcesURL.appendingPathComponent(
                relativePath
            )
            try fileManager.createDirectory(
                at: resourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try body.write(
                to: resourceURL,
                atomically: true,
                encoding: .utf8
            )
        }

        guard let bundle = Bundle(url: bundleURL) else {
            throw TemporaryAboutBundleError.invalidBundle
        }
        self.bundle = bundle
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: bundleURL)
        } catch {
            Issue.record(
                "Could not remove temporary about bundle: \(error)"
            )
        }
    }
}

private enum TemporaryAboutBundleError: Error {
    case invalidBundle
}
