# App Store metadata: Septena, the task app (source of truth)

This is the canonical store listing copy for **Septena**, the task app (code
name Septask; the name never ships). Septena Life's copy lives in
`docs/APPSTORE.md`. `appstore/metadata.mjs` parses it (run with
`SEPTENA_APP=septask`) into fastlane `deliver` metadata files
(`appstore/metadata-septask/<locale>/*.txt`, and `metadata-septask-mac/` for the
Mac app) and the viz manifest. Edit copy **here**, never in the generated `.txt`
files.

**Parse rules** (identical to APPSTORE.md; keep intact):

- A platform starts at `## Platform: <name> (<bundle id>)`.
- A field is a `### <field>` heading; everything until the next heading is the
  value (trimmed). Localized: `name`, `subtitle`, `promotional_text`,
  `description`, `keywords`, `release_notes`, `support_url`, `marketing_url`,
  `privacy_url`. Non-localized: `copyright`, `primary_category`,
  `secondary_category`.
- A platform with `### status` of `planned` is parsed but not emitted.
- Panel **visuals** live in `appstore/panels.septask.mjs`; copy lives here.

**Listing strategy** (keep panels honest to this, updated 2026-11-21): the
angle is *tasks that think with you*: a native task app with AI that asks before
it acts, built for the agents people already use, and open source. Sources:
Starlings `/strategy/positioning-septena-the-task-app` and the feature map
`/product/feature-map-septena-task-app` (use the app's words: Anytime, not
Someday; sections, not headings; When for the start date). Claim only what
ships; web, Android, Windows and self-hosting stay out of store copy until they
ship. The screenshots must prove **a focused task UI**, **today is your call**
(the Inbox waits above Today), and **your own agent can work a task**. Shots come from `SeptaskUITests/ScreenshotTests.swift` (names are the
contract): `tasks-today`, `tasks-upcoming`, `tasks-project`.

**Character limits** (validated by `appstore/validate.mjs`): name 30, subtitle
30, promotional_text 170, description 4000, keywords 100.

---

## Platform: iOS (com.septena.tasks)

### name

Septena

### subtitle

Tasks that think with you

### promotional_text

A task app that thinks with you, on iPhone, iPad, and Mac. Inbox, Today, and projects, with AI that asks before it acts. Connect Claude and work your list together.

### description

Septena is a task app that thinks with you. It is for people who want a short list and a clear day. Capture a thought in a second, sort it when you're ready, and decide what today holds before it decides for you.

THE BASICS, DONE CAREFULLY
Inbox, Today, Upcoming, and Anytime, with areas, projects, and sections to group the work. Deadlines, repeating tasks, notes, and attachments. Your calendar events sit next to today's tasks, so you plan against the hours you actually have.

TODAY IS YOUR CALL
New and loose tasks wait in the Inbox above Today. Nothing lands on your day until you put it there. Septena also learns where you usually file things and suggests the right project, on your device.

AI THAT ASKS FIRST
Some tasks need a moment of thinking before anyone can act on them. Open one and Septena asks a short question with a few answers to tap. Where it can, it drafts, compares, or looks something up. Then it hands you the one step only you can take. It runs on your device first and reaches further only when you let it.

YOUR AGENTS, IN YOUR LIST
Connect Claude or another agent that speaks MCP. Hand it a task and it claims it, asks you in the task when it needs a decision, and leaves the result for you to check. You can stop it on one task or pause every agent at once. Anything an agent writes is marked, so you can see what it touched.

COMING FROM THINGS OR REMINDERS
Import from Things once and keep your areas, projects, and sections. Things stays as it is. Pick a Reminders list and its reminders wait in your Inbox; each one you import moves out of Reminders.

OPEN SOURCE
The apps and the sync server are open source under the MIT License, so your tasks never depend on us. You can read how they are stored and how agents reach them.

Native on iPhone, iPad, and Mac, with your tasks in sync across all three.

### keywords

task manager,to-do,todo,tasks,things,reminders,projects,inbox,today,productivity,gtd,ai,claude

### release_notes

The first release of Septena: Inbox, Today, Upcoming, and Anytime, with areas and projects, Things and Reminders import, AI that asks before it acts, and a connector for your agents. Native on iPhone, iPad, and Mac.

### support_url

https://septena.app/support

### marketing_url

https://septena.app

### privacy_url

https://septena.app/privacy

### copyright

2026 MZ

### primary_category

PRODUCTIVITY

### secondary_category

UTILITIES

---

## Platform: macOS (com.septena.tasks)

> Separate App Store Connect app (own bundle id) → its own `deliver` run:
> `fastlane deliver --app_identifier com.septena.tasks --platform osx
> --metadata_path appstore/metadata-septask-mac --screenshots_path appstore/screenshots-septask-mac`.
> Mac screenshots must be 16:10 (the render pipeline outputs 2880×1800).

### name

Septena

### subtitle

Tasks that think with you

### promotional_text

A task app that thinks with you, built for the Mac: keyboard first, Quick Entry from anywhere, AI that asks before it acts. Connect Claude and work your list together.

### description

Septena is a task app that thinks with you, built as a real Mac app for people who want a short list and a clear day. Every action has a keyboard shortcut, and Quick Entry opens from anywhere so you can capture a task without leaving what you're doing.

THE BASICS, DONE CAREFULLY
Inbox, Today, Upcoming, and Anytime, with areas, projects, and sections to group the work. Deadlines, repeating tasks, notes, and attachments. Your calendar events sit next to today's tasks, so you plan against the hours you actually have.

TODAY IS YOUR CALL
New and loose tasks wait in the Inbox above Today. Nothing lands on your day until you put it there. Septena also learns where you usually file things and suggests the right project, on your device.

AI THAT ASKS FIRST
Some tasks need a moment of thinking before anyone can act on them. Open one and Septena asks a short question with a few answers to tap. Where it can, it drafts, compares, or looks something up. Then it hands you the one step only you can take. It runs on your device first and reaches further only when you let it.

YOUR AGENTS, IN YOUR LIST
Connect Claude or another agent that speaks MCP. Hand it a task and it claims it, asks you in the task when it needs a decision, and leaves the result for you to check. You can stop it on one task or pause every agent at once. Anything an agent writes is marked, so you can see what it touched.

COMING FROM THINGS OR REMINDERS
Import from Things once and keep your areas, projects, and sections. Things stays as it is. Pick a Reminders list and its reminders wait in your Inbox; each one you import moves out of Reminders.

OPEN SOURCE
The apps and the sync server are open source under the MIT License, so your tasks never depend on us. You can read how they are stored and how agents reach them.

Your tasks stay in sync across your Mac, iPhone, and iPad.

### keywords

task manager,to-do,todo,tasks,things,reminders,projects,productivity,gtd,ai,claude,mac

### release_notes

The first release of Septena on the Mac: keyboard-first lists, Quick Entry from anywhere, areas and projects, Things and Reminders import, AI that asks before it acts, and a connector for your agents.

### support_url

https://septena.app/support

### marketing_url

https://septena.app

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
fastlane deliver --app_identifier com.septena.tasks --platform osx \
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
