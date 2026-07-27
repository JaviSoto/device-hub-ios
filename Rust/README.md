# Device Hub Rust boundary

`DeviceHubFFI` is Device Hub's app-owned C ABI over a reviewed, pinned
`idevice` protocol stack. It targets iOS 27 and exposes three explicit
operations:

1. run a real Pairable Host listener and complete authenticated Pair Setup; or
2. reconnect to a stored target, authenticate it, establish the CoreDevice
   tunnel, perform Remote Service Discovery, and return one validated PNG
   screenshot; or
3. reconnect once, emit a validated initial screenshot, and keep an
   authenticated display, media, HID, and orientation session alive until
   cancellation.

Foundation discovery and advertisement stay in Swift. Rust owns protocol
framing, authentication, tunnel setup, and the cancellable worker lifecycle.
The boundary never performs raw multicast discovery, persists credentials, or
silently changes an authenticated reconnect into a new pairing attempt.

## Capability contract

`dh_ffi_capabilities()` is the runtime source of truth. ABI version 3 currently
sets exactly these bits:

| Bit | Capability | Guaranteed behavior |
| --- | --- | --- |
| 0 | `DH_CAPABILITY_SESSION_LIFECYCLE` | Explicit construction, one-shot start, persistence acknowledgement, cancellation, and synchronized teardown. |
| 1 | `DH_CAPABILITY_GENERATION_TAGGED_EVENTS` | Every serialized callback carries the caller's complete 128-bit generation and a per-session monotonic sequence. |
| 2 | `DH_CAPABILITY_SENSITIVE_INPUT_COPY` | Retained controller and peer credentials are copied synchronously, kept only in zeroizing Rust-owned memory, and never logged or persisted. |
| 3 | `DH_CAPABILITY_PAIRABLE_HOST` | A real iOS 27 Pairable Host listener and authenticated Pair Setup exchange. |
| 4 | `DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS` | The protocol stops at provisional and committed record transitions until Swift confirms durable persistence. |
| 5 | `DH_CAPABILITY_AUTHENTICATED_RECONNECT` | Rust verifies Bonjour `authTag` and Pair Verify against the stored peer; there is no automatic pairing fallback. |
| 6 | `DH_CAPABILITY_RSD_METADATA` | TLS-PSK, CDTunnel, and the userspace TCP stack establish authenticated Remote Service Discovery and return its canonical identity plus validated OS/build metadata when the device supplies it. |
| 7 | `DH_CAPABILITY_PNG_SCREENSHOT` | CoreDevice screenshot service returns one bounded PNG whose chunks, CRCs, dimensions, IDAT, and terminator are validated before callback delivery. |
| 8 | `DH_CAPABILITY_DEVELOPER_READINESS` | Remote operations fail closed unless Developer Mode and an Xcode-prepared personalized developer image are already available. |
| 9 | `DH_CAPABILITY_CONTROL_STREAM` | One authenticated display/control session remains live until cancellation. |
| 10 | `DH_CAPABILITY_VIDEO_NEGOTIATION` | Swift's one retained AVConference receiver owns the exact mode-5 offer/answer acknowledgement. |
| 11 | `DH_CAPABILITY_RAW_VIDEO_DATAGRAMS` | Each inbound video UDP datagram is delivered exactly once and in receive order. |
| 12 | `DH_CAPABILITY_HEVC_ACCESS_UNITS` | Strict RTP/RTCP and RFC 7798 parsing emits complete marker-closed HEVC access units and decoder configuration. |
| 13 | `DH_CAPABILITY_TOUCH_INPUT` | Normalized single-contact down/move/up/cancel plus one-command semantic tap. |
| 14 | `DH_CAPABILITY_KEYBOARD_INPUT` | Stateful HID keyboard edges and one-command key-plus-modifier chord taps. |
| 15 | `DH_CAPABILITY_HARDWARE_BUTTON_INPUT` | Stateful confirmed Home, Lock, Mute, Siri, and volume edges plus one-command taps. |
| 16 | `DH_CAPABILITY_ROTATION` | Serialized relative 90-degree left/right rotation with device-reported geometry. |
| 17 | `DH_CAPABILITY_SPLIT_MEDIA_CALLBACK` | High-rate media uses a separate synchronous, backpressured callback plane. |
| 18 | `DH_CAPABILITY_RELEASE_ALL_INPUT` | Held touch, key, modifier, and button state has one idempotent bounded cleanup command. |
| 19 | `DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS` | Every HEVC access unit carries the authoritative by-value display geometry that applies to that sample. |

The header also publishes fail-closed pairing, screenshot, and live-control
capability groups. Live control includes PNG screenshot because screenshot-first
is part of that operation, not an optional presentation detail.

## Pairing transaction

Create `DhPairingSessionConfig` with a stable `DhControllerIdentity`, then call
`dh_session_start()`:

1. Rust binds the dual-stack TCP listener.
2. `DH_EVENT_PAIRING_LISTENER_READY` reports the already-bound port. Swift may
   publish its Foundation Pairable Host Bonjour service only after this event.
3. `DH_EVENT_PAIRING_CODE` provides the six-digit code as callback-borrowed
   UTF-8.
4. After M5 authentication,
   `DH_EVENT_PAIR_RECORD_PROVISIONAL` supplies the authenticated peer and a
   nonzero persistence request ID. Swift must durably store that provisional
   record and call `dh_session_complete_persistence()` before Rust sends M6.
5. Only after M6 succeeds,
   `DH_EVENT_PAIR_RECORD_COMMITTED` asks Swift to promote the durable record.
   That transition also requires an explicit successful acknowledgement.

A failed, stale, duplicate, zero, or wrong-session acknowledgement never
advances the exchange. Reporting `DH_PERSISTENCE_FAILED` terminates the current
generation.

## Authenticated reconnect

Swift resolves `_remotepairing._tcp` with Foundation and passes one
`DhValidatedRemoteService`:

- a numeric IPv4 or IPv6 address and nonzero port;
- the IPv6 interface scope ID when the address is link-local;
- canonical service identifier;
- one or more decoded six-byte `authTag` values; and
- the exact supported semantic TXT values `ver=26`, `minVer=8`, and
  `flags=0`.

The constructor validates and copies this input graph. On start, Rust
independently derives the expected tag from the stored target alternate IRK and
rejects the service before opening a socket if none matches. It then performs
Pair Verify against the stored peer identity. A provisional record recovered
this way must be durably promoted and acknowledged before tunnel setup.

Only authenticated reconnect proceeds through TLS-PSK, CDTunnel, jktcp, RSD,
developer-readiness verification, and CoreDevice services. Device Hub never
mounts or downloads a developer image; Xcode must already have prepared the
target. The `DH_EVENT_RSD_READY` metadata carries
`Properties.OSVersion`, `BuildVersion`, `UniqueDeviceID`, and `ProductType`
directly from that authenticated handshake; Swift must not infer, substitute,
or synthesize those identity values. `UniqueDeviceID` and `ProductType` are
required and must match the M5-authenticated record. OS/build spans may be
empty when RSD omits non-security display metadata. Reconnect never falls back
to Pair Setup.

## Live viewing and control

A control session captures, validates, and emits one PNG before it opens
DisplayService. Failure to capture that image aborts the generation before any
audio, video, or input service starts. Rust then starts the required inert
mode-6 audio prerequisite and the caller's exact mode-5 video offer over the
same DisplayService connection and `clientSessionID`. It returns the target's
exact binary-plist answer; Swift configures and starts its retained
AVConference receiver before acknowledging success.

Rust never parses or rewrites Swift's offer and never calls DisplayService's
global `stopAll` operation. It owns UDP ordering, strict RTP/RTCP and HEVC
assembly, and all HID state. Raw datagram, decoder-configuration, access-unit,
and discontinuity events are transport facts only; decoded/displayed-frame
truth comes from the AVConference receiver callback. Access-unit geometry is
snapshotted on the media plane and must be preferred over independently
delivered display-geometry control events. Every discontinuity invalidates the
last emitted decoder-configuration revision, so the next access unit is always
preceded by a complete configuration event.

Keyboard input uses Indigo keyboard-button edge events. Chords press modifiers
before the ordinary key, release the ordinary key first, and then release
modifiers in reverse order. Touch, keyboard, and confirmed hardware-button taps
are each one bounded Rust command; their down/up pair cannot interleave with
cancellation or another queued input. If release delivery fails, teardown
retains and retries the held state through the common cleanup path.

## Ownership and threading

- Input structures and `DhBytes` spans are borrowed only for a constructor
  call. Every retained value is copied before that call returns.
- Swift owns all durable Keychain state. Rust retains credentials only for the
  session and zeroizes its sensitive copies during teardown.
- Low-rate control events use one private serial dispatcher. High-rate media
  invokes a separate synchronous callback on the sole protocol worker; Rust
  does not queue media and callback latency applies backpressure.
- `DhEvent`, its `payload`, `peer`, `rsd`, and every nested byte span are
  borrowed only until the callback returns. Swift must copy anything it keeps.
- Neither callback may call `dh_session_cancel()` or `dh_session_free()`, or
  unwind through C. Persistence and video negotiation acknowledgements are
  allowed from the control callback.
- `dh_session_free(DhSession **)` is the synchronization barrier. It clears
  caller storage, disables callbacks, cancels and joins the worker, joins the
  dispatcher, zeroizes secrets, and releases the session before returning.
  Calling it again with the now-null storage is safe.
- `dh_error_free(DhError **)` follows the same pointer-to-pointer ownership
  rule and nulls the caller's pointer.

Session free must not race another session call. Callback function and context
storage must remain valid until session free returns.

## Errors

Every synchronous fallible function optionally returns an owned `DhError`.
`dh_error_json()` borrows sanitized UTF-8 JSON until `dh_error_free()`:

```json
{"code":"…","stage":"…","retryable":false,"message":"…"}
```

Asynchronous failures use the same schema in
`DH_EVENT_SESSION_FAILED.payload`. Errors intentionally omit PINs,
credentials, peer records, endpoints, and raw protocol payloads. Rust panics
are caught at the ABI boundary and converted to sanitized failures.

## Build and verification

From the repository root:

```sh
Scripts/test-rust.sh
Scripts/build-protocol-xcframework.sh
Scripts/verify-protocol-xcframework.sh
```

The build creates:

```text
Rust/Artifacts/DeviceHubFFI.xcframework
```

It contains arm64 iPhoneOS 27 and arm64 iOS Simulator 27 slices, both with a
27.0 minimum deployment target. Verification compares packaged headers to the
reviewed source, links the public C smoke consumer against both slices, and
checks each Mach-O platform and minimum OS.

The wrapper pins upstream `idevice` revision
`a64b8867815b3da17b5c927531bdba877e8456ef` with only the reviewed
`ring`, `remote_pairing`, `tunnel_tcp_stack`, `display_stream`, and
`mobile_image_mounter` features.
Provenance and local security hardening are documented under `Vendor/idevice`.
Build products and Cargo caches stay under `Rust/.build` and are ignored by
Git.

## Live protocol verification target

Every ignored live Rust harness requires an explicit, nonempty target name.
`open_live_rsd_for_target` rejects missing target configuration before it
parses or opens an endpoint.

Run the RSD wire-contract probe only against an already-established trusted
test-device tunnel:

```sh
DEVICE_HUB_TEST_TARGET_NAME='Test iPhone' \
DEVICE_HUB_RSD_ENDPOINT='[<test-device-tunnel-ip>]:<rsd-port>' \
CARGO_TARGET_DIR=Rust/.build/live-rsd \
rustup run stable cargo test --manifest-path Rust/DeviceHubFFI/Cargo.toml \
  protocol::tests::live_ios_rsd_property_contract -- --ignored --nocapture
```
