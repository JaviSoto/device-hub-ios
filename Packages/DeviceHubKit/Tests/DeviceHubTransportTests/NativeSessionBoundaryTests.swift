import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Native session boundary")
struct NativeSessionBoundaryTests {
    @Test("FFI-bound text rejects leading and trailing whitespace")
    func ffiTextRejectsOuterWhitespace() throws {
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeController(udid: " controller")
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeController(udid: "controller ")
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeTarget(deviceID: " device")
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeTarget(accountIdentifier: "account ")
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeTarget(peerIdentifier: "\u{00A0}peer")
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeTarget(displayName: "Test iPhone\u{2003}")
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try Self.makeTarget(productType: "\tDeviceModel")
        }
        #expect(try Self.makeTarget().displayName == "Test iPhone")
        #expect(
            try Self.makeRemoteService().identifier.uuidString
                == "5C862BC6-B21B-4AE5-9FA9-ED80E62B6948"
        )
    }

    @Test("remote services accept at most Rust's 32 authentication tags")
    func authenticationTagLimit() throws {
        let maximumTags = (0 ..< 32).map(Self.authenticationTag)
        let accepted = try Self.makeRemoteService(authTags: maximumTags)
        #expect(accepted.authTags.count == 32)

        let tooManyTags = (0 ..< 33).map(Self.authenticationTag)
        #expect(throws: NativeSessionContractError.invalidAuthenticationTags) {
            try Self.makeRemoteService(authTags: tooManyTags)
        }
    }

    @Test("endpoint validation rejects local, malformed, and unsafe shapes")
    func endpointValidation() throws {
        let ipv4 = try NativeResolvedEndpoint(
            family: .ipv4,
            address: Data([192, 168, 1, 44]),
            scopeID: 0,
            port: 49155
        )
        #expect(ipv4.family == .ipv4)

        #expect(throws: NativeSessionContractError.self) {
            try NativeResolvedEndpoint(
                family: .ipv4,
                address: Data(repeating: 1, count: 16),
                scopeID: 0,
                port: 49155
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeResolvedEndpoint(
                family: .ipv6,
                address: Data([
                    0xFE, 0x80, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 1
                ]),
                scopeID: 0,
                port: 49155
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeResolvedEndpoint(
                family: .ipv4,
                address: Data([224, 0, 0, 1]),
                scopeID: 0,
                port: 49155
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeResolvedEndpoint(
                family: .ipv4,
                address: Data([127, 0, 0, 1]),
                scopeID: 0,
                port: 49155
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeResolvedEndpoint(
                family: .ipv4,
                address: Data([255, 255, 255, 255]),
                scopeID: 0,
                port: 49155
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeResolvedEndpoint(
                family: .ipv6,
                address: Data([
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 1
                ]),
                scopeID: 0,
                port: 49155
            )
        }

        let rfc3927 = try NativeResolvedEndpoint(
            family: .ipv4,
            address: Data([169, 254, 9, 8]),
            scopeID: 0,
            port: 49155
        )
        #expect(rfc3927.family == .ipv4)
        let scopedIPv6 = try NativeResolvedEndpoint(
            family: .ipv6,
            address: Data([
                0xFE, 0x80, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 1
            ]),
            scopeID: 7,
            port: 49155
        )
        #expect(scopedIPv6.scopeID == 7)
    }

    @Test("screenshots enforce PNG identity, dimensions, and bounded size")
    func screenshotValidation() throws {
        let png = pngHeader(width: 440, height: 956)
        let screenshot = try NativeScreenshot(
            bytes: png,
            pixelSize: PixelSize(width: 440, height: 956)
        )
        #expect(screenshot.pixelSize == PixelSize(width: 440, height: 956))

        #expect(throws: NativeSessionContractError.self) {
            try NativeScreenshot(
                bytes: Data(repeating: 0, count: 33),
                pixelSize: PixelSize(width: 440, height: 956)
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeScreenshot(
                bytes: png,
                pixelSize: PixelSize(width: 956, height: 440)
            )
        }
        #expect(throws: NativeSessionContractError.self) {
            try NativeScreenshot(
                bytes: pngHeader(width: 20000, height: 1),
                pixelSize: PixelSize(width: 20000, height: 1)
            )
        }
    }
}

extension NativeSessionBoundaryTests {
    @Test("session forwards lifecycle calls without exposing an artifact")
    func sessionOperations() async throws {
        let probe = NativeSessionProbe()
        let session = probe.session
        let requestID = try #require(
            NativePersistenceRequestID(rawValue: 42)
        )

        try await session.start()
        try await session.completePersistence(
            requestID,
            outcome: .succeeded
        )
        try await session.send(.button(.home, phase: .press))
        try await session.cancel()

        let operations = await probe.operations
        expectNoDifference(
            operations,
            [
                .start,
                .completePersistence(requestID, .succeeded),
                .command(.button(.home, phase: .press)),
                .cancel
            ]
        )
    }

    @Test("client forwards one Pair Verify probe through its public boundary")
    func clientPairVerifyProbe() async throws {
        let probe = NativePairVerifyClientProbe()
        let unavailable = NativeSessionFailure(
            code: "invalid_state",
            stage: "native_boundary",
            retryable: false
        )
        let client = NativeSessionClient(
            capabilities: [.pairVerifyDiscovery],
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw unavailable
            },
            makeRemoteSession: { _ async throws(NativeSessionFailure) in
                throw unavailable
            },
            verifyRemotePairing: { request in
                await probe.record(request.target.deviceID)
            }
        )
        let request = try NativeRemoteSessionRequest(
            generation: SessionGeneration(
                rawValue: #require(
                    UUID(
                        uuidString:
                        "00112233-4455-6677-8899-AABBCCDDEEFF"
                    )
                )
            ),
            controller: Self.makeController(),
            target: Self.makeTarget(deviceID: "test-phone"),
            service: Self.makeRemoteService()
        )

        try await client.verifyRemotePairing(request)

        #expect(await probe.deviceIDs == [DeviceID(rawValue: "test-phone")])
    }
}

private extension NativeSessionBoundaryTests {
    static func authenticationTag(_ index: Int) -> Data {
        Data([UInt8(index), 0, 0, 0, 0, 0])
    }

    private static func makeController(
        udid: String = "controller"
    ) throws -> NativeControllerIdentity {
        try NativeControllerIdentity(
            identifier: #require(
                UUID(uuidString: "D0A4A010-580E-4C4E-A9E1-06EE86ED79E2")
            ),
            udid: udid,
            longTermSecretKey: Data(repeating: 1, count: 32),
            alternateIRK: Data(repeating: 2, count: 16)
        )
    }

    private static func makeRemoteService(
        authTags: [Data] = [Data([1, 2, 3, 4, 5, 6])]
    ) throws -> NativeRemoteService {
        try NativeRemoteService(
            endpoint: NativeResolvedEndpoint(
                family: .ipv4,
                address: Data([192, 168, 1, 44]),
                scopeID: 0,
                port: 49155
            ),
            identifier: #require(
                UUID(uuidString: "5C862BC6-B21B-4AE5-9FA9-ED80E62B6948")
            ),
            authTags: authTags
        )
    }

    private static func makeTarget(
        deviceID: String = "device",
        accountIdentifier: String = "account",
        peerIdentifier: String = "peer",
        displayName: String = "Test iPhone",
        productType: String = "DeviceModel"
    ) throws -> NativeTargetPairingRecord {
        try NativeTargetPairingRecord(
            deviceID: DeviceID(rawValue: deviceID),
            accountIdentifier: accountIdentifier,
            peerIdentifier: peerIdentifier,
            peerPublicKey: Data(repeating: 3, count: 32),
            peerAlternateIRK: Data(repeating: 4, count: 16),
            displayName: displayName,
            productType: productType,
            completion: .committed
        )
    }
}

private func pngHeader(width: UInt32, height: UInt32) -> Data {
    var data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13,
        0x49, 0x48, 0x44, 0x52
    ])
    for value in [width, height] {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
    data.append(contentsOf: [
        8, 6, 0, 0, 0,
        0, 0, 0, 0
    ])
    return data
}

private actor NativeSessionProbe {
    enum Operation: Equatable {
        case cancel
        case command(DeviceCommand)
        case completePersistence(
            NativePersistenceRequestID,
            NativePersistenceOutcome
        )
        case start
    }

    private(set) var operations: [Operation] = []

    nonisolated var session: NativeSession {
        NativeSession(
            events: AsyncThrowingStream { _ in },
            start: {
                await self.append(.start)
            },
            completePersistence: { requestID, outcome in
                await self.append(
                    .completePersistence(requestID, outcome)
                )
            },
            send: { command in
                await self.append(.command(command))
            },
            cancel: {
                await self.append(.cancel)
            }
        )
    }

    private func append(_ operation: Operation) {
        operations.append(operation)
    }
}

private actor NativePairVerifyClientProbe {
    private(set) var deviceIDs: [DeviceID] = []

    func record(_ deviceID: DeviceID) {
        deviceIDs.append(deviceID)
    }
}
