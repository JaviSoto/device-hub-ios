import Foundation

/// Stable, app-owned identity for a target device.
public struct DeviceID: Codable, Hashable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Whether this controller has durable credentials for a target device.
public enum DevicePairingState: Codable, Equatable, Sendable {
    case paired
    case requiresPairing
}

/// Current local-network availability reported for a known target.
public enum DeviceReachability: Codable, Equatable, Sendable {
    case reachable
    case unavailable
}

/// User-facing identity and availability for one target device.
public struct DeviceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: DeviceID
    public var name: String
    /// Authenticated OS version, or `nil` until device metadata is available.
    public var operatingSystemVersion: String?
    public var pairingState: DevicePairingState
    public var productType: String
    public var reachability: DeviceReachability

    public init(
        id: DeviceID,
        name: String,
        productType: String,
        operatingSystemVersion: String?,
        pairingState: DevicePairingState,
        reachability: DeviceReachability
    ) {
        self.id = id
        self.name = name
        self.operatingSystemVersion = operatingSystemVersion
        self.pairingState = pairingState
        self.productType = productType
        self.reachability = reachability
    }
}

/// Canonically ordered device collection with stable selection rules.
///
/// Discovery order is intentionally discarded because network callbacks are
/// nondeterministic. The first snapshot for a duplicate identifier wins.
public struct DeviceRoster: Equatable, Sendable {
    public var devices: [DeviceSummary] {
        didSet {
            devices = Self.canonicalized(devices)
        }
    }

    public init(devices: [DeviceSummary] = []) {
        self.devices = Self.canonicalized(devices)
    }

    /// First target that is both paired and currently reachable.
    public var preferredSelectionID: DeviceID? {
        devices.first {
            $0.pairingState == .paired && $0.reachability == .reachable
        }?.id
    }

    /// Preserves a selected device as long as it remains known.
    ///
    /// In particular, a temporary network loss never jumps the user to a
    /// different device. A missing selection falls back only to a reachable,
    /// paired target.
    public func selectionID(preserving selectionID: DeviceID?) -> DeviceID? {
        if let selectionID, devices.contains(where: { $0.id == selectionID }) {
            return selectionID
        }
        return preferredSelectionID
    }

    private static func canonicalized(
        _ devices: [DeviceSummary]
    ) -> [DeviceSummary] {
        var seenIDs: Set<DeviceID> = []
        return devices
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let lhsKey = sortKey(for: lhs)
                let rhsKey = sortKey(for: rhs)
                if lhsKey.priority != rhsKey.priority {
                    return lhsKey.priority < rhsKey.priority
                }
                if lhsKey.name != rhsKey.name {
                    return lhsKey.name < rhsKey.name
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    private static func sortKey(
        for device: DeviceSummary
    ) -> (priority: Int, name: String) {
        let priority = switch (
            device.pairingState,
            device.reachability
        ) {
        case (.paired, .reachable):
            0
        case (.paired, .unavailable):
            1
        case (.requiresPairing, .reachable):
            2
        case (.requiresPairing, .unavailable):
            3
        }
        return (priority, device.name.lowercased())
    }
}
