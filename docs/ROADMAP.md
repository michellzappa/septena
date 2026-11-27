# Roadmap

The order of work, by track and milestone. Each phase links its spec. Each
milestone has a matching GitHub milestone on `michellzappa/septena`; each phase
is one issue there. Update this file when the order changes. Rules:
`docs/README.md`.

**Last updated:** 2026-11-26 (added the Agent surface track, ADR 0050).

**Public roadmap.** An issue labelled `roadmap` appears on
`septena.app/roadmap`. Its public copy and feature ID live in the site repo,
`content/roadmap.json`; status and Now/Next/Later follow the issue's state and
milestone. When you add the label, add the copy there too (the site build fails
on a listed issue without the label). Feature IDs: Starlings Docs
`/product/feature-map-septena-task-app`.

## Tracks

| Track | Spec | Label |
|---|---|---|
| Backend — leave iCloud | `docs/SEPTASK_BACKEND.md`, ADR 0002, ADR 0011 | `track:backend` |
| Linked projects (Starlings) | `docs/LINKED_PROJECTS_SPEC.md`, ADR 0003 | `track:links` |
| Task references | `docs/TASK_REFERENCES_SPEC.md`, ADR 0031 | `track:links` |
| Task factory | `docs/TASK_FACTORY_SPEC.md`, ADR 0005, ADR 0008 | `track:factory` |
| Project sharing | `docs/PROJECT_SHARING_SPEC.md`, ADR 0004 | `track:sharing` |
| Switcher essentials, moving in & other clients (web, Android) | Starlings `/strategy/product-roadmap`, `docs/ANDROID_CLIENT_SPEC.md`, ADR 0016 sign-in | `track:clients` |
| Companion devices (watch, desk orb) | `docs/COMPANION_DEVICES_SPEC.md`, ADR 0034, ADR 0035 | `track:clients` |
| Task fade & user stats | `docs/TASK_FADE_SPEC.md` (ADR 0006), `docs/USER_STATS_SPEC.md` (ADR 0063) | `track:fade` |
| Do (one task now) | `docs/DO_SPEC.md`, ADR 0041 | `track:clients` |
| Project notes as agent context | `docs/PROJECT_NOTES_SPEC.md`, ADR 0012 | `track:factory` |
| Launch — Septena name, free tier, paid sync, rate lock | `docs/SYNC_SUBSCRIPTION_SPEC.md`, ADR 0007, ADR 0010 | `track:launch` |
| Agent surface — what agents read and call | `docs/AGENT_SURFACE_SPEC.md`, ADR 0050 | `track:agent-surface` |
| Engineering foundation — CI as the gate, the shared core, deploys | `docs/ENGINEERING_PLAN.md`, ADR 0025, ADR 0027 | `track:foundation` |

## Milestones

### F — Foundation: CI is the gate (`Now`, engineering)

GitHub milestone "F Foundation: CI is the gate". Order and reasons:
`docs/ENGINEERING_PLAN.md`. #342 backend CI, #343 deploy from CI (mz: API
token), #344 Android conformance and launch guard, #345 protected `main`
(mz: yes). Runs before new feature work lands on the core.

Everything after M1 depends on M1. Inside a milestone, items can run in
parallel unless an arrow says otherwise.

### M1 — Backend cutover (`Now`)

Split into M1.1–M1.10 (issues on GitHub, 2026-11-19). Phase 0 deployed,
phase 1 importer and phase 2 preview connector written.

- M1.1 (mz) first import · M1.2 (mz) shadow week
- M1.3 rollback writer · M1.4 TaskSyncClient → M1.5 route writes ·
  M1.6 live nudge · M1.7 Sign in with Apple at launch · M1.8 gateway on the DO
- M1.9 (mz) cutover → M1.10 cleanup

Exit: all task data on `api.septena.app`, apps and MCP on the backend.

### Launch — Septena on iPhone, iPad and Mac (`Now`)

GitHub milestone: `"Launch Septena (iPhone, iPad, Mac)"`, label `track:launch`.
The task app ships as **Septena** (ADR 0007). Needs M1. Runs before M2
*(default: ship first, agents and switchers next; mz can overrule)*.

- Support (ADR 0054, `docs/SUPPORT_SPEC.md`): #675 backend routes, #676
  native Contact Support on every client, Starlings envisioning/starlings#1430,
  site septena-site#41 and #42; #677 later.
- #32 done: App Store records "Septena" (`com.septena.tasks`) and
  "Septena Life" (`com.septena.cloud`) exist (ADR 0007).
- #80, #81, #82 done: faster cold launch (Today draws first).
- #45 (mz) create the two sync products in App Store Connect
- #44 P0 entitlement on the backend (needs M1 phase 0 auth)
- #46 P1 StoreKit purchase, paywall, lapsed state; tip jar out of the task app
  (needs #44, #39)
- #47 P2 free mode works with no account and no network
- #108 annual signup-rate protection (cohort price lock on Apple + Stripe;
  gates checkout guarantee copy on `/pricing`)
- #31 / #48 rename pass: user-facing "Septask" → "Septena", life OS →
  "Septena Life", in the apps, the MCP skill text and the App Store copy.
  Code identifiers stay.
- #50 / #107 site rewrite around the task app and pricing page (private site repo).
  Website expansion #105 with #106, #109–#113 (all in this milestone). Live on
  2026-11-21: footer, features and workflow pages, platform pages, help,
  pricing (marked planned), moving-in hub, comparison registry, `/llms.txt`.
  Open: per-agent guides (#112), source moving-in pages (#111, #135), footer
  update card (#106). #95 done: `/changelog` shows task-app updates.
- #49 (mz) trademark search for "Septena" (classes 9 and 42)
- #3 privacy copy for the iCloud exit
- #43 P3 Stripe for the web client waits for the web client (M3)
- #118 move septena.app and every Septena worker to a dedicated Cloudflare
  account (infrastructure, no milestone; must not start during a launch week)

Exit: a sandbox purchase turns on sync with protected annual renewal pricing,
the stores and the site say "Septena", and the trademark search is clear.

**Septena Life** (the life OS) is on the back burner: fixes only, no new
features, no backend move planned.

### M2 — Agent intake v0 & Switcher readiness (`Next`)

GitHub milestone: `"M2 Agent intake v0"`. Two parallel lanes immediately after
Launch, reflecting the 2026-11-20 product direction (*Things-like simplicity,
multiplatform access and an agentic UX*):

**Lane A — Switcher essentials, Moving in & Agent-first onboarding:**

Switcher features in build order (ranked by mz, 2026-11-21: does its absence
stop a switch, does it back a promise the site makes, how small is it):

1. #97 Timed reminders (specific time alerts, sync, MCP, import mapping)
2. #126 Richer repeats (yearly, specific weekdays, ordinal monthly)
3. #76 Checklists inside a task (compact UI, sync, MCP, import mapping)
4. #130 Data export (backs "your tasks never depend on us")
5. #132 iOS swipe actions
6. #96 Tags (compact UI, filter, sync, MCP, import mapping)
7. #129 Widgets (pair with #89 App Intents)
8. #127 Star / Important (waits on the urgency-marker decision)
9. #131 Mac attachment parity

M3, not M2: #133 natural-language capture, #134 email-to-task.
#128 start/end times and an iCal feed stays in M2 but last: it pulls toward
calendar planning, which the positioning rules out.

Alongside the features:
- #98 Moving-in coverage tracker & #99 shared migration engine (preview, field
  mapping, loss report, counts reconciliation, retry, batch undo; audit existing
  Things/Reminders paths)
- #52 Microsoft To Do importer on `#99` (direct read-only Graph API v1.0;
  To Do closes 30 June 2027)
- #103 Agent-first onboarding (invite agent connection on first run, propose
  real areas/projects/tasks/emoji for review before creating; reuses `#70`)

**Lane B — Agent loop, trust & directories:**
- #87 Agents propose done, only the human accepts (blocks shipping trust line)
- #85 Listed in Claude and ChatGPT connector directories
- #86 Named keys for agents that cannot sign in
- #71 Connected agents and last activity in Settings
- F0 claims/stop/pause (built 2026-11-19) + Agent smart list UI
- #5 F1 scheduled runner, push questions, wake on answer
- Task references, first release (`docs/TASK_REFERENCES_SPEC.md`, ADR 0031, ADR
  0033): #386 R0 core, store, MCP, old issue links → #387 R1 Mac, iPhone, iPad
- Agents are the integrations (ADR 0038, ADR 0039): #496 duplicate check →
  #497 turned-down items → #501 source prompts · #498 Slack keys · #499
  proposals expire · #500 filed suggestions
- Project notes as agent context (`docs/PROJECT_NOTES_SPEC.md`, ADR 0012):
  #120 N0 store rules and history → #121 N1 MCP tools and claim payload ·
  #122 N2 notes first in the app → #123 N3 proposals and history UI ·
  #124 N4 notes-first content for #103

Exit: a switcher brings their lists over with clear loss disclosure, connects
Claude on first run, assigns a task, answers a question from the phone, and
accepts the result with no device awake in between.

### AS — Agent surface (`Next`)

GitHub milestone: `"AS Agent surface"`. Spec: `docs/AGENT_SURFACE_SPEC.md`.
Contract phases (AS3 to AS7) are issues on this repo. Site phases are issues
on `michellzappa/septena-site`; the spec lists both. Order: AS1 first, AS3
before AS5, AS7 before AS12.

Exit: every public page answers as Markdown, the agent spec with schema and
vectors is public, a retried write is safe, and `/v1` has an OpenAPI file.

### M3 — The factory ships code, Web client & Source adapters (`Later`)

GitHub milestone: `"M3 Factory ships code"`.

- F2 work profiles, approval cards, `errand`, kill switch
- F3 `code` workflow on a project's repo, run log
- Shared cross-platform registries ([ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md),
  accepted; prerequisites to `#21`, `#20`, `#136`): `#141`–`#145` done (`registry/`
  with 9 JSON registries, Swift/TS codegen, `lint-design.sh` drift gate, and
  shared conformance fixtures)
- Shared Rust core ([ADR 0025](adr/0025-shared-rust-core.md), `docs/SHARED_CORE_SPEC.md`):
  done: #246 C0 spike, #251 C5 releases (`core-v0.1.0`, `core-v0.2.0`).
  In progress: #250 C4 Apple (fade and conversation rules on the core; next,
  list membership after mz's device check, then recurrence with the watch
  change). Waiting: #247 C1 Android and Windows (after #173), #248 C2 web
  client (after WB1), #249 C3 backend (first slice #271 fade, after #117;
  then #272 fade-aware MCP). Housekeeping: #276 Rust lint gate, #273 MCP docs.
- Sign-in beyond Apple (ADR 0016): #168 identity table, #169 email code,
  #170 device approval, #171 email on Apple accounts. Needed by every
  non-Apple client.
- #21 Web client on `api.septena.app` (`docs/WEB_CLIENT_SPEC.md`, phases WB0 to WB5) (Rank 4 first wave — reaches Windows,
  Linux and browsers first; #43 Stripe billing pairs here)
- #133 natural-language capture in titles · #134 email-to-task address
- Task references, later phases: #388 R2 forwarded mail, no duplicates (after
  #134) → #389 R3 new-reply mark · #390 R4 back-links, drag, Android, web
- #137 Sign in with Google, Microsoft or an email link (decided 2026-11-21):
  the web client, Android, Windows and self-hosting all need a way in that is
  not Sign in with Apple. Changes the "no email address" privacy promise.
- Rank 5 moving-in adapters on `#99`: #100 Todoist & TickTick (direct read-only
  OAuth APIs), #101 Superlist (verify export schema first), #102 OmniFocus 4
  (CSV/TaskPaper) & Any.do (guided fallback)

Exit: a note in Septena becomes a merged PR tested from `needs_verify`, the web
client syncs the same account, and core migration adapters pass real fixtures.

### M4 — Sharing, Starlings, Android & Self-hosting (`Later`)

GitHub milestone: `"M4 Sharing and Starlings"`.

- #10 S0 project store and replicas, #11 S1 share / invite / join / assign:
  MVP built 2026-11-25, ahead of the rest of M4 (mz). Needs #169 (email
  sign-in) for people with no Apple device.
- #12 L2 Starlings links, several workspaces, dedupe
- #20 Android client on `api.septena.app` (`docs/ANDROID_CLIENT_SPEC.md`,
  phases #172 to #176; its Kotlin core #173 is Windows W0)
- #119 Self-hostable backend on the user's own Cloudflare account (ADR 0011)

Exit: a shared project with one other person, a Starlings project linked next
to its GitHub repo with no duplicates, Android on the same backend, and a
documented self-host server URL option.

### M5 — Breadth (`Later`)

GitHub milestone: `"M5 Breadth"`.

- #136 Windows client, Compose for Desktop on the Android Kotlin code
  ([ADR 0013](adr/0013-native-windows-app-on-the-android-code.md)):
  W0 shared Kotlin core → W1 Cloud PC spike → W2 first release scope →
  W3 signed installer and Store → W4 parity ledger. Starts after the #20 spike.
- L3 notes / deadline sync, "Send to Starlings" · L4 moves across lists (not
  GitHub, ADR 0033)
- S2 viewer role, activity, assignment push · S3 agents on shared projects
- F4 `factory-day` routes questions to Septena; daily digest
- #28, #53–#56 Task fade (T1–T4: touch/defer, weekly sweep, carry-over, stuck
  question, done-first week)
- User stats & foundations (`docs/USER_STATS_SPEC.md`, ADR 0063, held off
  `ready-for-agent`): #817 ST0 core + `registry/stats.json` → #820 ST1
  `stat_days` store, sync & export → #56 ST2 Weekly Reflection → #818 ST3
  Logbook Rhythm (open defaults: #819)
- #88 Packaged agent installs (Claude Code, Gemini CLI, OpenClaw)
- #89 Siri, Shortcuts and App Intents · #90 Public API with keys
- Companion devices: #430 CD0 added feed · #424 CD1 needs-you feed → #358 CD2 limited session →
  #425 CD3 live nudge · #426 CD4 voice (later)
- Do (`docs/DO_SPEC.md`, ADR 0041): #515 D0 core → #516 D1 store → #517 D2 iPhone, iPad,
  Mac, Android · #518 D3 watch · tinyseptena#18 D4 orb → #519 D5 Live Activity · #520 D6 Review ·
  #521 D7 agent proposal · #522 D8 web
- #65 Apple Watch · #51 Capture AI · #72–#74 Polish (drag to create, logbook by
  date, accessibility) · Public web links for projects (S4)

## Factory intake order (`ready-for-agent`)

Keep `ready-for-agent` focused on Launch and M2 so automated runs do not pull
M5 breadth items ahead of Launch and switcher readiness:

1. **Build now (already specced):** `#46`, `#47` (paywall + free mode), `#87`
   (agents propose done), `#85` (directories, once free-tier agent policy is set).
2. **Switcher features, in Lane A rank order:** `#97` (timed reminders) →
   `#126` (richer repeats) → `#76` (checklists) → `#130` (export) → `#132`
   (swipe actions) → `#96` (tags) → `#129` (widgets) → `#127` (star) → `#131`
   (Mac attachments) → `#128` (times and iCal). Pick the highest-ranked one
   whose spec is ready. `#133` and `#134` are M3 work: take them only after
   Lane A.
3. **Spec first, then add `ready-for-agent`:** `#108` (annual rate lock) →
   `#99` + `#52` (migration engine + Microsoft To Do) → `#103` (agent-first
   onboarding).
4. **Hold off `ready-for-agent` until M3–M5:** `#28`, `#53`–`#56` (Task Fade),
   `#65` (Watch), `#20`, `#21` (until specs are written for M3/M4).
5. **Shared core (ADR 0025):** an issue gets `ready-for-agent` when its
   blocker closes, never before: `#247` after `#173`, `#248` after WB1 of
   `#21`, `#271` after `#117`, `#272` after `#271`, the next `#250` step after
   mz's device check. Unblocked housekeeping (`#276`) can run any time; it
   touches only `core/` and CI. Every core change is gated by `core.yml`;
   agents never install Rust (`AGENTS.md`).

## Decisions waiting for mz

Each spec ends in an "Open questions" table with defaults. Silence means the
default stands. One GitHub issue per spec, labeled `needs-mz`, collects them.
Current strategic calls open in Starlings `/strategy/product-roadmap`:
free-tier agent call limits (for `#85` / `#103`), `Important/priority` and
`My Day` semantics (for `#99` / `#52`), and `#108` rate-lock cohort mechanics.
