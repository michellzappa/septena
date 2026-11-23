# Platform chrome for marketing screens

Status: **draft spec**, 2026-11-23. Owner: mz. Tracking: michellzappa/septena#227
(App Store sets) and michellzappa/septena-site#15 to #20 (one per plan step).

## Why

Every marketing screen of Septena (the website scenes, the press kit, the App
Store and Play Store panels) is drawn by the website's scene builder
(`septena-site/lib/task-ui/model.ts`, `components/task-ui/`), not captured
from a simulator. A drawn screen must look like the OS it claims to be: an
iPhone screen like iOS 27, an Android screen like Android, a Mac window like
macOS. Today the builder draws one iOS-like screen and changes a few details
for Android. This page lists what differs per platform, so each difference is
built once, from one source, and never improvised on a surface.

## Rules

1. **The target OS is data.** `registry/device-frames.json` gives every
   device a `system` block: `os`, `version` (the target release), `icons`
   (which column of `registry/icons.json` the app's own glyphs use) and
   `chrome` (the renderer's system chrome id). The renderer reads it. A new
   OS release changes the version there first, then the chrome to match.
2. **Two layers, never mixed.** *System chrome* belongs to the OS: status bar,
   home indicator or gesture bar, window title bar, caption buttons, system
   fonts. *App UI* belongs to Septena: lists, rows, checkboxes, the composer.
   The app UI follows what the real app on that platform draws (SwiftUI on
   iPhone and iPad, AppKit on Mac, Compose in `android/`, Compose Desktop on
   Windows per ADR 0013), not what the iPhone draws.
3. **Copy the OS from its official kit, never from memory.** Each OS below
   names its reference. Exact glyphs, sizes and fonts come from there. This
   page records what to check, not the pixel values.
4. **A platform that has not shipped stays out of store copy** (see
   `docs/APPSTORE-SEPTASK.md`). Its scenes may still appear on the website and
   in the press kit, labelled as planned.
5. **Licences.** SF Symbols and SF Pro may be used to show apps for Apple
   platforms; check Apple's licence before an Apple glyph appears on a
   non-Apple screen. Material Symbols (Apache 2.0) and Roboto (OFL) are free
   to use. Windows caption glyphs come from Segoe Fluent Icons, which ships
   with Windows; draw them from the Fluent System Icons repo (MIT) instead.

## Per platform

Status key: **ok** = drawn and checked against the kit; **approx** = drawn,
not checked against the target release; **missing** = not drawn.

### iPhone: iOS 27

Reference: Apple Design Resources, iOS 27 UI kit; SF Symbols app (latest).

| Element | What iOS draws | Scene builder today | Status |
|---|---|---|---|
| Status bar | Time at the left of the Dynamic Island (no AM/PM), cellular bars, Wi-Fi and battery at the right | Time plus a static SVG copied from Bipe's renderer (`phone-status-icons.tsx`) | approx |
| Dynamic Island | Pill cutout at the top centre | From `device-frames.json` (`cutout.kind: island`) | ok |
| Home indicator | Thin bar at the bottom centre | Drawn | approx |
| Toolbar buttons | Liquid Glass circles and capsules floating over content (since iOS 26) | Round and pill buttons with a light fill | approx |
| Large title | Bold large title under the toolbar | Drawn | approx |
| Font | SF Pro (Text and Display) | System font stack | approx |
| App glyphs | SF Symbols (`icons.json` `sfSymbol`) | Lucide | missing |

### iPad: iPadOS 27

Reference: Apple Design Resources, iPadOS 27 UI kit.

| Element | What iPadOS draws | Scene builder today | Status |
|---|---|---|---|
| Status bar | Time and date at the left, Wi-Fi and battery (with percentage) at the right; no island | Nothing (no iPad layout) | missing |
| Layout | Sidebar beside the list in landscape (split view), as the real app | Nothing; the App Store iPad set reuses iPhone screens | missing |
| Window controls | Windowed apps show window buttons at the top left (since iPadOS 26); full-screen apps do not | Nothing | missing |
| Home indicator | Thin bar at the bottom centre | Nothing | missing |
| Frame | Landscape, 1180 × 820 pt, front camera on the long edge | `device-frames.json` `ipad` | ok |

### Mac: macOS 27

Reference: Apple Design Resources, macOS 27 UI kit.

| Element | What macOS draws | Scene builder today | Status |
|---|---|---|---|
| Window | Rounded window, traffic lights at the top left, unified toolbar | Traffic lights in a separate grey bar above the content | approx |
| Sidebar | Translucent sidebar inset in the window (Liquid Glass since macOS 26) | Opaque sidebar | approx |
| Selection | System accent wash on the selected row (AGENTS.md: platform accent) | App accent wash | approx |
| Font | SF Pro at Mac sizes (13 pt body) | System font stack | approx |
| App glyphs | SF Symbols | Lucide | missing |
| Menu bar | Not part of a window capture | n/a | ok |

### Android phone: Android 17

Reference: Material 3 design kit (Figma), Android system UI as shipped on
Pixel; the app's own Compose screens in `android/app/.../ui/`.

| Element | What Android draws | Scene builder today | Status |
|---|---|---|---|
| Status bar | Time at the left, then notification icons; Wi-Fi, mobile signal and battery at the right, in Android's own glyph shapes | Time plus Lucide Signal, Wifi and BatteryFull | approx |
| Cutout | Centred punch-hole camera | From `device-frames.json` (`punchHole`) | ok |
| Gesture bar | Short, thin handle at the bottom | Drawn with an Android variant | approx |
| App bar and actions | Material top app bar; primary action as a Material FAB | iOS toolbar and the iOS Magic Plus button | missing |
| Rows and checkboxes | What `TaskHomeScreen.kt` draws (Material 3 list items) | iOS rows | missing |
| Font | Roboto Flex (system), or what the Compose theme sets | System font stack | missing |
| App glyphs | Material Symbols (`icons.json` `material`) | Lucide | missing |

### Windows: Windows 11

Reference: Windows 11 design kit (Figma) and Fluent System Icons; the
Compose Desktop client (ADR 0013) once it exists.

| Element | What Windows draws | Scene builder today | Status |
|---|---|---|---|
| Window | Title bar with minimize, maximize and close at the top right; 8 px rounded window corners; Mica backdrop | Caption buttons only on the web layout's browser bar | missing |
| App UI | The Compose Desktop client (Material, per ADR 0013) | Nothing | missing |
| Font | Segoe UI Variable for system chrome; the app's Compose theme inside | System font stack | missing |
| Frame | `device-frames.json` `windowsLaptop` | Shape exists | ok |

### Web

The web preview is a browser window with neutral chrome. It claims no OS.

## Plan

1. Move the system chrome out of `TaskScreen` into one component keyed by
   `system.chrome`, reading the device registry (no visual change). (site #15)
2. iOS 27 audit: redraw the status bar glyphs and toolbar from the iOS 27 kit;
   decide on SF Symbols for app glyphs (licence check, rule 5). (site #16)
3. iPad layout: an `ipad` capture layout with iPadOS chrome and the split
   view, then the App Store iPad set from it (#227). (site #17)
4. Mac: macOS 27 window chrome and the translucent sidebar, then the App
   Store Mac set from the mac layout (#227, #266). (site #18)
5. Android: Android status bar glyphs, gesture bar, and the app UI from the
   Compose screens with Material Symbols. (site #19)
6. Windows: a `windows` capture layout once the Compose Desktop client has a
   UI to copy (ADR 0013, W1). (site #20)

Each step updates the status column above in the same change.
