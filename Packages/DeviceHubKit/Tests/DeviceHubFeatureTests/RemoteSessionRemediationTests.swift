import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session remediation")
struct RemoteSessionRemediationTests {
    @Test("Try Again starts a new selected-device connection")
    func retryStartsConnection() async {
        let attemptID = UUID(
            uuid: (
                28, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        )
        let now = Date(timeIntervalSince1970: 2800)
        let clock = TestClock()
        let device = DeviceSummary(
            id: DeviceID(rawValue: "device"),
            name: "Test iPhone",
            productType: "iPhone",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .reachable
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                remediation: DeviceHubRemediation(error: .deviceLocked),
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = now
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
            $0.uuid = .constant(attemptID)
        }

        await store.send(.remediationButtonTapped) {
            $0.remediation = nil
        }
        await store.receive(\.retrySelectedDevice) {
            $0.session = ActiveRemoteSession(
                attemptID: attemptID,
                device: device,
                evaluatedAt: now
            )
        }
        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
    }

    @Test("Pairing can request Local Network Settings from the app shell")
    func pairingRequestsLocalNetworkSettings() async {
        let requestID = UUID(
            uuid: (
                29, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                pairing: PairingFeature.State(
                    remediation: DeviceHubRemediation(
                        error: .localNetworkDenied
                    )
                )
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
        }

        await store.send(
            .pairing(
                .presented(
                    .delegate(
                        .remediationRequested(
                            .grantLocalNetworkAccess
                        )
                    )
                )
            )
        ) {
            $0.externalRemediation = ExternalRemediationRequest(
                id: requestID,
                remedy: .grantLocalNetworkAccess
            )
            $0.pairing = nil
        }
    }

    @Test(
        "Developer-image errors require Xcode preparation",
        arguments: [
            DeviceHubError.developerImageUnavailable,
            DeviceHubError.developerImageIncompatible
        ]
    )
    func developerImageErrorsRequireXcode(
        error: DeviceHubError
    ) async {
        let device = DeviceSummary(
            id: DeviceID(rawValue: "device"),
            name: "Test iPhone",
            productType: "iPhone",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .reachable
        )
        let requestID = UUID(
            uuid: (
                30, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        )
        let connectionProbe = ConnectionProbe()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                remediation: DeviceHubRemediation(error: error),
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub.connect = { _ in
                await connectionProbe.record()
                throw DeviceHubError.secureConnectionFailed
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.remediationButtonTapped) {
            $0.externalRemediation = ExternalRemediationRequest(
                id: requestID,
                remedy: .prepareWithXcode
            )
        }
        let didConnect = await connectionProbe.wasInvoked
        #expect(!didConnect)
    }
}

private actor ConnectionProbe {
    private var didInvoke = false

    func record() {
        didInvoke = true
    }

    var wasInvoked: Bool {
        didInvoke
    }
}
