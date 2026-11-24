---
name: septena-photo-composite
description: Put a real Septena screenshot on the device in a photo (App Store panels, website, social). Use whenever a marketing image shows a device screen in a generated or real photo, when the screen or the photo of such an image changes, or when a new photo needs its screen measured.
---

# Photo composite

A marketing photo with a device is three layers. Each layer changes on its own.

| Layer | What | Source |
|---|---|---|
| 1. Photo | Person, hand, device body, light | Generated (ChatGPT / ImageGen) or real. `docs/photo-studio/SKILL.md` |
| 2. Screenshot | The app, positioned in perspective on the device | A PNG of the real UI |
| 3. Text | Title and lead | The panel renderer (`appstore/render.mjs`) or the page |

**The rule (mz, 2026-11-24): the screen is always a composed screenshot, never
a generated one.** A generated screen may exist while a photo is explored. It
never ships, not under the screenshot and not at its edges.

For devices that are 3D models, not a photo, use `docs/3d-studio/SKILL.md`.

## Layer 2: which screenshot

- Use an exported scene (`node appstore/export-scenes.mjs`, into
  `appstore/scenes/`) or a native capture. Scenes come from the website's task
  UI, not from the iPhone app: say so when it matters.
- Not a screenshot: `tools/3d-studio/make_demo_screens.swift` output. Those
  screens imitate the app.
- mz supplies a "signature view" of the app later. Until then Meet Septena
  uses scene `today/0`, light, Persimmon.
- Synthetic content only. No sparkle icon for AI.

## How it works

`tools/3d-studio/replace_photo_screen.py` warps the PNG onto the four measured
screen corners, masks the rounded corners, and matches the light of the photo
(black floor, white point, falloff, sheen, grain). It reads no pixel of the
photo's own screen. It runs in Blender's Python, so it needs Blender and no
other package. The warp is flat perspective, not a 3D scene.

Each photo `X.png` has a sidecar `X.screen.json` next to it:

- `corners`: TL, TR, BR, BL of the lit screen, 0..1 of the photo, origin top-left.
- `cornerRadius`: the screen's corner radius as a fraction of its width.
- `sha256`: the exact file that was measured.

## Change the screenshot

Change `photo.screen` of the panel in `appstore/panels.septask.mjs`, export the
scenes, render. The photo and the sidecar stay as they are.

## Add or change a photo

1. Put it in `appstore/art/`. The whole screen must be visible, flat, and lit
   evenly. Nothing may cover it: there is no mask for a finger over the glass.
   A light screen in the photo makes the edges easy to measure.
2. Measure the four screen edges, not the corners: fit a line along each
   straight edge and intersect the lines. The corners are rounded, so a corner
   read by eye is wrong. Aim for a fit error under 0.5 px.
3. Write `X.screen.json` with `corners` and `cornerRadius`. Leave `sha256` empty.
4. Remove the photo's own screen. This paints it black in place and writes the
   hash. Keep the original outside the repo:

   ```bash
   blender -b --python-exit-code 1 --python tools/3d-studio/replace_photo_screen.py -- \
     --photo appstore/art/X.png --blackout
   ```

5. Compose, then look at the result at full size. Check the four corners, the
   edges against the bezel, and that text runs parallel to the device edge:

   ```bash
   blender -b --python-exit-code 1 --python tools/3d-studio/replace_photo_screen.py -- \
     --photo appstore/art/X.png --ios SCREEN.png --out /tmp/composite.png
   ```

6. A panel: add `photo: { src: "art/X.png", screen: { src, appearance, accent } }`.
   Its row in `docs/APPSTORE-SEPTASK.md` keeps `-` as the scene: a scene there
   draws a second, upright phone over the photo.
   Anywhere else (website, social): use the composed PNG from step 5.

Pass `--python-exit-code 1` always. Without it Blender exits 0 on a Python error.

## What stops a generated screen

- The photo in the repo has a black screen: there is nothing to fall back to.
- `render.mjs` stops when a photo panel has no `screen`. `rendered: true` is
  only for 3D Studio renders, whose screens are PNGs on the models.
- `render.mjs` stops when the scene PNG is missing.
- The script stops when the sidecar is missing or the photo is not the one
  that was measured.

## Known gap

`appstore/art/photo-devices.png` is a 3D Studio render with imitated screens
(`make_demo_screens.swift`). Render it again with real scenes or captures.
