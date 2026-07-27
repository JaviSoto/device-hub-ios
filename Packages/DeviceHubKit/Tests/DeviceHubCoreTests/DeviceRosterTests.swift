import CustomDump
import DeviceHubCore
import Foundation
import Testing

struct DeviceRosterTests {
    @Test
    func preferredSelectionUsesFirstReachablePairedDevice() {
        let unavailable = DeviceSummary(
            id: DeviceID(rawValue: "unavailable"),
            name: "Bench iPhone",
            productType: "iPhone15,3",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .unavailable
        )
        let reachable = DeviceSummary(
            id: DeviceID(rawValue: "reachable"),
            name: "Test iPhone",
            productType: "iPhone15,3",
            operatingSystemVersion: "27.0",
            pairingState: .paired,
            reachability: .reachable
        )

        let roster = DeviceRoster(devices: [unavailable, reachable])

        expectNoDifference(roster.preferredSelectionID, reachable.id)
    }

    @Test
    func selectionPreservesTheCurrentDeviceWhenItBecomesUnavailable() {
        let selected = DeviceSummary.fixture(
            id: "selected",
            name: "Test iPhone",
            reachability: .unavailable
        )
        let available = DeviceSummary.fixture(
            id: "available",
            name: "Bench iPhone",
            reachability: .reachable
        )
        let roster = DeviceRoster(devices: [available, selected])

        expectNoDifference(
            roster.selectionID(preserving: selected.id),
            selected.id
        )
    }

    @Test
    func selectionFallsBackWhenTheCurrentDeviceDisappears() {
        let available = DeviceSummary.fixture(
            id: "available",
            name: "Test iPhone",
            reachability: .reachable
        )
        let roster = DeviceRoster(devices: [available])

        expectNoDifference(
            roster.selectionID(
                preserving: DeviceID(rawValue: "forgotten-device")
            ),
            available.id
        )
    }

    @Test
    func rosterHasDeterministicOrderAndDropsDuplicateSnapshots() {
        let unpaired = DeviceSummary.fixture(
            id: "unpaired",
            name: "Setup iPhone",
            pairingState: .requiresPairing,
            reachability: .reachable
        )
        let offline = DeviceSummary.fixture(
            id: "offline",
            name: "Zeta iPhone",
            reachability: .unavailable
        )
        let availableB = DeviceSummary.fixture(
            id: "available-b",
            name: "beta iPhone",
            reachability: .reachable
        )
        let availableA = DeviceSummary.fixture(
            id: "available-a",
            name: "Alpha iPhone",
            reachability: .reachable
        )
        let duplicate = DeviceSummary.fixture(
            id: "available-a",
            name: "A duplicate that must not replace the first snapshot",
            reachability: .unavailable
        )

        let roster = DeviceRoster(
            devices: [unpaired, offline, availableB, availableA, duplicate]
        )

        expectNoDifference(
            roster.devices.map(\.id),
            [
                DeviceID(rawValue: "available-a"),
                DeviceID(rawValue: "available-b"),
                DeviceID(rawValue: "offline"),
                DeviceID(rawValue: "unpaired")
            ]
        )
        expectNoDifference(roster.devices.first?.name, "Alpha iPhone")
    }

    @Test
    func noDeviceIsSelectedUntilAPairedDeviceIsReachable() {
        let requiresPairing = DeviceSummary.fixture(
            id: "requires-pairing",
            pairingState: .requiresPairing,
            reachability: .reachable
        )
        let offline = DeviceSummary.fixture(
            id: "offline",
            reachability: .unavailable
        )

        let roster = DeviceRoster(devices: [requiresPairing, offline])

        #expect(roster.preferredSelectionID == nil)
        #expect(roster.selectionID(preserving: nil) == nil)
    }

    @Test
    func pairedSummaryPreservesAnUnknownOSVersionThroughRosterAndCodable() throws {
        let summary = DeviceSummary(
            id: DeviceID(rawValue: "paired-before-rsd"),
            name: "Test iPhone",
            productType: "iPhone18,1",
            operatingSystemVersion: nil,
            pairingState: .paired,
            reachability: .reachable
        )

        let encoded = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(
            DeviceSummary.self,
            from: encoded
        )
        let roster = DeviceRoster(devices: [decoded])

        expectNoDifference(decoded, summary)
        #expect(decoded.operatingSystemVersion == nil)
        expectNoDifference(roster.devices, [summary])
        expectNoDifference(roster.preferredSelectionID, summary.id)
        expectNoDifference(
            roster.selectionID(preserving: summary.id),
            summary.id
        )
    }
}
