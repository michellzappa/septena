# App Store metadata: Septena, the task app (source of truth)

This is the canonical store listing copy for **Septena**, the task app (code
name Septask; the name never ships). Septena Life's copy lives in
`docs/APPSTORE.md`. `appstore/metadata.mjs` parses it (run with
`SEPTENA_APP=septask`) into fastlane `deliver` metadata files
(`appstore/metadata-septask/<locale>/*.txt`, and `metadata-septask-mac/` for the
Mac app) and the review data for the brand page. Edit copy **here**, never in the generated `.txt`
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
panels follow the tentpoles of Starlings `/house/language`, in order: tasks
that think with you, AI that asks before it acts, your agents do the work, you
decide when it’s done): the
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

Tasks that think with you, on iPhone, iPad and Mac. Your agents do the work. You decide when it’s done. AI asks before it acts.

### description

Septena is a task app that thinks with you. It is for people who want a short list and a clear day. Capture a thought in a second, sort it when you’re ready, and decide what today holds before it decides for you.

THE BASICS, DONE CAREFULLY
Inbox, Today, Upcoming, and Anytime, with areas, projects, and sections to group the work. Deadlines, repeating tasks, notes, and attachments. Your calendar events sit next to today's tasks, so you plan against the hours you actually have.

TODAY IS YOUR CALL
New and loose tasks wait in the Inbox at the top of Today. Nothing lands on your day until you put it there. Septena also learns where you usually file things and suggests the right project, on your device.

AI THAT ASKS BEFORE IT ACTS
Some tasks need a moment of thinking before anyone can act on them. Tap Discuss on a task and Septena asks a short question with a few answers to tap. Where it can, it drafts, compares, or looks something up. Then it hands you the one step only you can take. It runs on your device first and reaches further only when you let it.

YOUR AGENTS DO THE WORK. YOU DECIDE WHEN IT’S DONE.
Connect Claude or your own agent and hand it a task. It works on the task and asks you there when it needs a decision. It never closes the task. Finished work waits in Review until you Accept it or Send it back. Stop an agent on one task, or Pause all agents at once. Anything an agent writes is marked, so you can see what it touched.

THE LIST THAT LETS GO
An undated task you leave alone for 14 days moves to Faded. Once a week, Septena asks you to sweep. Keep what still matters. Let go of the rest, and it moves to the Logbook.

COMING FROM THINGS OR REMINDERS
Import from Things once and keep your areas, projects, and sections. Things stays as it is. From Reminders, pick a list and bring its reminders into your Inbox. Septena deletes each one from Reminders as it comes in.

YOURS, BUILT IN THE OPEN
The apps and the sync server are open source under the MIT License. Septena works without an account: your tasks stay on your device until you sign in. When you sign in, they sync through Septena’s private server. Back up everything as JSON at any time, and preview a backup before you import it.

Native on iPhone, iPad and Mac, with your tasks in sync across all three.

### keywords

task manager,to-do,todo,tasks,things,reminders,projects,inbox,today,productivity,gtd,ai,claude

### release_notes

The first release of Septena: Inbox, Today, Upcoming, and Anytime, with areas and projects, Things and Reminders import, AI that asks before it acts, and a connector for your agents. Native on iPhone, iPad and Mac.

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

Tasks that think with you, built for the Mac. Your agents do the work. You decide when it’s done. Keyboard first, with Quick Entry from anywhere.

### description

Septena is a task app that thinks with you, built as a real Mac app for people who want a short list and a clear day. Every action has a keyboard shortcut, and Quick Entry opens from anywhere so you can capture a task without leaving what you’re doing.

THE BASICS, DONE CAREFULLY
Inbox, Today, Upcoming, and Anytime, with areas, projects, and sections to group the work. Deadlines, repeating tasks, notes, and attachments. Your calendar events sit next to today's tasks, so you plan against the hours you actually have.

TODAY IS YOUR CALL
New and loose tasks wait in the Inbox at the top of Today. Nothing lands on your day until you put it there. Septena also learns where you usually file things and suggests the right project, on your device.

AI THAT ASKS BEFORE IT ACTS
Some tasks need a moment of thinking before anyone can act on them. Tap Discuss on a task and Septena asks a short question with a few answers to tap. Where it can, it drafts, compares, or looks something up. Then it hands you the one step only you can take. It runs on your device first and reaches further only when you let it.

YOUR AGENTS DO THE WORK. YOU DECIDE WHEN IT’S DONE.
Connect Claude or your own agent and hand it a task. It works on the task and asks you there when it needs a decision. It never closes the task. Finished work waits in Review until you Accept it or Send it back. Stop an agent on one task, or Pause all agents at once. Anything an agent writes is marked, so you can see what it touched.

THE LIST THAT LETS GO
An undated task you leave alone for 14 days moves to Faded. Once a week, Septena asks you to sweep. Keep what still matters. Let go of the rest, and it moves to the Logbook.

COMING FROM THINGS OR REMINDERS
Import from Things once and keep your areas, projects, and sections. Things stays as it is. From Reminders, pick a list and bring its reminders into your Inbox. Septena deletes each one from Reminders as it comes in.

YOURS, BUILT IN THE OPEN
The apps and the sync server are open source under the MIT License. Septena works without an account: your tasks stay on your device until you sign in. When you sign in, they sync through Septena’s private server. Back up everything as JSON at any time, and preview a backup before you import it.

Your tasks stay in sync across your Mac, iPhone and iPad.

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
- `title` is at most 28 characters, without the `*` marks. Each panel shows
  one shipped feature, and the title names that feature plainly.
- The title is the only text on a panel; leave `sub` empty. Subtitles were
  tried on 2026-11-23 and were too small to read in the store. The first
  panel's title is larger than the others. Say "your agent", never a vendor: Septena works
  with any agent that speaks MCP.
- No em or en dashes. Every title and sub passes the humanizer skill.
- Panels next to each other must not look alike. `appstore/panels.septask.mjs`
  varies the fill, light or dark screen, phone size and number of phones per
  slug. Phones never tilt. Each screen shows the app in the panel's own accent
  (decided 2026-11-23).

### iPhone

| slug | scene | callout | title | sub |
| --- | --- | --- | --- | --- |
| photo | - | - | Tasks that think with you. Septena is the task app for you and your agents. | |
| hook | today/0 | - | Tasks that think with you. The new task app built for you and your agents. | |
| devices | today/0 | - | Native on iPhone, iPad and Mac. Each app is built for its device. | |
| thinking | thinking/1 | - | AI that asks before it acts. It works on one task and asks you with buttons. | |
| agent-work | agents/2 | - | Your agents do the work. Give your agent a task, and it asks you when it needs you. | |
| agent-result | agents/3 | - | You decide when it’s done. Finished work waits in Review until you accept it. | |
| inbox | capture/1 | - | You choose your day. New tasks wait in the Inbox until you put them on Today. | |
| dates | dates/2 | - | See the week ahead. Every task can have a day to start and a deadline. | |
| looks | looks/2 | - | Make it yours. Pick an accent colour and a texture for your lists. | |

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
cd ../septena/appstore && node export-scenes.mjs     # 2. export phone screens at 3x, one set per panel accent
cd ../septena/appstore && npm run all:septask        # 3. metadata + render + validate
cd ../../_/septena-site && node scripts/sync-appstore.mjs && npm run dev
                                                     # 4. review at localhost:3000/about/brand#app-store
fastlane deliver --app_identifier com.septena.tasks --platform ios \
  --metadata_path appstore/metadata-septask \
  --screenshots_path appstore/screenshots-septask    # 5. upload (from the repo root)
```

- `appstore/scenes/` is gitignored. Its `manifest.json` records the site
  revision and fixture the screens came from; the brand page shows them.
- **Review in one place:** the site's `/about/brand#app-store` shows the panels,
  the store text with character counts and the check results, per platform
  (`validate.mjs` writes `review.septask.json`, `sync-appstore.mjs` copies it).
  The old local viz page and `serve.mjs` are gone (2026-11-23): never add a
  second viewer here.
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
