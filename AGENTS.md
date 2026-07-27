# Device Hub agent guide

This file defines the repository contract for coding agents and automated
contributors.

## Start here

1. Read `README.md`, `Docs/Architecture.md`, and the documentation for the
   layer being changed.
2. Run `mise install` and `mise run setup`.
3. Use `mise` tasks for builds, tests, generation, linting, previews, and
   archives. Run `mise tasks` for the supported entry points.
4. Inspect the complete diff before finishing. Do not include generated build
   products, credentials, personal infrastructure, or device data.

## Architecture

- Keep business logic in a functional core and side effects in thin shell
  layers.
- Put reusable Swift code in `Packages/DeviceHubKit`; app composition belongs
  in `Sources/DeviceHubApp` and `Sources/DeviceHubLive`.
- Keep protocol and FFI ownership in `Rust/DeviceHubFFI`.
- Features must not receive raw pointers, pair records, network addresses,
  packets, or codec buffers.
- Model asynchronous work with explicit connection generations and
  cancellation.
- Prefer removing obsolete paths to adding compatibility layers.
- Document new non-obvious APIs and security-sensitive invariants.

## Testing

- Reproduce a defect before changing production code.
- Add a regression that fails for the observed behavior, then implement the
  fix and rerun it.
- Use Swift Testing for Swift tests.
- Protocol changes require malformed-input, authentication-failure, and
  teardown coverage.
- UI changes require preview or snapshot evidence at relevant iPhone and iPad
  sizes.
- Run the strongest focused task while iterating and `mise run ci` before
  finishing.

## Process safety

- Run only one heavyweight build, test, archive, simulator, or device
  operation at a time.
- Do not leave detached processes, background jobs, simulators, or device
  sessions running after a task.
- Bound reverse-engineering commands by image, address range, runtime, and
  output.
- Never print provisioning material, environment contents, credentials, or
  full process command lines that may contain secrets.

## Device and data safety

- Pair with and control only devices owned by the tester or explicitly
  authorized for the test.
- Do not rotate controller identity, reset pairing, unregister a device,
  uninstall the app, or delete device data without explicit authorization for
  that action.
- Never commit pairing codes, pair records, private keys, PSKs, provisioning
  profiles, tokens, device identifiers, addresses, screenshots, screen
  contents, raw packets, or diagnostic databases.
- Keep fixtures synthetic and diagnostics inside the typed, redacted schema
  documented in `Docs/ProtocolSecurity.md`.
