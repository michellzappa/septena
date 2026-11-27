---
name: septena-bento-studio
description: Design and render Apple-style feature bento grids for Septena (App Store panels, Mac 16:10 panels, septena.app homepage overviews, and launch graphics) using registry tokens, real UI macros, and headless Chrome.
---

# Septena Bento Studio

Use this repo-local skill when designing or iterating on Apple-style bento feature grids for Septena. It sits alongside `docs/photo-studio/SKILL.md`, `docs/photo-composite/SKILL.md`, and `docs/3d-studio/SKILL.md` as the 2D compositional studio.

All prototype and study scripts live in `tools/bento-studio/`:
- `tools/bento-studio/render.mjs` — headless Chrome renderer (reuses `appstore/chrome.mjs`, zero npm dependencies) that outputs high-res PNGs plus a self-contained `renders/showcase.html` comparison page.
- `tools/bento-studio/renders/` — local render outputs (gitignored, matching `tools/3d-studio/renders/`).

## Sources and brand guardrails

- Read `registry/tokens.json` for all fruit accents and header textures. Never hand-pick off-brand accent hexes.
- Read `docs/APPSTORE-SEPTASK.md` for current store copy and listing constraints, and `docs/DesignSpec.md` for typography roles:
  - **SF Pro** for headlines, UI labels, and body copy.
  - **SF Rounded** strictly for large, isolated hero numbers (`100%`, `0`).
  - **SF Mono** for code, JSON snippets, MCP tool calls, and technical pills.
- Synthetic demo content only (`Send the launch update`, `Draft the launch brief`).
- Never use a sparkle icon for AI. Never name an AI vendor in store panels ("your agent", not a specific vendor).
- Never put external URLs or GitHub repo paths on App Store screenshots (Apple review hygiene).
- Keep all copy plain, direct, and free of em/en dashes.

## Established visual direction (2026-11-26)

### 1. Break the uniform card-grid pattern

A bento fails when every tile repeats `[icon in squircle] + [title] + [gray sentence]`. That reads as a timid SaaS grid rather than an Apple product bento.

Each tile should commit to a distinct visual idiom, and **no two adjacent tiles may share the same archetype**:

| Archetype | Example in Septena |
| --- | --- |
| **Oversized UI macro (edge-bleed)** | `Discuss` answer chips (`Asks before it acts`), `Inbox` band (`Today is your call`), `Review` sheet (`You decide when it's done`) bleeding past a tile edge instead of sitting inside double-padded boxes. |
| **Monumental hero number** | `100%` (`Open source · MIT`) or `0 bytes` (`Not in analytics`). Only use a number that makes instant sense without explanation. Avoid arbitrary-looking numbers like `14 days` (reads like a trial countdown). |
| **Macro hardware / physical cue** | Angled closeup of an anodized Mac keyboard corner with a lit Persimmon `K` on `⌘K` (`Keyboard-first`), or tactile iOS `On device` / `Account` switches. |
| **Tactile brand swatches** | Fanned overlapping deck of real fruit + texture cards (*Persimmon · Topography*, *Yuzu · Field Matrix*, *Carambola · Stipple*, *Haskap · Ridges*, *Pitaya · Washi*), spaced so every fruit name stays unclipped. |
| **Protocol / file artifact** | Tilted dark `septena-mcp` tool snippet (`tasks_claim`, `tasks_thread_append`, `tasks_set_handoff`) or `backup.json` card bleeding off an edge. |
| **3D Studio hardware render** | Real Blender Cycles render (`appstore/art/photo-devices.png`) framed cleanly so every device in the cluster stays intact. |

### 2. Grid geometry & interlocking seams

- **Landscape (`16:10`, `2400×1500` or `2880×1800` for Mac App Store):** 12-column × 3-row interlocking grid with non-stacking column seams across rows (`5 | 4 | 3`, `5 cont. | 3 | 4`, `3 | 4 | 5`).
- **Portrait App Store (`1320×2868`):** 2-column grid beneath the standard `lead()` headline — 1 wide dark anchor tile on top (`col 1 / -1`) followed by a 2×2 grid where at least one lower tile uses a deep accent/glass surface so the bottom half does not collapse into four identical white cards.
- **Concentric radii:** inner elements track outer tile curvature (`innerRadius ≈ outerRadius - padding`).

### 3. Surface & lighting balance

- Keep 50–70% of the grid on calm neutral tiles (`#FFFFFF` on `#EFEFF3` in light mode; `#141418` hairline-bordered obsidian on `#070709` in dark mode).
- Anchor the grid with **1–2 high-contrast dark or deep-cobalt tiles** and **1–2 saturated brand accent tiles** (Persimmon `#E05212`, Haskap `#1D63DC`) carrying subtle texture contours.
- In dark mode, keep the hero UI tile obsidian with a subtle warm Persimmon radial wash and dark-mode app UI rather than dropping a stark full-white slab onto a dark canvas.

### 4. Critical rendering gotchas (already solved in `tools/bento-studio/render.mjs`)

1. **Gradient-clipped hero digits get their crown sliced off:** Combining `line-height < 0.9` with `-webkit-background-clip: text` clips the top of large SF Rounded numerals (`0`, `100`). Keep `line-height >= 1.0` and add vertical padding (`padding: 6px 4px`).
2. **Framing vertical 3D Studio renders in wide landscape tiles:** `appstore/art/photo-devices.png` is `9:16`, with the 4-device cluster occupying roughly `y = 22%..75%`. Size the wrapper width to match the image width (`width: 468px`) and apply a horizontal `mask-image` feather (`transparent 0% → #000 30%`) on the wrapper itself so the left edge melts smoothly into the dark studio backdrop with zero vertical seam, while MacBook, iPad, iPhone, and Apple Watch all remain completely inside the frame.
3. **Overlapping fanned cards:** Keep horizontal card stride wide enough (`~140px` at `210px` card width) that long fruit names (`Persimmon`, `Carambola`) never clip under the neighboring card.

## Render workflow

```bash
node tools/bento-studio/render.mjs
```

Outputs `tools/bento-studio/renders/`:
- `bento-landscape-light.png` (`2400×1500`)
- `bento-landscape-dark.png` (`2400×1500`)
- `bento-appstore-open.png` (`1320×2868`)
- `showcase.html` (self-contained tabbed viewer with before/after App Store comparison)

Follow-up production integration (wiring composable bento tiles into `appstore/components.mjs`, Mac `16:10` store panels, and live React homepage tiles in `septena-site`) is tracked in GitHub issue #718.
