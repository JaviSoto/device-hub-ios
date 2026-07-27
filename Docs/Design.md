# Design system

## Direction

The remote screen is the content. App chrome uses system materials, typography,
navigation, menus, sheets, lists, and symbols so it recedes around that screen.
A restrained indigo accent connects the app icon, selection, and primary
actions.

The app hard-targets iOS/iPadOS 27 and uses current SwiftUI directly:

- a two-column `NavigationSplitView` with a 280–320 point sidebar in regular
  width;
- one `NavigationStack` remote-session root on iPhone and narrow iPad windows;
- a safe-area session header whose device picker remains a genuine 44-point
  target without covering remote pixels;
- `GlassEffectContainer` for the compact, related remote-control surface rather
  than separate ornamental capsules;
- transformed `onGeometryChange` values only when layout geometry must enter
  feature state;
- safe-area toolbars and insets that never cover tappable remote pixels.

Liquid Glass is reserved for interactive chrome. It is not layered over the
remote display, lists, error copy, or large background regions.

## Color

- Canvas: near-black neutral in both appearances to preserve remote-screen
  contrast.
- Accent: blue-violet/indigo, system-adjusted for contrast.
- Status is always communicated by a word and, where useful, a symbol. Color is
  supplemental.
- Initial screenshots remain labeled as “Starting live view” until native
  transport either produces decoded video or reports a bounded failure.

## Type and interaction

- Use semantic text styles and support accessibility sizes without truncating
  remedies.
- Every persistent control is at least 44×44 points.
- Ordinary remote taps have no controller-side haptic. Hardware-action controls
  use one restrained impact.
- Motion respects Reduce Motion. Orientation changes crossfade/resize rather
  than performing a disorienting controller-window rotation.
- VoiceOver identifies the selected target, freshness, input availability, and
  every hardware action. The raw remote image is one adjustable element unless
  richer target accessibility data becomes available.

## App icon

`Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` is the current full-bleed
bitmap for this project. It depicts two paired glass screen planes joined by one
luminous pulse. The mark contains no text, Apple marks, private framework
imagery, device chrome, or protocol/debug-tool symbolism.

The master is opaque RGB, 1024×1024, and intentionally has no pre-applied outer
corner mask. It is designed to remain legible at 1024, 64, and 32 pixels.
