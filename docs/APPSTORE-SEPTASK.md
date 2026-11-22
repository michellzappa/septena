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
- A platform ends at the next `## ` heading.
- Panel **copy and order** live in the `## Screenshots` tables below. Panel
  **visuals** (background tint, phone geometry) live in
  `appstore/panels.septask.mjs`, keyed by slug.

**Listing strategy** (keep panels honest to this, updated 2026-11-22; the
first panel says what the app is and its one unique claim: a task list your
own agent can work): the
angle is *tasks that think with you*: a native task app with AI that asks before
it acts, built for the agents people already use, and open source. Sources:
Starlings `/strategy/positioning-septena-the-task-app` and the feature map
`/product/feature-map-septena-task-app` (use the app's words: Anytime, not
Someday; sections, not headings; When for the start date). Claim only what
ships; web, Android, Windows and self-hosting stay out of store copy until they
ship. The screenshots must prove **a focused task UI**, **today is your call**
(the Inbox waits above Today), and **your own agent can work a task**. Screens come from the website's scene builder
(`../septena-site/lib/task-ui/model.ts`), not from the simulator. See
`## Screenshots`.

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

> The macOS platform of the same App Store Connect record (ADR 0007), with its own `deliver` run:
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

## Screenshots

One row is one App Store panel, in store order. `appstore/panels.septask.mjs`
reads this table; `appstore/validate.mjs` checks it.

- `scene` is `<scene id>/<step>` in the scene builder
  (`../septena-site/lib/task-ui/model.ts`, `SCENES`). The phone layout of that
  step is the screen in the panel.
- `callout` is an element id from that step's `.elements.json`, or `-`. The
  callout repeats the element's own on-screen text, larger, with a line to it.
  Callout text is never written by hand.
- `title` is at most 28 characters, without the `*` marks. It is the only
  text on the panel (decided 2026-11-22: one level of title, no subtitle).
  Leave `sub` empty. Each panel shows one shipped feature, and the title
  names that feature plainly. Say "your agent", never a vendor: Septena works
  with any agent that speaks MCP.
- No em or en dashes. Every title and sub passes the humanizer skill.

### iPhone

| slug | scene | callout | title | sub |
| --- | --- | --- | --- | --- |
| hook | today/0 | - | Tasks your agent can work | |
| agent-asks | agents/2 | - | Your agent asks, you decide | |
| agent-result | agents/3 | - | The result waits on the task | |
| inbox | capture/1 | - | New tasks wait in the Inbox | |
| plan | plan/1 | task-reply | Plan today from Anytime | |
| dates | dates/2 | - | Start dates and deadlines | |

---

## Workflow (the Septask loop)

The App Store pipeline in `appstore/` is shared with Septena Life and selected
with the `SEPTENA_APP` env var (default `septena`). See `appstore/apps.mjs` for
the registry. The renderer drives the installed Google Chrome over the
DevTools protocol (`appstore/chrome.mjs`): no npm install, no browser download.

iPhone screens come from the website's scene builder (decided 2026-11-22,
after Bipe's pipeline): the same task UI recreation the site uses, with a fixed
sample world (09:41, Friday 20 November), so the store and the site show the
same screens. Each screen comes with an `.elements.json`, and callouts anchor on
it.

```bash
cd ../septena-site && npx next build                 # 1. build the site (scene pages)
SCENE_OUTPUT=../septena/appstore/scenes SCENE_SCALE=3 SCENE_LAYOUTS=phone \
  node scripts/capture-scenes.mjs                    # 2. export phone screens at 3x
cd ../septena/appstore && npm run all:septask        # 3. metadata + render + validate
npm run viz:septask                                  # 4. review at 127.0.0.1:4477/viz/
fastlane deliver --app_identifier com.septena.tasks --platform ios \
  --metadata_path appstore/metadata-septask \
  --screenshots_path appstore/screenshots-septask    # 5. upload (from the repo root)
```

- `appstore/scenes/` is gitignored. Its `manifest.json` records the site
  revision and fixture the screens came from; the viz shows them.
- Re-export when a scene changes in `../septena-site/lib/task-ui/model.ts` or
  when a table row points at a new scene step.
- A new panel: add a row to the table above, pick its `scene` from the
  `/scenes` page on the site, and pick a `callout` id from that step's
  `.elements.json`. Visual tweaks (callout side and offset) go in
  `appstore/panels.septask.mjs`.
- One App Store Connect record holds iOS and macOS (ADR 0007). The Mac set
  still uses the July simulator panels and stays inactive until it moves to
  the scene builder's mac layout. iPad is inactive too.
- Composites land in `appstore/screenshots-septask/en-US/`.
