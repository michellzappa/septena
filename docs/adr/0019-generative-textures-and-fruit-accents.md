# 0019. Use procedural canvas textures and exotic-fruit accents over a Colorful default

- Status: proposed
- Date: 2026-11-21
- Deciders: mz

## Context

Visual personalization is one of the strongest emotional attachments people carry from Wunderlist, Superlist, Microsoft To Do, and Todoist. Two distinct patterns dominate the category:

1. **Photographic backgrounds** (Wunderlist, Superlist, Microsoft To Do) create warmth and list identity, but clash with Light/Dark switching, fight text legibility, inflate app bundles or require remote image CDNs (working against a local-first architecture), and feel repetitive once the stock catalog is familiar.
2. **Color themes** (Todoist) let people make the app feel personal with minimal complexity, and macOS's own **Multicolor** idiom shows how a colorful default can coexist cleanly with a single-hue user override.

Septena's task app currently locks its accent policy to `platformSystemAccent` (`registry/tokens.json`, `Theme.swift`, `SeptaskKitTheme.swift`), using wash-plus-matching-ink selection highlights and lifted paper cards over a grouped canvas (`Theme.groupedBackground` / `--task-color-canvas`). Because rows sit on clean cards and chrome floats in Liquid Glass, the recessed canvas behind cards (and optional faded header bands) is free to carry quiet texture without sacrificing legibility.

## Decision

Personalization in Septena (the task app) uses two lightweight, zero-asset primitives defined once in `registry/tokens.json` and `registry/settings.json` (ADR 0015):

1. **Procedural generative textures, never bundled or remote photographs.** A texture is a tiny deterministic descriptor (`style`, `placement`, `intensity`, `scale`, `seed`, `tintWithAccent`) rendered natively on-device (Metal `ShaderLibrary` / `Canvas` on Apple, Canvas2D/WebGL on Web, `RuntimeShader`/Canvas on Android & Windows). It costs zero megabytes, syncs as a few bytes of settings JSON, scales infinitely across Retina/widgets, harmonizes with Light/Dark/High Contrast modes, and can derive deterministic per-project seeds without user uploads.
2. **A `Colorful` default accent plus 11 global exotic-fruit single-color overrides.** Default `colorful` mirrors macOS Multicolor while respecting Septena's quiet sidebar discipline: primary selection, done checkboxes, active controls, and unread dots lean blue, **only Today** carries warm gold (`#F5C721`), overdue stays red, and filing lists (*Upcoming, Repeating, Anytime, Logbook*) stay quiet secondary gray (with user emoji on Areas and completion progress rings on Projects). Picking any exotic-fruit override (*Tamarillo, Persimmon, Yuzu, Carambola, Feijoa, Jagua, Haskap, Açaí, Mangosteen, Pitaya, Jabuticaba*) replaces the app's accent token with calibrated Light and Dark pairs (including *Jabuticaba* as the monochrome obsidian/ivory ink option). Selection stays wash-plus-matching-ink (`emphasizedAlphaLight` / `emphasizedAlphaDark`) so every fruit color stays contrast-safe in both appearances.

## Consequences

- **Zero asset or CDN overhead:** Visual identity stays 100% local-first, offline-safe, and trivially synced via the existing `settings` KV path (opt-in cross-device via `syncTheme`).
- **One canonical palette across apps and website:** `registry/tokens.json` feeds Swift, TypeScript, Kotlin, and `septena-site/components/task-ui/tokens.css`, keeping marketing/interactive previews in lockstep with shipped clients.
- **Legibility and accessibility stay protected:** Default placement (`behindCards`) leaves task rows on crisp solid paper; `Reduce Transparency`, `Increase Contrast`, and `Reduce Motion` degrade textures gracefully (reduced opacity or static flat canvas).
- **Trade-off:** Users cannot upload arbitrary personal photos as list wallpapers in v1; each platform needs a small procedural renderer (~150–250 lines) calibrated against shared golden parameters so textures look consistent across Apple, Web, Android, and Windows.

## Links

- Spec: `docs/CUSTOMIZATION_SPEC.md`
- Issue: `#196`
- Builds on: `docs/adr/0007-septena-is-the-task-app.md`, `docs/adr/0015-shared-registries-for-cross-platform-clients.md`, `docs/SETTINGS_UX_SPEC.md`, `docs/DesignSpec.md`
