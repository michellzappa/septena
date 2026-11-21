# Roadmap

The order of work, by track and milestone. Each phase links its spec. Each
milestone has a matching GitHub milestone on `michellzappa/septena`; each phase
is one issue there. Update this file when the order changes. Rules:
`docs/README.md`.

**Last updated:** 2026-11-21 (reconciled with Starlings Docs `/strategy/product-roadmap` and ADR 0011).

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
| Linked projects | `docs/LINKED_PROJECTS_SPEC.md`, ADR 0003 | `track:links` |
| Task factory | `docs/TASK_FACTORY_SPEC.md`, ADR 0005, ADR 0008 | `track:factory` |
| Project sharing | `docs/PROJECT_SHARING_SPEC.md`, ADR 0004 | `track:sharing` |
| Switcher essentials, moving in & other clients (web, Android) | Starlings `/strategy/product-roadmap`, `docs/SEPTASK_ANDROID_PLAN.md` | `track:clients` |
| Task fade | `docs/TASK_FADE_SPEC.md`, ADR 0006 | `track:fade` |
| Project notes as agent context | `docs/PROJECT_NOTES_SPEC.md`, ADR 0012 | `track:factory` |
| Launch — Septena name, free tier, paid sync, rate lock | `docs/SYNC_SUBSCRIPTION_SPEC.md`, ADR 0007, ADR 0010 | `track:launch` |

## Milestones

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
- #50 / #107 site rewrite around the task app and pricing page (private site repo)
- #49 (mz) trademark search for "Septena" (classes 9 and 42)
- #3 privacy copy for the iCloud exit
- #43 P3 Stripe for the web client waits for the web client (M3)

Exit: a sandbox purchase turns on sync with protected annual renewal pricing,
the stores and the site say "Septena", and the trademark search is clear.

**Septena Life** (the life OS) is on the back burner: fixes only, no new
features, no backend move planned.

### M2 — Agent intake v0 & Switcher readiness (`Next`)

GitHub milestone: `"M2 Agent intake v0"`. Two parallel lanes immediately after
Launch, reflecting the 2026-11-20 product direction (*Things-like simplicity,
multiplatform access and an agentic UX*):

**Lane A — Switcher essentials, Moving in & Agent-first onboarding (Ranks 1–3):**
- #76 Checklists inside a task (compact UI, sync, MCP, import mapping)
- #96 Tags (compact UI, filter, sync, MCP, import mapping)
- #97 Timed reminders (specific time alerts, sync, MCP, import mapping)
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
- #6 L0 GitHub links (read-only) → #7 L1 GitHub write-back
- Project notes as agent context (`docs/PROJECT_NOTES_SPEC.md`, ADR 0012):
  #120 N0 store rules and history → #121 N1 MCP tools and claim payload ·
  #122 N2 notes first in the app → #123 N3 proposals and history UI ·
  #124 N4 notes-first content for #103

Exit: a switcher brings their lists over with clear loss disclosure, connects
Claude on first run, assigns a task, answers a question from the phone, and
accepts the result with no device awake in between.

### M3 — The factory ships code, Web client & Source adapters (`Later`)

GitHub milestone: `"M3 Factory ships code"`.

- F2 work profiles, approval cards, `errand`, kill switch
- F3 `code` workflow on linked repos, run log (needs L0–L1)
- #21 Web client on `api.septena.app` (Rank 4 first wave — reaches Windows,
  Linux and browsers first; #43 Stripe billing pairs here)
- Rank 5 moving-in adapters on `#99`: #100 Todoist & TickTick (direct read-only
  OAuth APIs), #101 Superlist (verify export schema first), #102 OmniFocus 4
  (CSV/TaskPaper) & Any.do (guided fallback)

Exit: a note in Septena becomes a merged PR tested from `needs_verify`, the web
client syncs the same account, and core migration adapters pass real fixtures.

### M4 — Sharing, Starlings, Android & Self-hosting (`Later`)

GitHub milestone: `"M4 Sharing and Starlings"`.

- #10 S0 project store, relay, local store-scoped keys
- #11 S1 share / invite / accept UI
- #12 L2 Starlings links, several workspaces, dedupe
- #20 Android client on `api.septena.app` (rewrite `docs/SEPTASK_ANDROID_PLAN.md`
  on the backend)
- #119 Self-hostable backend on the user's own Cloudflare account (ADR 0011)

Exit: a shared project with one other person, a Starlings project linked next
to its GitHub repo with no duplicates, Android on the same backend, and a
documented self-host server URL option.

### M5 — Breadth (`Later`)

GitHub milestone: `"M5 Breadth"`.

- #136 Windows client, Compose for Desktop on the Android Kotlin code
  ([ADR 0013](adr/0013-native-windows-app-on-the-android-code.md), proposed):
  W0 shared Kotlin core → W1 Cloud PC spike → W2 first release scope →
  W3 signed installer and Store → W4 parity ledger. Starts after the #20 spike.
- L3 notes / deadline sync, "Send to…" · L4 moves across lists
- #15 L5 capture feeds (Gmail first) · #16 L6 Linear
- S2 viewer role, activity, assignment push · S3 agents on shared projects
- F4 `factory-day` routes questions to Septena; daily digest
- #28, #53–#56 Task fade (T1–T4: touch/defer, weekly sweep, carry-over, stuck
  question, done-first week)
- #88 Packaged agent installs (Claude Code, Gemini CLI, OpenClaw)
- #89 Siri, Shortcuts and App Intents · #90 Public API with keys
- #65 Apple Watch · #51 Capture AI · #72–#74 Polish (drag to create, logbook by
  date, accessibility) · Public web links for projects (S4)

## Factory intake order (`ready-for-agent`)

Keep `ready-for-agent` focused on Launch and M2 so automated runs do not pull
M5 breadth items ahead of Launch and switcher readiness:

1. **Build now (already specced):** `#46`, `#47` (paywall + free mode), `#87`
   (agents propose done), `#85` (directories, once free-tier agent policy is set).
2. **Spec first, then add `ready-for-agent`:** `#108` (annual rate lock) →
   `#76` (Checklists), `#96` (Tags), `#97` (Timed reminders) → `#99` + `#52`
   (migration engine + Microsoft To Do) → `#103` (agent-first onboarding).
3. **Hold off `ready-for-agent` until M3–M5:** `#28`, `#53`–`#56` (Task Fade),
   `#65` (Watch), `#20`, `#21` (until specs are written for M3/M4).

## Decisions waiting for mz

Each spec ends in an "Open questions" table with defaults. Silence means the
default stands. One GitHub issue per spec, labeled `needs-mz`, collects them.
Current strategic calls open in Starlings `/strategy/product-roadmap`:
free-tier agent call limits (for `#85` / `#103`), `Important/priority` and
`My Day` semantics (for `#99` / `#52`), and `#108` rate-lock cohort mechanics.
