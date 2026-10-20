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

Publication uses `git signoff-push`, which runs `mise run ci` against the exact
clean commit before pushing. There is no GitHub Actions workflow. The complete
gate runs SwiftFormat, SwiftLint, ShellCheck, jscpd, Periphery, Rust tests,
Swift package tests, protocol verification, previews, and the unsigned Release
build. Heavy builds and simulator-bound verification run serially.

## Simulator ownership

`mise run test:app`, `mise run test:media`, and snapshot recording each own one
fresh simulator for that test run. The app-test script first builds for the
generic iOS Simulator destination, then creates and boots the selected device.
On home Macs, setup applies `~/.config/simslim/codex.json` to that exact UDID
and immediately verifies it before boot. Each device name contains ` - Codex `
so an interrupted run can be distinguished from other simulators. GitHub-hosted
runners without SimSlim and its profile use the same exact-device lifecycle
without the host-specific profile.

Visual references are recorded and compared on the helper's default iPhone
model (currently iPhone 17 Pro). The matrix supplies iPhone and iPad view sizes
and traits. Use an iPad simulator for interactive window-resize checks, not to
record the shared references: UIKit text rasterization still depends on the
underlying simulator's display scale.

Native XCTest and snapshot runs keep one raw log and `.xcresult` per pass under
`DERIVED_DATA_PATH/TestEvidence/DeviceHub` by default. Set
`DEVICE_HUB_TEST_EVIDENCE_DIR` to an absolute caller-owned evidence folder
outside the repository instead. The shared runner prints a compact status,
elapsed time, and artifact paths; failures include a bounded diagnostic excerpt
while the full log and result bundle stay in that evidence folder. Swift
package, Rust, protocol, and app-build logs stay under
`DERIVED_DATA_PATH/RunOutputs`.
`test-app` reuses one `DERIVED_DATA_PATH` for preflight, live tests, snapshots,
and the final app build. Dead-code analysis keeps its package index under that
root's `Periphery/DeviceHubKit` child.

The setup helper is also available for a one-off UI run. It prints the exact
UDID and task-owned name as tab-separated fields; pass both back unchanged for
validation and cleanup. A specific model can be selected by its exact Xcode
device-type name:

```sh
IFS=$'\t' read -r UDID CREATED SIM_NAME < <(
  python3 BuildSupport/simulator_setup.py prepare --name device-hub-ui \
    --device-type 'iPad Pro 13-inch (M4)'
)
python3 BuildSupport/simulator_setup.py validate-task --udid "$UDID" --name "$SIM_NAME"
python3 BuildSupport/simulator_setup.py cleanup --udid "$UDID" --name "$SIM_NAME"
```

The default is the newest installed iOS 27.0-or-later runtime. To test the
stable floor explicitly, add `--runtime-version 27.0` and choose a phone or
iPad listed as supported by that runtime, for example:

```sh
python3 BuildSupport/simulator_setup.py prepare --name device-hub-ios-270 \
  --runtime-version 27.0 --device-type 'iPhone 17 Pro'
```

The helper checks Xcode's supported-device metadata before creating the exact
runtime/model pair. The iPhone Duo remains a 27.1 runtime device.

Cleanup restores and verifies stock simulator services through SimSlim before
shutting down and deleting only that exact task-owned UDID. If a run is
interrupted or cleanup cannot be proven, inspect that device's exact identity
and state, then use the helper's `cleanup` command with its original UDID and
name before retrying. Do not add a host-wide lease, lock, or watcher.

The old `codex-simulator-lease` prerequisite in the repository agent guide is
retired. The maintained `BuildSupport/simulator_setup.py` helper owns allocation,
SimSlim verification, and exact-device cleanup. Coordinate a shared renderer
with its current owner before changing pose; never create a second device to
work around that owner's active use.

For Duo folded-control verification, build generically first, then use a real
27.1 `iPhone Duo` from the helper and launch `--device-hub-fixture live`. Capture
the actual half-open hierarchy and run:

```sh
python3 BuildSupport/accessibility_contract.py --screen folded-live /absolute/path/to/half-open-axe.json
```

The unfixed app lacks Home, Lock, Keyboard, Rotate, and Remote Controls outside
the menu. After the change, the direct controls must occupy the lower area and
the same session's remote image the upper area. Check both themes, rotate,
open/close the native keyboard, and fold back to flat/cover without relaunching.
Run the existing `--screen live` check after flattening to prove the bottom
controls disappear. Inspect the screenshots as well as the hierarchy; this
text-only contract cannot establish pose, geometry, or remote hit accuracy.

To add only a new snapshot method's references, run
`DEVICE_HUB_RECORD_SNAPSHOTS=1 DEVICE_HUB_RECORD_SNAPSHOT_TEST=RemoteSessionFoldedControlsSnapshotTests Scripts/test-app.sh`.
The selector narrows only recording; the subsequent verification still runs
every visual snapshot. Inspect existing reference changes before accepting any.

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

App integration also launches the simulator-only live fixture and checks its
actual accessibility tree: Home, Lock, Keyboard, and Rotate must be absent
from the canvas and present after opening More Controls. These checks use the
production navigation root and never connect to a real device. Its session
event and frame streams stay open until the app disconnects; a completed event
stream means the remote session ended. The fixture's Settings-like display is
mock service data, not a screenshot from a physical device.

## Authorized-device verification

Protocol work should also be exercised on dedicated hardware owned by the
tester or explicitly authorized for the test. Verify visible target reactions
for taps, drags, keyboard input, and hardware controls; orientation and
letterbox accuracy; reconnection; sustained-motion quality; and bounded
teardown.

Preserve existing pairing identity and app data by default. Resetting pairing,
replacing identity, uninstalling the app, or deleting target data is not part
of ordinary verification.
