# 0063. User stats are content-free daily counts, never streaks

- Status: proposed (2026-11-27)
- Date: 2026-11-27
- Deciders: mz
- Extends: [ADR 0006](0006-tasks-fade-by-default.md) (done-first week), [ADR 0025](0025-shared-rust-core.md) (shared Rust core), [ADR 0043](0043-plus-links-and-a-counts-only-admin-page.md) (counts only, never content), [ADR 0058](0058-admin-growth-from-daily-snapshots-then-an-event-stream.md) (daily snapshots and event stream)
- Spec: [USER_STATS_SPEC.md](../USER_STATS_SPEC.md)

## Context

Users expect some record of what they got through over time, and the done-first weekly view (`docs/TASK_FADE_SPEC.md` §8, #56) already needs counts of completed and let-go tasks. At the same time, our psychology research (`/strategy/why-people-keep-lists`, `/strategy/todo-competition-and-ai`) shows why streak-and-quota systems like Todoist Karma backfire: self-criticism increases procrastination, 41% of list items never finish, only 15% of completed work starts on a to-do list, and normal quiet days break streaks and trigger abandonment.

Current task rows also cannot answer simple history questions accurately on their own: `deferCount` resets to `0` on any non-defer edit, `fadedAt` clears when a user keeps a task, purged tasks leave the store after 30 days, and the `changes` log is plan-windowed and absent on no-account devices. Live account inspection on 2026-11-27 also showed three real-world traps: repeated no-op `fadedAt` writes in `changes`, large agent task intake alongside human capture, and mixed naive-local `completedAt` vs UTC timestamps.

## Decision

User stats are stored as one simple, extensible, content-free daily counter table (`stat_days`) per user:

```sql
(day TEXT NOT NULL, metric TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (day, metric))
```

- **Content-free by structure.** Rows hold only a local day key (`YYYY-MM-DD`, from `homeTimezone` / `DayClock.today`), a registered metric ID from `registry/stats.json`, and a non-negative integer. No task IDs, titles, notes, areas, or project names ever enter `stat_days`.
- **Extensible without migrations.** Adding a new counter is adding one entry to `registry/stats.json` and one transition rule in `core/crates/septena-core`; the table schema never changes.
- **One pure classifier in the shared core.** `classify_task_transition(before, after, actor, day)` in `septena-core` compares effective post-store values (ignoring no-op writes and other shared-project members). Signed-in accounts update `stat_days` atomically inside `TaskStore.apply` and pull it read-only; no-account devices update the same local table in `TaskMutator` using the exact same core function.
- **User-favoring by rule (foundations, not chains).** No streaks, no daily or weekly quotas, no points or ranks, no red downward comparisons, no peer percentiles, and no subjective survey prompts. Practice habits (`sweep`, `wrap_up`) and outcomes (`done`, `let_go`) accumulate as durable counts and rolling weekly rhythm that **never reset to zero** after a quiet day or break. Deferrals are recorded quietly and never shown as a scolding score. Users can hide stats in Settings, export them in JSON, or clear them.
- **Compatible with existing anonymity rules.** Any future product-level aggregate (e.g., weekly fade or let-go rates) uses the existing ADR 0043 / ADR 0058 counts-only path (`accountSummary` / daily snapshots / Workers Analytics Engine) with zero new telemetry infrastructure.

## Consequences

- Adding future humane signals (`worked_on`, `unplanned_done`, etc.) takes one registry entry and a core rule, with zero database migrations across five platforms.
- Signed-in multi-device accounts cannot double-count transitions because `TaskStore` is the single serializer; offline no-account devices stay exact using the same Rust core.
- Per-project or per-area breakdowns are not stored in `stat_days` (keeping it content-free); if ever needed, clients can compute them transiently from live Logbook rows.
- Historical data before rollout can be backfilled once for `created`, `done`, `let_go`, and `faded` from existing rows; `deferred` starts accumulating cleanly from rollout forward.

## Links

- `docs/USER_STATS_SPEC.md` (#817 ST0, #820 ST1, #56 ST2, #818 ST3, #819 defaults)
- `docs/TASK_FADE_SPEC.md` (§3, §8) · `docs/DAILY_REVIEW_SPEC.md` (§4) · `docs/DO_SPEC.md` (§1, §8)
- [ADR 0006](0006-tasks-fade-by-default.md) · [ADR 0025](0025-shared-rust-core.md) · [ADR 0043](0043-plus-links-and-a-counts-only-admin-page.md) · [ADR 0058](0058-admin-growth-from-daily-snapshots-then-an-event-stream.md)
- Starlings strategy note: `/strategy/user-stats-and-reflection` · `/strategy/why-people-keep-lists`
