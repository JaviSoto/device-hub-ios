import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native constructor input marshalling")
struct DeviceHubNativeInputMarshallerTests {
    @Test("pairing graph uses exact ABI sizes and copied controller values")
    func pairingConfiguration() throws {
        let request = try pairingRequest()

        try DeviceHubNativeInputMarshaller.withPairingConfiguration(
            request: request,
            callback: nil,
            callbackContext: nil
        ) { configuration in
            let value = configuration.pointee
            #expect(
                value.struct_size
                    == UInt32(MemoryLayout<DhPairingSessionConfig>.size)
            )
            #expect(value.abi_version == DeviceHubNativeABI.expectedVersion)
            #expect(value.generation.high == 0x0011_2233_4455_6677)
            #expect(value.generation.low == 0x8899_AABB_CCDD_EEFF)
            #expect(copy(value.display_name) == Data("Device Hub".utf8))
            #expect(copy(value.model) == Data("iPhone".utf8))
            #expect(value.requested_port == 49155)

            let controller = try #require(value.controller_identity)
                .pointee
            #expect(
                controller.struct_size
                    == UInt32(MemoryLayout<DhControllerIdentity>.size)
            )
            #expect(
                copy(controller.identifier)
                    == Data(
                        "10213243-5465-7687-98A9-BACBDCEDFE0F".utf8
                    )
            )
            #expect(copy(controller.udid) == Data("controller-udid".utf8))
            #expect(
                copy(controller.long_term_secret_key)
                    == Data(repeating: 0x11, count: 32)
            )
            #expect(
                copy(controller.alternate_irk)
                    == Data(repeating: 0x22, count: 16)
            )
        }
    }

    @Test("remote graph binds endpoint, peer, TXT, and native-owned media")
    func remoteConfiguration() throws {
        let request = try remoteRequest()

        try DeviceHubNativeInputMarshaller.withRemoteConfiguration(
            request: request,
            operation: .controlStream,
            callbacks: DeviceHubNativeRemoteCallbacks(
                control: nil,
                controlContext: nil,
                media: nil,
                mediaContext: nil
            )
        ) { configuration in
            let value = configuration.pointee
            #expect(
                value.struct_size
                    == UInt32(MemoryLayout<DhRemoteSessionConfig>.size)
            )
            #expect(value.abi_version == DeviceHubNativeABI.expectedVersion)
            #expect(value.operation == DH_REMOTE_OPERATION_CONTROL_STREAM)
            #expect(copy(value.video_negotiator_offer).isEmpty)

            let target = try #require(value.target).pointee
            #expect(copy(target.device_id) == Data("test-phone".utf8))
            #expect(
                copy(target.peer_public_key)
                    == Data(repeating: 0x33, count: 32)
            )
            #expect(
                target.completion == DH_PAIRING_COMPLETION_COMMITTED
            )

            let service = try #require(value.service).pointee
            #expect(service.endpoint.family == DH_IP_FAMILY_IPV4)
            #expect(service.endpoint.scope_id == 0)
            #expect(service.endpoint.port == 58783)
            var address = service.endpoint.address
            let addressBytes = withUnsafeBytes(of: &address, Array.init)
            #expect(
                addressBytes
                    == [192, 168, 1, 25] + Array(repeating: 0, count: 12)
            )
            #expect(
                copy(service.identifier)
                    == Data(
                        "AABBCCDD-EEFF-4011-9234-556677889900".utf8
                    )
            )
            #expect(
                copy(service.auth_tags)
                    == Data([
                        1, 2, 3, 4, 5, 6,
                        7, 8, 9, 10, 11, 12
                    ])
            )
            #expect(
                service.wire_protocol_version
                    == NativeRemoteService.wireProtocolVersion
            )
            #expect(
                service.minimum_wire_protocol_version
                    == NativeRemoteService.minimumWireProtocolVersion
            )
            #expect(service.flags == NativeRemoteService.flags)
        }
    }

    @Test("Pair Verify probe has no media or negotiation inputs")
    func pairVerifyConfiguration() throws {
        let request = try remoteRequest()
        let controlContext = UnsafeMutableRawPointer(bitPattern: 0xCAFE)

        DeviceHubNativeInputMarshaller.withRemoteConfiguration(
            request: request,
            operation: .pairVerify,
            callbacks: DeviceHubNativeRemoteCallbacks(
                control: nil,
                controlContext: controlContext,
                media: ignoredMediaCallback,
                mediaContext: UnsafeMutableRawPointer(bitPattern: 0xBEEF)
            )
        ) { configuration in
            let value = configuration.pointee
            #expect(value.operation == DH_REMOTE_OPERATION_PAIR_VERIFY)
            #expect(copy(value.video_negotiator_offer).isEmpty)
            #expect(value.callback_context == controlContext)
            #expect(value.media_callback == nil)
            #expect(value.media_callback_context == nil)
        }
    }

    private func pairingRequest() throws -> NativePairingSessionRequest {
        try NativePairingSessionRequest(
            generation: generation,
            controller: controller,
            displayName: "Device Hub",
            model: "iPhone",
            requestedPort: 49155
        )
    }

    private func remoteRequest() throws -> NativeRemoteSessionRequest {
        try NativeRemoteSessionRequest(
            generation: generation,
            controller: controller,
            target: NativeTargetPairingRecord(
                deviceID: DeviceID(rawValue: "test-phone"),
                accountIdentifier: "account",
                peerIdentifier: "peer",
                peerPublicKey: Data(repeating: 0x33, count: 32),
                peerAlternateIRK: Data(repeating: 0x44, count: 16),
                displayName: "Test iPhone",
                productType: "iPhone18,2",
                completion: .committed
            ),
            service: NativeRemoteService(
                endpoint: NativeResolvedEndpoint(
                    family: .ipv4,
                    address: Data([192, 168, 1, 25]),
                    scopeID: 0,
                    port: 58783
                ),
                identifier: UUID(
                    uuidString: "AABBCCDD-EEFF-4011-9234-556677889900"
                )!,
                authTags: [
                    Data([1, 2, 3, 4, 5, 6]),
                    Data([7, 8, 9, 10, 11, 12])
                ]
            )
        )
    }

    private var controller: NativeControllerIdentity {
        get throws {
            try NativeControllerIdentity(
                identifier: UUID(
                    uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F"
                )!,
                udid: "controller-udid",
                longTermSecretKey: Data(repeating: 0x11, count: 32),
                alternateIRK: Data(repeating: 0x22, count: 16)
            )
        }
    }

    private var generation: SessionGeneration {
        SessionGeneration(
            rawValue: UUID(
                uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
            )!
        )
    }

    private func copy(_ bytes: DhBytes) -> Data {
        guard let data = bytes.data else {
            return Data()
        }
        return Data(bytes: data, count: bytes.count)
    }
}

private let ignoredMediaCallback: DhMediaEventCallback = { _, _ in }
