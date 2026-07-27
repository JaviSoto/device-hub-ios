# Protocol and Security Contract

## Upstream

The protocol engine is
[`jkcoxson/idevice`](https://github.com/jkcoxson/idevice), pinned to commit
`a64b8867815b3da17b5c927531bdba877e8456ef` and its resolved Cargo lockfile.
It is MIT licensed.

The app uses an independently written domain wrapper plus a focused patch set
required to fail closed. Setup fetches the pinned upstream revision and applies
the checked-in patches; the upstream repository is not copied into this
repository. Every patch has a regression test and remains reviewable against
its upstream base.

Enabled `idevice` features:

```text
ring
remote_pairing
tunnel_tcp_stack
display_stream
mobile_image_mounter
```

The app uses `mobile_image_mounter` only to verify the existing personalized
developer image. The `tss` feature is deliberately not enabled: version 1
never mounts or downloads an image and never contacts Apple's TSS service.

## Durable identity

The controller identity consists of:

- a stable controller identifier;
- a stable controller UDID;
- an Ed25519 long-term secret key;
- a 16-byte altIRK.

These values live in Keychain and survive application upgrades. Recreating them
invalidates the target device's trust, so uninstall/reinstall is never a normal
deployment step.

A target record stores only the stable identity and peer material needed for
future authentication. The app writes a provisional record after independently
verifying pairing message M5 and before sending M6, then commits it after M6.
This closes the crash window without treating an unverified peer as paired.
Host and peer altIRKs are distinct values. A provisional record is retained
across a crash and promoted only after authenticated pair-verify succeeds; the
app never discards an ambiguous record automatically.

The remote-pairing wire advertisement remains `ver=26` and `minVer=17`. The
iOS 27 deployment target is not substituted into that protocol field. The app
never calls upstream per-attempt identity generators.

The app never persists:

- the SRP shared secret;
- a tunnel or TLS PSK;
- cipher counters;
- tunnel addresses;
- raw packets;
- display frames or screenshots.

## Authentication

The wrapper independently verifies:

- the target identity and signature in pairing M5;
- the target signature in pair-verify M2;
- modern Bonjour `authTag` values against the intended stored target.

Authentication failure is terminal for that attempt. The app never silently
falls back into pairing; pairing begins only from an explicit user action or an
explicit unpaired result.

Pairing message M5 is accepted only when the identifier is valid UTF-8 and
nonempty, the Ed25519 public key is exactly 32 bytes, the signature is exactly
64 bytes, the altIRK is exactly 16 bytes, the signature verifies over the
HomeKit-derived transcript, and the OPACK account identifier agrees with the
signed TLV identifier. The provisional persistence callback must acknowledge
success before Rust emits a valid M6.

The regression suite also proves:

- an incorrect TLS Finished value closes the connection rather than continuing;
- malformed CBC padding returns a typed integrity error and cannot panic;
- truncated or oversized CDTunnel declared lengths cannot produce an
  out-of-bounds slice.

## Local-network discovery

Swift owns Bonjour advertisement, browsing, resolution, and Local Network
permission through Foundation and Network.framework. The app does not rely on
the upstream raw-multicast `mdns-sd` path, which can require an Apple multicast
entitlement. Swift passes only validated service endpoint and TXT fields across
the narrow Rust boundary.

## Connection generation

A connection generation is indivisible:

```text
authenticated Bonjour match
→ pair verify
→ TLS 1.2 PSK Remote Pairing listener
→ TLS-PSK CoreDevice tunnel
→ userspace TCP/IP
→ Remote Service Discovery
→ developer services
→ screenshot
→ display
→ HID
```

Any broken layer tears down the complete generation. Reconnection creates fresh
cryptographic/session state and resets media depacketizers, pending input, held
buttons, and frame freshness.

## Developer services

Every authenticated RSD generation rechecks Developer Mode, looks up an
existing `Personalized` developer image, and requires the exact CoreDevice
services needed by the requested screenshot or control path. Readiness is not
cached once per target boot.

Version 1 requires Xcode to have prepared the matching iOS 27 personalized
image already. It never mounts, imports, or downloads an image, never attempts
to replace one, and never contacts TSS. Missing image or service readiness is a
visible, typed failure rather than an implicit mounting flow.

## Media and input

- A clean PNG screenshot is the first visual proof before live display begins.
- Rust starts the inert audio prerequisite before video with the same client
  session identifier, constructs the userspace video offer, and validates the
  negotiated answer before accepting packets.
- The app-owned HEVC assembler emits only complete access units. It strips the
  protocol trailer, treats packet loss/marker inconsistency as corruption,
  drops corrupt units, gates dependent frames until a new IRAP, and debounces
  PLI requests. Upstream's convenience depacketizer is not used directly as a
  VideoToolbox boundary.
- Rust owns inbound RTP/RTCP parsing and outbound receiver reports, NACKs, and
  PLIs. Swift receives only validated codec configuration and complete HEVC
  access units for VideoToolbox decoding.
- Each decoded frame carries generation, orientation, dimensions, presentation
  time, and receipt time.
- Input is disabled until a fresh decoded frame and HID readiness belong to the
  same generation.
- Coordinates are transformed through the displayed aspect-fit rectangle and
  target orientation, then clamped to target pixels.
- HID writes are serialized. Cancellation performs best-effort releases,
  including modifiers in reverse order.
- Touch and the stateful virtual keyboard use UniversalHID. Hardware buttons
  use Indigo. Keyboard chords update one UniversalHID usage bitmap, and
  cancellation clears the complete bitmap before teardown.
- A successful write is not treated as proof that an input landed; real-device
  validation must observe the target.
- Media teardown always names this app's session UUID. The upstream
  `stopAll=true` convenience call is prohibited. If another host owns an unknown
  media session, the app reports Device Busy rather than stopping that session.

## Diagnostics boundary

Allowed diagnostics include phase transitions, redacted typed errors, latency,
codec name, frame age, cancellation outcome, and reconnect outcome. The local
store is bounded and accepts only the typed event vocabulary.

Remote diagnostics are off by default. A build must explicitly provide a
destination, and the user must enable sharing before any diagnostic event is
uploaded. The app displays the destination host while sharing is enabled.
Public configuration contains no endpoint or upload credential.

Diagnostics never include PINs, controller or peer secrets, pair records, PSKs,
packets, unredacted IP, MAC, or host addresses, screenshots, frames, screen
contents, keystrokes, touch coordinates, or arbitrary free-form payloads.
