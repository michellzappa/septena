# Roadmap

The order of work, by track and milestone. Each phase links its spec. Each
milestone has a matching GitHub milestone on `michellzappa/septena`; each phase
is one issue there. Update this file when the order changes. Rules:
`docs/README.md`.

**Last updated:** 2026-11-19.

## Tracks

| Track | Spec | Label |
|---|---|---|
| Backend — leave iCloud | `docs/SEPTASK_BACKEND.md`, ADR 0002 | `track:backend` |
| Linked projects | `docs/LINKED_PROJECTS_SPEC.md`, ADR 0003 | `track:links` |
| Task factory | `docs/TASK_FACTORY_SPEC.md`, ADR 0005 | `track:factory` |
| Project sharing | `docs/PROJECT_SHARING_SPEC.md`, ADR 0004 | `track:sharing` |
| Other clients (web, Android) | spec to rewrite on the backend | `track:clients` |
| Task fade | `docs/TASK_FADE_SPEC.md`, ADR 0006 | `track:fade` |
| Launch — Septena name and paid sync | `docs/SYNC_SUBSCRIPTION_SPEC.md`, ADR 0007 | `track:launch` |

## Milestones

Everything after M1 depends on M1. Inside a milestone, items can run in
parallel unless an arrow says otherwise.

### M1 — Backend cutover

Split into M1.1–M1.10 (issues on GitHub, 2026-11-19). Phase 0 deployed,
phase 1 importer and phase 2 preview connector written.

- M1.1 (mz) first import · M1.2 (mz) shadow week
- M1.3 rollback writer · M1.4 TaskSyncClient → M1.5 route writes ·
  M1.6 live nudge · M1.7 Sign in with Apple at launch · M1.8 gateway on the DO
- M1.9 (mz) cutover → M1.10 cleanup

Exit: all task data on `api.septena.app`, apps and MCP on the backend.

### Launch — Septena on iPhone, iPad and Mac

The task app ships as **Septena** (ADR 0007). Needs M1. Runs before M2
*(default: ship first, agents next; mz can overrule)*.

- Sync subscription: spec the paywall (StoreKit, what stays free, how the
  backend checks the entitlement), then build it
- Privacy copy for the iCloud exit
- No "Septask" in any user-facing string
- App Store rename, by mz in App Store Connect (ADR 0007, Consequences)

Exit: Septena is live on the App Store on iPhone, iPad and Mac, syncing
through `api.septena.app`.

**Septena Life** (the life OS) is on the back burner: fixes only, no new
features, no backend move planned.

### Launch track (runs next to M1–M2)

GitHub milestone: "Launch Septena (iPhone, iPad, Mac)", label `track:launch`.

- #32 done: App Store records "Septena" (`com.septena.tasks`) and
  "Septena Life" (`com.septena.cloud`) exist (ADR 0007).
- #45 (mz) create the two sync products in App Store Connect
- #44 P0 entitlement on the backend (needs M1 phase 0 auth)
- #46 P1 StoreKit purchase, paywall, lapsed state; tip jar out of the task app
  (needs #44, #39)
- #47 P2 free mode works with no account and no network
- #31 / #48 rename pass: user-facing "Septask" → "Septena", life OS →
  "Septena Life", in the apps, the MCP skill text and the App Store copy.
  Code identifiers stay.
- #50 site rewrite around the task app and a pricing page (private site repo)
- #49 (mz) trademark search for "Septena" (classes 9 and 42)
- #3 privacy copy for the iCloud exit
- #43 P3 Stripe for the web client waits for the web client (Later)

Exit: a sandbox purchase turns on sync, the stores and the site say
"Septena", and the trademark search is clear.

### M2 — Agent intake v0

- F0 claims, stages, Agent smart list
- F1 scheduled runner, push questions, wake on answer
- L0 GitHub links, read-only
- L1 GitHub write-back (complete / reopen / title)

Exit: mz assigns a note to Claude, answers its question from the phone, and
gets a result, with no device awake in between.

### M3 — The factory ships code

- F2 work profiles, approval cards, `errand`, kill switch
- F3 `code` workflow on linked repos, run log (needs L0–L1)

Exit: a note in Septask becomes a merged PR on this repo, and mz tests it from
the `needs_verify` list.

### M4 — Sharing and Starlings

- S0 project store, relay, local store-scoped keys
- S1 share / invite / accept UI
- L2 Starlings links, several workspaces, dedupe

Exit: a shared project with one other person, and a Starlings project linked
next to its GitHub repo with no duplicate items.

### M5 — Breadth

- L3 notes / deadline sync, "Send to…"
- L4 moves across lists
- L5 capture feeds (Gmail first)
- L6 Linear
- S2 viewer role, activity, assignment push
- S3 agents on shared projects, linked + shared
- F4 `factory-day` routes questions to Septask; daily digest
- T1 task fade P1: touch and defer fields, no UI change

### Later

- Web client on the backend (reaches every platform first).
- Android client: rewrite `docs/SEPTASK_ANDROID_PLAN.md` on the backend.
- Public web links for projects (`docs/PROJECT_SHARING_SPEC.md` S4).

## Decisions waiting for mz

Each spec ends in an "Open questions" table with defaults. Silence means the
default stands. One GitHub issue per spec, labeled `needs-mz`, collects them.
