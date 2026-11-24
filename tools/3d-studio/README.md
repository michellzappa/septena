# Septena 3D Marketing Studio

Headless **Blender 5.x Cycles (Apple Silicon Metal GPU)** pipeline for rendering pixel-accurate 3D marketing scenes with real Septena screenshots and physically-based screen reflections.

See [docs/3d-studio/SKILL.md](../../docs/3d-studio/SKILL.md) for the full art direction, shader recipes, and Blender gotchas learned while building this studio.

## First-time setup

1. Install Blender (`brew install --cask blender`).
2. Fetch the pinned free Royalty-Free Apple device `.blend` models from BlenderKit (~38 MB, gitignored):
   ```bash
   python3 tools/3d-studio/fetch_models.py
   ```
3. *(Optional)* Generate SF Pro Persimmon demo screens for testing:
   ```bash
   swift -module-cache-path /tmp/swift-module-cache tools/3d-studio/make_demo_screens.swift
   ```

## Quick start

Render the default 4-device low-angle isometric hero (`1080×1920`, 9:16) with your own screenshots:

```bash
blender -b --python tools/3d-studio/render.py -- \
  --preset iso-vertical \
  --mac path/to/mac-desktop.png \
  --ipad path/to/ipad-landscape.png \
  --ios path/to/ios-today.png \
  --watch path/to/watch-today.png \
  --samples 112 \
  --save-blend tools/3d-studio/studio_iso.blend \
  --out tools/3d-studio/renders/iso_vertical_4dev.png
```

## CLI options

| Flag | Values | Description |
| :--- | :--- | :--- |
| `--mac` | PNG/JPG path | MacBook Pro 14" display texture (`3024×1964` / ~3:2 aspect) |
| `--ipad` | PNG/JPG path | iPad Mini landscape display texture (`2266×1488`) |
| `--no-ipad` | flag | Omit the iPad Mini for a 3-device layout |
| `--ios` | PNG/JPG path | iPhone display texture (standard iPhone screenshot) |
| `--watch` | PNG/JPG path | Apple Watch OLED display texture (`410×502`) |
| `--phone` | `pro` (default), `air` | Switches between iPhone 17 Pro Max and iPhone 17 Air |
| `--mac-finish` | `silver` (default), `space-black` | Bead-blasted satin-matte anodized aluminum finish |
| `--preset` | `iso-vertical`, `ortho-vertical`, `hero-vertical`, `hero-wide`, `square`, `closeup-phone` | Camera framing & projection (`iso-*` / `ortho-*` are true orthographic) |
| `--keep-notch` | flag | Keep MacBook camera notch & iPhone Dynamic Island (both removed by default) |
| `--scale` | `0.5`, `1.0` (default), `2.0` | Resolution multiplier (`0.5` for ~9s drafts, `2.0` for 4K) |
| `--samples` | `32`–`256` (default `64`) | Cycles path-tracing samples (`112`–`128` recommended for finals) |
| `--save-blend` | `.blend` path | Saves the assembled editable scene for interactive tweaking in Blender GUI |

## Device models (`models/`, gitignored)

Fetched reproducibly via `fetch_models.py` (all free Royalty-Free BlenderKit `.blend` files):
- `macbook_pro_14_2024.blend` — MacBook Pro 14" (notch removed + symmetric top/bottom rounded OLED corners)
- `ipad_mini_space_grey.blend` — iPad Mini (bezels thinned to ~4.2 mm + analytic concentric 8.4 mm inner corners)
- `iphone_17_pro_max.blend` — iPhone 17 Pro Max (Dynamic Island & earpiece slit removed by default)
- `iphone_17_air.blend` — iPhone 17 Air
- `smart_watch_2.blend` — Apple Watch (rigid strap loop relaxed into a low soft strap; detached rear clasp pin removed)
