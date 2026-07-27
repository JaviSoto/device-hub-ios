import CustomDump
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Remote-pairing Bonjour TXT")
struct RemotePairingTXTTests {
    @Test("pairable-host TXT uses the stable identity and protocol versions")
    func pairableHostTXT() throws {
        let identifier = try #require(UUID(
            uuidString: "2BE6E510-0325-4365-923E-B14C6F57DB3A"
        ))
        let alternateIRK = try #require(Data(
            base64Encoded: "Mgp6ZGPzXM2ku9br46vsiw=="
        ))

        let advertisement = try PairableHostAdvertisement(
            identifier: identifier,
            alternateIRK: alternateIRK,
            displayName: "Device Hub",
            model: "Mac17,7",
            listenerPort: 49155
        )

        #expect(
            advertisement.serviceType
                == "_remotepairing-pairable-host._tcp."
        )
        #expect(
            advertisement.serviceName
                == "2BE6E510-0325-4365-923E-B14C6F57DB3A"
        )
        #expect(advertisement.listenerPort == 49155)
        try expectNoDifference(
            RemotePairingTXTCodec.entries(
                from: advertisement.txtRecord
            ),
            [
                RemotePairingTXTEntry(key: .name, value: "Device Hub"),
                RemotePairingTXTEntry(
                    key: .identifier,
                    value: "2BE6E510-0325-4365-923E-B14C6F57DB3A"
                ),
                RemotePairingTXTEntry(
                    key: .authTag,
                    value: "kXjlTr2l"
                ),
                RemotePairingTXTEntry(key: .model, value: "Mac17,7"),
                RemotePairingTXTEntry(key: .flags, value: "1"),
                RemotePairingTXTEntry(key: .version, value: "26"),
                RemotePairingTXTEntry(
                    key: .minimumVersion,
                    value: "17"
                )
            ]
        )
    }

    @Test("iOS 27 target advertisement matches the live wire contract")
    func iOS27TargetAdvertisement() throws {
        let targetIdentifier = "FF3C60C8-FEDB-442C-AF20-BC1A5BD3C632"
        let service = try ValidatedRemotePairingService(
            serviceName: targetIdentifier,
            hostName: "test-ipad.local.",
            port: 49152,
            resolvedEndpoints: [
                NativeResolvedEndpoint(
                    family: .ipv4,
                    address: Data([192, 168, 1, 44]),
                    scopeID: 0,
                    port: 49152
                )
            ],
            txtRecord: makeTXT([
                ("identifier", targetIdentifier),
                ("authTag", "FMRC4BwF"),
                ("ver", "26"),
                ("minVer", "8"),
                ("flags", "0")
            ])
        )

        #expect(service.identifier == targetIdentifier)
        #expect(service.authTags == [Data(base64Encoded: "FMRC4BwF")])
    }

    @Test("TXT framing rejects truncation, empty keys, and unknown fields")
    func malformedFraming() {
        expectError(.truncatedEntry) {
            try RemotePairingTXTCodec.entries(from: Data([4, 0x61]))
        }
        expectError(.emptyKey) {
            try RemotePairingTXTCodec.entries(from: Data([2, 0x3D, 0x31]))
        }
        expectError(.unknownField) {
            let data = try makeTXT([("surprise", "value")])
            return try RemotePairingTXTCodec.entries(from: data)
        }
    }

    @Test("wire versions are parsed canonically and fail closed")
    func wireVersions() throws {
        for entries in [
            validEntries(replacing: ("ver", "27")),
            validEntries(replacing: ("minVer", "17")),
            validEntries(replacing: ("ver", "026")),
            validEntries(replacing: ("flags", "01")),
            validEntries(replacing: ("flags", "1"))
        ] {
            #expect(throws: RemotePairingTXTError.self) {
                try ValidatedRemotePairingService(
                    serviceName: identifier,
                    hostName: "test-iphone.local.",
                    port: 49155,
                    resolvedEndpoints: [testEndpoint()],
                    txtRecord: makeTXT(entries)
                )
            }
        }
    }

    @Test("all required fields are present exactly once")
    func requiredFieldsAndDuplicates() {
        var missingFlags = validEntries()
        missingFlags.removeAll { $0.0 == "flags" }
        expectError(.missingField(.flags)) {
            try validatedService(entries: missingFlags)
        }

        var duplicateFlags = validEntries()
        duplicateFlags.append(("flags", "0"))
        expectError(.duplicateField(.flags)) {
            try validatedService(entries: duplicateFlags)
        }

        var duplicateAuthTag = validEntries()
        duplicateAuthTag.append(("authTag", "kXjlTr2l"))
        expectError(.duplicateAuthTag) {
            try validatedService(entries: duplicateAuthTag)
        }
    }

    @Test("multiple unique auth tags are preserved for authenticated matching")
    func multipleAuthTags() throws {
        var entries = validEntries()
        entries.append(("authTag", "AQIDBAUG"))

        let service = try validatedService(entries: entries)

        try expectNoDifference(
            service.authTags,
            [
                #require(Data(base64Encoded: "kXjlTr2l")),
                #require(Data(base64Encoded: "AQIDBAUG"))
            ]
        )
    }

    @Test("auth tags must be canonical base64 containing exactly six bytes")
    func authTagEncoding() {
        for value in [
            "",
            "not-base64",
            "AQIDBAU=",
            "AQIDBAUGBw==",
            " kXjlTr2l",
            "kXjlTr2l\n"
        ] {
            expectError(.invalidAuthTag) {
                try validatedService(
                    entries: validEntries(replacing: ("authTag", value))
                )
            }
        }
    }

    @Test("service identity, endpoint, and text fields are validated")
    func identityEndpointAndText() throws {
        #expect(throws: RemotePairingTXTError.self) {
            try ValidatedRemotePairingService(
                serviceName: "different",
                hostName: "test-iphone.local.",
                port: 49155,
                resolvedEndpoints: [testEndpoint()],
                txtRecord: makeTXT(validEntries())
            )
        }
        #expect(throws: RemotePairingTXTError.self) {
            try ValidatedRemotePairingService(
                serviceName: identifier,
                hostName: "not a host",
                port: 49155,
                resolvedEndpoints: [testEndpoint()],
                txtRecord: makeTXT(validEntries())
            )
        }
        #expect(throws: RemotePairingTXTError.self) {
            try ValidatedRemotePairingService(
                serviceName: identifier,
                hostName: "test-iphone.local.",
                port: 0,
                resolvedEndpoints: [testEndpoint()],
                txtRecord: makeTXT(validEntries())
            )
        }
    }

    @Test("resolved numeric endpoints are required and port-bound")
    func resolvedEndpoints() throws {
        let service = try validatedService()
        try expectNoDifference(service.resolvedEndpoints, [testEndpoint()])

        expectError(.missingResolvedEndpoint) {
            try ValidatedRemotePairingService(
                serviceName: identifier,
                hostName: "test-iphone.local.",
                port: 49155,
                resolvedEndpoints: [],
                txtRecord: makeTXT(validEntries())
            )
        }
        expectError(.endpointPortMismatch) {
            try ValidatedRemotePairingService(
                serviceName: identifier,
                hostName: "test-iphone.local.",
                port: 49155,
                resolvedEndpoints: [
                    NativeResolvedEndpoint(
                        family: .ipv4,
                        address: Data([192, 168, 1, 44]),
                        scopeID: 0,
                        port: 49156
                    )
                ],
                txtRecord: makeTXT(validEntries())
            )
        }
    }

    @Test("equivalent endpoint sets have one canonical representation")
    func canonicalResolvedEndpoints() throws {
        let first = try testEndpoint()
        let second = try NativeResolvedEndpoint(
            family: .ipv4,
            address: Data([192, 168, 1, 45]),
            scopeID: 0,
            port: 49155
        )
        let forward = try validatedService(
            resolvedEndpoints: [first, second, first]
        )
        let reversed = try validatedService(
            resolvedEndpoints: [second, first]
        )

        #expect(forward == reversed)
        expectNoDifference(
            forward.resolvedEndpoints,
            reversed.resolvedEndpoints
        )
        expectNoDifference(
            forward.resolvedEndpoints,
            [first, second]
        )
    }

    @Test("redacted descriptions never reveal network or auth-tag values")
    func redaction() throws {
        let service = try validatedService()
        let description = String(describing: service)
        let debugDescription = String(reflecting: service)

        #expect(description == "<redacted-remote-pairing-service>")
        #expect(debugDescription == "<redacted-remote-pairing-service>")
        #expect(!description.contains("test-iphone"))
        #expect(!description.contains("kXjlTr2l"))
        #expect(!debugDescription.contains(identifier))
    }
}

let identifier = "2BE6E510-0325-4365-923E-B14C6F57DB3A"

private func validEntries(
    replacing replacement: (String, String)? = nil
) -> [(String, String)] {
    let replacement = replacement
    return [
        ("identifier", identifier),
        ("authTag", "kXjlTr2l"),
        ("flags", "0"),
        ("ver", "26"),
        ("minVer", "8")
    ]
    .map { entry in
        guard let replacement, replacement.0 == entry.0 else {
            return entry
        }
        return replacement
    }
}

private func validatedService(
    entries: [(String, String)] = validEntries(),
    resolvedEndpoints: [NativeResolvedEndpoint]? = nil
) throws -> ValidatedRemotePairingService {
    try ValidatedRemotePairingService(
        serviceName: identifier,
        hostName: "test-iphone.local.",
        port: 49155,
        resolvedEndpoints: resolvedEndpoints ?? [testEndpoint()],
        txtRecord: makeTXT(entries)
    )
}

func testEndpoint() throws -> NativeResolvedEndpoint {
    try NativeResolvedEndpoint(
        family: .ipv4,
        address: Data([192, 168, 1, 44]),
        scopeID: 0,
        port: 49155
    )
}

func makeTXT(
    _ entries: [(String, String)]
) throws -> Data {
    var data = Data()
    for (key, value) in entries {
        let bytes = Data("\(key)=\(value)".utf8)
        guard let length = UInt8(exactly: bytes.count) else {
            throw TestFixtureError.entryTooLong
        }
        data.append(length)
        data.append(bytes)
    }
    return data
}

private func expectError(
    _ expected: RemotePairingTXTError,
    operation: () throws -> some Any
) {
    do {
        _ = try operation()
        Issue.record("Expected \(expected)")
    } catch let error as RemotePairingTXTError {
        expectNoDifference(error, expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private enum TestFixtureError: Error {
    case entryTooLong
}
