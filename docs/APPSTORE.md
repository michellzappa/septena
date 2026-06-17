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

**Listing strategy** (keep panels honest to this): angle is *all-in-one life
dashboard*; audience is *privacy-conscious general*; the screenshots must prove
**the Week**, **correlations**, and **privacy**. Panel order (highest-converting
first): hook (all-in-one) → the Week → correlations → sections → privacy →
close. Shots come from `SeptenaUITests/ScreenshotTests.swift` (names are the
contract): hook `01-Week`, week `06-Week-heatmap`, correlations
`08-Correlations`, sections `05-Goals`; privacy/close are statement panels.

**Character limits** (validated by `appstore/validate.mjs`): name 30,
subtitle 30, promotional_text 170, description 4000, keywords 100 (comma
separated, no spaces needed after commas).

---

## Platform: iOS (com.septena.cloud)

### name

Septena

### subtitle

One private app for everything

### promotional_text

Keep your whole life in one private place: tasks, sleep, training, mood, and more. Your data stays in your own iCloud. No accounts, no ads, and it's free.

### description

Your life ends up scattered across separate apps that never talk to each other. A tracker here, a journal there, a habit app you keep forgetting to open. Septena brings it all home: one private app for everything you track.

ONE APP FOR EVERYTHING
One surface, so the things you track can finally relate. Tasks, training, sleep, nutrition, habits, mood, hydration, and more, each in its own section you turn on or quietly hide. A fact on its own is just a fact. Only when everything lives in one place can you see that two facts are connected. Turn on what matters, hide the rest, and your data stays exactly where it was.

BUILT AROUND THE WEEK
A day is too noisy and a month is too late. A week is where sleep, training, food, and habits start to relate. Open Septena and your last seven days are there at a glance, in heatmaps and quiet sparklines across every section. The Correlations view does the math you would never do by eye, like late afternoon coffee turning up in last night's sleep. It tells you plainly when the data is still too thin to trust, and streaks count only what you actually did.

PRIVATE BY ARCHITECTURE
There is no account to create and no server to trust. No ads, no analytics, no one looking over your shoulder. Your data lives on your device and syncs only through your own iCloud, invisible even to us. Nothing to breach, sell, or shut down. Export all of it whenever you like.

BRING YOUR OWN AI
Septena ships no AI of its own. It opens an optional door, so you can point your own AI at your data and ask it anything, with your permission and a visible record of everything it touches. Your call, your tools, your audit trail.

WHEREVER YOU ALREADY ARE
A Home and Lock Screen widget for the day ahead. An Apple Watch app and complications for the few things that matter right now. Log hands-free with Siri and Shortcuts. Step back to any past day to see how it really went.

Septena is made by an independent developer, for daily use first: fast, quiet, and calm. A place to run your life, and it's free.

Try it with a tap of demo data before you commit a single detail of your own.

### keywords

habit tracker,journal,planner,routine,sleep,mood,nutrition,fitness,diary,offline,goals,water

### release_notes

Septena's first public release. The Week dashboard, a full set of optional sections, cross-section correlations, an Apple Watch app, Home and Lock Screen widgets, and a demo mode so you can look around before committing any of your own data. Thank you for trying it.

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

> Separate App Store Connect app (own bundle id) → its own `deliver` run:
> `fastlane deliver --app_identifier com.septena.cloud.mac --platform osx
> --metadata_path appstore/metadata-mac --screenshots_path appstore/screenshots-mac`.
> Mac screenshots must be 16:10 (the render pipeline outputs 2880×1800).

### name

Septena

### subtitle

One private app for everything

### promotional_text

Your whole life in one calm Mac window: tasks, sleep, training, mood, and more. Your data stays in your own iCloud. No accounts, no ads, and it's free.

### description

Your life ends up scattered across separate apps that never talk to each other. Septena brings it all home, now in a calm window on your Mac: one private app for everything you track.

ONE APP FOR EVERYTHING
One surface, so the things you track can finally relate. Tasks, training, sleep, nutrition, habits, mood, hydration, and more, each in its own section you turn on or quietly hide. A fact on its own is just a fact. Only when everything lives in one place can you see that two facts are connected. Turn on what matters, hide the rest, and your data stays exactly where it was.

BUILT AROUND THE WEEK
A day is too noisy and a month is too late. A week is where sleep, training, food, and habits start to relate. See your last seven days at a glance, in heatmaps and quiet sparklines across every section. The Correlations view does the math you would never do by eye, like late afternoon coffee turning up in last night's sleep, and it tells you plainly when the data is still too thin to trust.

PRIVATE BY ARCHITECTURE
There is no account to create and no server to trust. No ads, no analytics. Your data lives on your devices and syncs only through your own iCloud, invisible even to us. Nothing to breach, sell, or shut down. Export all of it whenever you like.

BRING YOUR OWN AI
Septena ships no AI of its own. It opens an optional door, so you can point your own AI at your data and ask it anything, with your permission and a visible record of everything it touches. Your call, your tools, your audit trail.

ONE LIFE, EVERY SCREEN
Septena syncs the same private dashboard across Mac, iPhone, iPad, and Apple Watch through your iCloud. Start on one, pick up on another.

Septena is made by an independent developer, for daily use first: fast, quiet, and calm. A place to run your life, and it's free.

### keywords

habit tracker,journal,planner,routine,sleep,mood,nutrition,fitness,diary,goals,water,dashboard

### release_notes

Septena's first release on the Mac. The full Week dashboard, a full set of optional sections, cross-section correlations, and private iCloud sync with your iPhone, iPad, and Apple Watch.

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
xcodegen generate                     # 0. once, after adding SeptenaMacUITests
cd appstore && npm install            #    first time only (Playwright)
./capture.sh iphone69 light           # 1. capture raw screens straight into raw/
./capture.sh ipad13 light             #    (per device class)
./capture.sh mac light
npm run all                           # 2. metadata + render composites + validate
npm run viz                           # 3. open the App Store viz to verify
fastlane deliver                      # 4. upload iOS metadata + screenshots (no binary)
fastlane deliver --app_identifier com.septena.cloud.mac --platform osx \
  --metadata_path appstore/metadata-mac --screenshots_path appstore/screenshots-mac
```

- Raw captures land in `appstore/raw/<device>/<light|dark>/`. Capture targets:
  iPhone/iPad reuse `SeptenaUITests` (different simulator); Mac uses the new
  `SeptenaMacUITests` target; Watch is manual
  (`xcrun simctl io <watch-sim> screenshot`, single Next screen).
- Composites render to `screenshots/en-US/` (iPhone + iPad, deliver sorts by
  resolution) and `screenshots-mac/en-US/` (Mac, separate ASC app) at exact ASC
  pixel sizes.
- Surfaces + sizes live in `appstore/devices.mjs` (`active: true` to include):
  iPhone 6.9" 1320×2868, iPad 13" 2064×2752, Mac 2880×1800 (landscape), Watch
  410×502. Per-device panel layouts in `appstore/panels.config.mjs`. PNG, RGB,
  no alpha, max 10 per device class.
- `scripts/screenshots.sh` (Desktop output) + `npm run shots:sync` remain as the
  legacy iPhone path; `capture.sh` supersedes them by writing straight into raw/.
