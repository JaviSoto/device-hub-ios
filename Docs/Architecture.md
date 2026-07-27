# Architecture

## Shape

Device Hub follows a functional-core, imperative-shell architecture:

```text
DeviceHubApp
└── DeviceHubUI
    └── DeviceHubFeature
        ├── DeviceHubCore
        ├── DeviceHubDiagnostics
        └── DeviceHubClient
            └── DeviceHubTransport
                ├── DeviceHubPersistence
                ├── DeviceHubMedia
                └── DeviceHubFFI.xcframework
                    └── pinned and patched idevice
```

- `DeviceHubApp` composes dependencies and lifecycle only.
- `DeviceHubCore` owns pure values and derivations.
- `DeviceHubFeature` owns explicit TCA state, actions, effects, and cancellation.
- `DeviceHubUI` renders feature state and sends user intents.
- `DeviceHubClient` is the only contract visible to product features.
- `DeviceHubTransport` owns Swift/Rust lifetime bridging.
- `DeviceHubMedia` owns the complete-access-unit VideoToolbox boundary and
  latest-frame delivery.
- Swift owns Foundation/Network.framework Bonjour advertisement, browsing,
  resolution, and TXT validation. Rust owns pairing, tunnels, Remote Service
  Discovery, media, HID, and their structured tasks after Swift supplies a
  validated endpoint.
- `DeviceHubDiagnostics` accepts only a deliberately redacted event vocabulary.

The app and every package hard-target iOS/iPadOS 27. There are no availability
branches or legacy transport modes.

## Session ownership

Each remote-session scene owns one active target. Every connection receives a
new `SessionGeneration` value. Asynchronous events carry that generation, and
reducers reject events from any prior generation. This ownership model keeps
sessions isolated and allows future iPadOS windows to host independent
connections.

Changing targets performs this sequence:

1. Disable input immediately.
2. Invalidate the current generation.
3. Release held touches, buttons, keys, and modifiers.
4. Cancel media and the userspace tunnel.
5. Await bounded, idempotent teardown.
6. Clear the old image.
7. Create the next generation.

Freeing a Rust session cancels and joins its structured tasks. Its callback
context cannot be invoked after the corresponding free operation returns.

## Dependency rules

- Features never receive raw Rust pointers, pair records, network addresses,
  RSD ports, service handles, RTP packets, or codec buffers.
- The live client does not silently become a fixture client.
- Test clients fail loudly for every unimplemented endpoint.
- Errors cross module boundaries as typed, redacted domain errors with a stage
  and retry classification.
- Long-lived observations use `AsyncStream` or `AsyncThrowingStream` with an
  explicit termination path.

## Build system

- mise is the supported entry point for setup, generation, builds, tests,
  linting, previews, and archives.
- XcodeGen owns the Xcode project definition.
- Reusable code remains in the local Swift package.
- Swift Testing is the only test framework.
- SwiftFormat, SwiftLint, Periphery, jscpd, XcodeGen, and AXe are verification
  gates.
- Rust source and `Cargo.lock` are pinned; the XCFramework is reproducibly built
  for arm64 device and arm64 simulator.
- Signing configuration is local and never committed. Unsigned simulator builds
  and locally signed device archives use the same generated project.
