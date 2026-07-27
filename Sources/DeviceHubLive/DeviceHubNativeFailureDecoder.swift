import DeviceHubTransport
import Foundation

/// Reduces sanitized native error JSON to Transport's closed failure
/// vocabulary without retaining its free-form message.
enum DeviceHubNativeFailureDecoder {
    private static let maximumJSONByteCount = 16 * 1024

    static func decode(_ data: Data) -> NativeSessionFailure {
        guard
            !data.isEmpty,
            data.count <= maximumJSONByteCount
        else {
            return genericFailure
        }

        do {
            let payload = try JSONDecoder().decode(
                Payload.self,
                from: data
            )
            return NativeSessionFailure(
                code: payload.code,
                stage: payload.stage,
                retryable: payload.retryable
            )
        } catch {
            // The native payload is already sanitized, but decoder diagnostics
            // could still retain its contents. Collapse every shape failure
            // without logging either the payload or the decoding error.
            return genericFailure
        }
    }

    static var genericFailure: NativeSessionFailure {
        NativeSessionFailure(
            code: "native_failure",
            stage: "native_boundary",
            retryable: false
        )
    }

    private struct Payload: Decodable {
        let code: String
        let retryable: Bool
        let stage: String
    }
}
