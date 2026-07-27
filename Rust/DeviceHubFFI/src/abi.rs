//! Stable C-compatible data types for the Device Hub native boundary.

use std::ffi::{c_char, c_void};

/// Current binary ABI version.
pub const DH_ABI_VERSION: u32 = 3;

/// The session lifecycle API is implemented.
pub const DH_CAPABILITY_SESSION_LIFECYCLE: u64 = 1 << 0;
/// Every callback event carries its owning connection generation.
pub const DH_CAPABILITY_GENERATION_TAGGED_EVENTS: u64 = 1 << 1;
/// Controller and peer credentials are copied into Rust-owned memory.
pub const DH_CAPABILITY_SENSITIVE_INPUT_COPY: u64 = 1 << 2;
/// Rust can bind and run an iOS 27 Pairable Host listener.
pub const DH_CAPABILITY_PAIRABLE_HOST: u64 = 1 << 3;
/// Pair records require acknowledged provisional and committed persistence.
pub const DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS: u64 = 1 << 4;
/// Reconnect requires stored-peer Pair Verify and never falls back to pairing.
pub const DH_CAPABILITY_AUTHENTICATED_RECONNECT: u64 = 1 << 5;
/// The transport establishes and reports authenticated Remote Service Discovery.
pub const DH_CAPABILITY_RSD_METADATA: u64 = 1 << 6;
/// The transport returns a validated PNG from CoreDevice screenshot service.
pub const DH_CAPABILITY_PNG_SCREENSHOT: u64 = 1 << 7;
/// Every remote operation proves Xcode-prepared developer readiness first.
pub const DH_CAPABILITY_DEVELOPER_READINESS: u64 = 1 << 8;
/// Rust can keep an authenticated display/control session alive until cancelled.
pub const DH_CAPABILITY_CONTROL_STREAM: u64 = 1 << 9;
/// The caller supplies and acknowledges AVConference video negotiation.
pub const DH_CAPABILITY_VIDEO_NEGOTIATION: u64 = 1 << 10;
/// Every inbound display UDP datagram is forwarded once, in receive order.
pub const DH_CAPABILITY_RAW_VIDEO_DATAGRAMS: u64 = 1 << 11;
/// Rust emits complete, marker-closed HEVC access units and decoder config.
pub const DH_CAPABILITY_HEVC_ACCESS_UNITS: u64 = 1 << 12;
/// Stateful normalized single-contact touchscreen input is implemented.
pub const DH_CAPABILITY_TOUCH_INPUT: u64 = 1 << 13;
/// Stateful virtual HID keyboard input is implemented.
pub const DH_CAPABILITY_KEYBOARD_INPUT: u64 = 1 << 14;
/// Confirmed iOS hardware-button transitions are implemented.
pub const DH_CAPABILITY_HARDWARE_BUTTON_INPUT: u64 = 1 << 15;
/// Relative 90-degree rotation returns device-reported orientation metadata.
pub const DH_CAPABILITY_ROTATION: u64 = 1 << 16;
/// High-rate media uses a synchronous callback isolated from control events.
pub const DH_CAPABILITY_SPLIT_MEDIA_CALLBACK: u64 = 1 << 17;
/// Active touch, keyboard, and button state can be released atomically.
pub const DH_CAPABILITY_RELEASE_ALL_INPUT: u64 = 1 << 18;
/// Every access unit carries its authoritative display-geometry snapshot.
pub const DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS: u64 = 1 << 19;
/// Rust can authenticate a discovered endpoint with Pair Verify only.
pub const DH_CAPABILITY_PAIR_VERIFY_DISCOVERY: u64 = 1 << 20;

/// Capability mask implemented by this binary.
pub const IMPLEMENTED_CAPABILITIES: u64 = DH_CAPABILITY_SESSION_LIFECYCLE
    | DH_CAPABILITY_GENERATION_TAGGED_EVENTS
    | DH_CAPABILITY_SENSITIVE_INPUT_COPY
    | DH_CAPABILITY_PAIRABLE_HOST
    | DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS
    | DH_CAPABILITY_AUTHENTICATED_RECONNECT
    | DH_CAPABILITY_RSD_METADATA
    | DH_CAPABILITY_PNG_SCREENSHOT
    | DH_CAPABILITY_DEVELOPER_READINESS
    | DH_CAPABILITY_CONTROL_STREAM
    | DH_CAPABILITY_VIDEO_NEGOTIATION
    | DH_CAPABILITY_RAW_VIDEO_DATAGRAMS
    | DH_CAPABILITY_HEVC_ACCESS_UNITS
    | DH_CAPABILITY_TOUCH_INPUT
    | DH_CAPABILITY_KEYBOARD_INPUT
    | DH_CAPABILITY_HARDWARE_BUTTON_INPUT
    | DH_CAPABILITY_ROTATION
    | DH_CAPABILITY_SPLIT_MEDIA_CALLBACK
    | DH_CAPABILITY_RELEASE_ALL_INPUT
    | DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS
    | DH_CAPABILITY_PAIR_VERIFY_DISCOVERY;

/// Result status returned by every fallible ABI operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum DhStatus {
    /// The operation completed successfully.
    Ok = 0,
    /// One or more arguments violate the ABI contract.
    InvalidArgument = 1,
    /// The operation is not valid in the session's current state.
    InvalidState = 2,
    /// An internal dispatcher or synchronization failure occurred.
    Internal = 3,
    /// A Rust panic was caught before it crossed the C boundary.
    Panic = 4,
}

/// A borrowed byte span.
///
/// Input spans need to remain valid only for the calling function. Event spans
/// remain valid only until the event callback returns.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhBytes {
    /// First byte, or null when `count` is zero.
    pub data: *const u8,
    /// Number of readable bytes beginning at `data`.
    pub count: usize,
}

impl DhBytes {
    /// Creates a borrowed span over `bytes`.
    #[must_use]
    pub fn from_slice(bytes: &[u8]) -> Self {
        Self {
            data: bytes.as_ptr(),
            count: bytes.len(),
        }
    }

    /// Creates an empty span.
    #[must_use]
    pub const fn empty() -> Self {
        Self {
            data: std::ptr::null(),
            count: 0,
        }
    }
}

/// Opaque 128-bit identity for one connection generation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(C)]
pub struct DhGeneration {
    /// Most-significant 64 bits.
    pub high: u64,
    /// Least-significant 64 bits.
    pub low: u64,
}

/// Stable controller credentials copied at session creation.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhControllerIdentity {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Canonical UUID text used as the remote-pairing identifier.
    pub identifier: DhBytes,
    /// Stable controller UDID sent to the peer.
    pub udid: DhBytes,
    /// Exactly 32 bytes of Ed25519 secret-key material.
    pub long_term_secret_key: DhBytes,
    /// Exactly 16 bytes used only as this host's alternate IRK.
    pub alternate_irk: DhBytes,
}

/// Numeric address family for a Swift-resolved endpoint.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhIpFamily {
    /// IPv4; the first four address bytes are used and the rest must be zero.
    Ipv4 = 4,
    /// IPv6; all sixteen address bytes are used.
    Ipv6 = 6,
}

/// One numeric endpoint already resolved and validated by Swift.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhResolvedEndpoint {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Address family.
    pub family: u32,
    /// Network-order IPv4 or IPv6 address bytes.
    pub address: [u8; 16],
    /// IPv6 interface scope, or zero for IPv4/global IPv6.
    pub scope_id: u32,
    /// Nonzero TCP port.
    pub port: u16,
    /// Reserved; must be zero.
    pub reserved: u16,
}

/// Pairing milestone stored for one target.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhPairingCompletion {
    /// M5 was verified and persisted, but M6 may not have completed.
    Provisional = 1,
    /// M6 was sent and the record was durably committed.
    Committed = 2,
}

/// Durable peer material needed to authenticate Pair Verify.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhTargetPairingRecord {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Stable target UDID.
    pub device_id: DhBytes,
    /// Account identifier from the authenticated M5 OPACK payload.
    pub account_identifier: DhBytes,
    /// Identifier covered by the target's M5 signature.
    pub peer_identifier: DhBytes,
    /// Exactly 32 bytes containing the target's Ed25519 public key.
    pub peer_public_key: DhBytes,
    /// Exactly 16 bytes containing the target's alternate IRK.
    pub peer_alternate_irk: DhBytes,
    /// Target name authenticated during pairing.
    pub display_name: DhBytes,
    /// Target hardware model authenticated during pairing.
    pub product_type: DhBytes,
    /// Last durable pairing milestone.
    pub completion: u32,
    /// Reserved; must be zero.
    pub reserved: u32,
}

/// Validated semantic fields from one `_remotepairing._tcp` announcement.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhValidatedRemoteService {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Numeric endpoint selected from Foundation's resolved addresses.
    pub endpoint: DhResolvedEndpoint,
    /// Canonical UUID service identifier.
    pub identifier: DhBytes,
    /// One or more concatenated six-byte decoded TXT `authTag` values.
    pub auth_tags: DhBytes,
    /// TXT `ver`; must be 26.
    pub wire_protocol_version: u8,
    /// TXT `minVer`; must be 8.
    pub minimum_wire_protocol_version: u8,
    /// TXT `flags`; must be 0.
    pub flags: u8,
    /// Reserved; must be zero.
    pub reserved: u8,
}

/// Session state carried by every callback event.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhSessionState {
    /// Session exists but has not started.
    Ready = 1,
    /// A protocol operation is running.
    Running = 2,
    /// Rust is waiting for the caller to durably persist a pair record.
    WaitingForPersistence = 3,
    /// Pair Verify succeeded; a tunnel may also be authenticated and active.
    Connected = 4,
    /// The one-shot operation completed.
    Completed = 5,
    /// Cancellation won the terminal-state race.
    Cancelled = 6,
    /// The operation failed with a sanitized error.
    Failed = 7,
}

/// Current protocol phase.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhConnectionPhase {
    /// No protocol work has started.
    Idle = 0,
    /// Binding the Pairable Host listener.
    BindingPairingListener = 1,
    /// Waiting for a device to connect to the listener.
    AwaitingPairingPeer = 2,
    /// Running Pair Setup.
    Pairing = 3,
    /// Waiting for durable persistence acknowledgement.
    PersistingPairRecord = 4,
    /// Authenticating an existing pair record.
    VerifyingPairing = 5,
    /// Establishing TLS-PSK, CDTunnel, and userspace TCP.
    OpeningTunnel = 6,
    /// Performing the RSD handshake.
    DiscoveringServices = 7,
    /// Calling CoreDevice screenshot service.
    CapturingScreenshot = 8,
    /// The requested operation completed.
    Ready = 9,
    /// Proving developer mode and the Xcode-prepared personalized image.
    PreparingDevice = 10,
    /// Opening displayservice and starting audio/video media negotiation.
    StartingDisplayStream = 11,
    /// Waiting for the caller to configure and start its video receiver.
    WaitingForVideoReceiver = 12,
    /// Opening authenticated UniversalHID and Indigo input services.
    OpeningInput = 13,
    /// Display datagrams, complete access units, and input are active.
    Streaming = 14,
}

/// Typed callback event discriminator.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhEventKind {
    /// Session execution began.
    SessionStarted = 1,
    /// The current protocol phase changed.
    PhaseChanged = 2,
    /// `value` contains the already-bound Pairable Host TCP port.
    PairingListenerReady = 3,
    /// `payload` contains the six-digit UTF-8 Pair Setup code.
    PairingCode = 4,
    /// `peer` must be durably stored before M6; acknowledge `request_id`.
    PairRecordProvisional = 5,
    /// `peer` must be promoted after M6; acknowledge `request_id`.
    PairRecordCommitted = 6,
    /// Pair Verify completed successfully.
    Authenticated = 7,
    /// `rsd` describes the authenticated RSD generation.
    RsdReady = 8,
    /// `payload` is a validated PNG; image dimensions are populated.
    ScreenshotPng = 9,
    /// The one-shot operation completed.
    SessionCompleted = 10,
    /// `payload` contains sanitized UTF-8 JSON describing the failure.
    SessionFailed = 11,
    /// Cancellation terminated the operation.
    SessionCancelled = 12,
    /// `payload` is the displayservice video negotiator answer to acknowledge.
    VideoNegotiationAnswer = 13,
    /// `video_datagram` contains one complete inbound video UDP datagram.
    VideoDatagram = 14,
    /// `video_configuration` contains a complete changed VPS/SPS/PPS set.
    VideoConfiguration = 15,
    /// `video_access_unit` contains one complete marker-closed HEVC AU.
    VideoAccessUnit = 16,
    /// `value` contains a [`DhVideoDiscontinuity`] raw value.
    VideoDiscontinuity = 17,
    /// Both authenticated HID services and the virtual keyboard are usable.
    InputReady = 18,
    /// `display_geometry` contains device-reported orientation and pixel geometry.
    DisplayGeometry = 19,
}

/// Operation selected by [`DhRemoteSessionConfig`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhRemoteOperation {
    /// Capture one validated PNG and complete.
    Screenshot = 1,
    /// Negotiate a persistent display stream and authenticated input channel.
    ControlStream = 2,
    /// Authenticate one discovered endpoint with Pair Verify and complete.
    PairVerify = 3,
}

/// Result of configuring the caller-owned video receiver.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhVideoNegotiationOutcome {
    /// The receiver accepted the answer and started successfully.
    Succeeded = 1,
    /// Receiver configuration failed; terminate this generation.
    Failed = 2,
}

/// Complete-AU integrity failure that requires decoder recovery.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhVideoDiscontinuity {
    /// An RTP sequence gap exceeded bounded reordering.
    SequenceGap = 1,
    /// RTP timestamp changed before the prior access unit closed.
    TimestampChangedWithoutMarker = 2,
    /// The datagram or RFC 7798 payload was malformed.
    MalformedPayload = 3,
    /// One NAL exceeded the configured safety limit.
    NalUnitTooLarge = 4,
    /// A VPS, SPS, or PPS exceeded the configured safety limit.
    ParameterSetTooLarge = 5,
    /// One complete access unit exceeded the configured safety limit.
    AccessUnitTooLarge = 6,
    /// One access unit contained too many NAL units.
    TooManyNalUnits = 7,
    /// Video arrived before a complete VPS/SPS/PPS set.
    MissingParameterSets = 8,
    /// A valid RTP packet did not match the negotiated payload type or SSRC.
    UnexpectedStream = 9,
}

/// Stateful single-contact touchscreen transition.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhTouchPhase {
    /// Begin a contact at the supplied normalized point.
    Down = 1,
    /// Move the active contact to the supplied normalized point.
    Move = 2,
    /// Release the active contact at the supplied normalized point.
    Up = 3,
    /// Release the active contact at its last successfully sent point.
    Cancel = 4,
    /// Atomically press, hold briefly, and release at the supplied point.
    Tap = 5,
}

/// Stateful virtual keyboard transition.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhKeyboardPhase {
    /// Press one HID Keyboard/Keypad usage.
    Down = 1,
    /// Release one pressed HID Keyboard/Keypad usage.
    Up = 2,
    /// Release every pressed usage; `usage` must be zero.
    CancelAll = 3,
    /// Atomically press, hold briefly, and release one usage.
    Tap = 4,
}

/// Confirmed iOS hardware button.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhHardwareButton {
    /// Home.
    Home = 1,
    /// Lock / side button.
    Lock = 2,
    /// Volume up.
    VolumeUp = 3,
    /// Volume down.
    VolumeDown = 4,
    /// Mute.
    Mute = 5,
    /// Siri.
    Siri = 6,
}

/// Stateful hardware-button transition.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhButtonPhase {
    /// Press.
    Down = 1,
    /// Release.
    Up = 2,
    /// Cancel a pressed button.
    Cancel = 3,
    /// Atomically press, hold briefly, and release.
    Tap = 4,
}

/// Verified relative 90-degree rotation request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhRotationDirection {
    /// Counter-clockwise.
    Left = 1,
    /// Clockwise.
    Right = 2,
}

/// Device-reported physical orientation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhOrientation {
    /// The service has not yet reported a recognized non-flat orientation.
    Unknown = 0,
    /// Upright portrait.
    Portrait = 1,
    /// Upside-down portrait.
    PortraitUpsideDown = 2,
    /// Home/gesture edge on the viewer's right.
    LandscapeLeft = 3,
    /// Home/gesture edge on the viewer's left.
    LandscapeRight = 4,
    /// Device is lying face up.
    FaceUp = 5,
    /// Device is lying face down.
    FaceDown = 6,
}

/// Borrowed authenticated peer data carried by pair-record events.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhVerifiedPeer {
    /// Stable target UDID.
    pub device_id: DhBytes,
    /// Account identifier authenticated inside M5.
    pub account_identifier: DhBytes,
    /// Identifier covered by the target's signature.
    pub peer_identifier: DhBytes,
    /// Exactly 32 bytes of Ed25519 public-key material.
    pub peer_public_key: DhBytes,
    /// Exactly 16 bytes of target alternate-IRK material.
    pub peer_alternate_irk: DhBytes,
    /// Target display name.
    pub display_name: DhBytes,
    /// Target hardware model.
    pub product_type: DhBytes,
}

/// Borrowed RSD metadata carried by [`DhEventKind::RsdReady`].
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhRsdMetadata {
    /// RSD generation UUID.
    pub uuid: DhBytes,
    /// Authenticated RSD `Properties.OSVersion`.
    pub operating_system_version: DhBytes,
    /// Authenticated RSD `Properties.BuildVersion`.
    pub build_version: DhBytes,
    /// Authenticated RSD `Properties.UniqueDeviceID`.
    pub unique_device_id: DhBytes,
    /// Authenticated RSD `Properties.ProductType`.
    pub product_type: DhBytes,
    /// Messaging protocol version.
    pub protocol_version: u64,
    /// Number of validated advertised services.
    pub service_count: u64,
    /// One when CoreDevice screenshot service is present.
    pub screenshot_service_available: u8,
    /// Reserved; must be zero.
    pub reserved: [u8; 7],
}

/// Borrowed complete HEVC decoder parameter sets.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhVideoConfiguration {
    /// Monotonic configuration revision, beginning at one.
    pub revision: u64,
    /// Coded pixel width after HEVC conformance-window cropping.
    pub pixel_width: u32,
    /// Coded pixel height after HEVC conformance-window cropping.
    pub pixel_height: u32,
    /// Latest device-reported [`DhOrientation`], or unknown.
    pub orientation: u32,
    /// Must be zero.
    pub reserved: u32,
    /// HEVC video parameter set without a start code or length prefix.
    pub video_parameter_set: DhBytes,
    /// HEVC sequence parameter set without a start code or length prefix.
    pub sequence_parameter_set: DhBytes,
    /// HEVC picture parameter set without a start code or length prefix.
    pub picture_parameter_set: DhBytes,
}

/// Borrowed complete marker-closed HEVC access unit.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhVideoAccessUnit {
    /// Four-byte big-endian length-prefixed HEVC NAL units.
    pub bytes: DhBytes,
    /// Parameter-set revision required to decode this access unit.
    pub parameter_set_revision: u64,
    /// Negotiated RTP synchronization source.
    pub ssrc: u32,
    /// RTP timestamp shared by all NAL units in this access unit.
    pub rtp_timestamp: u32,
    /// First RTP sequence number contributing to this access unit.
    pub first_sequence_number: u16,
    /// Last RTP sequence number contributing to this access unit.
    pub last_sequence_number: u16,
    /// One for an intra random-access access unit, otherwise zero.
    pub is_sync: u8,
    /// Must be zero.
    pub reserved: [u8; 3],
    /// Authoritative display geometry snapshot that applies to this access unit.
    pub geometry: DhDisplayGeometry,
}

/// Borrowed inbound video UDP datagram.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhVideoDatagram {
    /// Complete immutable UDP payload, never coalesced or split.
    pub bytes: DhBytes,
    /// Peer source port, provided for diagnostics only.
    pub source_port: u16,
    /// Must be zero.
    pub reserved: [u8; 6],
}

/// Device-reported orientation combined with the latest decoded pixel geometry.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhDisplayGeometry {
    /// Latest SPS-derived pixel width, or zero before configuration.
    pub pixel_width: u32,
    /// Latest SPS-derived pixel height, or zero before configuration.
    pub pixel_height: u32,
    /// Current [`DhOrientation`] raw value.
    pub orientation: u32,
    /// Last non-flat [`DhOrientation`] raw value.
    pub non_flat_orientation: u32,
    /// One when rotation lock is enabled.
    pub orientation_locked: u8,
    /// Must be zero.
    pub reserved: [u8; 7],
}

/// A callback event borrowed only for the callback invocation.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhEvent {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// ABI version used to encode this event.
    pub abi_version: u32,
    /// Owning connection generation.
    pub generation: DhGeneration,
    /// Monotonic sequence number within this callback plane, starting at one.
    pub sequence: u64,
    /// Typed event discriminator.
    pub kind: DhEventKind,
    /// Session state after applying the event.
    pub state: DhSessionState,
    /// Current protocol phase.
    pub phase: DhConnectionPhase,
    /// Reserved; must be zero.
    pub reserved: u32,
    /// Persistence request identity, or zero for non-persistence events.
    pub request_id: u64,
    /// Event-specific numeric value, such as a listener port.
    pub value: u64,
    /// Event-specific borrowed bytes.
    pub payload: DhBytes,
    /// Authenticated peer view, or null.
    pub peer: *const DhVerifiedPeer,
    /// RSD metadata view, or null.
    pub rsd: *const DhRsdMetadata,
    /// Video decoder configuration, or null.
    pub video_configuration: *const DhVideoConfiguration,
    /// Complete HEVC access unit, or null.
    pub video_access_unit: *const DhVideoAccessUnit,
    /// Complete inbound video UDP datagram, or null.
    pub video_datagram: *const DhVideoDatagram,
    /// Orientation and pixel geometry, or null.
    pub display_geometry: *const DhDisplayGeometry,
    /// PNG width for screenshot events, otherwise zero.
    pub image_width: u32,
    /// PNG height for screenshot events, otherwise zero.
    pub image_height: u32,
}

/// Serial callback invoked on the session's private dispatcher thread.
pub type DhEventCallback =
    Option<unsafe extern "C" fn(event: *const DhEvent, context: *mut c_void)>;

/// Synchronous media callback invoked on the protocol worker.
///
/// Only video datagram, configuration, access-unit, and discontinuity events
/// use this callback. Borrowed bytes must be copied before returning. Blocking
/// applies backpressure to media reception but never occupies the control-event
/// queue.
pub type DhMediaEventCallback =
    Option<unsafe extern "C" fn(event: *const DhEvent, context: *mut c_void)>;

/// Configuration for one explicit Pairable Host attempt.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhPairingSessionConfig {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Unique connection generation.
    pub generation: DhGeneration,
    /// Stable controller identity copied during creation.
    pub controller_identity: *const DhControllerIdentity,
    /// Name displayed by the peer.
    pub display_name: DhBytes,
    /// Mac model identifier displayed by the peer.
    pub model: DhBytes,
    /// Requested listener port, or zero for an ephemeral port.
    pub requested_port: u16,
    /// Reserved; must be zero.
    pub reserved: [u8; 6],
    /// Required serial event callback.
    pub callback: DhEventCallback,
    /// Opaque context passed to `callback`.
    pub callback_context: *mut c_void,
}

/// Configuration for one authenticated reconnect and screenshot attempt.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhRemoteSessionConfig {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Unique connection generation.
    pub generation: DhGeneration,
    /// Stable controller identity copied during creation.
    pub controller_identity: *const DhControllerIdentity,
    /// Durable authenticated target record copied during creation.
    pub target: *const DhTargetPairingRecord,
    /// Swift-validated semantic Bonjour service copied during creation.
    pub service: *const DhValidatedRemoteService,
    /// [`DhRemoteOperation`] raw value.
    pub operation: u32,
    /// Must be zero.
    pub reserved: u32,
    /// Required binary-plist AVConference offer for a control stream; empty for screenshot.
    pub video_negotiator_offer: DhBytes,
    /// Required serial event callback.
    pub callback: DhEventCallback,
    /// Opaque context passed to `callback`.
    pub callback_context: *mut c_void,
    /// Required for control streams and null for screenshots.
    pub media_callback: DhMediaEventCallback,
    /// Opaque context passed only to `media_callback`.
    pub media_callback_context: *mut c_void,
}

/// Generation-tagged normalized touchscreen input.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhTouchInput {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Must match the session generation.
    pub generation: DhGeneration,
    /// [`DhTouchPhase`] raw value.
    pub phase: u32,
    /// Horizontal normalized coordinate from zero through `u16::MAX`.
    pub x: u16,
    /// Vertical normalized coordinate from zero through `u16::MAX`.
    pub y: u16,
    /// Must be zero.
    pub reserved: u32,
}

/// Generation-tagged HID Keyboard/Keypad input.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhKeyboardInput {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Must match the session generation.
    pub generation: DhGeneration,
    /// [`DhKeyboardPhase`] raw value.
    pub phase: u32,
    /// HID Keyboard/Keypad usage; zero only for cancel-all.
    pub usage: u16,
    /// HID modifier bitmap; bits zero through seven map usages E0 through E7.
    pub modifiers: u8,
    /// Must be zero.
    pub reserved: u8,
}

/// Generation-tagged confirmed iOS hardware-button input.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhHardwareButtonInput {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Must match the session generation.
    pub generation: DhGeneration,
    /// [`DhHardwareButton`] raw value.
    pub button: u32,
    /// [`DhButtonPhase`] raw value.
    pub phase: u32,
    /// Must be zero.
    pub reserved: u64,
}

/// Generation-tagged outbound AVConference video control datagram.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhVideoControlDatagram {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Must match the session generation.
    pub generation: DhGeneration,
    /// One complete outbound UDP payload.
    pub bytes: DhBytes,
}

/// Generation-tagged verified relative rotation.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhRotationInput {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Must match the session generation.
    pub generation: DhGeneration,
    /// [`DhRotationDirection`] raw value.
    pub direction: u32,
    /// Must be zero.
    pub reserved: u32,
}

/// Generation-tagged request to release every native held input.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct DhReleaseAllInput {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Must equal [`DH_ABI_VERSION`].
    pub abi_version: u32,
    /// Must match the session generation.
    pub generation: DhGeneration,
}

/// Result supplied for a pending pair-record persistence request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum DhPersistenceOutcome {
    /// The requested state is durably stored.
    Succeeded = 1,
    /// Persistence failed; the protocol generation must terminate.
    Failed = 2,
}

/// Opaque, app-owned transport session.
pub struct DhSession {
    pub(crate) inner: crate::session::Session,
}

/// Owned, sanitized error allocated by the Rust boundary.
pub struct DhError {
    pub(crate) json: std::ffi::CString,
}

/// Returns the pointer type used by [`crate::dh_ffi_version`].
pub(crate) const fn c_string_pointer(bytes: &'static [u8]) -> *const c_char {
    bytes.as_ptr().cast()
}
