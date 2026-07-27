import DeviceHubCore
import DeviceHubMedia
import Foundation

/// Shape failures rejected while constructing a native video callback bridge.
public enum NativeVideoContractError: Error, Equatable, Sendable {
    case invalidBufferCapacity
}

/// Sanitized reason that the native video stream failed closed.
public enum NativeVideoFailureReason:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case bufferSaturated
    case invalidAccessUnit
    case invalidConfiguration
    case invalidSequence
    case missingConfiguration
    case multipleConsumers
    case native(NativeSessionFailure)

    public var description: String {
        let kind = switch self {
        case .bufferSaturated:
            "buffer-saturated"
        case .invalidAccessUnit:
            "invalid-access-unit"
        case .invalidConfiguration:
            "invalid-configuration"
        case .invalidSequence:
            "invalid-sequence"
        case .missingConfiguration:
            "missing-configuration"
        case .multipleConsumers:
            "multiple-consumers"
        case .native:
            "native"
        }
        return "<redacted-native-video-failure \(kind)>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["failure": description],
            displayStyle: .enum
        )
    }
}

/// Terminal failure tagged to the native session generation that produced it.
public struct NativeVideoTerminalFailure:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let generation: SessionGeneration
    public let reason: NativeVideoFailureReason

    public init(
        generation: SessionGeneration,
        reason: NativeVideoFailureReason
    ) {
        self.generation = generation
        self.reason = reason
    }

    public var description: String {
        "<redacted-native-video-terminal-failure>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["failure": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Terminal state returned synchronously to an artifact callback.
public enum NativeVideoStreamTermination:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case cancelled
    case failed(NativeVideoFailureReason)
    case finished

    public var description: String {
        let kind = switch self {
        case .cancelled:
            "cancelled"
        case .failed:
            "failed"
        case .finished:
            "finished"
        }
        return "<redacted-native-video-termination \(kind)>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["termination": description],
            displayStyle: .enum
        )
    }
}

/// Immediate callback disposition used to stop native producers after teardown.
public enum NativeVideoIngressResult:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case accepted
    case terminal(NativeVideoStreamTermination)

    public var description: String {
        switch self {
        case .accepted:
            "<native-video-ingress accepted>"
        case .terminal:
            "<redacted-native-video-ingress terminal>"
        }
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["result": description],
            displayStyle: .enum
        )
    }
}

/// A validated HEVC decoder configuration copied from one native callback.
public struct NativeVideoConfiguration:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let configuration: HEVCConfiguration
    public let generation: SessionGeneration
    public let sequenceNumber: UInt64

    public init(
        generation: SessionGeneration,
        sequenceNumber: UInt64,
        configuration: HEVCConfiguration
    ) {
        self.configuration = configuration
        self.generation = generation
        self.sequenceNumber = sequenceNumber
    }

    public var description: String {
        "<redacted-native-video-configuration>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["configuration": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// One validated, complete HEVC access unit copied from a native callback.
///
/// Raw RTP packets and partial NAL fragments cannot be represented by this
/// boundary. The native producer must assemble one complete length-prefixed
/// access unit before calling ``NativeVideoEventBridge/receiveAccessUnit(
/// sequenceNumber:receivedAt:orientation:pixelSize:bytes:)``.
public struct NativeVideoAccessUnit:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let sample: HEVCCompressedSample

    public init(sample: HEVCCompressedSample) {
        self.sample = sample
    }

    public var generation: SessionGeneration {
        sample.generation
    }

    public var sequenceNumber: UInt64 {
        sample.sequenceNumber
    }

    public var description: String {
        "<redacted-native-video-access-unit>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["accessUnit": "<redacted>"],
            displayStyle: .struct
        )
    }
}

/// Decoder-reset boundary in the ordered native media stream.
public struct NativeVideoDiscontinuity: Equatable, Sendable {
    public let generation: SessionGeneration
    public let sequenceNumber: UInt64

    public init(
        generation: SessionGeneration,
        sequenceNumber: UInt64
    ) {
        self.generation = generation
        self.sequenceNumber = sequenceNumber
    }
}

/// Ordered, generation-tagged input emitted by the native video bridge.
///
/// Only a later successful VideoToolbox decode may turn an access unit into a
/// `RemoteDisplayFrame`. These events are compressed-media inputs and must not
/// be treated as frame freshness or input-authorization evidence.
public enum NativeVideoEvent:
    CustomDebugStringConvertible,
    CustomReflectable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case accessUnit(NativeVideoAccessUnit)
    case configuration(NativeVideoConfiguration)
    case discontinuity(NativeVideoDiscontinuity)
    case failed(NativeVideoTerminalFailure)
    case finished(generation: SessionGeneration)

    public var description: String {
        let kind = switch self {
        case .accessUnit:
            "access-unit"
        case .configuration:
            "configuration"
        case .discontinuity:
            "discontinuity"
        case .failed:
            "failed"
        case .finished:
            "finished"
        }
        return "<redacted-native-video-event \(kind)>"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["event": description],
            displayStyle: .enum
        )
    }
}
