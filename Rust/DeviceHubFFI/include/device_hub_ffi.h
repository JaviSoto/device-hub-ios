#ifndef DEVICE_HUB_FFI_H
#define DEVICE_HUB_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__has_attribute)
#if __has_attribute(warn_unused_result)
#define DH_NODISCARD __attribute__((warn_unused_result))
#endif
#endif
#ifndef DH_NODISCARD
#define DH_NODISCARD
#endif

/**
 * Device Hub's app-owned iOS 27 protocol boundary, ABI version 2.
 *
 * INPUT OWNERSHIP
 * ---------------
 * Every input pointer and DhBytes span is borrowed only for its constructor
 * call. Constructors validate and copy all retained values, including
 * controller and peer key material, before returning. The library retains
 * sensitive copies only in memory, never persists them, and zeroizes them
 * during teardown. The app owns durable Keychain persistence.
 *
 * CALLBACK OWNERSHIP AND THREADING
 * --------------------------------
 * Low-rate control events are serialized on one private dispatcher. High-rate
 * media events use a separate synchronous callback on the sole protocol
 * worker: Rust never queues them, callback blocking applies backpressure, and
 * raw datagrams arrive exactly once and in receive order. DhEvent and every
 * pointer/span reachable from it are borrowed only until that callback
 * returns; copy retained values before returning.
 *
 * Neither callback may call dh_session_cancel() or dh_session_free(), unwind,
 * throw, or otherwise escape through this C boundary. Persistence/video ACK
 * calls are allowed from the control callback. Callback functions and contexts
 * remain valid until dh_session_free() returns. Session calls must not race
 * dh_session_free().
 *
 * SESSION AND ERROR OWNERSHIP
 * ---------------------------
 * Successful constructors return one uniquely owned DhSession. Errors returned
 * through out_error are sanitized, uniquely owned DhError values. Release both
 * types with their pointer-to-pointer free functions. Each free clears caller
 * storage before teardown; calling it again with that now-null storage is a
 * safe no-op. Passing a null storage pointer to dh_session_free() is invalid.
 * Before any fallible call, non-null out_error storage must not contain a live
 * owned error; release a prior error before reusing that storage.
 *
 * SECURITY AND PROTOCOL ORDERING
 * ------------------------------
 * Pairable Host binds its TCP listener before emitting
 * DH_EVENT_PAIRING_LISTENER_READY. Publish the Foundation Bonjour service only
 * after receiving that event. An authenticated M5 pair record is emitted as
 * provisional and must be durably acknowledged before M6 is sent. A committed
 * record is emitted only after M6 succeeds and must also be acknowledged.
 *
 * Reconnect accepts only a Swift-resolved numeric endpoint, including an IPv6
 * scope ID where required, plus validated semantic `_remotepairing._tcp` TXT
 * fields. TXT authTag values remain bounded discovery hints; authenticated
 * Pair Verify against the stored peer identity is the authoritative endpoint
 * proof, and Rust never falls back into pairing. All exposed errors and
 * asynchronous failure payloads are sanitized and never contain credentials,
 * PINs, or raw protocol payloads.
 */

#define DH_ABI_VERSION ((uint32_t)3)

typedef int32_t DhStatus;
#define DH_STATUS_OK ((DhStatus)0)
#define DH_STATUS_INVALID_ARGUMENT ((DhStatus)1)
#define DH_STATUS_INVALID_STATE ((DhStatus)2)
#define DH_STATUS_INTERNAL ((DhStatus)3)
#define DH_STATUS_PANIC ((DhStatus)4)

typedef uint64_t DhCapabilities;
/** Session construction, start, cancellation, persistence ACK, and teardown. */
#define DH_CAPABILITY_SESSION_LIFECYCLE ((DhCapabilities)1 << 0)
/** Every callback includes the exact 128-bit generation supplied at creation. */
#define DH_CAPABILITY_GENERATION_TAGGED_EVENTS ((DhCapabilities)1 << 1)
/** All retained controller and target credentials are copied and zeroized. */
#define DH_CAPABILITY_SENSITIVE_INPUT_COPY ((DhCapabilities)1 << 2)
/** A real iOS 27 Pairable Host listener and authenticated Pair Setup. */
#define DH_CAPABILITY_PAIRABLE_HOST ((DhCapabilities)1 << 3)
/** Pair Setup and recovery stop until each durable record write is ACKed. */
#define DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS ((DhCapabilities)1 << 4)
/** Stored-peer Pair Verify is required; there is no pairing fallback. */
#define DH_CAPABILITY_AUTHENTICATED_RECONNECT ((DhCapabilities)1 << 5)
/**
 * TLS-PSK/CDTunnel/jktcp completes authenticated RSD and returns its canonical
 * OS, build, device, and product identity.
 */
#define DH_CAPABILITY_RSD_METADATA ((DhCapabilities)1 << 6)
/** CoreDevice returns one structurally and CRC-validated PNG screenshot. */
#define DH_CAPABILITY_PNG_SCREENSHOT ((DhCapabilities)1 << 7)
/** Every remote operation verifies Developer Mode and an Xcode-prepared DDI. */
#define DH_CAPABILITY_DEVELOPER_READINESS ((DhCapabilities)1 << 8)
/** Authenticated display and input services stay live until cancellation. */
#define DH_CAPABILITY_CONTROL_STREAM ((DhCapabilities)1 << 9)
/** The caller's retained AVConference receiver owns mode-5 negotiation. */
#define DH_CAPABILITY_VIDEO_NEGOTIATION ((DhCapabilities)1 << 10)
/** Every inbound video UDP datagram is delivered exactly once and in order. */
#define DH_CAPABILITY_RAW_VIDEO_DATAGRAMS ((DhCapabilities)1 << 11)
/** Complete marker-closed HEVC access units and decoder config are emitted. */
#define DH_CAPABILITY_HEVC_ACCESS_UNITS ((DhCapabilities)1 << 12)
/** Stateful normalized single-contact touch input is implemented. */
#define DH_CAPABILITY_TOUCH_INPUT ((DhCapabilities)1 << 13)
/** Stateful complete-chord keyboard edges and atomic semantic taps. */
#define DH_CAPABILITY_KEYBOARD_INPUT ((DhCapabilities)1 << 14)
/** Confirmed iOS hardware-button transitions and atomic semantic taps. */
#define DH_CAPABILITY_HARDWARE_BUTTON_INPUT ((DhCapabilities)1 << 15)
/** Relative 90-degree rotation returns authoritative orientation metadata. */
#define DH_CAPABILITY_ROTATION ((DhCapabilities)1 << 16)
/** High-rate media uses a synchronous callback isolated from control events. */
#define DH_CAPABILITY_SPLIT_MEDIA_CALLBACK ((DhCapabilities)1 << 17)
/** Active touch, keyboard, and button state can be released atomically. */
#define DH_CAPABILITY_RELEASE_ALL_INPUT ((DhCapabilities)1 << 18)
/** Every HEVC access unit carries the geometry snapshot that applies to it. */
#define DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS ((DhCapabilities)1 << 19)
/** A discovered endpoint can be authenticated with Pair Verify and no tunnel. */
#define DH_CAPABILITY_PAIR_VERIFY_DISCOVERY ((DhCapabilities)1 << 20)

/** Minimum fail-closed capability set for Pairable Host onboarding. */
#define DH_REQUIRED_CAPABILITIES_PAIRING                                      \
  (DH_CAPABILITY_SESSION_LIFECYCLE |                                          \
   DH_CAPABILITY_GENERATION_TAGGED_EVENTS |                                   \
   DH_CAPABILITY_SENSITIVE_INPUT_COPY | DH_CAPABILITY_PAIRABLE_HOST |         \
   DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS)

/** Minimum fail-closed capability set for authenticated screenshots. */
#define DH_REQUIRED_CAPABILITIES_SCREENSHOT                                   \
  (DH_CAPABILITY_SESSION_LIFECYCLE |                                          \
   DH_CAPABILITY_GENERATION_TAGGED_EVENTS |                                   \
   DH_CAPABILITY_SENSITIVE_INPUT_COPY |                                       \
   DH_CAPABILITY_AUTHENTICATED_RECONNECT | DH_CAPABILITY_RSD_METADATA |       \
   DH_CAPABILITY_PNG_SCREENSHOT | DH_CAPABILITY_DEVELOPER_READINESS)

/** Minimum fail-closed capability set for shipping live viewing and control. */
#define DH_REQUIRED_CAPABILITIES_LIVE_CONTROL                                 \
  (DH_CAPABILITY_SESSION_LIFECYCLE |                                          \
   DH_CAPABILITY_GENERATION_TAGGED_EVENTS |                                   \
   DH_CAPABILITY_SENSITIVE_INPUT_COPY |                                       \
   DH_CAPABILITY_AUTHENTICATED_RECONNECT | DH_CAPABILITY_RSD_METADATA |       \
   DH_CAPABILITY_PNG_SCREENSHOT | DH_CAPABILITY_DEVELOPER_READINESS |          \
   DH_CAPABILITY_CONTROL_STREAM | DH_CAPABILITY_VIDEO_NEGOTIATION |           \
   DH_CAPABILITY_RAW_VIDEO_DATAGRAMS | DH_CAPABILITY_HEVC_ACCESS_UNITS |       \
   DH_CAPABILITY_TOUCH_INPUT | DH_CAPABILITY_KEYBOARD_INPUT |                 \
   DH_CAPABILITY_HARDWARE_BUTTON_INPUT | DH_CAPABILITY_ROTATION |             \
   DH_CAPABILITY_SPLIT_MEDIA_CALLBACK | DH_CAPABILITY_RELEASE_ALL_INPUT |      \
   DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS)

typedef uint32_t DhIpFamily;
#define DH_IP_FAMILY_IPV4 ((DhIpFamily)4)
#define DH_IP_FAMILY_IPV6 ((DhIpFamily)6)

typedef uint32_t DhPairingCompletion;
#define DH_PAIRING_COMPLETION_PROVISIONAL ((DhPairingCompletion)1)
#define DH_PAIRING_COMPLETION_COMMITTED ((DhPairingCompletion)2)

typedef uint32_t DhSessionState;
#define DH_SESSION_STATE_READY ((DhSessionState)1)
#define DH_SESSION_STATE_RUNNING ((DhSessionState)2)
#define DH_SESSION_STATE_WAITING_FOR_PERSISTENCE ((DhSessionState)3)
#define DH_SESSION_STATE_CONNECTED ((DhSessionState)4)
#define DH_SESSION_STATE_COMPLETED ((DhSessionState)5)
#define DH_SESSION_STATE_CANCELLED ((DhSessionState)6)
#define DH_SESSION_STATE_FAILED ((DhSessionState)7)

typedef uint32_t DhConnectionPhase;
#define DH_CONNECTION_PHASE_IDLE ((DhConnectionPhase)0)
#define DH_CONNECTION_PHASE_BINDING_PAIRING_LISTENER ((DhConnectionPhase)1)
#define DH_CONNECTION_PHASE_AWAITING_PAIRING_PEER ((DhConnectionPhase)2)
#define DH_CONNECTION_PHASE_PAIRING ((DhConnectionPhase)3)
#define DH_CONNECTION_PHASE_PERSISTING_PAIR_RECORD ((DhConnectionPhase)4)
#define DH_CONNECTION_PHASE_VERIFYING_PAIRING ((DhConnectionPhase)5)
#define DH_CONNECTION_PHASE_OPENING_TUNNEL ((DhConnectionPhase)6)
#define DH_CONNECTION_PHASE_DISCOVERING_SERVICES ((DhConnectionPhase)7)
#define DH_CONNECTION_PHASE_CAPTURING_SCREENSHOT ((DhConnectionPhase)8)
#define DH_CONNECTION_PHASE_READY ((DhConnectionPhase)9)
#define DH_CONNECTION_PHASE_PREPARING_DEVICE ((DhConnectionPhase)10)
#define DH_CONNECTION_PHASE_STARTING_DISPLAY_STREAM ((DhConnectionPhase)11)
#define DH_CONNECTION_PHASE_WAITING_FOR_VIDEO_RECEIVER ((DhConnectionPhase)12)
#define DH_CONNECTION_PHASE_OPENING_INPUT ((DhConnectionPhase)13)
#define DH_CONNECTION_PHASE_STREAMING ((DhConnectionPhase)14)

typedef uint32_t DhEventKind;
#define DH_EVENT_SESSION_STARTED ((DhEventKind)1)
#define DH_EVENT_PHASE_CHANGED ((DhEventKind)2)
#define DH_EVENT_PAIRING_LISTENER_READY ((DhEventKind)3)
#define DH_EVENT_PAIRING_CODE ((DhEventKind)4)
#define DH_EVENT_PAIR_RECORD_PROVISIONAL ((DhEventKind)5)
#define DH_EVENT_PAIR_RECORD_COMMITTED ((DhEventKind)6)
#define DH_EVENT_AUTHENTICATED ((DhEventKind)7)
#define DH_EVENT_RSD_READY ((DhEventKind)8)
#define DH_EVENT_SCREENSHOT_PNG ((DhEventKind)9)
#define DH_EVENT_SESSION_COMPLETED ((DhEventKind)10)
#define DH_EVENT_SESSION_FAILED ((DhEventKind)11)
#define DH_EVENT_SESSION_CANCELLED ((DhEventKind)12)
#define DH_EVENT_VIDEO_NEGOTIATION_ANSWER ((DhEventKind)13)
#define DH_EVENT_VIDEO_DATAGRAM ((DhEventKind)14)
#define DH_EVENT_VIDEO_CONFIGURATION ((DhEventKind)15)
#define DH_EVENT_VIDEO_ACCESS_UNIT ((DhEventKind)16)
#define DH_EVENT_VIDEO_DISCONTINUITY ((DhEventKind)17)
#define DH_EVENT_INPUT_READY ((DhEventKind)18)
#define DH_EVENT_DISPLAY_GEOMETRY ((DhEventKind)19)

typedef uint32_t DhRemoteOperation;
#define DH_REMOTE_OPERATION_SCREENSHOT ((DhRemoteOperation)1)
#define DH_REMOTE_OPERATION_CONTROL_STREAM ((DhRemoteOperation)2)
#define DH_REMOTE_OPERATION_PAIR_VERIFY ((DhRemoteOperation)3)

typedef uint32_t DhVideoNegotiationOutcome;
#define DH_VIDEO_NEGOTIATION_SUCCEEDED ((DhVideoNegotiationOutcome)1)
#define DH_VIDEO_NEGOTIATION_FAILED ((DhVideoNegotiationOutcome)2)

typedef uint32_t DhVideoDiscontinuity;
#define DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP ((DhVideoDiscontinuity)1)
#define DH_VIDEO_DISCONTINUITY_TIMESTAMP_CHANGED_WITHOUT_MARKER               \
  ((DhVideoDiscontinuity)2)
#define DH_VIDEO_DISCONTINUITY_MALFORMED_PAYLOAD ((DhVideoDiscontinuity)3)
#define DH_VIDEO_DISCONTINUITY_NAL_TOO_LARGE ((DhVideoDiscontinuity)4)
#define DH_VIDEO_DISCONTINUITY_PARAMETER_SET_TOO_LARGE ((DhVideoDiscontinuity)5)
#define DH_VIDEO_DISCONTINUITY_ACCESS_UNIT_TOO_LARGE ((DhVideoDiscontinuity)6)
#define DH_VIDEO_DISCONTINUITY_TOO_MANY_NAL_UNITS ((DhVideoDiscontinuity)7)
#define DH_VIDEO_DISCONTINUITY_MISSING_PARAMETER_SETS ((DhVideoDiscontinuity)8)
#define DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM ((DhVideoDiscontinuity)9)

typedef uint32_t DhTouchPhase;
#define DH_TOUCH_PHASE_DOWN ((DhTouchPhase)1)
#define DH_TOUCH_PHASE_MOVE ((DhTouchPhase)2)
#define DH_TOUCH_PHASE_UP ((DhTouchPhase)3)
#define DH_TOUCH_PHASE_CANCEL ((DhTouchPhase)4)
#define DH_TOUCH_PHASE_TAP ((DhTouchPhase)5)

typedef uint32_t DhKeyboardPhase;
#define DH_KEYBOARD_PHASE_DOWN ((DhKeyboardPhase)1)
#define DH_KEYBOARD_PHASE_UP ((DhKeyboardPhase)2)
#define DH_KEYBOARD_PHASE_CANCEL_ALL ((DhKeyboardPhase)3)
/** Atomically press, hold briefly, and release one nonzero usage. */
#define DH_KEYBOARD_PHASE_TAP ((DhKeyboardPhase)4)

typedef uint32_t DhHardwareButton;
#define DH_HARDWARE_BUTTON_HOME ((DhHardwareButton)1)
#define DH_HARDWARE_BUTTON_LOCK ((DhHardwareButton)2)
#define DH_HARDWARE_BUTTON_VOLUME_UP ((DhHardwareButton)3)
#define DH_HARDWARE_BUTTON_VOLUME_DOWN ((DhHardwareButton)4)
#define DH_HARDWARE_BUTTON_MUTE ((DhHardwareButton)5)
#define DH_HARDWARE_BUTTON_SIRI ((DhHardwareButton)6)

typedef uint32_t DhButtonPhase;
#define DH_BUTTON_PHASE_DOWN ((DhButtonPhase)1)
#define DH_BUTTON_PHASE_UP ((DhButtonPhase)2)
#define DH_BUTTON_PHASE_CANCEL ((DhButtonPhase)3)
/** Atomically press, hold briefly, and release. */
#define DH_BUTTON_PHASE_TAP ((DhButtonPhase)4)

typedef uint32_t DhRotationDirection;
#define DH_ROTATION_DIRECTION_LEFT ((DhRotationDirection)1)
#define DH_ROTATION_DIRECTION_RIGHT ((DhRotationDirection)2)

typedef uint32_t DhOrientation;
#define DH_ORIENTATION_UNKNOWN ((DhOrientation)0)
#define DH_ORIENTATION_PORTRAIT ((DhOrientation)1)
#define DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN ((DhOrientation)2)
#define DH_ORIENTATION_LANDSCAPE_LEFT ((DhOrientation)3)
#define DH_ORIENTATION_LANDSCAPE_RIGHT ((DhOrientation)4)
#define DH_ORIENTATION_FACE_UP ((DhOrientation)5)
#define DH_ORIENTATION_FACE_DOWN ((DhOrientation)6)

typedef uint32_t DhPersistenceOutcome;
#define DH_PERSISTENCE_SUCCEEDED ((DhPersistenceOutcome)1)
#define DH_PERSISTENCE_FAILED ((DhPersistenceOutcome)2)

typedef struct DhSession DhSession;
typedef struct DhError DhError;

/** A borrowed byte span. data may be null only when count is zero. */
typedef struct DhBytes {
  const uint8_t *data;
  size_t count;
} DhBytes;

/** An opaque 128-bit identity for one connection attempt. */
typedef struct DhGeneration {
  uint64_t high;
  uint64_t low;
} DhGeneration;

/** Stable controller credentials copied synchronously by each constructor. */
typedef struct DhControllerIdentity {
  uint32_t struct_size;
  uint32_t abi_version;
  /** Canonical hyphenated UUID text. */
  DhBytes identifier;
  /** Stable controller UDID text. */
  DhBytes udid;
  /** Exactly 32 bytes of Ed25519 secret-key material; not all zero. */
  DhBytes long_term_secret_key;
  /** Exactly 16 bytes used as this controller's alternate IRK; not all zero. */
  DhBytes alternate_irk;
} DhControllerIdentity;

/** One already-resolved numeric endpoint; hostnames are not accepted. */
typedef struct DhResolvedEndpoint {
  uint32_t struct_size;
  /** DH_IP_FAMILY_IPV4 or DH_IP_FAMILY_IPV6. */
  DhIpFamily family;
  /**
   * Network-order address bytes. IPv4 uses the first four bytes and requires
   * the remaining twelve bytes to be zero.
   */
  uint8_t address[16];
  /** Required for link-local IPv6; zero for IPv4 and global IPv6. */
  uint32_t scope_id;
  /** Nonzero TCP port. */
  uint16_t port;
  /** Must be zero. */
  uint16_t reserved;
} DhResolvedEndpoint;

/** Durable peer material required to authenticate Pair Verify. */
typedef struct DhTargetPairingRecord {
  uint32_t struct_size;
  uint32_t abi_version;
  DhBytes device_id;
  DhBytes account_identifier;
  DhBytes peer_identifier;
  /** Exactly 32 bytes of target Ed25519 public-key material. */
  DhBytes peer_public_key;
  /** Exactly 16 bytes of target alternate-IRK material; not all zero. */
  DhBytes peer_alternate_irk;
  DhBytes display_name;
  DhBytes product_type;
  /** DH_PAIRING_COMPLETION_PROVISIONAL or _COMMITTED. */
  DhPairingCompletion completion;
  /** Must be zero. */
  uint32_t reserved;
} DhTargetPairingRecord;

/**
 * Semantic fields from a validated `_remotepairing._tcp` announcement.
 *
 * auth_tags contains one or more concatenated decoded six-byte TXT authTag
 * discovery hints. Pair Verify, not these rotating hints, authenticates the
 * target. The endpoint must be selected from Foundation's resolved addresses.
 */
typedef struct DhValidatedRemoteService {
  uint32_t struct_size;
  uint32_t abi_version;
  DhResolvedEndpoint endpoint;
  /** Canonical hyphenated UUID service identifier. */
  DhBytes identifier;
  DhBytes auth_tags;
  /** Exact supported TXT values: ver=26, minVer=8, flags=0. */
  uint8_t wire_protocol_version;
  uint8_t minimum_wire_protocol_version;
  uint8_t flags;
  /** Must be zero. */
  uint8_t reserved;
} DhValidatedRemoteService;

/** Authenticated peer fields borrowed by pair-record events. */
typedef struct DhVerifiedPeer {
  DhBytes device_id;
  DhBytes account_identifier;
  DhBytes peer_identifier;
  DhBytes peer_public_key;
  DhBytes peer_alternate_irk;
  DhBytes display_name;
  DhBytes product_type;
} DhVerifiedPeer;

/** Authenticated RSD metadata borrowed by DH_EVENT_RSD_READY. */
typedef struct DhRsdMetadata {
  /** RSD generation UUID. */
  DhBytes uuid;
  /** Authenticated RSD Properties.OSVersion, or empty; never synthesized. */
  DhBytes operating_system_version;
  /** Authenticated RSD Properties.BuildVersion, or empty. */
  DhBytes build_version;
  /** Authenticated RSD Properties.UniqueDeviceID. */
  DhBytes unique_device_id;
  /** Authenticated RSD Properties.ProductType. */
  DhBytes product_type;
  uint64_t protocol_version;
  uint64_t service_count;
  uint8_t screenshot_service_available;
  /** Must be zero. */
  uint8_t reserved[7];
} DhRsdMetadata;

/** Complete changed HEVC decoder configuration borrowed by media callback. */
typedef struct DhVideoConfiguration {
  uint64_t revision;
  /** SPS-derived dimensions after conformance-window cropping. */
  uint32_t pixel_width;
  uint32_t pixel_height;
  DhOrientation orientation;
  /** Must be zero. */
  uint32_t reserved;
  /** NAL payloads without start codes or length prefixes. */
  DhBytes video_parameter_set;
  DhBytes sequence_parameter_set;
  DhBytes picture_parameter_set;
} DhVideoConfiguration;

/** One complete inbound video UDP payload borrowed by media callback. */
typedef struct DhVideoDatagram {
  DhBytes bytes;
  /** Diagnostics only; routing uses the retained authenticated socket. */
  uint16_t source_port;
  /** Must be zero. */
  uint8_t reserved[6];
} DhVideoDatagram;

/** Authoritative orientation plus latest SPS-derived pixel geometry. */
typedef struct DhDisplayGeometry {
  uint32_t pixel_width;
  uint32_t pixel_height;
  DhOrientation orientation;
  DhOrientation non_flat_orientation;
  uint8_t orientation_locked;
  /** Must be zero. */
  uint8_t reserved[7];
} DhDisplayGeometry;

/** Complete marker-closed HEVC access unit borrowed by media callback. */
typedef struct DhVideoAccessUnit {
  /** Four-byte big-endian length-prefixed HEVC NAL units. */
  DhBytes bytes;
  /** Decoder configuration epoch required by this access unit. */
  uint64_t parameter_set_revision;
  uint32_t ssrc;
  uint32_t rtp_timestamp;
  uint16_t first_sequence_number;
  uint16_t last_sequence_number;
  /** One for an HEVC intra random-access access unit. */
  uint8_t is_sync;
  /** Must be zero. */
  uint8_t reserved[3];
  /**
   * Authoritative by-value snapshot that applies to this access unit.
   *
   * Consumers must use this snapshot rather than racing independently
   * delivered DH_EVENT_DISPLAY_GEOMETRY control events.
   */
  DhDisplayGeometry geometry;
} DhVideoAccessUnit;

/**
 * One event borrowed for a single control or media callback invocation.
 *
 * payload contains a six-digit UTF-8 PIN for DH_EVENT_PAIRING_CODE, a
 * validated PNG for DH_EVENT_SCREENSHOT_PNG, or sanitized UTF-8 error JSON for
 * DH_EVENT_SESSION_FAILED. Media pointers are non-null only for their exact
 * media event kind. Raw datagrams do not prove decoding or frame display.
 * sequence is monotonic independently within each callback plane.
 */
typedef struct DhEvent {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  uint64_t sequence;
  DhEventKind kind;
  DhSessionState state;
  DhConnectionPhase phase;
  /** Must be zero. */
  uint32_t reserved;
  uint64_t request_id;
  uint64_t value;
  DhBytes payload;
  const DhVerifiedPeer *peer;
  const DhRsdMetadata *rsd;
  const DhVideoConfiguration *video_configuration;
  const DhVideoAccessUnit *video_access_unit;
  const DhVideoDatagram *video_datagram;
  const DhDisplayGeometry *display_geometry;
  uint32_t image_width;
  uint32_t image_height;
} DhEvent;

/** Serial callback invoked on a session-owned private dispatcher thread. */
typedef void (*DhEventCallback)(const DhEvent *event, void *context);

/**
 * Synchronous media callback invoked on the sole protocol worker.
 *
 * Receives only DH_EVENT_VIDEO_DATAGRAM, _VIDEO_CONFIGURATION,
 * _VIDEO_ACCESS_UNIT, and _VIDEO_DISCONTINUITY. It is never queued by Rust.
 * Copy every borrowed byte span before returning.
 */
typedef void (*DhMediaEventCallback)(const DhEvent *event, void *context);

/** Configuration for one explicit Pairable Host attempt. */
typedef struct DhPairingSessionConfig {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  const DhControllerIdentity *controller_identity;
  DhBytes display_name;
  DhBytes model;
  /** Requested listener port, or zero for an ephemeral port. */
  uint16_t requested_port;
  /** Must be zero. */
  uint8_t reserved[6];
  DhEventCallback callback;
  void *callback_context;
} DhPairingSessionConfig;

/** Configuration for one Pair Verify, screenshot, or live-control attempt. */
typedef struct DhRemoteSessionConfig {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  const DhControllerIdentity *controller_identity;
  const DhTargetPairingRecord *target;
  const DhValidatedRemoteService *service;
  DhRemoteOperation operation;
  /** Must be zero. */
  uint32_t reserved;
  /**
   * Exact binary-plist mode-5 offer produced by the retained AVConference
   * receiver for control streams; empty for screenshots.
   */
  DhBytes video_negotiator_offer;
  /** Required lossless control callback. */
  DhEventCallback callback;
  void *callback_context;
  /** Required for control streams; null for screenshots. */
  DhMediaEventCallback media_callback;
  void *media_callback_context;
} DhRemoteSessionConfig;

/** Generation-tagged normalized touchscreen input. */
typedef struct DhTouchInput {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  DhTouchPhase phase;
  uint16_t x;
  uint16_t y;
  /** Must be zero. */
  uint32_t reserved;
} DhTouchInput;

/** Generation-tagged HID Keyboard/Keypad transition. */
typedef struct DhKeyboardInput {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  DhKeyboardPhase phase;
  /** HID Keyboard/Keypad usage; zero only for CANCEL_ALL. */
  uint16_t usage;
  /** HID modifier bitmap; bits zero through seven map usages E0 through E7. */
  uint8_t modifiers;
  /** Must be zero. */
  uint8_t reserved;
} DhKeyboardInput;

/** Generation-tagged confirmed hardware-button transition. */
typedef struct DhHardwareButtonInput {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  DhHardwareButton button;
  DhButtonPhase phase;
  /** Must be zero. */
  uint64_t reserved;
} DhHardwareButtonInput;

/** Generation-tagged outbound AVConference RTCP/control datagram. */
typedef struct DhVideoControlDatagram {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  /** One complete nonempty UDP payload, at most UINT16_MAX bytes. */
  DhBytes bytes;
} DhVideoControlDatagram;

/** Generation-tagged relative 90-degree rotation. */
typedef struct DhRotationInput {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
  DhRotationDirection direction;
  /** Must be zero. */
  uint32_t reserved;
} DhRotationInput;

/** Generation-tagged idempotent release of every native held input. */
typedef struct DhReleaseAllInput {
  uint32_t struct_size;
  uint32_t abi_version;
  DhGeneration generation;
} DhReleaseAllInput;

/** Returns the binary ABI version. */
uint32_t dh_ffi_abi_version(void);

/** Returns a mask containing only functionality implemented by this binary. */
DhCapabilities dh_ffi_capabilities(void);

/** Returns a process-lifetime NUL-terminated wrapper version string. */
const char *dh_ffi_version(void);

/** Returns the process-lifetime NUL-terminated pinned idevice revision. */
const char *dh_ffi_idevice_revision(void);

/**
 * Creates one Pairable Host session without binding the listener.
 *
 * On success, out_session receives unique ownership and out_error is cleared.
 * On failure, out_session is null and out_error optionally receives one owned,
 * sanitized error. out_error itself may be null. Non-null output storage must
 * not already contain a live owned pointer.
 */
DH_NODISCARD
DhStatus dh_pairing_session_create(const DhPairingSessionConfig *config,
                                   DhSession **out_session,
                                   DhError **out_error);

/**
 * Creates one Pair Verify, screenshot, or live-control session.
 *
 * Construction validates and copies the complete input graph synchronously.
 * Start authenticates the connected endpoint against the stored peer identity
 * with Pair Verify before any optional tunnel work.
 * Output ownership follows dh_pairing_session_create().
 */
DH_NODISCARD
DhStatus dh_remote_session_create(const DhRemoteSessionConfig *config,
                                  DhSession **out_session,
                                  DhError **out_error);

/**
 * Starts a created pairing, Pair Verify, screenshot, or control session.
 *
 * Repeated calls while running are no-ops. Starting a terminal session returns
 * DH_STATUS_INVALID_STATE.
 */
DH_NODISCARD
DhStatus dh_session_start(DhSession *session, DhError **out_error);

/**
 * Completes exactly one pending pair-record persistence request.
 *
 * request_id must exactly match the nonzero ID in the corresponding
 * provisional or committed event. Duplicate, stale, zero, or wrong-session
 * IDs fail without advancing the protocol. DH_PERSISTENCE_FAILED terminates
 * that protocol generation.
 */
DH_NODISCARD
DhStatus dh_session_complete_persistence(DhSession *session,
                                         uint64_t request_id,
                                         DhPersistenceOutcome outcome,
                                         DhError **out_error);

/**
 * ACKs configuration/start success or failure for the retained video receiver.
 */
DH_NODISCARD
DhStatus dh_session_complete_video_negotiation(
    DhSession *session, DhGeneration generation,
    DhVideoNegotiationOutcome outcome, DhError **out_error);

/** Queues one ordered normalized touch transition or atomic touchscreen tap. */
DH_NODISCARD
DhStatus dh_session_send_touch(DhSession *session, const DhTouchInput *input,
                               DhError **out_error);

/** Queues one ordered virtual-keyboard transition. */
DH_NODISCARD
DhStatus dh_session_send_keyboard(DhSession *session,
                                  const DhKeyboardInput *input,
                                  DhError **out_error);

/** Queues one ordered confirmed iOS hardware-button transition. */
DH_NODISCARD
DhStatus dh_session_send_hardware_button(
    DhSession *session, const DhHardwareButtonInput *input,
    DhError **out_error);

/** Queues one ordered relative 90-degree rotation. */
DH_NODISCARD
DhStatus dh_session_rotate(DhSession *session, const DhRotationInput *input,
                           DhError **out_error);

/**
 * Queues an idempotent reset of all native held touch/key/button state.
 *
 * This cleanup command remains valid after UI freshness authorization is
 * revoked, until the native input services close.
 */
DH_NODISCARD
DhStatus dh_session_release_all_input(DhSession *session,
                                      const DhReleaseAllInput *input,
                                      DhError **out_error);

/** Queues one outbound video RTCP/control UDP payload to device port 50001. */
DH_NODISCARD
DhStatus dh_session_send_video_control_datagram(
    DhSession *session, const DhVideoControlDatagram *datagram,
    DhError **out_error);

/**
 * Requests cancellation and drains the terminal control callback.
 *
 * Repeated requests are no-ops. This must not be called from either callback.
 */
DH_NODISCARD
DhStatus dh_session_cancel(DhSession *session, DhError **out_error);

/**
 * Cancels, joins, zeroizes, releases, and nulls a uniquely owned session.
 *
 * No callback from this session can begin after this function returns. Passing
 * storage containing null is a successful no-op. Passing a null storage
 * pointer returns DH_STATUS_INVALID_ARGUMENT. Calling from the session's own
 * callback returns DH_STATUS_INVALID_STATE without consuming the session.
 */
DH_NODISCARD
DhStatus dh_session_free(DhSession **inout_session);

/**
 * Returns borrowed sanitized UTF-8 JSON valid until dh_error_free().
 *
 * The schema is:
 * {"code":string,"stage":string,"retryable":boolean,"message":string}
 * Null returns null.
 */
const char *dh_error_json(const DhError *error);

/**
 * Releases and nulls one uniquely owned error.
 *
 * A null storage pointer and storage containing null are both no-ops.
 */
void dh_error_free(DhError **inout_error);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // DEVICE_HUB_FFI_H
