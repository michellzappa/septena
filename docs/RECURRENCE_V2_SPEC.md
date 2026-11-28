# Richer recurrence rules (V2) — spec

**Status:** proposal (2026-11-21). Defaults in §9 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `registry/entities.json`, `registry/conformance/recurrence.json`, `backend/src/recurrence.ts`, `SeptenaCore/DateParser.swift` (`RecurrenceDateCalculator`), `SeptenaCore/Models.swift` (`Recurrence`), `SeptenaCore/Persistence.swift`, `Septask/SeptaskKitDatePopover.swift`, `Septena/Shell/Tasks/TaskPickerSheets.swift`.
**Tracking issue:** [#126](https://github.com/septena/septena/issues/126).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Extend Septena's task recurrence model from `{day, week, month} × interval` to cover the real-world cadences people rely on and bring from Things, Microsoft To Do, Todoist, TickTick, and Apple Reminders:

1. **Yearly** (`unit: "year"`, e.g. annual renewals, birthdays, taxes).
2. **Specific weekdays** (e.g. weekdays Mon–Fri, Mon/Wed/Fri, every Tue & Thu, every 2 weeks on Mon/Thu).
3. **Monthly day-of-month & ordinal weekday** (e.g. 15th of every month, last day of every month, 1st Monday of every month, last Friday of every 3 months).

**UX / IA ideal (progressive disclosure):** Keep the default repeat picker just as calm as today (Daily · Weekly · Monthly · Yearly + After completion / On schedule). Reveal weekday pills and monthly day/ordinal selectors only when the user taps **"Custom…"** or selects Weekly/Monthly options in the expanded picker. Never turn the picker into a cron builder.

## 2. Backward compatibility & data model (ADR 0015)

All existing tasks have only `recurrenceUnit` (`day` | `week` | `month`), `recurrenceInterval`, and `recurrenceAfterCompletion`. Those continue to work identically with zero migration required.

### Registry updates (`registry/entities.json`)

1. Expand `enums.recurrenceUnit`:
   ```json
   "recurrenceUnit": ["day", "week", "month", "year"]
   ```
2. Add three nullable columns to `entities.task.columns`:

| Column | Kind | Format / Constraint | Meaning |
|---|---|---|---|
| `recurrenceWeekdays` | `json` | `int[]` sorted unique ISO-ish / Apple weekday numbers `1..7` (`1 = Sun, 2 = Mon, ..., 7 = Sat` — matching Swift `Calendar.component(.weekday)` and JS `Date.getUTCDay() + 1`), max 7 items, nullable | Used when `unit == "week"` and `afterCompletion == false`. Null or empty = legacy single-anchor weekly step (`interval * 7` days). |
| `recurrenceMonthDay` | `int` | `1..31` or `-1` (meaning "last day of month"), nullable | Used when `unit == "month"` (or `"year"`) and `afterCompletion == false`. Mutually exclusive with ordinal weekday. Null = legacy anchor-day behavior (including existing `keepMonthEnd` rule). |
| `recurrenceOrdinalWeekday` | `json` | `{ "ordinal": -1 \| 1 \| 2 \| 3 \| 4, "weekday": 1..7 }` (nullable) | Used when `unit == "month"` (or `"year"`) and `afterCompletion == false`. Example: `{ "ordinal": -1, "weekday": 6 }` = last Friday of the month (`6 = Friday`). Mutually exclusive with `recurrenceMonthDay`. |

*(Default: 1 = Sunday … 7 = Saturday across JSON, Swift, TypeScript, and Kotlin — matches existing `DateParser.swift` line 182 and Foundation `Calendar` without an extra translation layer. Validated explicitly by `registry/conformance/recurrence.json`.)*

### Invariants
- `afterCompletion == true` ignores `recurrenceWeekdays`, `recurrenceMonthDay`, and `recurrenceOrdinalWeekday` (completion-anchored rules always step purely from `completedOn` by `interval` units). UI clears/hides schedule-only sub-options when switched to "After completion".
- If both `recurrenceMonthDay` and `recurrenceOrdinalWeekday` are somehow set on an incoming wire row, `recurrenceOrdinalWeekday` takes precedence in the calculator and validation rejects setting both simultaneously on new writes.
- `occurrenceID(sourceTaskID, scheduled)` is **unchanged** (FNV-1a 64 over `"<sourceTaskID>|<scheduled>"`), so existing convergence guarantees hold automatically.

## 3. Exact date arithmetic (LOCKSTEP: Swift + TypeScript + future Kotlin)

Both `SeptenaCore/DateParser.swift` (`RecurrenceDateCalculator.nextDate`) and `backend/src/recurrence.ts` (`nextScheduledDate`) MUST produce byte-identical outputs on every vector in `registry/conformance/recurrence.json`:

### 3.1 `unit == "year"`
- Step = `max(1, interval)` years from `anchor`.
- **Leap day (Feb 29):**
  - On a **fixed schedule** (`!afterCompletion`), if the anchor is Feb 29 (or `recurrenceMonthDay == -1` in Feb), non-leap target years clamp to Feb 28; a subsequent leap year returns to Feb 29 only if `recurrenceMonthDay == 29` (or `keepMonthEnd` on Feb 28/29? **Explicit rule**: preserve `recurrenceMonthDay` when present: `monthDay = 29` in Feb yields Feb 28 in non-leap years and Feb 29 in leap years; without `recurrenceMonthDay`, Feb 29 + 1 year = Feb 28, matching `addMonths(anchor, step * 12, keepMonthEnd: false)` so a plain Feb 28 fixed yearly task never drifts to Feb 29 on leap years). *(default: explicit `monthDay` prevents Feb 28→29 drift while allowing Feb 29→28→29!)*
  - On `afterCompletion == true`, simply add `step` years, clamping Feb 29 → Feb 28 in non-leap years.
- If `recurrenceOrdinalWeekday` is set with `unit == "year"` (e.g. "4th Thursday of November"), advance `step` years keeping `anchor.month`, then resolve the `ordinal`-th `weekday` of that `(targetYear, anchor.month)`.

### 3.2 `unit == "week"` with `recurrenceWeekdays` (fixed schedule)
- Normalize `weekdays`: deduplicate, filter to `1..7`, sort ascending. If empty, fall back to legacy `addDays(anchor, step * 7)`.
- **Week boundary:** Define a rule's week starting on **Monday** (`ISO week`, Mon=2..Sun=1 mapped to Mon=0..Sun=6) *(default: ISO Monday-first week so "every 2 weeks on Sat & Sun" keeps the weekend together in the same week instead of splitting Sunday into the next week!)*.
- Advancing one slot from `current` (starting at `anchor`):
  1. Look for the next weekday in `weekdays` strictly later in the **same ISO week** as `current`. If found, that date is the next occurrence.
  2. Otherwise, jump forward `step` ISO weeks to the Monday of `(isoWeekStart(current) + step * 7 days)` and pick the **earliest** weekday in `weekdays` (in Mon→Sun order) within that target ISO week.
- Apply the existing catch-up loop (`while next <= completedOn`) with the 10,000-iteration guard rail.

### 3.3 `unit == "month"` with `recurrenceMonthDay` (fixed schedule)
- Step forward `step` calendar months from `(anchor.y, anchor.m)`.
- If `recurrenceMonthDay == -1`, day = `daysInMonth(targetY, targetM)`.
- Else (`1..31`), day = `min(recurrenceMonthDay, daysInMonth(targetY, targetM))`.
- Example: `recurrenceMonthDay = 31`, `interval = 1`: Jan 31 → Feb 28 → Mar 31 → Apr 30.
- Example: `recurrenceMonthDay = 28`, `interval = 1`: Feb 28 → Mar 28 (does NOT falsely snap to Mar 31, solving the legacy Feb 28 ambiguity!).

### 3.4 `unit == "month"` with `recurrenceOrdinalWeekday` (fixed schedule)
- Step forward `step` calendar months from `(anchor.y, anchor.m)`.
- Find all dates in `(targetY, targetM)` matching `weekday` (`1..7`).
- If `ordinal == -1`, pick the last match in that month.
- If `ordinal` is `1..4`, pick the 1-indexed `ordinal`-th match (guaranteed to exist in every Gregorian month since every month has at least 28 days = 4 full weeks).
- Apply the existing catch-up loop (`while next <= completedOn`).

### 3.5 Human-readable `shortLabel`
- Simple cases stay short: `"Daily"`, `"Weekly"`, `"Monthly"`, `"Yearly"`, `"Every 2 weeks"`.
- Special shorthand:
  - `week` + `interval == 1` + `[2, 3, 4, 5, 6]` → `"Weekdays"`
  - `week` + `interval == 1` + `[1, 7]` → `"Weekends"`
  - `week` + `interval == 1` + `[2, 4, 6]` → `"Mon, Wed, Fri"`
  - `week` + `interval == 2` + `[2, 4]` → `"Every 2 wks (Mon, Wed)"`
  - `month` + `monthDay == -1` → `"Last day of month"` (or `"Every 3 mos (last day)"`)
  - `month` + `ordinalWeekday == {-1, 6}` → `"Last Friday"` (or `"1st Monday"`)

## 4. Progressive-disclosure UI

### Mac (`SeptaskKitDatePopover.swift`, `SeptaskKitInspector.swift`)
- Default Repeat popover shows compact presets: **Daily**, **Weekdays**, **Weekly**, **Monthly**, **Yearly**, plus **After completion** toggle and **Custom…** disclosure button.
- Expanding **Custom…** reveals:
  - `Every [N] [Days | Weeks | Months | Years]`
  - When **Weeks** + Fixed schedule: 7 compact weekday toggle pills (`M T W T F S S`), zero clutter when hidden.
  - When **Months** + Fixed schedule: segmented choice `On day [15 / Last]` vs. `On the [1st..4th / Last] [Weekday]`.
  - Live one-line preview: `"Next: Fri, Dec 4"`.

### iPhone & iPad (`TaskPickerSheets.swift`, `TaskAttributeBar.swift`)
- Same preset strip + expandable Custom section inside `RecurrencePickerSheet`, writing through `TaskMutator.setRecurrence(id:recurrence:)` with a single `TaskUndo` entry.

## 5. MCP & Agent surface

- `tasks_list` / `tasks_get`: include `recurrence` fields (`recurrenceWeekdays`, `recurrenceMonthDay`, `recurrenceOrdinalWeekday`) when non-null.
- `tasks_create` / `tasks_update`: accept `recurrenceUnit` (`day` | `week` | `month` | `year`), `recurrenceInterval`, `recurrenceAfterCompletion`, `recurrenceWeekdays`, `recurrenceMonthDay`, `recurrenceOrdinalWeekday`.
- Completing a recurring task via `tasks_complete` on `api.septena.app` uses the updated `nextScheduledDate` and copies all new recurrence columns onto the spawned occurrence.

## 6. Importer & export mappings

| Source | Mapping |
|---|---|
| Things (`ThingsImport`) | Yearly (`unit: "year"`), weekly weekday bitmasks → `recurrenceWeekdays`, monthly day/last/ordinal → `recurrenceMonthDay` / `recurrenceOrdinalWeekday`. |
| Microsoft To Do (`#52`) | Graph `patternedRecurrence`: `daily`, `weekly` (+ `daysOfWeek`), `absoluteMonthly` (`dayOfMonth`), `relativeMonthly` (`index` + `daysOfWeek`), `absoluteYearly`, `relativeYearly`. |
| Todoist (`#100`) / TickTick (`#100`) | Standard weekday, monthly day/last, ordinal weekday, yearly rules; exotic rules (e.g. "every 3rd workday") disclosed in migration loss report (#99). |
| Apple Reminders | `EKRecurrenceRule` (`daily`, `weekly`, `monthly`, `yearly`, `daysOfTheWeek`, `daysOfTheMonth`, `setPositions`). |
| Export (`SeptaskDataTransfer.swift`) | Serialize all new recurrence columns losslessly in JSON and human-readable label in Markdown/CSV. |

## 7. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **RV0 — Registry, conformance & core arithmetic** | Update `registry/entities.json` & regenerate constants; expand `registry/conformance/recurrence.json` with 15+ vectors (yearly, leap day, weekdays, biweekly Mon/Thu, weekend ISO-week preservation, monthDay 31/28/-1, ordinal 1st Mon / last Fri, catch-up, exceptions); implement lockstep arithmetic in `backend/src/recurrence.ts`, `SeptenaCore/DateParser.swift`, `SeptenaCore/Models.swift`; update `backend/src/store/columns.ts`, `TaskStore`/MCP tools (`taskShared.ts`, `writeTasks.ts`), `Persistence.swift`, `Outbox.swift`, `TaskBackendMapping.swift`, `TaskSyncApply.swift`, `TaskHistory.swift`, `SeptaskDataTransfer.swift`. | None |
| **RV1 — Progressive-disclosure Repeat UI (Mac & iOS)** | Update Mac (`SeptaskKitDatePopover.swift`, `SeptaskKitInspector.swift`) and iOS/iPadOS (`TaskPickerSheets.swift`, `TaskAttributeBar.swift`) with Yearly, Weekdays preset, and collapsible Custom controls (weekday pills, monthly day/last, ordinal weekday) + live next-date preview. | RV0 |
| **RV2 — Things & Reminders importer fidelity** | Map yearly, weekday-set, and monthly day/ordinal rules in `ThingsImport` and `RemindersBridge`. | RV0 |

## 8. Verification

- `node scripts/gen-registries.mjs --check` passes.
- `node --test backend/test/conformance.test.ts` and `cd backend && ./node_modules/.bin/tsc --noEmit` pass.
- `scripts/build.sh SeptenaMac 'platform=macOS'` and `scripts/build.sh SeptaskMac 'platform=macOS'` both green.
- Manual test by mz: create "Weekdays", "Every 2 weeks Mon/Thu", "Last Friday of month", "Yearly on Feb 29", complete each and confirm spawned next date matches preview.

## 9. Open questions

| Question | Default |
|---|---|
| Weekday integer numbering on wire | `1 = Sunday … 7 = Saturday` (matches Swift `Calendar` & `DateParser.swift`) *(default)* |
| Week start for multi-week `recurrenceWeekdays` intervals | Monday (ISO week) so Sat+Sun stay in the same week *(default)* |
| Ordinal weekday `5th` option | Support `1..4` and `-1` (Last); no `"5th"` since most months lack a 5th weekday *(default)* |
| Max ordinal/weekday complexity | No compound multi-month / multi-weekday-ordinal rules (e.g. "Jan & Jul 1st Mon"); disclose as unsupported in importers *(default)* |
| Completing a fixed rule with `recurrenceMonthDay: 28` | Stays on the 28th every month (fixes legacy Feb 28 → Mar 31 snap ambiguity) *(default)* |
