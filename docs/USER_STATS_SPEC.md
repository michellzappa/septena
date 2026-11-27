# User stats — spec

**Status:** proposal (2026-11-27). Defaults marked *(default)* stand until mz overrules them in §9.
**Decisions:** [ADR 0063](adr/0063-user-stats-are-content-free-daily-counts.md), [ADR 0006](adr/0006-tasks-fade-by-default.md) (§8 done-first week), [ADR 0025](adr/0025-shared-rust-core.md) (shared Rust core), [ADR 0043](adr/0043-plus-links-and-a-counts-only-admin-page.md) & [ADR 0058](adr/0058-admin-growth-from-daily-snapshots-then-an-event-stream.md) (counts-only anonymity).
**Builds on:** `docs/TASK_FADE_SPEC.md` (§3, §8, #56), `docs/DAILY_REVIEW_SPEC.md` (§4, #618), `docs/DO_SPEC.md` (§1, §8, #520), `docs/DATA_EXPORT_SPEC.md`.
**Psychology reference:** `/strategy/why-people-keep-lists`, `/strategy/the-instrument-manifesto`, and `/strategy/user-stats-and-reflection` in Starlings Docs.

## 1. Goal

Help users build strong list foundations and better habits without gamification or guilt.

A streak is a fragile chain: one busy weekend or sick day resets it to zero and triggers abandonment. A foundation is bricks laid: taking a break never erases what you already built. Septena reinforces the four habits that actually keep a list calm — **capture out of your head, keep Today small, shrink what feels heavy, and let go regularly** — and reflects honest, durable progress.

**Hard bans (never ship):**
- No daily or weekly streaks ("longest streak", streak flames, vacation mode). Nothing ever resets to zero after a quiet day or week.
- No daily or weekly completion targets, quotas, Karma points, levels, or ranks.
- No red downward comparisons ("down 40% from last week") or peer percentiles.
- No guilt words (`overdue`, `behind`, `failed`, `missed`, `broken`, `streak`) — follows `/house/language`.
- No minute totals (`docs/DO_SPEC.md` §8) and no subjective pulse surveys.

## 2. Data model

One content-free daily counter table, `stat_days`:

| Column | Type | Meaning |
|---|---|---|
| `day` | `TEXT` (`YYYY-MM-DD`) | User's local day key (`homeTimezone` on server, `DayClock.today` on device) |
| `metric` | `TEXT` | Stable metric ID from `registry/stats.json` |
| `count` | `INTEGER` | Non-negative count for `(day, metric)` |

Primary key: `(day, metric)`. Rows with `count = 0` are omitted or deleted.

**Why content-free:** `stat_days` never stores task IDs, titles, notes, tags, areas, or project names. It is safe to export, survives 30-day task purges without retaining deleted task text, and costs ~2 KB per year of use.

## 3. Extensible metric registry (`registry/stats.json`)

Metrics live in one shared JSON registry generated into Swift, Kotlin, TypeScript, and Rust (`scripts/gen-registries.mjs`). Adding a metric requires no database migration.

Initial metric set *(default)*:

| Metric ID | Fired when (effective `before -> after` transition) | Undo / reverse | Surface role |
|---|---|---|---|
| `done` | Open task transitions to `status == "done"` | Reopening (`done -> open`) decrements `-1` on the original `completedAt` day | Primary (leads Weekly Reflection & Logbook) |
| `done_agent` | Subset of `done` where `endState == "agent_assisted_done"` (accepted from Review) | Same as `done` | Supporting note ("N with your agent") |
| `let_go` | Open task transitions to `status == "cancelled"` with `dropReason` (`"user"` or `"faded"`) | Reopening (`cancelled -> open`) decrements `-1` on the original `completedAt` day | Primary (sits beside `done` as an equal decision) |
| `sweep` | Weekly sweep finishes (`fadeSweptAt` advances to a new day) | None (max 1 per day) | Foundation counter (cumulative, never resets) |
| `wrap_up` | Daily review sheet completed (`dailyReviewDismissedOn` set via review, once #618 ships) | None (max 1 per day) | Foundation counter (cumulative, never resets) |
| `created` | Human inserts a non-heading task (`before == null`, `source != "mcp"`) | Deleting an untouched task on the same day decrements `-1` *(default)* | Secondary context (flow) |
| `created_agent` | Agent inserts a non-heading task (`before == null`, `source == "mcp"`) | Same as above | Secondary context (keeps agent intake separate from user capture) |
| `faded` | Open task transitions `fadedAt: null -> non-null` | Keeping it on the same day decrements `-1` | Quiet context (kept separate from `let_go` so initial fade passes do not distort user choices) |
| `deferred` | Open task transitions with `after.deferCount > before.deferCount` (increment only, never reset-to-0) | Undo reducing `deferCount` on the same day decrements `-1` | Quiet / secondary (never shown as a scolding failure count) |
| `worked_on` | `Do` session ends without completing the task (`exit` in `stopped`, `later`, `replaced`), counted at most once per task per day (when `Do` ships) | None | Supporting ("worked on, not finished") |

## 4. Rules in the shared core (`core/crates/septena-core`)

All transition and rollup math lives once in `core/crates/septena-core/src/stats.rs` with golden vectors in `registry/conformance/stats.json`:

1. **Effective transitions only.** `classify_task_transition(before, after, actor, local_day)` compares stored values before and after the write, never raw pushed field lists. A no-op write (such as repeated identical `fadedAt` pushes observed in live sync logs) emits zero deltas.
2. **Headings never count.** Any row with `kind == "heading"` emits zero deltas.
3. **Sync, recurrence spawn, and purge never fake activity.** Only real state transitions count; 30-day permanent purges emit zero deltas.
4. **Shared projects stay personal.** In `ProjectStore`, actions by other members (`member:...`) do not increment this user's `stat_days`.
5. **Local day key from one clock.** On the server, `day` comes from the transition's UTC instant converted to the account's `homeTimezone` (falling back to UTC when unset), avoiding naive local `completedAt` format drift. Offline devices use `DayClock.today`.
6. **Non-negative clamp.** Every update computes `max(0, count + delta)`.
7. **Foundations-first rollups (`summarize_stats`).** Returns:
   - **Period totals** (Mon-Sun weeks and calendar months) for `done`, `let_go`, `created`, `created_agent`, `done_agent`, `faded`, `worked_on`.
   - **Cumulative foundations** (all-time totals that never reset: `done`, `let_go`, `sweep`, `wrap_up`, plus rolling `"N of the last 4 weeks"` for sweeps).
   - **At most one quiet factual note** (deterministic, local, zero AI): e.g., freshness share from recent Logbook rows (*"Most tasks you finish get done within 3 days"*), lighter-list week (*"Finished N and let go of M"*), or shame-free return after ≥7 quiet days (*"Welcome back — your list waited"*). Never computes streaks, scores, or negative percentages.

## 5. Storage, sync, and privacy

- **Signed-in accounts:** `TaskStore.apply` calls `classify_task_transition` inside the same SQLite transaction as the entity write and updates `stat_days`. Clients pull `stat_days` read-only via sync (no multi-device double counting).
- **No-account / offline devices:** `TaskMutator` calls the exact same core function against a local `stat_days` table. On first sign-in, local buckets seed the empty server table once.
- **Backfill on upgrade:** One-time migration derives historical `created`, `created_agent`, `done`, `done_agent`, `let_go`, and `faded` from existing rows; `deferred`, `sweep`, and `wrap_up` accumulate from rollout forward.
- **Export, clear, and delete:** Included in free lossless JSON export (`DATA_EXPORT_SPEC.md`, table `stat_days`). A "Clear reflection stats" action wipes `stat_days` without touching tasks. Deleting an account deletes `stat_days`.
- **Admin / collective compatibility (ADR 0043, ADR 0058):** No new telemetry pipeline. Any future product-level aggregate (such as total tasks let go per week) uses the existing ADR 0043 / ADR 0058 counts-only `accountSummary` / daily snapshots / Workers Analytics Engine path, never with content and never shown back to users as peer comparisons.

## 6. User-facing surfaces

Progressive disclosure. Nothing is added to Today's chrome or sidebar badges.

1. **Weekly Reflection (Done-first week, #56):**
   - Shown at the top of the weekly sweep sheet and in Logbook's weekly header.
   - Leads with **Done** and **Let go** as equal decisions (plus **Worked on** when `Do` ships, and a quiet note if agents assisted).
   - Shows at most one calm factual note (never a streak or downward delta).
   - Quiet week (0-1 done): shows a warm, neutral line (*"A quiet week on your list."*), never an empty-bar failure state.
2. **Logbook Rhythm (optional, on demand):**
   - Compact collapsible header or sheet inside Logbook showing:
     - **Foundations** (cumulative, non-resetting: sweeps, let go, finished).
     - **Recent weeks** (last 8-12 weeks of Done and Let go as soft, equal-weight marks — no target line, no streak counter, no red drops).
     - **Quiet details** (expanded on tap): Captured (you / agents) and Moved (`deferred`).
3. **Settings toggle:**
   - `showReflectionStats` (synced bool, default `true`) in Settings ▸ Lists. Turning it off hides all stat headers cleanly without deleting `stat_days`.

*(Share cards such as "I let go of N tasks this month" and year-end letters are deferred to a later phase; `stat_days` already supports them with zero schema changes.)*

## 7. Validation on live account data (2026-11-27)

Tested read-only against mz's real Septena account (785 inspected tasks across Today, Anytime, Upcoming, Faded, Review, and the newest 500 of 1,807 completed tasks, plus 200 recent activity entries; entire `stat_days` export = 226 rows / 12.6 KB JSON):

- **Anti-streak proof:** Between 2026-11-14 and 2026-11-20, mz had three 0-done days (Sat, Mon, Wed) inside a 28-done week followed by a 119-done week. A streak counter would have broken three times in five days; weekly rhythm (27, 13, 52, 89 done over four weeks) reflects real human waves.
- **Self-knowledge proof:** 64% of completed tasks finished within 3 days and 84% within 14 days — validating the 14-day fade window directly from the user's own rhythm.
- **Agent separation:** In the trailing 7 days, 96 of 212 created tasks came from agents (Claude and ChatGPT). Separating `created` from `created_agent` keeps the summary accurate.
- **System-pass separation:** 118 untouched tasks faded in one initial pass on 2026-11-21 (vs 14 over the next six days). Separating `faded` from `let_go` prevents one-off hygiene passes from swamping user decisions.
- **Sync edge cases caught:** Live `tasks_history` showed repeated no-op `fadedAt` upserts (`changes: {}`), blank inline drafts updated seconds later with a title, first-time scheduling (`deferCount` unchanged at 0), and naive local `completedAt` strings alongside UTC `at` stamps. All four are handled directly by §4.

## 8. Roadmap & factory plan (phases and build tickets)

**Milestone:** `M5 Breadth` · **Track:** `track:fade` · **Intake rule:** Not labelled `ready-for-agent` until mz promotes it (per `docs/ROADMAP.md` factory intake order). Each phase becomes one GitHub issue in `septena/septena` (ST2 updates or replaces `#56`).

| Phase | Issue | Issue scope (What → Where → Done when) | Depends on |
|---|---|---|---|
| **ST0 — Core & registry** | #817 | **What:** Add `registry/stats.json` (metric catalog) + codegen in `scripts/gen-registries.mjs`; add `core/crates/septena-core/src/stats.rs` (`classify_task_transition`, `summarize_stats`) + WASM/UniFFI exports; add golden vectors in `registry/conformance/stats.json` covering all live-data edge cases (no-op `fadedAt`, blank drafts, `deferCount` increment vs reset, agent vs human, shared-member exclusion, undo clamp, Mon-Sun rollups, cumulative foundations). **Done when:** `core.yml` passes across Rust, Swift, JVM, and WASM harnesses; `gen-registries.mjs --check` passes; core release tagged & pinned (`scripts/core-pin.sh`). | none |
| **ST1 — Store, sync & export** | #820 | **What:** Add `stat_days` SQLite table to `backend/src/store/TaskStore.ts`, update atomically inside `TaskStore.apply` via core WASM using `homeTimezone`, expose read-only pull (`statDays=1` flag) + one-time backfill + `POST /v1/stats/clear`; add local `stat_days` mirror for offline/no-account clients (SwiftData, SQLDelight, IndexedDB) seeded on first sign-in; include `stat_days` in JSON export (`DATA_EXPORT_SPEC.md`) and account deletion. **Done when:** Backend tests cover backfill, multi-device no-double-count, undo reversal, clear, export round-trip, and account wipe; `tsc --noEmit` and client builds pass. | #817 (ST0) |
| **ST2 — Weekly Reflection** | #56 | **What:** Add `showReflectionStats` synced setting (`registry/settings.json`, `backend/src/store/columns.ts`, default `true`) + copy in `registry/surfaces.json` (humanized per `/house/language`); render Done + Let go + quiet note in Weekly Sweep header and Logbook weekly header across Apple (iOS/iPadOS/Mac AppKit), Android, and Web; handle quiet weeks and shame-free return without empty-bar guilt; include quick "I did this" unplanned log. **Done when:** All three shells render from `stat_days` + core rollup, Settings toggle hides headers without deleting data, `parity.yml` + `lint-design.sh` + platform builds pass. | #820 (ST1) |
| **ST3 — Logbook Rhythm** | #818 | **What:** Add compact on-demand Rhythm header/sheet in Logbook showing cumulative foundations (`sweep`, `wrap_up`, `let_go`, `done`), rolling 8-12 week wave view (soft equal-weight marks, no streaks/targets/red drops), and expandable Captured/Moved details; wire `wrap_up` counter once Daily Review (`#618`) ships and `worked_on` once Do (`#520`) ships; add "Clear reflection stats" in Settings ▸ Privacy & Data. **Done when:** All three shells match registry copy, zero banned streak/quota patterns, builds and `parity.yml` green. | #56 (ST2) |

## 9. Open questions for mz

Collected in #819 (`needs-mz`, silence = default stands after 7 days per `docs/agents/factory.md` §2.2):

| Question | Default |
|---|---|
| Milestone & priority | `M5 Breadth`, `track:fade`, held off `ready-for-agent` until mz promotes |
| Metric list in v1 | `done`, `done_agent`, `let_go`, `sweep`, `wrap_up`, `created`, `created_agent`, `faded`, `deferred` (+ `worked_on` with Do) |
| Weekly grouping in Logbook Rhythm | Monday to Sunday, using the user's `homeTimezone` / `DayClock` |
| Undo decrement on same-day delete of an untouched task | Yes, decrements `created` by 1 |
| `deferred` visibility | Quiet secondary line only in expanded Logbook details; never a headline number |
| Default for `showReflectionStats` | `true` (opt-out in Settings) |
| Quiet factual note in Weekly Reflection | Deterministic local core math only (no AI/LLM call, at most 1 line) |
