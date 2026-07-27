# Device Hub Preview Renderer

`DeviceHubPreviewRenderer` is a macOS 27 command-line tool that captures a
deterministic visual matrix from the real `DeviceHubUI` surface.

It is intentionally a separate Swift package. Keeping the AppKit renderer out
of `Packages/DeviceHubKit` prevents iOS package tests from compiling a
macOS-only target.

## Run the verified pipeline

From the repository root:

```bash
OUT_DIR=/private/tmp/device-hub-previews \
  Scripts/render-local-previews.sh
```

The script resolves Xcode 27, runs this package's Swift Testing suite, renders
into an isolated staging directory, validates every PNG and catalog hash, and
atomically promotes the completed artifact set.

The executable contract is:

```bash
swift run --package-path Tools/DeviceHubPreviewRenderer \
  DeviceHubPreviewRenderer --output /path/to/output

swift run --package-path Tools/DeviceHubPreviewRenderer \
  DeviceHubPreviewRenderer --list-json

swift run --package-path Tools/DeviceHubPreviewRenderer \
  DeviceHubPreviewRenderer --list-json --output /path/to/output
```

`--output` emits exactly the required PNG filenames. `--list-json` either
renders in memory or validates an existing output directory, then emits stable
viewport, state, dimension, byte-count, and SHA-256 metadata.

## Safety and fidelity boundary

- Fixture state, synthetic pixels, and dependencies exist only in this tool
  package and are not linked into the shipped app.
- Rendering performs no discovery, networking, pairing, Keychain access,
  simulator work, or device control.
- The tool hosts `DeviceHubView` in an unordered AppKit window because SwiftUI
  `ImageRenderer` substitutes an unsupported-content placeholder for the real
  navigation hierarchy.
- These artifacts prove deterministic state coverage and catch gross layout
  regressions. The iOS 27 simulator snapshot suite remains the fidelity source
  of truth for UIKit rendering, safe areas, and platform chrome.
