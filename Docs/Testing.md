# Testing

Compilation proves that the layers fit together. Device Hub's tests also cover
state transitions, parser boundaries, media generations, input transforms,
teardown, and the real device path.

## Local verification

Use the repository's `mise` tasks rather than invoking individual toolchains
with ad hoc flags:

```sh
mise run test
mise run lint
mise run previews
mise run build
```

Run `mise run ci` before submitting a change. Documentation-only changes run
fast repository checks; product changes run the complete Swift and Rust test,
source-check, generated-project, app-build, and visual validation suite. Set
`DEVICE_HUB_FULL_CI=1` to force every gate locally.

GitHub Actions uses one Xcode 27 runner and one checkout. Shared project and
protocol generation run first; independent lint, test, verification, and
unsigned Release-build steps then run concurrently with separate logs. Pull
requests targeting `main` use the same workflow. Workflows from external forks
require maintainer approval before they run.

## Simulator ownership

`mise run test:app`, `mise run test:media`, and snapshot recording delegate
local simulator ownership to the host-wide `codex-simulator-lease` supervisor
when it is installed. The supervisor serializes simulator work across
repositories, records the exact UUID before boot, terminates the complete
workload process group, and does not release ownership until shutdown and
deletion are verified.

Exit status `75` means another simulator workflow owns the host. Status `125`
means cleanup could not be proven. After an aborted, detached, timed-out, or
signal-terminated run, do not retry the test command. First run:

```sh
codex-simulator-lease reap
codex-simulator-lease status --json
```

The reaper targets only the registered UUID and retains durable state when
cleanup cannot be verified. Isolated environments without the shared
supervisor, including GitHub-hosted runners, use one stable managed simulator
name and verified exact-device teardown.

## Regression strategy

For a reproducible defect:

1. Capture the failure at the smallest owning boundary.
2. Add a regression and verify that it fails.
3. Fix the underlying cause.
4. Rerun the focused regression and the real reproduction.
5. Run the broader task for every affected layer.

Prefer real fixtures and temporary directories. Stub live network and device
services only where deterministic tests cannot own them.

## Protocol coverage

The protocol suites should prove that:

- cancelling pairing removes the advertisement and commits no record;
- relaunching can reconnect with an existing pair record;
- provisional pairing records recover safely across interruption;
- forged pairing and pair-verify signatures are rejected;
- authentication failure never starts pairing implicitly;
- malformed lengths, padding, packets, and codec units fail closed;
- screenshot delivery precedes the live display transition;
- orientation and letterbox transforms map to the intended target pixel;
- cancellation releases touches, buttons, keys, and modifiers;
- stale events from an earlier connection generation are ignored;
- teardown reaches EOF without callbacks, leaks, or lingering advertisements;
- an unknown media owner returns Device Busy instead of being stopped;
- diagnostics remain typed, bounded, and redacted.

## Visual coverage

Render and inspect the preview or snapshot matrix for:

- iPhone portrait and landscape;
- iPad full screen and narrow Stage Manager windows;
- light and dark appearance;
- empty, pairing, connecting, live, offline, locked, Developer Mode off,
  local-network denied, Device Busy, and viewing-only states;
- accessibility text sizes, VoiceOver order, Reduce Motion, and increased
  contrast.

Clipping, overlap, unreadable hierarchy, dead controls, obscured remote pixels,
and stale-screen ambiguity block completion.

Use `mise run snapshots:record` when an intentional visual change requires new
iOS reference images. The task records the matrix and immediately reruns it in
comparison mode so stale or incomplete references cannot pass silently.

## Authorized-device verification

Protocol work should also be exercised on dedicated hardware owned by the
tester or explicitly authorized for the test. Verify visible target reactions
for taps, drags, keyboard input, and hardware controls; orientation and
letterbox accuracy; reconnection; sustained-motion quality; and bounded
teardown.

Preserve existing pairing identity and app data by default. Resetting pairing,
replacing identity, uninstalling the app, or deleting target data is not part
of ordinary verification.
