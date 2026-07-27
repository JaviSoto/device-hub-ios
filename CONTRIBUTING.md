# Contributing to Device Hub

Contributions are welcome. Device Hub crosses UI, cryptographic, media, and
device-control boundaries, so changes should be focused, tested, and explicit
about the layer they own.

## Development setup

Development requires macOS with Xcode 27 and the iOS 27 SDK. The repository
uses [mise](https://mise.jdx.dev/) to install the remaining tools and expose
the supported workflows.

```sh
mise install
mise run setup
mise run build
```

Run `mise tasks` to see all available tasks. The usual validation loop is:

```sh
mise run test
mise run lint
mise run ci
```

The generated Xcode project is not source of truth. Edit `project.yml`, then
run `mise run generate`.

## Repository structure

- `Packages/DeviceHubKit` contains reusable Swift domain, feature, transport,
  persistence, media, diagnostics, and UI code.
- `Sources/DeviceHubApp` and `Sources/DeviceHubLive` compose the application
  and live dependencies.
- `Rust/DeviceHubFFI` implements the protocol engine and Swift/Rust boundary.
- `Sources/DeviceHubPrivateMedia` contains the narrow native media boundary.
- `Docs` records the product, architecture, design, testing, and security
  contracts.

See [Architecture](Docs/Architecture.md) before introducing dependencies
between layers.

## Engineering principles

- Keep business logic in pure, testable transitions and side effects in thin
  shell layers.
- Model feature behavior as explicit state and actions.
- Keep raw pointers, pair records, addresses, packets, and codec buffers behind
  their owning transport boundaries.
- Preserve typed, redacted errors across module boundaries.
- Never add an implicit pairing fallback or a fixture fallback to production.
- Delete superseded paths instead of retaining compatibility branches.
- Document non-obvious APIs and security-sensitive invariants.

## Tests

For a reproducible defect, add a regression that exercises the failing
boundary and verify that it fails before changing production code. Refactors
should cover success, failure, cancellation, and state restoration.

Use Swift Testing for Swift tests. Protocol changes also require malformed
input, authentication failure, and teardown coverage. Prefer real fixtures and
temporary directories; stub only live external systems.

Run the smallest relevant task while iterating, then `mise run ci` before
opening a pull request. See [Testing](Docs/Testing.md) for the complete
validation contract.

## Device and data safety

Test live pairing and control only on devices you own or are explicitly
authorized to control. Never weaken authentication to simplify a test.

Do not commit pairing records, PINs, keys, tokens, provisioning profiles,
certificates, device identifiers, diagnostic databases, screen content,
screenshots, network addresses, or generated credentials. Fixtures must use
clearly synthetic values.

Actions that reset pairing, replace controller identity, uninstall the app, or
delete device data require explicit authorization from the device owner.

## Pull requests

Before opening a pull request:

- keep the change within the smallest owning layer;
- add or update regression coverage;
- run `mise run ci`;
- update documentation when a public contract changes;
- inspect the complete diff for debug output, personal infrastructure,
  generated files, and accidental credentials;
- leave the worktree free of build products.

Security-sensitive changes should follow the private reporting process in
[SECURITY.md](SECURITY.md) before public discussion.
