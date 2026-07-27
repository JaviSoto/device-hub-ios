# DeviceHubPrivateMedia

`DeviceHubPrivateMedia` is the runtime-loaded iOS 27 AVConference boundary for
Device Hub's video-only mode-5 display stream. It deliberately imports no
private headers, links no private frameworks, and requests no private
entitlements.

## Session contract

1. Keep one `DHAVConferenceReceiver` for the entire video session.
2. Call `makeNegotiatorOfferWithError:` exactly once and send those bytes
   verbatim as displayservice's `negotiatorOffer`.
3. Start the transport's separate, inert mode-6 audio prerequisite first. Audio
   and video use the same displayservice connection and transport
   `clientSessionID`; AVConference's internal video call ID remains independent.
4. Pass the returned video `negotiatorAnswer` to that same receiver, then
   configure and start it.
5. Forward complete inbound RTP/RTCP datagrams to the receiver and forward its
   outbound RTCP datagrams to the paired device.

The caller owns the supplied `CALayer`. It may remain detached while decoding
starts; reveal it by attaching that exact layer after the first-frame event and
size it during layout. On unmount, invalidate the receiver before removing the
layer. The receiver retains but never reparents it and performs AVConference
layer binding and clearing on the main thread.

`DidStart` confirms AVConference accepted the stream and bound the layer.
`DidReceiveFirstFrame` is the first proof of decoded output. Stall/recovery,
last-frame, RTP timeout, RTCP timeout, and RTCP recovery events are projected
from AVConference's exact iOS 27 delegate callbacks. Geometry updates expose a
typed public value rather than leaking private objects.

## Validation

Run the single hermetic entrypoint:

```sh
Sources/DeviceHubPrivateMedia/Tests/run-tests.sh
```

It runs the synthetic mode-5 negotiation and lifecycle suite on macOS, compiles
and links the production boundary for iPhoneOS 27 with warnings as errors, and
runs a non-streaming iOS 27 Simulator probe. Simulator lacks AVConference's
video rule collection and currently rejects mode-5 initialization with
`GKVoiceChatServiceErrorDomain` code `32032`; that limitation passes only when
the framework ABI is valid and the exact known error, operation, and code match.
Any other failure remains fail-closed.

The harness uses the shared `codex-simulator-lease` supervisor when available.
On an isolated host, it reuses one exact managed simulator or creates it and
verifies its removal afterward. It never contacts a paired device or starts a
network stream. The probe runs as a direct simulator process with an isolated
home; it does not install or launch an app through SpringBoard. A physical iOS
27 device is still required to prove codec capability and decoded frames end
to end.
