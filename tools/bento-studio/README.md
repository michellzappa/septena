# Septena Bento Studio

Headless Chrome pipeline for designing and rendering Apple-style feature bento studies (App Store portrait panels, `16:10` landscape homepage / Mac App Store grids, and launch recaps) using Septena's real `registry/tokens.json` palette and `appstore/chrome.mjs` renderer.

See [docs/bento-studio/SKILL.md](../../docs/bento-studio/SKILL.md) for the established art direction, tile archetypes, grid geometry, and rendering rules.

## Usage

Requires Google Chrome installed locally (same requirement as `appstore/render.mjs`, zero npm dependencies):

```bash
node tools/bento-studio/render.mjs
```

Outputs into `tools/bento-studio/renders/` (gitignored):
- `bento-landscape-light.png` (`2400×1500`, 16:10 Apple light canvas)
- `bento-landscape-dark.png` (`2400×1500`, 16:10 Apple keynote dark canvas)
- `bento-appstore-open.png` (`1320×2868`, portrait App Store study for the `open` panel)
- `showcase.html` (self-contained tabbed preview with Light, Dark, and App Store Before/After comparison)
