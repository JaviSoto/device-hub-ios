import ComposableArchitecture
import CustomDump
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote-session toolbar presentation")
struct RemoteSessionToolbarPresentationTests {
    @Test("No selection is represented explicitly")
    func noSelection() {
        expectNoDifference(
            RemoteSessionFeature.State().toolbarPresentation,
            .noSelection
        )
    }

    @Test("Pairing-required selection cannot be described as no selection")
    func pairingRequired() {
        let device = toolbarDevice(pairingState: .requiresPairing)

        expectNoDifference(
            RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            ).toolbarPresentation,
            .pairingRequired(device)
        )
    }

    @Test("Stopped viewing takes precedence exactly as it does on the canvas")
    func viewingStopped() {
        let device = toolbarDevice(pairingState: .requiresPairing)

        expectNoDifference(
            RemoteSessionFeature.State(
                isViewingStopped: true,
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            ).toolbarPresentation,
            .viewingStopped(device)
        )
    }

    @Test("Session status comes from the selected session")
    func session() {
        let device = toolbarDevice()
        let session = ActiveRemoteSession(
            attemptID: UUID(
                uuid: (
                    7, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0
                )
            ),
            device: device,
            evaluatedAt: Date(timeIntervalSince1970: 1000)
        )

        expectNoDifference(
            RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: session
            ).toolbarPresentation,
            .session(
                device: device,
                presentation: .connecting(.locating)
            )
        )
    }

    @Test("Paired selections without a session show their real availability")
    func availabilityWithoutSession() {
        let reachable = toolbarDevice()
        let offline = toolbarDevice(
            id: "offline",
            reachability: .unavailable
        )

        expectNoDifference(
            RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [reachable]),
                selectedDeviceID: reachable.id
            ).toolbarPresentation,
            .session(
                device: reachable,
                presentation: .connecting(.locating)
            )
        )
        expectNoDifference(
            RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [offline]),
                selectedDeviceID: offline.id
            ).toolbarPresentation,
            .session(
                device: offline,
                presentation: .offline
            )
        )
    }

    @Test("A visible remediation replaces stale connection progress")
    func remediationReplacesConnectionProgress() {
        let device = toolbarDevice()
        let error = DeviceHubError.developerModeDisabled

        expectNoDifference(
            RemoteSessionFeature.State(
                remediation: DeviceHubRemediation(error: error),
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            ).toolbarPresentation,
            .session(
                device: device,
                presentation: .ended(error)
            )
        )
    }

    @Test("Losing the selected device clears the stopped-viewing label")
    func losingSelectionClearsStoppedViewing() async {
        let device = toolbarDevice()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                isViewingStopped: true,
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            )
        ) {
            RemoteSessionFeature()
        }

        await store.send(.availabilitySnapshotReceived([])) {
            $0.isViewingStopped = false
            $0.roster = DeviceRoster()
            $0.selectedDeviceID = nil
        }
        expectNoDifference(store.state.toolbarPresentation, .noSelection)
    }

    @Test("An unavailable replacement clears stopped-viewing state")
    func replacementSelectionClearsStoppedViewing() async {
        let first = toolbarDevice(id: "first")
        let replacement = toolbarDevice(
            id: "replacement",
            reachability: .unavailable
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                isViewingStopped: true,
                roster: DeviceRoster(devices: [first]),
                selectedDeviceID: first.id
            )
        ) {
            RemoteSessionFeature()
        }

        await store.send(.availabilitySnapshotReceived([replacement])) {
            $0.isViewingStopped = false
            $0.roster = DeviceRoster(devices: [replacement])
            $0.selectedDeviceID = nil
        }
        expectNoDifference(
            store.state.toolbarPresentation,
            .noSelection
        )
    }

    @Test("Stop viewing cannot create a stopped state without a selection")
    func stopViewingWithoutSelection() async {
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        }

        await store.send(.stopViewingButtonTapped)
        #expect(!store.state.isViewingStopped)
        expectNoDifference(store.state.toolbarPresentation, .noSelection)
    }
}

private func toolbarDevice(
    id: String = "test-phone",
    pairingState: DevicePairingState = .paired,
    reachability: DeviceReachability = .reachable
) -> DeviceSummary {
    DeviceSummary(
        id: DeviceID(rawValue: id),
        name: "Test iPhone",
        productType: "iPhone",
        operatingSystemVersion: "27.0",
        pairingState: pairingState,
        reachability: reachability
    )
}
