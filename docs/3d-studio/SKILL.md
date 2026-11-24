---
name: septena-3d-studio
description: Render repeatable, pixel-accurate 3D Apple device marketing scenes in Blender Cycles (Metal GPU) for Septena, with real screenshots, procedural topographic backdrops, and Apple industrial-design polish.
---

# Septena 3D Studio

Use this repo-local skill when creating or iterating on 3D device hero renders (MacBook Pro 14", iPad Mini, iPhone 17 Pro Max / Air, Apple Watch) for Septena marketing, App Store panels, or launch visuals.

All scripts live in `tools/3d-studio/`:
- `tools/3d-studio/render.py` — headless Cycles/Metal studio builder & renderer
- `tools/3d-studio/fetch_models.py` — reproducible fetcher for the pinned free Royalty-Free BlenderKit `.blend` models
- `tools/3d-studio/make_demo_screens.swift` — generates SF Pro Persimmon `#E05212` placeholder screens (`screens/demo_*.png`)
- `tools/3d-studio/studio_iso.blend` — locally saved editable scene (gitignored; regenerated in <1s via `--save-blend`)

## Why Blender + pre-made models

- **Never model Apple hardware procedurally** from scratch — fetch clean real-world-scale `.blend` models and script the lighting, materials, UV projection, hardware polish, and camera in Python (`bpy`).
- **Pixel-accurate UI:** Unlike AI image generation, Cycles renders real PNG screenshots with zero text warping and casts physically-based screen light onto the dark desk.
- **Asset sourcing:** **BlenderKit's free public API** (`https://www.blenderkit.com/api/v1/search/?query=...%20asset_type:model%20is_free:true` and `/api/v1/downloads/<uuid>/?scene_uuid=<uuid>`) resolves direct Royalty-Free `.blend` downloads with no login and no attribution strings. *(Sketchfab's `/v3/models/{uid}/download` requires an authenticated account token and returns HTTP 401 without one.)*

## User's established 3D visual direction

- **Camera & composition (`--preset iso-vertical`, 9:16):**
  - **Low-angle true orthographic isometric** (`~9.5°` elevation, ~`21°` front-left azimuth).
  - **Tight zoom:** MacBook bleeds slightly off the left edge while keeping the entire Mac app window visible; the iPhone's gleaming right titanium rail sits right along the right edge of the frame with ~1% breathing sliver (no empty right-hand margin).
  - **Midpoint vertical anchor:** Devices occupy the vertical middle of the 9:16 frame, leaving ~25–28% dark topographic headroom above for headline copy (e.g. *"One list, every device."*) and a smooth warm-lit dark slate desk below.
  - **4-device array:** MacBook Pro 14" in back, landscape iPad Mini in front of the left half of the MacBook keyboard, iPhone in front of the right keyboard edge, and Apple Watch laid low in front-center between iPad and iPhone. Overlap over the lower MacBook display is fine and keeps all screens large and legible.
- **Industrial-design details (all applied procedurally in `render.py`):**
  - **MacBook Pro 14":** Notchless OLED display with **symmetric rounded corners on BOTH top and bottom** (`corner_radius=0.036, aspect=1.522` analytic SDF mask), velvety bead-blasted anodized aluminum (`metallic=0.88`, `roughness=0.42`, micro-bead bump `scale=1800, strength=0.015` — **never** shiny `0.25` chrome), dark matte keyboard (`Emission Strength = 0.0`).
  - **iPad Mini:** Chunky stock 10 mm bezels thinned procedurally via `thin_ipad_bezels()` down to uniform **~4.2 mm** bezels, paired with an **analytic concentric inner corner radius** (`corner_radius=0.068, aspect=1.507` → `8.4 mm = outer 12.6 mm − 4.2 mm bezel`) so corner curvature tracks the outer glass rim concentrically.
  - **iPhone:** Clean, uninterrupted glass top edge by default — `remove_iphone_island()` strips the Dynamic Island, selfie lens, and top earpiece slit strictly inside the top-center zone (`|x - cx| < 0.015`, `ymax - 0.013 < y < ymax - 0.0002`, skipping `color`/`glass` materials so rounded corner rails and front glass stay intact). Warm natural/desert titanium rail (`roughness=0.18`).
  - **Apple Watch:** Assumes a **soft silicone strap** — `relax_watch_soft_strap()` compresses the rigid circular rear loop (`42%` depth, tucked bottom loop) and removes the detached rear clasp pin (`Cylinder.003`) so the Watch lays low (`-46°`) and grounded on the desk.
- **Background & lighting:**
  - **Backdrop:** 100% procedural dark charcoal matte wall (`#011..030`) with whisper-subtle topographic contour lines (`Noise -> Multiply(26) -> Fract -> Abs(x-0.5) -> ColorRamp`), angled perpendicular to the isometric camera.
  - **Desk:** Deep matte charcoal slate (`size=20.0`, macro+micro procedural roughness `0.26..0.46` and micro-bump) catching warm Persimmon (`#E05212`) reflections from the screens.

## Critical Blender / Cycles gotchas (already solved in `render.py`)

1. **AgX washes out bright UI screenshots:** Setting a single screen `Emission Strength = 3.0` makes white UI and light orange cards blow out under `AgX` tone-mapping. **Fix:** Split rays with `ShaderNodeLightPath -> Is Camera Ray`:
   - Camera rays get `Gamma = 1.28`, `Saturation = 1.16`, `cam_strength ≈ 1.48–1.52` (crisp, legible dark ink & vibrant cards).
   - Non-camera (GI/glossy bounce) rays get raw texture at `bounce_strength = 4.5–8.5` (rich warm reflections onto the desk).
2. **Low orthographic camera clips the bottom desk:** An `ORTHO` camera positioned close to the subject (`z = 0.25m`) with tall portrait `ortho_scale` has lower camera rays originating *below* `Z = 0`, producing a solid black horizontal bar at the bottom of the frame. **Fix:** Pull the `ORTHO` camera **3× farther back along the exact same sightline** (`loc = target + 3.0 * (loc - target)`) so every ray originates well above `Z = 0` with zero change to framing or angle, and make the desk `size = 20.0`.
3. **Vertical 9:16 camera math:** Set `camera.sensor_fit = 'HORIZONTAL'` (Blender's default `AUTO` fits `36mm` to height in portrait, zooming `1.78×` too tight horizontally).
4. **Exact floor contact:** Compute `min(v.z)` over transformed mesh vertices in `drop_to_floor()`, not rotated `bound_box` corners (which float tilted watches/phones off the desk).
5. **UV normalization:** Re-project each device's screen faces directly from local coordinates (`reproject_planar_uv`) so arbitrary PNG screenshots map edge-to-edge `[0, 1]` without manual UV work.
6. **Sandbox note for Swift helper:** Run `swift -module-cache-path /tmp/swift-module-cache tools/3d-studio/make_demo_screens.swift` when invoking inside a restricted sandbox.

## Render workflow

1. **Fast iteration (~9s on Apple Silicon Metal GPU):**
   ```bash
   blender -b --python tools/3d-studio/render.py -- \
     --preset iso-vertical --scale 0.5 --samples 32 \
     --out /tmp/preview.png
   ```
2. **Production render (`1080×1920` ~80s; add `--scale 2.0` for 4K):**
   ```bash
   blender -b --python tools/3d-studio/render.py -- \
     --preset iso-vertical \
     --mac path/to/mac.png \
     --ipad path/to/ipad.png \
     --ios path/to/ios.png \
     --watch path/to/watch.png \
     --samples 112 \
     --save-blend tools/3d-studio/studio_iso.blend \
     --out tools/3d-studio/renders/iso_vertical_4dev.png
   ```
3. **Real screenshots:** Current Septena task-app screens come from `node appstore/export-scenes.mjs` (`appstore/scenes/`) or user-supplied native Mac/iPad/iPhone/Watch captures. Do **not** reuse the older June all-in-one Septena Life screenshots in `appstore/raw/`.
