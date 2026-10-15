# Product Contract

## North star

Device Hub is a remote session, not a protocol dashboard.

The first screen answers one question: **What is on this device, and can I
control it right now?**

The selected device's screen is the primary visual anchor. Device identity,
connection status, switching, and hardware controls remain immediately
available but visually secondary.

## Information architecture

```text
Remote Session
├── Device picker
│   ├── Available
│   ├── Offline or needs attention
│   └── Pair another device
├── Pair Device sheet
├── Device Details sheet
└── Remote Canvas
    ├── Screen
    ├── Connection-state overlay
    ├── Keyboard capture
    └── Contextual hardware controls
```

There is no dashboard and no Devices, Control, Logs, or Settings tab bar.

## Remote-session invariants

- Switching devices clears the old frame before changing the selected name.
- A frame older than one second is `Delayed`, never `Live`.
- A frame older than three seconds is dimmed and labeled `Last frame`; input is
  paused while the session reconnects.
- Touch input is enabled only after a fresh decoded frame and the matching HID
  channel are both ready for the same session generation.
- The screen is aspect-fit without a decorative device bezel. Letterboxed
  regions do not send input.
- Remote orientation changes the canvas shape; it does not rotate the controller
  app.
- Clipboard transfer is explicit. Automatic clipboard synchronization is not a
  first-release feature.

## Primary controls

The More menu stays close to the top-right corner and contains:

1. Home
2. Lock
3. Keyboard
4. Rotate

Secondary hardware controls, device selection, pairing, reconnect, and
stop-viewing live in the same menu. There is no bottom action bar or trailing
control rail. The remote canvas has no app-added padding.

## Platform adaptation

- iPhone and iPad use one full-window remote-session screen. The More menu
  contains device selection. Device details use a sheet.
- Every window size keeps hardware actions inside the corner menu.
- Both platforms support light and dark appearance, Dynamic Type, portrait and
  landscape targets, reduced motion, VoiceOver, and hardware keyboards.

## Product failures

The following block release even when the underlying protocol works:

- stale pixels labeled live;
- fake devices or fixture fallback in the shipping app;
- controls without a working effect;
- protocol identifiers, addresses, or raw error codes in ordinary UI;
- thick device bezels or a terminal-style developer aesthetic;
- indefinite progress without a timeout or useful remedy;
- iPad merely stretching the iPhone layout;
- app chrome that reserves space around the device image or covers more than
  the small floating controls require.
