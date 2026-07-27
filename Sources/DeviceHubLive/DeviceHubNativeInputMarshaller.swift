import Darwin
import DeviceHubCore
import DeviceHubFFI
import DeviceHubTransport
import Foundation

/// Closure-scoped native storage for one constructor input graph.
///
/// Rust copies every borrowed span synchronously. This arena keeps all Swift
/// pointers stable for that call and explicitly clears every allocation before
/// releasing it, including identifiers and key material.
private final class DeviceHubNativeInputArena {
    private struct Allocation {
        let byteCount: Int
        let pointer: UnsafeMutableRawPointer
    }

    private var allocations: [Allocation] = []

    deinit {
        for allocation in allocations {
            _ = memset_s(
                allocation.pointer,
                allocation.byteCount,
                0,
                allocation.byteCount
            )
            allocation.pointer.deallocate()
        }
    }

    func bytes(_ data: Data) -> DhBytes {
        guard !data.isEmpty else {
            return DhBytes(data: nil, count: 0)
        }
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: data.count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        data.copyBytes(
            to: UnsafeMutableRawBufferPointer(
                start: pointer,
                count: data.count
            )
        )
        allocations.append(
            Allocation(byteCount: data.count, pointer: pointer)
        )
        return DhBytes(
            data: UnsafePointer(
                pointer.assumingMemoryBound(to: UInt8.self)
            ),
            count: data.count
        )
    }

    func bytes(_ value: String) -> DhBytes {
        bytes(Data(value.utf8))
    }
}

/// Borrowed callbacks installed together in one native remote constructor.
struct DeviceHubNativeRemoteCallbacks {
    let control: DhEventCallback?
    let controlContext: UnsafeMutableRawPointer?
    let media: DhMediaEventCallback?
    let mediaContext: UnsafeMutableRawPointer?
}

/// One validated remote constructor shape.
///
/// The operation selects whether the native protocol owns a live media stream
/// or performs Pair Verify without opening media services.
enum DeviceHubNativeRemoteOperation: Equatable, Sendable {
    case controlStream
    case pairVerify

    fileprivate var nativeValue: DhRemoteOperation {
        switch self {
        case .controlStream:
            DH_REMOTE_OPERATION_CONTROL_STREAM
        case .pairVerify:
            DH_REMOTE_OPERATION_PAIR_VERIFY
        }
    }

    fileprivate var usesMediaCallback: Bool {
        switch self {
        case .controlStream:
            true
        case .pairVerify:
            false
        }
    }
}

/// Builds exact, zero-initialized ABI inputs for synchronous constructors.
enum DeviceHubNativeInputMarshaller {
    static func withPairingConfiguration<Result>(
        request: NativePairingSessionRequest,
        callback: DhEventCallback?,
        callbackContext: UnsafeMutableRawPointer?,
        _ operation: (UnsafePointer<DhPairingSessionConfig>) throws -> Result
    ) rethrows -> Result {
        let arena = DeviceHubNativeInputArena()
        var controller = controllerIdentity(
            request.controller,
            arena: arena
        )
        var configuration = DhPairingSessionConfig()
        configuration.struct_size = UInt32(
            MemoryLayout<DhPairingSessionConfig>.size
        )
        configuration.abi_version = DeviceHubNativeABI.expectedVersion
        configuration.generation = generation(request.generation)
        configuration.display_name = arena.bytes(request.displayName)
        configuration.model = arena.bytes(request.model)
        configuration.requested_port = request.requestedPort
        configuration.callback = callback
        configuration.callback_context = callbackContext

        return try withUnsafePointer(to: &controller) { controllerPointer in
            configuration.controller_identity = controllerPointer
            return try withUnsafePointer(to: &configuration, operation)
        }
    }

    static func withRemoteConfiguration<Result>(
        request: NativeRemoteSessionRequest,
        operation remoteOperation: DeviceHubNativeRemoteOperation,
        callbacks: DeviceHubNativeRemoteCallbacks,
        _ operation: (UnsafePointer<DhRemoteSessionConfig>) throws -> Result
    ) rethrows -> Result {
        let arena = DeviceHubNativeInputArena()
        var controller = controllerIdentity(
            request.controller,
            arena: arena
        )
        var target = targetPairingRecord(
            request.target,
            arena: arena
        )
        var service = remoteService(
            request.service,
            arena: arena
        )
        var configuration = DhRemoteSessionConfig()
        configuration.struct_size = UInt32(
            MemoryLayout<DhRemoteSessionConfig>.size
        )
        configuration.abi_version = DeviceHubNativeABI.expectedVersion
        configuration.generation = generation(request.generation)
        configuration.operation = remoteOperation.nativeValue
        configuration.video_negotiator_offer = DhBytes()
        configuration.callback = callbacks.control
        configuration.callback_context = callbacks.controlContext
        if remoteOperation.usesMediaCallback {
            configuration.media_callback = callbacks.media
            configuration.media_callback_context = callbacks.mediaContext
        }

        return try withUnsafePointer(to: &controller) { controllerPointer in
            configuration.controller_identity = controllerPointer
            return try withUnsafePointer(to: &target) { targetPointer in
                configuration.target = targetPointer
                return try withUnsafePointer(to: &service) { servicePointer in
                    configuration.service = servicePointer
                    return try withUnsafePointer(
                        to: &configuration,
                        operation
                    )
                }
            }
        }
    }

    static func generation(_ generation: SessionGeneration) -> DhGeneration {
        let native = DeviceHubNativeGeneration(generation.rawValue)
        return DhGeneration(high: native.high, low: native.low)
    }

    private static func controllerIdentity(
        _ controller: NativeControllerIdentity,
        arena: DeviceHubNativeInputArena
    ) -> DhControllerIdentity {
        var value = DhControllerIdentity()
        value.struct_size = UInt32(MemoryLayout<DhControllerIdentity>.size)
        value.abi_version = DeviceHubNativeABI.expectedVersion
        value.identifier = arena.bytes(controller.identifier.uuidString)
        value.udid = arena.bytes(controller.udid)
        value.long_term_secret_key = arena.bytes(
            controller.longTermSecretKey
        )
        value.alternate_irk = arena.bytes(controller.alternateIRK)
        return value
    }

    private static func targetPairingRecord(
        _ target: NativeTargetPairingRecord,
        arena: DeviceHubNativeInputArena
    ) -> DhTargetPairingRecord {
        var value = DhTargetPairingRecord()
        value.struct_size = UInt32(
            MemoryLayout<DhTargetPairingRecord>.size
        )
        value.abi_version = DeviceHubNativeABI.expectedVersion
        value.device_id = arena.bytes(target.deviceID.rawValue)
        value.account_identifier = arena.bytes(target.accountIdentifier)
        value.peer_identifier = arena.bytes(target.peerIdentifier)
        value.peer_public_key = arena.bytes(target.peerPublicKey)
        value.peer_alternate_irk = arena.bytes(target.peerAlternateIRK)
        value.display_name = arena.bytes(target.displayName)
        value.product_type = arena.bytes(target.productType)
        value.completion = switch target.completion {
        case .committed:
            DH_PAIRING_COMPLETION_COMMITTED
        case .provisional:
            DH_PAIRING_COMPLETION_PROVISIONAL
        }
        return value
    }

    private static func remoteService(
        _ service: NativeRemoteService,
        arena: DeviceHubNativeInputArena
    ) -> DhValidatedRemoteService {
        var value = DhValidatedRemoteService()
        value.struct_size = UInt32(
            MemoryLayout<DhValidatedRemoteService>.size
        )
        value.abi_version = DeviceHubNativeABI.expectedVersion
        value.endpoint = endpoint(service.endpoint)
        value.identifier = arena.bytes(service.identifier.uuidString)
        let authenticationTags = service.authTags.reduce(into: Data()) {
            $0.append($1)
        }
        value.auth_tags = arena.bytes(authenticationTags)
        value.wire_protocol_version =
            NativeRemoteService.wireProtocolVersion
        value.minimum_wire_protocol_version =
            NativeRemoteService.minimumWireProtocolVersion
        value.flags = NativeRemoteService.flags
        return value
    }

    private static func endpoint(
        _ endpoint: NativeResolvedEndpoint
    ) -> DhResolvedEndpoint {
        var value = DhResolvedEndpoint()
        value.struct_size = UInt32(MemoryLayout<DhResolvedEndpoint>.size)
        value.family = switch endpoint.family {
        case .ipv4:
            DH_IP_FAMILY_IPV4
        case .ipv6:
            DH_IP_FAMILY_IPV6
        }
        _ = withUnsafeMutableBytes(of: &value.address) { address in
            endpoint.address.copyBytes(to: address)
        }
        value.scope_id = endpoint.scopeID
        value.port = endpoint.port
        return value
    }
}
