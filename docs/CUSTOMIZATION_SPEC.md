# Customization: Generative Canvas Textures & Exotic-Fruit Accents — Spec

**Status:** building ([#196](https://github.com/michellzappa/septena/issues/196))
**Date:** 2026-11-21
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md), [ADR 0019](adr/0019-generative-textures-and-fruit-accents.md)
**Builds on:** `registry/tokens.json`, `registry/settings.json` (`docs/SETTINGS_UX_SPEC.md`), `docs/DesignSpec.md`, and `septena-site/components/task-ui/`
**Scope:** Septena (the task app) across iOS, iPadOS, macOS, Web (`#21`), Android (`#20`), and Windows (`#136`).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)* and collected in §9.

---

## 1. Goal & Principles

Give Septena tactile, unmistakable warmth and personal ownership—the part people loved about Wunderlist, Superlist, and Todoist—without importing their failure modes (clashing stock photos, dark-mode legibility breaks, bloated asset bundles, or per-platform drift).

1. **Zero-asset & local-first:** Every surface texture is mathematically generated on-device from a tiny seed descriptor. Works 100% offline, adds ~0 KB to app binaries, and syncs in a few bytes.
2. **Legibility & Liquid Glass depth:** Textures live exclusively as a soft **header wash** at the top of the list surface (~200–245pt fading cleanly to 0% into the grouped canvas below). Grouped list cards and inline notices use **Liquid Glass translucency** (a light touch of blur ~`6–8pt` + subtle inner specular rim) so the header wash breathes softly behind top cards — with **no in-app material picker**, deferring opaque fallback directly to the user's OS `Reduce Transparency` and `Increase Contrast` settings (a scoped amendment to `DesignSpec.md` §5.5 for textured grouped lists).
3. **Appearance-native:** Every accent and texture adapts automatically to Light Mode, Dark Mode, High Contrast, Reduce Transparency, and Reduce Motion.
4. **One source of truth (ADR 0015):** The accent palette, Light/Dark hex pairs, texture catalog, defaults, and setting keys live in `registry/tokens.json` and `registry/settings.json` and generate code for Swift, TypeScript, Kotlin, and the website's canonical `components/task-ui/tokens.css`.

---

## 2. Accent System: `Colorful` Default + Global Exotic Fruits

### 2.1 Default: `colorful` (macOS Multicolor idiom, Septena sidebar discipline)
- Primary interactive accent (row selection wash, done checkbox fill, active tab/chip tint, unread dot, composer Save CTA) leans **blue** (`#007AFF` light / `#0A84FF` dark), matching Apple's Multicolor default.
- Preserves Septena's established **color-only-on-Today** sidebar grammar (`SidebarView.swift`, `SeptaskKitSidebar.swift`, `registry/destinations.json`):
  - **Today:** Sunlit Gold (`#F5C721`) in the **sidebar** — the only colored smart-list glyph (the bucket you act on). In the **list view's page header**, Today's sun stays quiet neutral gray (`--task-color-control` / `inkSecondary`). There is no separate Inbox row in the sidebar (loose captures live in the Inbox triage band at the top of Today).
  - **Review / Upcoming / Repeating / Anytime / Logbook:** Quiet neutral secondary gray — neutral filing locations never turn into a rainbow.
  - **Overdue deadlines:** System Red (`overdueRed`).
  - **Areas:** User-chosen emoji (or muted dot when unset), semibold weight, no section text header.
  - **Projects:** House completion ring (`ProjectProgressIcon` / `KitGlyph.progress` — `14pt` diameter, `2.5pt` rounded stroke, `0.22` track opacity, clockwise from 12 o'clock; never a Things-style filled pie wedge), regular weight, flush on the same leading glyph axis as Areas.
  - **No brand logo/check row** in the sidebar header.
- Swatch UI renders as a crisp multicolor conic ring (same mental model as macOS System Settings ▸ Appearance ▸ Multicolor).

### 2.2 Global Exotic-Fruit Overrides (7 curated colors — locked 2026-11-21)
Selecting any fruit overrides `selectionAccent`, `listSelectionFill`, `checkboxFill`, `SelectableChip` tint, unread dots, iOS active tab tint, and (when enabled) the generative texture tint. All values are Light/Dark calibrated for wash-plus-matching-ink contrast safety (`DesignSpec.md` §4.5).

| ID | Display Name | Region / Character | Light Hex | Dark Hex | Done Check Ink (Light / Dark) |
|---|---|---|---|---|---|
| `colorful` | **Colorful** *(default)* | Blue-leaning + semantic | `#007AFF` | `#0A84FF` | `#FFFFFF` / `#FFFFFF` |
| `tamarillo` | **Tamarillo** | Andes · Ruby crimson | `#D6333F` | `#FF5C67` | `#FFFFFF` / `#FFFFFF` |
| `persimmon` | **Persimmon** | East Asia · Burnt vermilion | `#E05212` | `#FF7738` | `#FFFFFF` / `#FFFFFF` |
| `yuzu` | **Yuzu** | Japan · Sunlit citrus gold | `#C28500` | `#F2BF2C` | `#FFFFFF` / `#141518` |
| `carambola` | **Carambola** | SE Asia · Starfruit lime | `#5B8C00` | `#9EE034` | `#FFFFFF` / `#141518` |
| `acai` | **Açaí** | Amazon · Royal indigo | `#6544D6` | `#9B82FF` | `#FFFFFF` / `#FFFFFF` |
| `pitaya` | **Pitaya** | Mesoamerica · Dragonfruit rose | `#D4266C` | `#FF5C9B` | `#FFFFFF` / `#FFFFFF` |
| `jabuticaba` | **Jabuticaba** | Brazil · Obsidian / ivory ink | `#27272E` | `#E4E4EA` | `#FFFFFF` / `#141518` |

> Note on contrast: bright Dark-mode accents (`yuzu`, `carambola`, `jabuticaba`) switch the check glyph inside a filled checkbox to `#141518` so the checkmark always clears WCAG AA against its fill.

### 2.3 Accent Reach (Restrained Only — locked 2026-11-21)
- Accent applies **strictly in restrained scope** (no expressive/chrome-tinting mode): row selection wash (`emphasizedAlphaLight: 0.22`, `emphasizedAlphaDark: 0.34`), done checkboxes, active chips/pills, active iOS tab, primary modal CTA, unread context dot, and header-wash geometry ink (always harmonized with the active accent; `jabuticaba` naturally produces monochrome ink). Overdue red, quiet gray filing-list icons, page headers, and canvas neutrality remain untouched.

### 2.4 Relationship to macOS System Accent
- `registry/tokens.json` evolves `accentPolicy` from fixed `"platformSystemAccent"` to `"userAccentWithColorfulDefault"`.
- A user who wants pure macOS System Settings passthrough can either use `colorful` (default, leans blue) or we can optionally include a `system` meta-option on macOS if requested *(default: omit separate `system` swatch to keep one cross-platform mental model across macOS, iOS, Web, Android, and Windows)*.

---

## 3. Procedural Generative Canvas Textures

### 3.1 Locked v1 Texture Roster (6 procedural + `none`)

Selected by mz (2026-11-21); `relief`, `isoFlow`, and `terrainMesh` were dropped after visual review. `causticGlass` was dropped on 2026-11-22: it did not look good. Its id stays in the `canvasTexture` wire enum (`registry/entities.json`) so older clients can still sync it; the app reads it as `none`.

| ID | Display Name | Generative Primitive | Aesthetic Feel |
|---|---|---|---|
| `none` | **Pure Canvas** *(default)* | Flat system grouped background | Zero visual noise baseline |
| `topography` | **Topography** | Marching-squares elevation contours over 4-octave **3D** fBm (every 4th contour weighted as an index line); subtly **morphs shape in place** along `z = t` when motion is on rather than flat scrolling | Swiss cartography, architectural calm |
| `fieldMatrix` | **Field Matrix** | Precision micro-dot grid whose radius and opacity modulate across a 3D height field | Braun / Dieter Rams industrial grid |
| `stippleDrift` | **Stipple Drift** | Deterministic elevation-gated stipple dither (fixed dot anchors, evolving height wave — zero flicker) | Risograph print / e-ink texture |
| `ridges` | **Ridge Lines** | Horizontal elevation cross-sections smoothly displaced by 3D noise, vertically tapered | Rhythmic terrain profiles |
| `washiPaper` | **Washi Paper** | Fine laid-paper screen lines (`sugeta`) + long curved kozo/unryu mulberry fibers + short pulp micro-fibers (pure vector fiber geometry, zero tonal blobs) | Tactile handmade Japanese stationery |

### 3.2 Texture Placement & Parameters (Header Wash Only — locked 2026-11-21)

Textures render **exclusively as a faded top header wash** extending **all the way to the top edge of the screen/window** (`ignoresSafeArea(edges: .top)` behind the iOS status bar / Dynamic Island and behind the macOS unified title bar / toolbar), fading smoothly over ~200–245pt to 0% into the grouped canvas below. Pure geometry ink **always harmonizes with the active accent** (~58% blend toward accent, zero background gradient blobs; `jabuticaba` naturally renders neutral monochrome ink). There is no placement or tint toggle.

| Parameter | Type / Range | Default | Notes |
|---|---|---|---|
| `canvasTexture` | enum (`none`, `topography`, `fieldMatrix`, `stippleDrift`, `ridges`, `washiPaper`) | `"none"` *(default; could preview `"topography"` in onboarding)* | |
| `textureIntensity` | int `15…100` (no UI since 2026-11-22; the stored value still applies) | `55` | Clamped so high values never hurt contrast |
| `textureMotion` | enum (`still`, `slowDrift`) | `"still"` | Optional glacial **3D slice morphing** (`z = t * speed` so shapes evolve in place rather than treadmill-scrolling; ~20fps GPU cadence, auto-pauses under Reduce Motion, Low Power Mode, and inactive/background windows) |

**Daily deterministic seed (no user setting):** Smart lists (`Today`, `Upcoming`, `Anytime`, etc.) derive their seed automatically from **`FNV-1a(DayClock.today)`** (`"YYYY-MM-DD"`). Every morning produces a fresh procedural terrain that matches identically across all of a user's devices with zero synced seed state and no manual Shuffle button (honors `DayClock` day-rollover and time-travel automatically).

### 3.3 Per-Project Deterministic Identity (Phase C3)
- When `projectHeaderTextures` is enabled (opt-in or automatic when a texture is active), opening a Project uses `headerWash` seeded deterministically from `FNV-1a(project.id)` (already in `registry/rules.json` for `occurrenceID`).
- Every project quietly receives its own unique elevation contour without any manual setup or stored image. Users can still re-roll a project's seed via an optional `textureSeed` field later if desired.

### 3.4 Rendering Architecture per Platform
- **Apple (iOS / iPadOS / macOS):**
  - SwiftUI `Canvas` / Metal `ShaderLibrary` (`colorEffect` / `layerEffect`) for GPU-native zero-CPU rendering at Retina resolution, static once rendered (no continuous frame loop, zero battery drain).
  - macOS AppKit shell (`SeptaskKit`): `CALayer` / `CAMetalLayer` or cached `CGImage` backing on the scroll view's document backdrop behind `KitCardCell` views, re-rendered only on resize, appearance change, or setting change.
- **Web (`#21`):** Offscreen `<canvas>` (or CSS `paint()` / cached blob URL) rendered once per viewport/theme change using the exact same Mulberry32 + value-noise fBm parameters as the conformance fixture.
- **Android (shipped, #371):** a Kotlin port of `HeaderWashEngine` (`android/app/.../ui/HeaderWashEngine.kt`) draws into a Compose `DrawScope` on a background thread. A still wash is a cached bitmap; Slow drift renders 15 frames a second into rotating bitmaps and pauses while the app is in the background, animations are off, or Battery Saver is on. The seed, the PRNG and the noise volume match the Swift code bit for bit (`HeaderWashNoiseTest`). The generator is not in the shared core yet (spec: #196).
- **Windows (`#136`):** Compose `DrawScope` / Canvas using the shared registry parameters.
- **Accessibility & battery invariants:**
  - `Reduce Motion`: forces `textureMotion` to `still` (zero animation); seed/style transitions skip cross-fading.
  - `Low Power Mode` & window inactivity: automatically pauses `slowDrift` (`TimelineView(.animation(minimumInterval: 1/20, paused: ...))` on Apple, `document.hidden` / window blur on Web & Desktop) so idle or battery-constrained sessions cost zero GPU frames.
  - `Increase Contrast`: automatically halves `textureIntensity` (cap `<= 30`) so separators and card edges dominate.
  - `Reduce Transparency`: floating Liquid Glass chrome (and any frosted/glassy card material) falls back to opaque `cardSurface` (`DesignSpec.md` §5.5), keeping legibility intact over textured canvases.

---

## 4. Settings IA & Cross-Device Sync Contract

Follows `docs/SETTINGS_UX_SPEC.md` (single canonical home in **Appearance**; zero duplicated controls):

### 4.1 Registry Keys (`registry/settings.json`)

| Key | Scope | Type / Enum | Default | Storage Key |
|---|---|---|---|---|
| `appearanceMode` | `device` | `enum: ["system", "light", "dark"]` | `"system"` | `septena.appearance.mode` |
| `syncTheme` | `device` | `bool` | `true` | `septena.appearance.syncTheme` |
| `accentColor` | `synced` *(honored locally if `syncTheme == false`)* | `enum` (8 IDs from `tokens.json`) | `"colorful"` | `septena.appearance.accentColor` |
| `canvasTexture` | `synced` *(honored locally if `syncTheme == false`)* | `enum` (texture IDs from `tokens.json`) | `"none"` | `septena.appearance.canvasTexture` |
| `textureIntensity` | `synced` *(honored locally if `syncTheme == false`)* | `int` (`15…100`) | `55` | `septena.appearance.textureIntensity` |
| `textureMotion` | `synced` *(honored locally if `syncTheme == false`)* | `enum: ["still", "slowDrift"]` | `"still"` | `septena.appearance.textureMotion` |

- **How `syncTheme` works (Todoist idiom):** Always stored device-local (`default: true`). When `true`, writes to the 6 appearance keys push to `api.septena.app` settings KV and remote updates apply locally. When `false`, this device keeps its own local appearance (e.g., bold Persimmon on iPhone, quiet Jabuticaba on Mac) without overwriting other devices.
- **`accent_color` customSurface** in `docs/SETTINGS_UX_SPEC.md` evolves into the unified **Appearance** picker surface:
  - Mode segmented control (`Light` / `Dark` / `System`) + `Sync across devices` toggle
  - Mini-app preview card grid for `Colorful` + 7 exotic fruits (live-tinted sidebar + checkbox preview inside each card)
  - Live-rendered procedural header-wash texture strip + intensity presets + optional Slow Drift toggle (seed refreshes daily automatically)

---

## 5. Canonical Website `task-ui` Parity & Alignment

`septena-site/components/task-ui/` (`tokens.css`, `task-ui.css`, `task-screen.tsx`) is the canonical HTML/CSS representation of Septena across `mac`, `web`, and `phone` layouts. A side-by-side audit against the native Apple shells (`SeptaskKitSidebar.swift`, `SidebarView.swift`, `registry/destinations.json`) identified five sidebar drifts in the current website component that should be aligned alongside the token work:

1. **No `(check) Septena` sidebar brand row** on macOS/iPad — sidebar starts straight into smart lists.
2. **No separate `Inbox` smart list** — Inbox lives as the triage band at the top of Today; sidebar lists follow `registry/destinations.json` (`Today`, `Review`, `Upcoming`, `Repeating`, `Anytime`, `Logbook`).
3. **Color only on Today (sidebar only)** — Today's sun carries `#F5C721` in the sidebar and stays quiet gray in the list page heading; all other smart-list glyphs stay quiet secondary gray.
4. **Emoji on Areas (no `"Area"` text header)** — Areas render as clickable semibold rows with their leading emoji (or muted dot), trailing fold chevron, and count.
5. **Progress rings on Projects** — Projects render with Septena's house completion ring (`ProjectProgressIcon` / `KitGlyph.progress`: `14pt` diameter, `2.5pt` rounded stroke, `0.22` track opacity — not a plain circle and not a Things pie wedge) on the same flush left glyph axis (regular weight, no indentation step).
6. **One leading-glyph vertical midline** — Every leading icon in the list column (page heading sun/ring, inline notice glyph, group tray/emoji, and task checkboxes) shares one exact horizontal center axis (`SeptaskKitLayout.leadingGlyphCenterX` parity), with larger header glyphs overflowing symmetrically around that midline.
7. **Non-selectable demo chrome** — `.task-surface` (and all interactive app demo components) must set `user-select: none; -webkit-user-select: none; cursor: default;` (allowing `user-select: text; cursor: text;` only on actual `<input>` / `<textarea>` controls) so hovering or clicking never flashes an I-beam cursor or highlights mockup copy.
8. **Neutral time/day pills** — Trailing time/day pills (`.task-date`, `TaskStatusPill`, `KitChipView`) stay neutral secondary gray on a subtle neutral wash across web, simulator, and native apps — never yellow/amber (only overdue deadlines use semantic red).

- Extend `registry/tokens.json` with `fruitAccents` (light/dark hex + check ink + origin metadata) and `textures` (catalog IDs + defaults).
- Update `septena-site/scripts/task-tokens.mjs` (in the site repo) to consume `registry/tokens.json` so `--task-color-accent`, `--task-color-accentWash`, and optional `[data-accent="<fruit>"]` / texture canvas layers stay 1:1 with the native apps.
- Marketing pages (e.g., `/features` customization preview, App Store panels) can then render live interactive exotic-fruit + generative-texture demos directly on top of the aligned `TaskScreen` component.

---

## 6. Phased Delivery Plan

| Phase | Scope | Depends on |
|---|---|---|
| **C0 — Registry & Sync Keys** | Add `fruitAccents` and `textures` to `registry/tokens.json`, add appearance keys to `registry/settings.json`, regenerate Swift/TS constants, update backend `SETTING_VALUES` allowlist, add `registry/capabilities.json` entry (`appearance.customization`). | ADR 0015 (shipped) |
| **C1 — Exotic-Fruit Accents & Appearance Picker (Apple)** | Route `Theme.selectionAccent`, `Theme.listSelectionFill`, `Theme.checkboxFill`, `Theme.checkboxCheck`, and `SeptaskKitTheme` through the resolved fruit accent (`colorful` default). Replace legacy swatch row in Settings ▸ Appearance with mini-app fruit cards + `Light/Dark/System` + `Sync across devices`. | C0 |
| **C2 — Procedural Header-Wash Textures (Apple)** | Implement deterministic PRNG + 3D fBm + the 6 locked v1 procedural renderers as a top header wash in SwiftUI (`Canvas`/Metal) and AppKit (`SeptaskKit` backdrop layer) + optional `slowDrift` + accessibility/battery guards. | C1 |
| **C3 — Per-Project Deterministic Header Textures** | Derive per-project `headerWash` seed from `FNV-1a(project.id)` with opt-in toggle and optional per-project seed shuffle. | C2 |
| **C4 — Cross-Platform & Website Parity** | Port accent tokens + procedural Canvas2D/AGSL renderers to Web (`#21`), Android (`#20`), Windows (`#136`), and sync `septena-site/components/task-ui/tokens.css` from `registry/tokens.json`. | C0, `#21`, `#20`, `#136` |

---

## 7. Non-Goals (v1)

- Custom user-uploaded photo wallpapers or Unsplash integrations.
- Fast, high-frequency, or default-on animated shaders (motion stays strictly opt-in via `textureMotion: "slowDrift"` at a low ~20fps glacial cadence).
- Per-task or per-section arbitrary custom hex pickers outside the curated exotic-fruit palette.
- Custom font-family pickers (typography stays governed by `DesignSpec.md` §5 and the 5-step text scale).

---

## 8. Testing & Verification Criteria

- **Contrast check:** Every fruit accent in both Light and Dark modes passes WCAG AA for checkbox check glyph contrast and readable row title ink over `listSelectionFill`.
- **Determinism check:** Golden conformance fixture verifies `seed=42` yields matching height samples across Swift, TypeScript, and Kotlin PRNG/noise helpers.
- **Accessibility check:** Enabling `Increase Contrast` visibly dampens texture opacity; enabling `Reduce Transparency` keeps floating Liquid Glass toolbars/tab bars legible over every texture at max intensity.
- **Sync check:** Toggling `syncTheme = false` on one device isolates local changes without clobbering synced settings on a second device.

---

## 9. Open Questions (defaults stand unless mz overrules)

| Topic | Decision | Default |
|---|---|---|
| **Default texture for new installs** | Start on `none` (pure canvas) or a whisper-subtle `washiPaper` / `topography`? | `none` — opt-in in Appearance *(default)* |
| **Intensity control in UI** | 3 tactile presets (`Subtle` / `Balanced` / `Bold`) vs. continuous slider? | 3 presets (`35 / 55 / 80`) *(default)* |
| **Milestone placement** | Keep in `M5 Breadth` (post-Launch/M2), or pull C0–C1 (exotic-fruit accents) forward into M3 polish? | `M5 Breadth` *(default)* |
