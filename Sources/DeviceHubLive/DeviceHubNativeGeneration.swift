import Foundation

/// Canonical 128-bit representation passed across the native session ABI.
///
/// UUID bytes are split in network-byte order so generation identity remains
/// stable across processor endianness and every callback can be rejected
/// against the exact connection attempt that created it.
struct DeviceHubNativeGeneration: Equatable, Sendable {
    let high: UInt64
    let low: UInt64

    init(_ uuid: UUID) {
        var uuidBytes = uuid.uuid
        let bytes = withUnsafeBytes(of: &uuidBytes) {
            Array($0)
        }
        high = bytes.prefix(8).reduce(UInt64.zero) {
            ($0 << 8) | UInt64($1)
        }
        low = bytes.suffix(8).reduce(UInt64.zero) {
            ($0 << 8) | UInt64($1)
        }
    }
}
