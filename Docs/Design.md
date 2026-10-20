# Design system

## Direction

The remote screen is the content. App chrome uses system materials, typography,
navigation, menus, sheets, lists, and symbols so it recedes around that screen.
A restrained indigo accent connects the app icon, selection, and primary
actions.

The app hard-targets iOS/iPadOS 27 and uses current SwiftUI directly:

- one `NavigationStack` remote-session root on iPhone and iPad;
- an aspect-fit device image that uses the full window, with no header or
  toolbar space around it;
- a centered device name and status overlay that fades three seconds after a
  live connection, and stays visible when the connection needs attention;
- transformed `onGeometryChange` values only when layout geometry must enter
  feature state;
- a single 44-point More menu near the top-right corner, which contains Home,
  Lock, Keyboard, Rotate, device selection, pairing, details, and session options;
- no bottom action bar, trailing control rail, or app-added canvas padding.

On iPhone Duo 27.1, an overlay `ArrangementView` separates the existing canvas
and controls only when the display folds. Its primary view contains controls;
the secondary view contains the remote screen. Native arrangement layout puts
the screen above controls in tabletop orientation and beside them after
rotation. An `onGeometryChange` Boolean projection of active `.division`
reserved regions exposes direct controls only when that fold overlaps the
arrangement's available area. No hinge-angle thresholds or device-family checks
decide layout. The `NavigationStack` stays outside the arrangement. iOS 27.0
keeps the established full-window layout through one API-availability check.

The iOS 27.1 `24A94425` simulator reports `overlayArrangementZIndex == 0` to
both immediate primary and secondary readers in cover, flat, and half-open
states. It does not distinguish separation on that runtime. Active native
division regions do: inactive when flat, active when folded. The query uses
the default active-only regions and never computes pane frames. When the
native keyboard opens, the existing UIKit-backed presentation binding hides
the panel from the remaining overlay rather than obscuring the remote image.
The keyboard's own accessory controls and corner More menu remain available.
Native keyboard avoidance and `ArrangementView` placement remain responsible
for the space.

Liquid Glass gives the small controls contrast over the device image. The
rest of the canvas remains clear.

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
