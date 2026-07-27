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

The persistent control bar contains no more than five actions:

1. Home
2. Lock
3. Keyboard
4. Rotate
5. More

Secondary hardware controls, capture actions, reconnect, and stop-viewing live
inside menus.

## Platform adaptation

- iPhone uses one remote-session screen. Device selection and details are
  sheets.
- iPhone landscape uses compact overlays in letterboxed space rather than a
  desktop sidebar.
- iPad uses a collapsible 280–320 point device sidebar and one remote-canvas
  detail. Narrow Stage Manager windows collapse to the iPhone navigation shape.
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
- app chrome obscuring tappable remote content.
