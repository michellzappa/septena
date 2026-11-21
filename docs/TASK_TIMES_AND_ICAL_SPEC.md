# Optional start/end times, iCal feed & CalDAV exploration — spec

**Status:** proposal (2026-11-21). Defaults in §7 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0011](adr/0011-self-hostable-backend.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `registry/entities.json`, `docs/TIMED_REMINDERS_SPEC.md` (#97), `docs/RECURRENCE_V2_SPEC.md` (#126), `backend/src/`, `Septask/SeptaskKitDatePopover.swift`, `Septena/Shell/Tasks/CalendarEventRow.swift`.
**Tracking issue:** [#128](https://github.com/michellzappa/septena/issues/128).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Deliberately **skip** turning Septena into a complex in-app calendar time-blocking planner, while letting users who want time-of-day scheduling:
1. Optionally attach a **start time** and **end time (or duration)** to any scheduled task via progressive disclosure.
2. Subscribe to a **private read-only iCal (`.ics`) feed** generated from `api.septena.app` so scheduled/timed tasks show up directly inside Apple Calendar, Google Calendar, Outlook, or Fantastical.
3. Evaluate (before committing engineering) whether a **writable CalDAV server** on `api.septena.app` is worth building as Phase 2 so dragging/creating events in a calendar app writes back into Septena tasks.

## 2. Optional start/end time on tasks (ADR 0015)

Add three nullable columns to `entities.task.columns` in `registry/entities.json`:

| Column | Kind | Format / Constraint | Meaning |
|---|---|---|---|
| `startTime` | `text` | `HH:MM` (24-hour local wall clock, regex `^([01]\d|2[0-3]):[0-5]\d$`), nullable | Optional start time on `scheduled` date. Null = date-only all-day task (default). |
| `durationMinutes` | `int` | `min: 5, max: 1440` (5 min to 24h), nullable | Optional duration; `endTime = startTime + durationMinutes`. Storing duration instead of separate end date cleanly handles tasks crossing midnight and keeps rescheduling trivial *(default)*. |
| `timeZone` | `text` | IANA zone (max 64, nullable) | Null = floating local time (default); set only if user opts into a fixed zone, aligned with `#97`. |

### UX / IA (progressive disclosure)
- Date-only tasks show **zero** time UI.
- Inside the When popover (Mac) / Date sheet (iOS), a compact `"Add time"` link reveals `Start` (e.g. `14:00`) + optional `Duration` chips (`15m`, `30m`, `1h`, `2h`, `Custom`).
- In Today & Upcoming: timed tasks show their quiet time slot (`14:00–15:00`) and optionally interleave cleanly alongside read-only `CalendarEventRow` items in the Agenda header.
- Relationship to timed reminders (`#97`): setting `startTime` can offer a one-tap `"Remind at start"` toggle (off or on per user preference — *(default: opt-in toggle in the time row, never silently duplicating notifications)*).

## 3. Phase 1 — Private read-only iCal (`.ics`) subscription feed

- **Endpoint:** `GET /v1/ical/<secret-token>.ics` on `api.septena.app` (also works on self-hosted Workers per ADR 0011).
- **Token management:** User enables `"Calendar Feed (iCal)"` in Settings ▸ Connections (progressive disclosure — disabled by default). One tap creates an unguessable 32-byte base64url token and copies the `webcal://api.septena.app/v1/ical/<token>.ics` URL; one tap rotates/revokes it.
- **Mapping (RFC 5545):**
  - Default scope: open tasks with a `scheduled` date or `deadline` within `[today - 30d, today + 365d]` (configurable: `Timed tasks only` vs. `All dated tasks`, default `All dated tasks`).
  - Timed task (`scheduled` + `startTime`): `VEVENT` with `DTSTART`/`DTEND` (default 30 min if `durationMinutes == null`), `SUMMARY`, `DESCRIPTION` (notes + `septask://task/<id>` deep link), `UID: <taskId>@septena.app`, `SEQUENCE` from task `rev`.
  - Date-only task (`scheduled` or `deadline`, no `startTime`): all-day `VEVENT` (`VALUE=DATE`), prefixed cleanly (e.g. `⚑ <title>` for deadlines).
  - Caching: `ETag` keyed by `TaskStore` current `rev` + `Cache-Control: private, max-age=300` so calendar apps poll cheaply.

## 4. Phase 2 evaluation — Writable CalDAV server (decision gate for mz)

Before building CalDAV write-back, here is the realistic engineering trade-off on Cloudflare Workers + Durable Objects:

| Dimension | Read-only `.ics` feed (Phase 1) | Writable CalDAV server (Phase 2) |
|---|---|---|
| **Protocol surface** | Single `GET` endpoint (~250 LOC) | WebDAV + RFC 4791 (`OPTIONS`, `PROPFIND`, `REPORT`, `PUT`, `DELETE`, `sync-collection`, `ETag`/`If-Match`, XML multistatus parsing, `VEVENT` + `VTODO` round-trip) (~1,500–2,500 LOC) |
| **Client quirks** | Works universally across Apple Calendar, Google Calendar, Outlook, Fantastical | Apple Calendar, macOS `CalendarAgent`, Thunderbird, and DAVx5 each have strict/quirky `PROPFIND` depth, principal-discovery, and recurrence-override (`RECURRENCE-ID`) behaviors; Google Calendar does **not** support external CalDAV accounts at all |
| **Auth** | Single revocable URL token | HTTP Basic Auth with per-user App Password (since Sign in with Apple / OAuth isn't supported by native CalDAV clients) |
| **Conflict & data-loss risk** | Zero (read-only) | High unless carefully scoped: calendar clients strip unknown fields, mutate `RRULE`s into shapes Septena doesn't support, or delete events when users clear a calendar |
| **Value unlocked** | See Septena tasks in every calendar app (including Google Calendar!) | Drag a task block in Apple Calendar / Fantastical to reschedule its `scheduled` + `startTime` + `durationMinutes`, or create a new event in a "Septena" calendar that lands in Septena's Inbox/Today |

**Recommendation *(default)*:**
1. Ship **Phase 0 (optional `startTime` / `durationMinutes`)** and **Phase 1 (private `.ics` feed)** first — tiny footprint, works in Apple, Google, and Outlook Calendar immediately, zero data-loss risk.
2. Only greenlight **Phase 2 (CalDAV write-back)** as a **narrow, scoped VEVENT-only calendar** ("Septena Tasks" calendar where `PUT` creates/updates `title`, `scheduled`, `startTime`, `durationMinutes`, `notes` only, ignores unsupported `RRULE` rewrites, and maps `DELETE` to clearing `startTime`/`scheduled` rather than deleting the task!) **after mz confirms Phase 1 feels valuable enough to warrant CalDAV maintenance**.

## 5. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **IC0 — Optional `startTime` / `durationMinutes` schema & UI** | Add `startTime`, `durationMinutes`, `timeZone` to `registry/entities.json`, backend, MCP, SwiftData, and progressive-disclosure `"Add time"` controls on Mac & iOS. | `#97` TR0 (shares time-zone contract) |
| **IC1 — Private read-only `.ics` feed on `api.septena.app`** | Add token generation/rotation, RFC 5545 `.ics` generator with `ETag` caching on the Worker, and Settings ▸ Connections `"Calendar Feed"` UI. | IC0 |
| **IC2 — Scoped writable CalDAV endpoint (gated on mz decision)** | Narrow CalDAV server (`PROPFIND`/`REPORT`/`PUT`/`DELETE` with App Password) scoped strictly to `scheduled`/`startTime`/`durationMinutes`/`title`/`notes`. **Do not start until mz approves after IC1.** | IC1 + mz go-ahead |

## 6. Verification

- RFC 5545 validator test on generated `.ics` output (folding 75-octet lines, CRLF, escaping `,`/`;`/`\n`, timezone & all-day dates).
- `node scripts/gen-registries.mjs --check`, `backend` tests, `SeptenaMac` + `SeptaskMac` builds green.

## 7. Open questions

| Question | Default |
|---|---|
| End time storage | Store `durationMinutes` (`5..1440`) alongside `startTime` rather than separate end timestamp *(default)* |
| Default `.ics` duration when only `startTime` is set | 30 minutes *(default)* |
| Writable CalDAV server (IC2) | Hold behind mz decision gate after IC1 `.ics` feed ships *(default)* |
| Plan gating for `.ics` feed | Free account includes read-only `.ics` feed (server cost is negligible with ETag caching) *(default)* |
