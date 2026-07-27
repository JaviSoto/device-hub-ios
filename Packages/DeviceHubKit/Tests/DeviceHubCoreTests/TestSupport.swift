import DeviceHubCore

extension DeviceSummary {
    static func fixture(
        id: String,
        name: String = "Test iPhone",
        pairingState: DevicePairingState = .paired,
        reachability: DeviceReachability = .reachable
    ) -> Self {
        Self(
            id: DeviceID(rawValue: id),
            name: name,
            productType: "iPhone15,3",
            operatingSystemVersion: "27.0",
            pairingState: pairingState,
            reachability: reachability
        )
    }
}
