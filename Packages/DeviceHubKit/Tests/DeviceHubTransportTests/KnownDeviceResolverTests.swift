import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Authenticated remote-pairing discovery")
struct KnownDeviceResolverTests {
    @Test("a valid tag maps the service to one known device")
    func oneKnownDeviceMatches() throws {
        let service = try makeService(authTags: ["kXjlTr2l"])
        let device = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "test-phone"),
            alternateIRK: #require(Data(
                base64Encoded: "Mgp6ZGPzXM2ku9br46vsiw=="
            ))
        )

        let match = try KnownDeviceResolver.resolve(
            service,
            among: [device]
        )

        expectNoDifference(
            match,
            DeviceID(rawValue: "test-phone")
        )
    }

    @Test("an unknown authentication tag produces no availability")
    func unknownTagDoesNotMatch() throws {
        let service = try makeService(authTags: ["AQIDBAUG"])
        let device = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "test-phone"),
            alternateIRK: Data((1 ... 16).map(UInt8.init))
        )

        #expect(
            try KnownDeviceResolver.resolve(service, among: [device]) == nil
        )
    }

    @Test("a service matching multiple records fails closed")
    func ambiguousMatchFailsClosed() throws {
        let first = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "first"),
            alternateIRK: Data((1 ... 16).map(UInt8.init))
        )
        let second = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "second"),
            alternateIRK: Data((17 ... 32).map(UInt8.init))
        )
        let service = try makeService(authTags: [
            first.authTag(for: identifier).base64EncodedString(),
            second.authTag(for: identifier).base64EncodedString()
        ])

        #expect(throws: KnownDeviceResolutionError.ambiguousAuthTags) {
            try KnownDeviceResolver.resolve(
                service,
                among: [first, second]
            )
        }
    }

    @Test("duplicate durable identities fail before browsing")
    func duplicateKnownDeviceFailsClosed() throws {
        let first = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "duplicate"),
            alternateIRK: Data((1 ... 16).map(UInt8.init))
        )
        let second = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "duplicate"),
            alternateIRK: Data((17 ... 32).map(UInt8.init))
        )

        #expect(throws: KnownDeviceResolutionError.duplicateKnownDevice) {
            try KnownDeviceResolver.validate([first, second])
        }
    }

    @Test("matching identities are universally redacted")
    func identityRedaction() throws {
        let device = try KnownRemotePairingDevice(
            deviceID: DeviceID(rawValue: "secret-tracking-id"),
            alternateIRK: Data((1 ... 16).map(UInt8.init))
        )

        #expect(
            String(describing: device) == "<redacted-known-device-identity>"
        )
        #expect(
            String(reflecting: device) == "<redacted-known-device-identity>"
        )
    }
}

private func makeService(
    authTags: [String]
) throws -> ValidatedRemotePairingService {
    var entries: [(String, String)] = [
        ("identifier", identifier),
        ("flags", "0"),
        ("ver", "26"),
        ("minVer", "8")
    ]
    entries.append(contentsOf: authTags.map { ("authTag", $0) })

    return try ValidatedRemotePairingService(
        serviceName: identifier,
        hostName: "test-iphone.local.",
        port: 49155,
        resolvedEndpoints: [testEndpoint()],
        txtRecord: makeTXT(entries)
    )
}
