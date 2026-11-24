# Septena App Icon & Appearance Decisions

Locked on 2026-11-21 and shipped to `main` in `michellzappa/septena`.

## 1. Locked Brand Mark — The Septena Upright Compass

The only Septena mark, on every app surface.

- **Form:** All-round circular dial inside the Apple squircle housing (rejected: 7-sided heptagon, 7-ray rose, engraved outer bezel, Pomodoro pie segments).
- **Upright North pointer:** Points straight up (`-90°`) in the active exotic-fruit accent.
- **7-way compass bearings:** 6 clean rounded machined ticks at bearings `k = 1…6` (every `51.43°`).
- **Checkmark geometry:** Sculpted checkmark (`M 377 511 L 460 598 L 639 426`) aligned collinearly with the 2nd tick (`-38.57°`).
- **Recessed moat ring** separating outer shell and inner dial:
  - **Colored shell (`Framed`):** Deep dark-tinted moat (calibrated against Things 3's dark-blue moat).
  - **Black shell (`Default`):** Pitch-black machined groove.
  - **White shell (`Light`):** Mild warm-stone / milled-aluminum moat (`#B9B5AC → #DBD8D0` light face; `#AEABA2 → #D4D1C9` dark face).
- **Automatic checkmark contrast rule:**
  - **Black or White outer shell (`Default`, `Light`):** Accented checkmark (or brushed titanium/charcoal on `Mono`).
  - **Colored outer shell (`Framed`):** **90% black charcoal-graphite** (`#4C5058 → #363940`, calibrated against Things 3's `#535963` check) on white inside; crisp white `#F6F6F8 → #DFDFE5` on dark inside.
- **Canonical default icon (`AppIcon`):** Jabuticaba obsidian black shell + Persimmon orange North pointer & checkmark.

## 2. 23-Icon Prebaked System & Settings Parity (iOS + macOS)

- **Settings ▸ Appearance UI** (`AppIconPickerSection` inside `AppearancePickerView`, parity across iOS, iPadOS, and macOS):
  - **3 Icon Styles:** `Default` (Obsidian), `Light` (Ceramic white), `Framed` (Things-style colored shell). `Stealth` (always-dark dial even in Light OS) was dropped on 2026-11-22: it looked almost the same as Default's dark-mode icon, and its 8 sets cost about a quarter of `Assets.car`. A saved `stealth` value falls back to `obsidian`.
  - **Icon Color = Accent (2026-11-22):** no separate icon color choice. The icon follows the app Accent one to one: each fruit accent gives the same fruit icon, `Jabuticaba` gives `Mono`, and `Colorful` (the default accent) gives `Persimmon`, the primary icon, so a fresh install never switches icons. `Haskap` (blue) was added to the Accent list so the blue icon has a theme. The old `appIconColor` override setting was removed; a stored value is ignored.
- **Registry keys** (`registry/entities.json`, `registry/settings.json`):
  - `appIconFinish` (`obsidian | ceramic | framed`, device-local, default `obsidian`).
  - `accentColor` (`colorful | tamarillo | persimmon | yuzu | carambola | haskap | acai | pitaya | jabuticaba`) selects the icon color too.
- **Bundle & OS Light/Dark behavior:**
  - **iOS:** 23 `.appiconset` bundles (`1 Default + 22 Alternates`, `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS: YES`), each with explicit 1024px Light OS + Dark OS (`luminosity: dark`) opaque RGB PNGs. Primary `AppIcon` stays 8-bit pristine; 22 alternates use 5-bit/channel (32-level) quantization with an 8×8 ordered (Bayer) dither. The plain cut (2026-11-21) shrank `Assets.car` from 96.8 MB to 24.7 MB universal but banded the dial's gradients. The dither (2026-11-22) removes the banding at Home Screen sizes for 37.9 MB universal (18.9 MB thinned for iPhone 17,1) with 30 alternates. Measured alternatives: 64 levels without dither 41.3 MB (faint bands), 64 levels with dither 55.1 MB. `ICON_QUANT_LEVELS` and `ICON_DITHER=0` in `scripts/generate-app-icons.mjs` rerun the comparison. Without Stealth (22 alternates): 27.9 MB universal, 13.9 MB thinned for iPhone 17,1.
  - **macOS:** Live CoreGraphics Retina `NSImage` rendering into `NSApp.applicationIconImage` + `dockTile` (reacts to Light/Dark appearance switches) and persists on `/Applications/Septask.app` via `NSWorkspace.shared.setIcon(_:forFile:)`.
- **Single generator source of truth:** `tools/logo-builder/dial-svg.mjs` → `scripts/generate-app-icons.mjs` (outputs all 23 iOS `.appiconset`s, macOS `Septask/AppIcon.icns`, and watchOS `AppIcon-1024.png`).

## 3. Where the mark is drawn

- **iOS Launch Screen:** Blank, system background only (`LaunchBackground`). The glyph launch screen was removed on 2026-11-23.
- **Settings & About (`SeptenaIconTile`):** Live `SeptenaCompassIconView` mirroring the user's active icon finish & color.
- **macOS & watchOS:** `Septask/AppIcon.icns` and `SeptaskWatch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.

## 4. Related UX & Performance Decisions Locked in the Same Session

- **Brand-free onboarding copy:** Restored brand-free Get Started checklist strings in `TaskNotices.swift` (`"Connect an assistant to your tasks"`, `"Import from another app"`).
- **Header Texture polish:** Removed descriptive subtitles from `TextureTileButton` (names only, matching Accent tiles) and increased `Field Matrix` Slow drift z-slice speed 5× (`z = phase * 0.18`) so fixed-grid dots breathe visibly.
- **iOS 120 Hz scroll & tap performance:** Eliminated per-frame `SelectableScrollList` `@State` invalidations on scroll, cached static `HeaderWashEngine` textures to Retina `CGImage` + off-main-thread drift, replaced per-row live `.thinMaterial` blurs & non-editing shadows on iOS task cards, cached `todayNotices` outside `TaskListView.body`, hydrated filter storage once on arrival, and deferred off-screen tab reloads.

## Shipped Commits on `main`

- `f1a45c08` — 31-icon Septena Compass system and iOS Appearance icon picker
- `04e8dfea` — Compass mark across launch screen, About, macOS, watchOS, and bursts
- `453f0959` — Registry-backed App Icon switcher parity on macOS
- `8ce6e37b` — Restore brand-free Get Started checklist copy
- `84722060` — Optimize iOS task list scroll performance and shrink alternate AppIcon `Assets.car` 4×
- `9dc18ba3` — Includes `TaskListView` main-thread SQLite optimizations (`cachedTodayNotices`, single-shot hydration, off-screen tab deferral)
- `b33b4ef2` — Increase `Field Matrix` Slow drift z-slice speed 5×
- `bfb3c01e` — Remove descriptive subtitles from Header Texture tiles
