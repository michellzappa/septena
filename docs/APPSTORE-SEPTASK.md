# App Store metadata — Septask (source of truth)

This is the canonical store listing copy for **Septask**, the focused tasks app
over Septena's own task data. `appstore/metadata.mjs` parses it (run with
`SEPTENA_APP=septask`) into fastlane `deliver` metadata files
(`appstore/metadata-septask/<locale>/*.txt`, and `metadata-septask-mac/` for the
Mac app) and the viz manifest. Edit copy **here**, never in the generated `.txt`
files. Septena's own copy lives in `docs/APPSTORE.md`.

**Parse rules** (identical to APPSTORE.md; keep intact):

- A platform starts at `## Platform: <name> (<bundle id>)`.
- A field is a `### <field>` heading; everything until the next heading is the
  value (trimmed). Localized: `name`, `subtitle`, `promotional_text`,
  `description`, `keywords`, `release_notes`, `support_url`, `marketing_url`,
  `privacy_url`. Non-localized: `copyright`, `primary_category`,
  `secondary_category`.
- A platform with `### status` of `planned` is parsed but not emitted.
- Panel **visuals** live in `appstore/panels.septask.mjs`; copy lives here.

**Listing strategy** (keep panels honest to this): angle is *a real, private,
AI-drivable task manager* for people who want data ownership without the whole
life OS (the Things crowd). The screenshots must prove **a focused task UI**,
**today is a verb** (triage, not a dumping ground), and **your own AI can drive
it**. Shots come from `SeptaskUITests/ScreenshotTests.swift` (names are the
contract): `tasks-today`, `tasks-upcoming`, `tasks-project`.

**Character limits** (validated by `appstore/validate.mjs`): name 30, subtitle
30, promotional_text 170, description 4000, keywords 100.

---

## Platform: iOS (com.septena.tasks)

### name

Septask

### subtitle

Focused tasks, in your iCloud

### promotional_text

A real task app: Inbox, Today, Upcoming, and projects, kept in your own iCloud and drivable by your own AI. The same tasks as Septena, in a focused app. Free.

### description

Septask is a task app and nothing else. Inbox, Today, Upcoming, and Someday, with areas and projects underneath. Capture in a second, triage when you are ready, and let today be something you decide rather than a pile that lands on you. It is built to stand next to the best task apps on feel: keyboard flow on the Mac, calm density, and a fast Reminders import.

TODAY IS A VERB
Work scheduled for today does not get dumped on your plate. It lands in a review zone you triage, so you decide what today actually is before you start. Projects group related work under an area, each with its own list and a progress ring that fills as you finish.

THE SAME TASKS AS SEPTENA
Septask is not a lite version, and it is not a separate copy of your to-dos. It reads and writes the same task records in your own iCloud that the full Septena app does. Add a task in one and it is in the other. They are two windows onto one private dataset, so there is no lock-in and no migration. Start with just tasks today; turn on the rest of your life in Septena tomorrow and your tasks are already there.

PRIVATE BY ARCHITECTURE
There is no account to create and no server to trust. Your tasks live on your device and sync only through your own iCloud, invisible even to us. Nothing to breach, sell, or shut down. The code is open source, so the privacy claim is something you can audit rather than a policy you are asked to trust.

BRING YOUR OWN AI
Septask ships no AI of its own. It opens an optional door, so you can point your own AI at your tasks and let it read, add, and reorganize on your behalf. Anything an agent touches is marked, so nothing it does hides in your list. Your call, your tools, your audit trail.

Native on iPhone, iPad, and Mac, and free. Try it with a tap of demo data before you commit a single task of your own.

### keywords

task manager,to-do,todo,tasks,things,reminders,projects,inbox,today,productivity,gtd,ai,private

### release_notes

Septask's first release: a focused, private task app over the same iCloud task data as Septena. Inbox, Today, Upcoming, and Someday, with areas and projects, a Reminders import, and an optional door for your own AI. Native on iPhone, iPad, and Mac.

### support_url

https://septena.app/support

### marketing_url

https://septena.app/septask

### privacy_url

https://septena.app/privacy

### copyright

2026 MZ

### primary_category

PRODUCTIVITY

### secondary_category

UTILITIES

---

## Platform: macOS (com.septena.tasks.mac)

> Separate App Store Connect app (own bundle id) → its own `deliver` run:
> `fastlane deliver --app_identifier com.septena.tasks.mac --platform osx
> --metadata_path appstore/metadata-septask-mac --screenshots_path appstore/screenshots-septask-mac`.
> Mac screenshots must be 16:10 (the render pipeline outputs 2880×1800).

### name

Septask

### subtitle

Focused tasks, in your iCloud

### promotional_text

A real task app for the Mac: keyboard flow, calm lists, and projects, kept in your own iCloud and drivable by your own AI. The same tasks as Septena. Free.

### description

Septask is a task app and nothing else, now in a calm window on your Mac. Inbox, Today, Upcoming, and Someday, with areas and projects underneath. Keyboard flow, calm density, and a fast Reminders import, built to stand next to the best task apps on the Mac.

TODAY IS A VERB
Work scheduled for today does not get dumped on your plate. It lands in a review zone you triage, so you decide what today actually is before you start. Projects group related work under an area, each with its own list and a progress ring that fills as you finish.

THE SAME TASKS AS SEPTENA
Septask is not a lite version, and it is not a separate copy of your to-dos. It reads and writes the same task records in your own iCloud that the full Septena app does. Add a task in one and it is in the other. They are two windows onto one private dataset, so there is no lock-in and no migration. Start with just tasks today; turn on the rest of your life in Septena tomorrow and your tasks are already there.

PRIVATE BY ARCHITECTURE
There is no account to create and no server to trust. Your tasks live on your devices and sync only through your own iCloud, invisible even to us. Nothing to breach, sell, or shut down. The code is open source, so the privacy claim is something you can audit rather than a policy you are asked to trust.

BRING YOUR OWN AI
Septask ships no AI of its own. It opens an optional door, so you can point your own AI at your tasks and let it read, add, and reorganize on your behalf. Anything an agent touches is marked, so nothing it does hides in your list.

Syncs the same private tasks across Mac, iPhone, and iPad through your iCloud. Start on one, pick up on another, and it is free.

### keywords

task manager,to-do,todo,tasks,things,reminders,projects,productivity,gtd,ai,private,mac

### release_notes

Septask's first release on the Mac: a focused, private task app over the same iCloud task data as Septena. Inbox, Today, Upcoming, and Someday, with areas and projects, a Reminders import, and an optional door for your own AI.

### support_url

https://septena.app/support

### marketing_url

https://septena.app/septask

### privacy_url

https://septena.app/privacy

### copyright

2026 MZ

### primary_category

PRODUCTIVITY

### secondary_category

UTILITIES

---

## Workflow (the Septask loop)

The App Store pipeline in `appstore/` is shared by both apps and selected with
the `SEPTENA_APP` env var (default `septena`). See `appstore/apps.mjs` for the
registry (schemes, test targets, bundle ids, output dirs).

```bash
xcodegen generate                                   # 0. once, after adding the UITest targets
cd appstore && npm install                          #    first time only (Playwright)
SEPTENA_APP=septask ./capture.sh iphone69 light     # 1. capture raw task screens
SEPTENA_APP=septask ./capture.sh ipad13 light       #    (per device class)
SEPTENA_APP=septask ./capture.sh mac light
npm run all:septask                                 # 2. metadata + render + validate (Septask)
npm run viz:septask                                 # 3. open the viz to review
# 4. upload — Septask is two separate ASC apps (see fastlane/Deliverfile):
fastlane deliver --app_identifier com.septena.tasks --platform ios \
  --metadata_path appstore/metadata-septask --screenshots_path appstore/screenshots-septask
fastlane deliver --app_identifier com.septena.tasks.mac --platform osx \
  --metadata_path appstore/metadata-septask-mac --screenshots_path appstore/screenshots-septask-mac
```

- Capture targets are `SeptaskUITests` (iPhone/iPad) and `SeptaskMacUITests`
  (Mac); navigation is task-only (no tabs/Week/Next). Demo seed bypasses the
  Septask welcome so a fresh sim lands straight in tasks.
- If the configured simulator isn't installed, set `SEPTENA_SIM` (e.g.
  `SEPTENA_SIM="iPhone 17 Pro Max"`) — any 6.9" Pro Max keeps the ASC size.
- Raw shots land in `appstore/raw-septask/<device>/<appearance>/`; composites in
  `screenshots-septask/en-US/` (iOS) and `screenshots-septask-mac/en-US/` (Mac).
- Device `active` flags live in `apps.mjs`; each class stays inactive (and so
  exempt from the parity guard) until its real captures exist.
- Website: copy a raw shot into `../septena-site/public/screenshots/` as
  `iphone/septask-today.png` and `septask-mac.png` and the `/septask` hero swaps
  the placeholder for it automatically.
