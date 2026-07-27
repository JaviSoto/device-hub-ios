import ComposableArchitecture
import CustomDump
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session availability lifecycle")
struct RemoteSessionAvailabilityTests {
    @Test("An empty initial roster does not browse Bonjour availability")
    func emptyInitialRosterDefersAvailabilityBrowsing() async {
        let availabilityProbe = AvailabilityInvocationProbe()
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub.availability = {
                availabilityProbe.record()
                return AsyncStream { continuation in
                    continuation.finish()
                }
            }
            $0.deviceHub.pairedDevices = { [] }
        }

        await store.send(.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isLoadingRoster = false
        }

        expectNoDifference(
            availabilityProbe.invocationCount,
            0
        )
        #expect(store.state.pairing == nil)
        #expect(!store.state.isObservingAvailability)
    }

    @Test("A nonempty initial roster starts Bonjour availability")
    func nonemptyInitialRosterStartsAvailabilityBrowsing() async {
        let availabilityPipe = AsyncStream<
            [DeviceSummary]
        >.makeStream()
        let availabilityProbe = AvailabilityInvocationProbe()
        let pairedDevice = availabilityDevice(
            id: "paired",
            reachability: .unavailable
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub.availability = {
                availabilityProbe.record()
                return availabilityPipe.stream
            }
            $0.deviceHub.pairedDevices = { [pairedDevice] }
        }

        await store.send(.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isLoadingRoster = false
            $0.isObservingAvailability = true
            $0.roster = DeviceRoster(devices: [pairedDevice])
        }

        availabilityPipe.continuation.yield([pairedDevice])
        await store.receive(\.availabilitySnapshotReceived)
        expectNoDifference(
            availabilityProbe.invocationCount,
            1
        )

        await store.send(.appLifecycleChanged(.background)) {
            $0.isObservingAvailability = false
            $0.lifecycle = .background
        }
        availabilityPipe.continuation.finish()
    }

    @Test("First successful pairing starts availability after an empty roster")
    func firstPairingStartsAvailabilityBrowsing() async {
        let availabilityPipe = AsyncStream<
            [DeviceSummary]
        >.makeStream()
        let availabilityProbe = AvailabilityInvocationProbe()
        let pairedDevice = availabilityDevice(
            id: "paired",
            reachability: .unavailable
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                pairing: PairingFeature.State()
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub.availability = {
                availabilityProbe.record()
                return availabilityPipe.stream
            }
        }

        await store.send(
            .pairing(.presented(.delegate(.paired(pairedDevice))))
        ) {
            $0.isObservingAvailability = true
            $0.pairing = nil
            $0.roster = DeviceRoster(devices: [pairedDevice])
            $0.selectedDeviceID = pairedDevice.id
        }
        availabilityPipe.continuation.yield([pairedDevice])
        await store.receive(\.availabilitySnapshotReceived)
        expectNoDifference(
            availabilityProbe.invocationCount,
            1
        )

        await store.send(.appLifecycleChanged(.background)) {
            $0.isObservingAvailability = false
            $0.lifecycle = .background
        }
        availabilityPipe.continuation.finish()
    }
}

private func availabilityDevice(
    id: String,
    reachability: DeviceReachability
) -> DeviceSummary {
    DeviceSummary(
        id: DeviceID(rawValue: id),
        name: "Test iPhone",
        productType: "iPhone",
        operatingSystemVersion: "27.0",
        pairingState: .paired,
        reachability: reachability
    )
}

private final class AvailabilityInvocationProbe: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    var invocationCount: Int {
        lock.withLock {
            count
        }
    }

    func record() {
        lock.withLock {
            count += 1
        }
    }
}
