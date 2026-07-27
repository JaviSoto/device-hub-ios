/// An explicit request to begin pairing with one nearby device.
///
/// The request is intentionally empty today. Stable controller identity and
/// cryptographic material are implementation details loaded by the live
/// transport, never parameters supplied by a feature.
public struct PairingRequest: Equatable, Sendable {
    public init() {}
}
