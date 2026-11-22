# Native marketing scenes

> **Superseded 2026-11-22.** ADR 0022 is rejected: the website draws scenes in code from the app's registries, not from native captures. Kept for history. Remaining work: michellzappa/septena-site#10.

Status: superseded. Owner: mz.

The website explains Septena with scenes: a few app screens in a loop, one caption per step, and a spotlight on the part that the caption names. This spec moves the screens from the website's web copy of the app to real captures from Septask. The website keeps only the explanation layer.

## Goal

- Every pixel of a scene's app screen comes from the shipped app, on iPhone and on Mac, in light and dark.
- Each concept appears in context: the full real screen, with one named part lit and the rest dimmed.
- A capture that lands on the wrong screen fails. It never produces a plausible image with the wrong name.

Out of scope for v1: iPad, Android, Windows, the planned web app, screen recordings.

## How it fits together

1. **Fixture.** The app launches with `-SeptenaSeed marketing`: an in-memory store, no sync, a fixed day and time, and the data every scene needs.
2. **Scene scripts** (`appstore/scenes/scenes.json`, app repo) list each scene's steps. A step has actions (open a destination, open a task, type a title, toggle a task), an `expect` identifier that proves the screen is right, and a `spotlight` identifier.
3. **Scene runner** (one XCUITest per platform: `SeptaskUITests/SceneCaptureTests`, `SeptaskMacUITests/SceneCaptureTests`) reads the scripts, runs each step, asserts `expect`, then saves the screenshot and the frames of every identifier the step names.
4. **Exporter** (`appstore/export-scenes.mjs`) turns the test attachments into the site's existing manifest format: `<scene>/<layout>/<appearance>/<step>.png` plus `.elements.json`, with provenance (source revision, scheme, OS, device, appearance, digest).
5. **Site import** (`septena-site/scripts/import-native-scenes.mjs`) copies the export into `public/scenes/`. `check-scenes.mjs` validates digests, sizes and provenance, and fails on a scene that a script lists but the export lacks.
6. **Site player** shows the PNG in device chrome, draws the spotlight from the element frame, crossfades between steps, and shows the caption from `septena-site/content/scene-captions.json`.

Captions live in the site because they are marketing copy (humanizer, `docs/marketing.md` voice). Scripts live in the app repo because they depend on app identifiers and fixture ids. They join by scene id and step id.

## Fixture: `-SeptenaSeed marketing`

A second scenario beside `demo` in `SeptenaCore/DemoSeed.swift`, under the same `DemoSeedMode` guard (DEBUG only, in-memory, no sync). Requirements:

- Fixed clock: `DayClock` pinned to Friday 20 November, 09:41, so dates and "Today" read the same in every run.
- The task backend is off, not only CloudKit (#94).
- Stable ids for every record a script touches (`mk-…`), so scripts never match by title.
- Content (titles follow the website's existing sample world):
  - Areas Work and Personal; projects Website (Work) and Home (Personal).
  - Two tasks in the Inbox band on Today, one of them an agent proposal.
  - Today tasks in Admin and Website.
  - A Website task with notes.
  - A task with a start day (Monday) and a deadline (Friday), so Upcoming is not empty.
  - A repeating task ("Water the plants", every Friday).
  - A task with two image attachments.
  - A task with an agent conversation: a question, your answer, a result.
  - A few completed tasks for the Logbook.

## Identifiers the app must expose

Use `.a11yID(.tasks(…))` / `.a11yID(.sidebar(…))` in SwiftUI and the `kitA11y…` helpers (`setAccessibilityIdentifier`) in the Septask Mac AppKit shell. The same identifier on both platforms.

| Identifier | Part |
|---|---|
| `tasks.list.<destination>` | root of each list (today, upcoming, anytime, logbook, project) |
| `tasks.today.inboxBand` | the Inbox band on Today |
| `tasks.section.<id>` | a group header (area, project, day) |
| `septena.task.row.<id>` | a task row (exists on iOS `SelectableScrollList`; add on the Mac table) |
| `tasks.composer` | the new-task composer |
| `tasks.detail` | task detail (iOS) / inspector (Mac) |
| `tasks.detail.notes`, `.when`, `.deadline`, `.repeat`, `.attachments`, `.project` | parts of the detail |
| `tasks.thread` | the task conversation |
| `sidebar.destination.<id>` | sidebar rows (Mac sidebar, and the iPhone list root: iPhone has no tab bar, ADR 0024) |

Destination ids come from `registry/destinations.json`. These identifiers also serve VoiceOver, Voice Control and the existing contract tests.

## Scenes for v1

| Scene | Steps (spotlight) | Used on |
|---|---|---|
| `fundamentals` | Today (Inbox band) · Today (your picked tasks) · Upcoming (dated row) · Anytime (list) · project (section) · task (detail) · agent (thread) | home, `/features` |
| `capture` | composer · Inbox band row · row filed under a project · row checked off | `/workflows/capture` |
| `plan` | Anytime row · row set to Today · Today list | `/workflows/today` |
| `structure` | Inbox band row · project list · detail project field | `/workflows/projects` |
| `dates` | detail · when and deadline fields · Upcoming row | `/workflows/dates` |
| `repeat` | repeating row · checked off · next one in Upcoming | `/workflows/repeating-tasks` |
| `notes` | project row · notes field · attachments | `/workflows/notes-and-files` |
| `agents` | assigned row · thread question · result · unread row | `/workflows/agent-delegation`, home |

Each scene captures on `phone` (iPhone 17 Pro, compact tabs) and `mac` (app window), light and dark.

## Phases

| Phase | Work | Repo |
|---|---|---|
| P0 | Harden the capture runner: assert destination and fixture before each capture, fail on failed navigation, record provenance (#94) | app |
| P1 | Marketing fixture and identifiers (above) (#222) | app |
| P2 | Scene scripts, scene runner, exporter, `capture.sh scenes` mode (#223) | app |
| P3 | Site import, provenance checks, native player with spotlight and captions (septena-site#8) | site |
| P4 | Write the v1 scenes, swap every scene on the site to native frames, take the web task UI out of marketing (septena-site#9) | both |
| Later | Screen recordings for real motion; iPad | both |

P1 and P3 do not depend on each other and can run at the same time. P3 can be built against one hand-captured frame set.

## Who runs captures

Capture boots simulators and runs a signed Mac build. mz runs `appstore/capture.sh scenes`, or clears an agent to run it in that session. No unattended or scheduled capture, and never a runtime download (#94, AGENTS.md). Mac capture runs on the laptop, because it needs the development certificate. Builds use the laptop's build lock.

## Open questions

1. **Agent conversation in the fixture.** Task conversations come from the task backend (ADR 0008). The fixture needs a local stand-in that the detail view renders, or the `agents` steps wait.
2. **The web task UI.** Keep it only as the labeled design preview for the planned web app, or delete it.
3. **iPad.** Out of v1. Confirm.
