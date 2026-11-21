# Customization: Generative Canvas Textures & Exotic-Fruit Accents — Spec

**Status:** proposal ([#196](https://github.com/michellzappa/septena/issues/196))
**Date:** 2026-11-21
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md), [ADR 0019](adr/0019-generative-textures-and-fruit-accents.md)
**Builds on:** `registry/tokens.json`, `registry/settings.json` (`docs/SETTINGS_UX_SPEC.md`), `docs/DesignSpec.md`, and `septena-site/components/task-ui/`
**Scope:** Septena (the task app) across iOS, iPadOS, macOS, Web (`#21`), Android (`#20`), and Windows (`#136`).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)* and collected in §9.

---

## 1. Goal & Principles

Give Septena tactile, unmistakable warmth and personal ownership—the part people loved about Wunderlist, Superlist, and Todoist—without importing their failure modes (clashing stock photos, dark-mode legibility breaks, bloated asset bundles, or per-platform drift).

1. **Zero-asset & local-first:** Every surface texture is mathematically generated on-device from a tiny seed descriptor. Works 100% offline, adds ~0 KB to app binaries, and syncs in a few bytes.
2. **Legibility first:** Task rows always sit on crisp, lifted paper cards (`Theme.cardSurface` / `--task-color-paper`). Textures live on the recessed canvas behind cards (or as a faded top atmospheric band), never fighting row copy.
3. **Appearance-native:** Every accent and texture adapts automatically to Light Mode, Dark Mode, High Contrast, Reduce Transparency, and Reduce Motion.
4. **One source of truth (ADR 0015):** The accent palette, Light/Dark hex pairs, texture catalog, defaults, and setting keys live in `registry/tokens.json` and `registry/settings.json` and generate code for Swift, TypeScript, Kotlin, and the website's canonical `components/task-ui/tokens.css`.

---

## 2. Accent System: `Colorful` Default + Global Exotic Fruits

### 2.1 Default: `colorful` (macOS Multicolor idiom, Septena sidebar discipline)
- Primary interactive accent (row selection wash, done checkbox fill, active tab/chip tint, unread dot, composer Save CTA) leans **blue** (`#007AFF` light / `#0A84FF` dark), matching Apple's Multicolor default.
- Preserves Septena's established **color-only-on-Today** sidebar grammar (`SidebarView.swift`, `SeptaskKitSidebar.swift`, `registry/destinations.json`):
  - **Today:** Sunlit Gold (`#F5C721`) — the only colored smart-list glyph (the bucket you act on). There is no separate Inbox row in the sidebar (loose captures live in the Inbox triage band at the top of Today).
  - **Review / Upcoming / Repeating / Anytime / Logbook:** Quiet neutral secondary gray — neutral filing locations never turn into a rainbow.
  - **Overdue deadlines:** System Red (`overdueRed`).
  - **Areas:** User-chosen emoji (or muted dot when unset), semibold weight, no section text header.
  - **Projects:** Completion pie/ring progress indicator (`ProjectProgressIcon` / `KitGlyph.progress`), regular weight, flush on the same leading glyph axis as Areas.
  - **No brand logo/check row** in the sidebar header.
- Swatch UI renders as a crisp multicolor conic ring (same mental model as macOS System Settings ▸ Appearance ▸ Multicolor).

### 2.2 Global Exotic-Fruit Overrides (11 curated colors)
Selecting any fruit overrides `selectionAccent`, `listSelectionFill`, `checkboxFill`, `SelectableChip` tint, unread dots, iOS active tab tint, and (when enabled) the generative texture tint. All values are Light/Dark calibrated for wash-plus-matching-ink contrast safety (`DesignSpec.md` §4.5).

| ID | Display Name | Region / Character | Light Hex | Dark Hex | Done Check Ink (Light / Dark) |
|---|---|---|---|---|---|
| `colorful` | **Colorful** *(default)* | Blue-leaning + semantic multicolor | `#007AFF` | `#0A84FF` | `#FFFFFF` / `#FFFFFF` |
| `tamarillo` | **Tamarillo** | Andes · Ruby crimson | `#D6333F` | `#FF5C67` | `#FFFFFF` / `#FFFFFF` |
| `persimmon` | **Persimmon** | East Asia · Burnt vermilion | `#E05212` | `#FF7738` | `#FFFFFF` / `#FFFFFF` |
| `yuzu` | **Yuzu** | Japan · Sunlit citrus gold | `#C28500` | `#F2BF2C` | `#FFFFFF` / `#141518` |
| `carambola` | **Carambola** | SE Asia · Starfruit lime | `#5B8C00` | `#9EE034` | `#FFFFFF` / `#141518` |
| `feijoa` | **Feijoa** | South America · Botanical emerald | `#15804A` | `#34D388` | `#FFFFFF` / `#141518` |
| `jagua` | **Jagua** | Amazon · Mineral lagoon teal | `#0D7E8A` | `#2DD4DF` | `#FFFFFF` / `#141518` |
| `haskap` | **Haskap** | Hokkaido · Deep cobalt blue | `#1D63DC` | `#4E94FF` | `#FFFFFF` / `#FFFFFF` |
| `acai` | **Açaí** | Amazon · Royal indigo | `#6544D6` | `#9B82FF` | `#FFFFFF` / `#FFFFFF` |
| `mangosteen` | **Mangosteen** | SE Asia · Velvet plum | `#9E2A7B` | `#DB62B7` | `#FFFFFF` / `#FFFFFF` |
| `pitaya` | **Pitaya** | Mesoamerica · Dragonfruit rose | `#D4266C` | `#FF5C9B` | `#FFFFFF` / `#FFFFFF` |
| `jabuticaba` | **Jabuticaba** | Brazil · Obsidian / ivory ink | `#27272E` | `#E4E4EA` | `#FFFFFF` / `#141518` |

> Note on contrast: bright Dark-mode accents (`yuzu`, `carambola`, `feijoa`, `jagua`, `jabuticaba`) switch the check glyph inside a filled checkbox to `#141518` so the checkmark always clears WCAG AA against its fill.

### 2.3 Accent Reach
- **`restrained`** *(default)*: Accent applies to selection wash (`emphasizedAlphaLight: 0.22`, `emphasizedAlphaDark: 0.34`), done checkboxes, active chips/pills, active iOS tab, primary modal CTA, unread context dot, and optional texture tint. Today's gold sun, overdue red, and quiet gray filing-list icons remain untouched.
- **`expressive`** *(optional future toggle — deferred out of v1 by default)*: Also tints Today's glyph, project progress rings, screen title, and adds a subtle 4–6% canvas/sidebar warmth tint. Filing-list icons (*Upcoming, Repeating, Anytime, Logbook*) still remain quiet gray.

### 2.4 Relationship to macOS System Accent
- `registry/tokens.json` evolves `accentPolicy` from fixed `"platformSystemAccent"` to `"userAccentWithColorfulDefault"`.
- A user who wants pure macOS System Settings passthrough can either use `colorful` (default, leans blue) or we can optionally include a `system` meta-option on macOS if requested *(default: omit separate `system` swatch to keep one cross-platform mental model across macOS, iOS, Web, Android, and Windows)*.

---

## 3. Procedural Generative Canvas Textures

### 3.1 Shortlist (v1 Confirmed + Fine-Tuning Candidates)

**Confirmed v1 set (5 procedural + `none`):**

| ID | Display Name | Generative Primitive | Aesthetic Feel |
|---|---|---|---|
| `none` | **Pure Canvas** *(default)* | Flat system grouped background | Zero visual noise baseline |
| `topography` | **Topography** | Marching-squares elevation contours over 4-octave 2D fBm, every 4th contour weighted as an index line | Swiss cartography, architectural calm |
| `ridges` | **Ridge Lines** | Horizontal elevation cross-sections smoothly displaced by 2D noise, vertically tapered | Rhythmic terrain profiles |
| `fieldMatrix` | **Field Matrix** | Precision micro-dot grid whose radius and opacity modulate across a height field | Braun / Dieter Rams industrial grid |
| `washiPaper` | **Washi Paper** | Low-frequency tonal clouding + sparse deterministic micro-fibers | Fine tactile stationery, near-subliminal |
| `stippleDrift` | **Stipple Drift** | Deterministic elevation-gated stipple dither | Risograph print / e-ink texture |

**Fine-tuning candidates (evaluate before C2 freeze):**
- `relief` (**Relief Terrain**): Normalized Lambertian hillshade over a ridged height map (embossed cotton paper / sculpted obsidian).
- `isoFlow` (**Iso-Flow**): Curl-noise streamlines tracing iso-elevation paths.
- `terrainMesh` (**Terrain Mesh**): Fine geometric drafting lattice lifted by the height field.
- *(Dropped from v1: `caustics` — optical Voronoi webs feel busier than Septena's calm architectural tone.)*

### 3.2 Texture Parameters & Placement

| Parameter | Type / Range | Default | Notes |
|---|---|---|---|
| `canvasTexture` | enum (`none`, `topography`, `ridges`, `fieldMatrix`, `washiPaper`, `stippleDrift`, …) | `"none"` *(default; could preview `"topography"` in onboarding)* | |
| `texturePlacement` | enum (`behindCards`, `headerWash`, `railAndCanvas`) | `"behindCards"` | `behindCards` keeps cards crisp paper; `headerWash` fades softly over the top ~180–200pt like a modern list cover |
| `textureIntensity` | int `15…100` (exposed as 3 presets in UI: `Subtle` 35 / `Balanced` 55 / `Bold` 80, or continuous slider) | `55` | Clamped so high values never hurt contrast |
| `textureSeed` | int `1…9999` | `42` | User can tap **Shuffle** to pick a new terrain; deterministic everywhere |
| `textureTintWithAccent` | bool | `true` | Blends texture ink ~58% toward active accent + subtle radial glow; `false` uses pure neutral ink |

### 3.3 Per-Project Deterministic Identity (Phase C3)
- When `projectHeaderTextures` is enabled (opt-in or automatic when a texture is active), opening a Project uses `headerWash` seeded deterministically from `FNV-1a(project.id)` (already in `registry/rules.json` for `occurrenceID`).
- Every project quietly receives its own unique elevation contour without any manual setup or stored image. Users can still re-roll a project's seed via an optional `textureSeed` field later if desired.

### 3.4 Rendering Architecture per Platform
- **Apple (iOS / iPadOS / macOS):**
  - SwiftUI `Canvas` / Metal `ShaderLibrary` (`colorEffect` / `layerEffect`) for GPU-native zero-CPU rendering at Retina resolution, static once rendered (no continuous frame loop, zero battery drain).
  - macOS AppKit shell (`SeptaskKit`): `CALayer` / `CAMetalLayer` or cached `CGImage` backing on the scroll view's document backdrop behind `KitCardCell` views, re-rendered only on resize, appearance change, or setting change.
- **Web (`#21`):** Offscreen `<canvas>` (or CSS `paint()` / cached blob URL) rendered once per viewport/theme change using the exact same Mulberry32 + value-noise fBm parameters as the conformance fixture.
- **Android / Windows (`#20`, `#136`):** Compose `DrawScope` / AGSL `RuntimeShader` (Android 13+, Canvas fallback below) using the shared registry parameters.
- **Accessibility invariants:**
  - `Reduce Motion`: textures are already static (never animated continuously); seed/style transitions cross-fade only when Reduce Motion is off.
  - `Increase Contrast`: automatically halves `textureIntensity` (cap `<= 30`) so separators and card edges dominate.
  - `Reduce Transparency`: floating Liquid Glass chrome falls back to opaque `cardSurface` (`DesignSpec.md` §5.5), keeping legibility intact over textured canvases.

---

## 4. Settings IA & Cross-Device Sync Contract

Follows `docs/SETTINGS_UX_SPEC.md` (single canonical home in **Appearance**; zero duplicated controls):

### 4.1 Registry Keys (`registry/settings.json`)

| Key | Scope | Type / Enum | Default | Storage Key |
|---|---|---|---|---|
| `appearanceMode` | `device` | `enum: ["system", "light", "dark"]` | `"system"` | `septena.appearance.mode` |
| `syncTheme` | `device` | `bool` | `true` | `septena.appearance.syncTheme` |
| `accentColor` | `synced` *(honored locally if `syncTheme == false`)* | `enum` (12 IDs from `tokens.json`) | `"colorful"` | `septena.appearance.accentColor` |
| `canvasTexture` | `synced` *(honored locally if `syncTheme == false`)* | `enum` (texture IDs from `tokens.json`) | `"none"` | `septena.appearance.canvasTexture` |
| `texturePlacement` | `synced` *(honored locally if `syncTheme == false`)* | `enum: ["behindCards", "headerWash", "railAndCanvas"]` | `"behindCards"` | `septena.appearance.texturePlacement` |
| `textureIntensity` | `synced` *(honored locally if `syncTheme == false`)* | `int` (`15…100`) | `55` | `septena.appearance.textureIntensity` |
| `textureSeed` | `synced` *(honored locally if `syncTheme == false`)* | `int` (`1…9999`) | `42` | `septena.appearance.textureSeed` |
| `textureTintWithAccent` | `synced` *(honored locally if `syncTheme == false`)* | `bool` | `true` | `septena.appearance.textureTint` |

- **How `syncTheme` works (Todoist idiom):** Always stored device-local (`default: true`). When `true`, writes to the 6 appearance keys push to `api.septena.app` settings KV and remote updates apply locally. When `false`, this device keeps its own local appearance (e.g., bold Persimmon on iPhone, quiet Jabuticaba on Mac) without overwriting other devices.
- **`accent_color` customSurface** in `docs/SETTINGS_UX_SPEC.md` evolves into the unified **Appearance** picker surface:
  - Mode segmented control (`Light` / `Dark` / `System`) + `Sync across devices` toggle
  - Mini-app preview card grid for `Colorful` + 11 exotic fruits (live-tinted sidebar + checkbox preview inside each card)
  - Live-rendered procedural texture card strip + placement segmented pill + intensity presets + Shuffle seed button

---

## 5. Canonical Website `task-ui` Parity & Alignment

`septena-site/components/task-ui/` (`tokens.css`, `task-ui.css`, `task-screen.tsx`) is the canonical HTML/CSS representation of Septena across `mac`, `web`, and `phone` layouts. A side-by-side audit against the native Apple shells (`SeptaskKitSidebar.swift`, `SidebarView.swift`, `registry/destinations.json`) identified five sidebar drifts in the current website component that should be aligned alongside the token work:

1. **No `(check) Septena` sidebar brand row** on macOS/iPad — sidebar starts straight into smart lists.
2. **No separate `Inbox` smart list** — Inbox lives as the triage band at the top of Today; sidebar lists follow `registry/destinations.json` (`Today`, `Review`, `Upcoming`, `Repeating`, `Anytime`, `Logbook`).
3. **Color only on Today** — Today's sun carries `#F5C721`; all other smart-list glyphs stay quiet secondary gray.
4. **Emoji on Areas (no `"Area"` text header)** — Areas render as clickable semibold rows with their leading emoji (or muted dot), trailing fold chevron, and count.
5. **Progress rings on Projects** — Projects render with `ProjectProgressIcon`-style completion pie rings on the same flush left glyph axis (regular weight, no indentation step).
6. **Non-selectable demo chrome** — `.task-surface` (and all interactive app demo components) must set `user-select: none; -webkit-user-select: none; cursor: default;` (allowing `user-select: text; cursor: text;` only on actual `<input>` / `<textarea>` controls) so hovering or clicking never flashes an I-beam cursor or highlights mockup copy.

- Extend `registry/tokens.json` with `fruitAccents` (light/dark hex + check ink + origin metadata) and `textures` (catalog IDs + defaults).
- Update `septena-site/scripts/task-tokens.mjs` (in the site repo) to consume `registry/tokens.json` so `--task-color-accent`, `--task-color-accentWash`, and optional `[data-accent="<fruit>"]` / texture canvas layers stay 1:1 with the native apps.
- Marketing pages (e.g., `/features` customization preview, App Store panels) can then render live interactive exotic-fruit + generative-texture demos directly on top of the aligned `TaskScreen` component.

---

## 6. Phased Delivery Plan

| Phase | Scope | Depends on |
|---|---|---|
| **C0 — Registry & Sync Keys** | Add `fruitAccents` and `textures` to `registry/tokens.json`, add appearance keys to `registry/settings.json`, regenerate Swift/TS constants, update backend `SETTING_VALUES` allowlist, add `registry/capabilities.json` entry (`appearance.customization`). | ADR 0015 (shipped) |
| **C1 — Exotic-Fruit Accents & Appearance Picker (Apple)** | Route `Theme.selectionAccent`, `Theme.listSelectionFill`, `Theme.checkboxFill`, `Theme.checkboxCheck`, and `SeptaskKitTheme` through the resolved fruit accent (`colorful` default). Replace legacy swatch row in Settings ▸ Appearance with mini-app fruit cards + `Light/Dark/System` + `Sync across devices`. | C0 |
| **C2 — Procedural Canvas Textures (Apple)** | Implement deterministic PRNG + 2D fBm + the confirmed v1 procedural renderers in SwiftUI (`Canvas`/Metal) and AppKit (`SeptaskKit` backdrop layer). Wire `behindCards`, `headerWash`, and `railAndCanvas` placements + accessibility guards (`Increase Contrast`, `Reduce Transparency`). | C1 |
| **C3 — Per-Project Deterministic Header Textures** | Derive per-project `headerWash` seed from `FNV-1a(project.id)` with opt-in toggle and optional per-project seed shuffle. | C2 |
| **C4 — Cross-Platform & Website Parity** | Port accent tokens + procedural Canvas2D/AGSL renderers to Web (`#21`), Android (`#20`), Windows (`#136`), and sync `septena-site/components/task-ui/tokens.css` from `registry/tokens.json`. | C0, `#21`, `#20`, `#136` |

---

## 7. Non-Goals (v1)

- Custom user-uploaded photo wallpapers or Unsplash integrations.
- Animated / continuously moving background shaders (battery & distraction hazard).
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
| **v1 texture shortlist** | Ship 5 confirmed (`topography`, `ridges`, `fieldMatrix`, `washiPaper`, `stippleDrift`) + `none`, or include any of `relief` / `isoFlow` / `terrainMesh`? | 5 confirmed + `none` *(default)* |
| **Default texture for new installs** | Start on `none` (pure canvas) or a whisper-subtle `washiPaper` / `topography`? | `none` — opt-in in Appearance *(default)* |
| **Accent reach toggle** | Ship `restrained` only in v1, or expose `restrained` vs. `expressive` toggle in Settings? | `restrained` only in v1 *(default)* |
| **Fruit roster & names** | Keep all 11 global exotic fruits (including `Jabuticaba` monochrome ink), or trim to 8–9? | All 11 + `Colorful` = 12 (clean 3×4 grid) *(default)* |
| **Intensity control in UI** | 3 tactile presets (`Subtle` / `Balanced` / `Bold`) vs. continuous slider? | 3 presets (`35 / 55 / 80`) *(default)* |
| **Milestone placement** | Keep in `M5 Breadth` (post-Launch/M2), or pull C0–C1 (exotic-fruit accents) forward into M3 polish? | `M5 Breadth` *(default)* |
