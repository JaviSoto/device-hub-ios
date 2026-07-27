import DeviceHubCore
import Foundation

enum KnownDeviceResolutionError: Error, Equatable, Sendable {
    case ambiguousAuthTags
    case duplicateKnownDevice
    case invalidAlternateIRK
}

/// App-internal discovery identity derived from one authenticated pair record.
///
/// Neither the peer identity-resolution key nor the device identifier may
/// appear in logs or reflection. The value exists only in memory while Bonjour
/// discovery is active.
struct KnownRemotePairingDevice:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Sendable
{
    let deviceID: DeviceID
    private let alternateIRK: Data

    init(deviceID: DeviceID, alternateIRK: Data) throws {
        guard
            alternateIRK.count == 16,
            alternateIRK.contains(where: { $0 != 0 })
        else {
            throw KnownDeviceResolutionError.invalidAlternateIRK
        }
        self.alternateIRK = alternateIRK
        self.deviceID = deviceID
    }

    func authTag(for serviceIdentifier: String) -> Data {
        RemotePairingAuthTag.compute(
            alternateIRK: alternateIRK,
            serviceIdentifier: serviceIdentifier
        )
    }

    var description: String {
        "<redacted-known-device-identity>"
    }

    var debugDescription: String {
        description
    }
}

enum KnownDeviceResolver {
    static func validate(
        _ devices: [KnownRemotePairingDevice]
    ) throws {
        var identifiers: Set<DeviceID> = []
        for device in devices {
            guard identifiers.insert(device.deviceID).inserted else {
                throw KnownDeviceResolutionError.duplicateKnownDevice
            }
        }
    }

    /// Resolves only an authenticated, unambiguous Bonjour identity.
    ///
    /// Multiple `authTag` fields are legitimate when a target knows multiple
    /// controllers. A service matching multiple durable records indicates
    /// corrupt state and is rejected rather than choosing one arbitrarily.
    static func resolve(
        _ service: ValidatedRemotePairingService,
        among devices: [KnownRemotePairingDevice]
    ) throws -> DeviceID? {
        try validate(devices)
        let matches = devices.filter { device in
            service.authTags.contains(
                device.authTag(for: service.identifier)
            )
        }
        guard matches.count <= 1 else {
            throw KnownDeviceResolutionError.ambiguousAuthTags
        }
        return matches.first?.deviceID
    }
}
