# App Store metadata — source of truth

This file is the canonical store listing copy for every Septena platform.
`appstore/metadata.mjs` parses it into fastlane `deliver` metadata files
(`appstore/metadata/<locale>/*.txt`) and the viz manifest. Edit copy **here**,
never in the generated `.txt` files.

**Parse rules** (keep them intact):

- A platform starts at `## Platform: <name> (<bundle id>)`.
- A field is a `### <field>` heading; everything until the next heading is the
  value (trimmed). Recognized localized fields: `name`, `subtitle`,
  `promotional_text`, `description`, `keywords`, `release_notes`,
  `support_url`, `marketing_url`, `privacy_url`. Non-localized: `copyright`,
  `primary_category`, `secondary_category`.
- A platform with `### status` of `planned` is parsed but not emitted.
- Panel **visuals** (headlines, screenshot choices, overlays) live in code:
  `appstore/panels.config.mjs`. Copy lives here; composition lives there.

**Character limits** (validated by `appstore/validate.mjs`): name 30,
subtitle 30, promotional_text 170, description 4000, keywords 100 (comma
separated, no spaces needed after commas).

---

## Platform: iOS (com.septena.cloud)

### name

Septena

### subtitle

Your private life dashboard

### promotional_text

Septena 1.0 — the Week dashboard, 16 life sections, Apple Watch app, widgets, and correlations. Local-first, synced privately through your own iCloud.

### description

Septena is a private, local-first operating system for your life. Tasks, training, nutrition, sleep, habits, hydration, mood, body, supplements, chores, groceries, and more — every domain is a section you can enable or hide, and everything meets on one Week dashboard.

THE WEEK
One glance at the trailing seven days. Sparklines, heatmaps, and per-section tiles show what you did, what's pending, and where the streaks are.

NEXT, EVERYWHERE
A single Next feed — the few things that matter right now — shared across iPhone, Apple Watch, and widgets, so the same answer follows you to whichever screen is closest.

CORRELATIONS
Septena looks across sections so you don't have to: caffeine against sleep, training against mood. Patterns surface on the dashboard once there's enough data to mean something.

SECTIONS, NOT SILOS
Sixteen sections, each optional. Disable one and its surfaces disappear — your data never does. Colors, labels, and visibility are yours to change.

PRIVATE BY ARCHITECTURE
No accounts. No servers. No ads. No analytics. Your data lives on your device and syncs through your own iCloud private database — end-to-end, invisible to us. Export everything, any time.

ALSO IN THE BOX
- Apple Watch app with complications and quick-add
- Home Screen and Lock Screen widgets, Live Activities
- App Intents: log anything with Siri or Shortcuts
- Health, Oura, Withings, and GitHub integrations
- Time travel: scrub back to any day
- Demo mode to explore with curated data before committing

Built by one person, for daily use first. Septena is opinionated, fast, and quiet — a place to run your life, not another feed to check.

### keywords

habit tracker,life,journal,sleep,nutrition,training,mood,private,health log,routine,goals,water

### release_notes

First public release: Week dashboard, 16 sections, Next feed, Apple Watch app, widgets, correlations, demo mode.

### support_url

https://septena.app/support

### marketing_url

https://septena.app

### privacy_url

https://septena.app/privacy

### copyright

2026 MZ

### primary_category

HEALTH_AND_FITNESS

### secondary_category

PRODUCTIVITY

---

## Platform: macOS (com.septena.cloud.mac)

### status

planned

> Separate App Store Connect app (own bundle id) → its own `deliver` run with
> `screenshots-mac/`. Mac screenshots must be 16:10 — 2880×1800 preferred.
> Copy will start as the iOS copy minus iPhone-specific lines.

---

## Platform: watchOS (com.septena.cloud.watchkitapp)

### status

planned

> Watch screenshots upload under the **iOS** app (same listing), at watch
> resolutions (410×502 Ultra / 416×496 Series 10). Needs a watch screenshot
> capture pass (no `ScreenshotTests` target for the watch yet); the
> `appstore/devices.mjs` `watch` entry is pre-wired, just inactive.

---

## Workflow (the whole loop)

```bash
scripts/screenshots.sh light          # 1. capture raw screens (simulator, demo seed)
cd appstore && npm install            #    first time only (Playwright)
npm run shots:sync                    # 2. pull captures into appstore/raw/
npm run all                           # 3. metadata + render composites + validate
npm run viz                           # 4. open the App Store viz to verify
fastlane deliver                      # 5. upload metadata + screenshots (no binary)
```

- Raw captures land in `appstore/raw/iphone69/<light|dark>/`.
- Composites render to `appstore/screenshots/en-US/` at exact ASC pixel sizes.
- `fastlane/Deliverfile` points deliver at `appstore/metadata` + `appstore/screenshots`.
- Screenshot specs encoded in `appstore/devices.mjs`: iPhone 6.9" 1320×2868
  (ASC scales smaller iPhone shelves from it), iPad 13" 2064×2752, Mac
  2880×1800, Watch 410×502. PNG/JPEG, RGB, no alpha, max 10 per device class.
