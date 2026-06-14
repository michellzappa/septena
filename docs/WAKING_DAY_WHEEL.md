# Waking-day boundary for the dashboard wheel

**Status:** BUILT 2026-06-14 (uncommitted; iOS + macOS + watchOS schemes green,
39 SeptenaCoreTests pass; not device-tested). **Scope:** presentation lens on the
day-dial only — explicitly *not* a redefinition of the app-wide day.

## What shipped

- `SeptenaCore/WakingDay.swift` — the pure resolver (no model deps), with
  `WakingDay+Oura.swift` as the `OuraNight` adapter. 11 unit tests in
  `SeptenaCoreTests/WakingDayTests.swift`.
- `dayKey(containing:)` returns the civil-midnight key of the waking day; layered
  sleep → `cutoffHour` (default 4) → midnight. `daysAgo(_:todayKey:)` for the
  wheel's recency rings.
- Wired into `TimeOfDayWheel.Event.init`, `RhythmData.load` (+ training/sleep
  band loaders), `DayDialHero`, `RhythmHomepageView`, and the (currently
  disabled) `RhythmSnapshotBuilder` for lockstep. The dashboard dials build a
  `WakingDay` from the loaded Oura nights; section-detail dials keep the legacy
  midnight default (`WakingDay(enabled: false)`).
- Toggle: `@AppStorage("wheel.wakingDay")`, default **on**, shared by both
  dashboard dials. **No Settings UI yet** — flip it via the key or add a row in
  Settings ▸ Home (next step).
- `RhythmHomepageView` reload now keys to `todayStart` (the waking key), so the
  dial rolls at wake/4am, not only at midnight. `DayDialHero` already keyed to
  `displayedStart`.

### Deferred from this spec
- **Dial rotation "wake at top."** The hero already rotates "now" to the top
  (`northFraction: nowFraction`), an orthogonal existing choice; wake-at-top
  would replace it and is left as a future option.
- `cutoffHour` is fixed at 4 for v1 (no per-user setting).

---

## Original design notes

## Problem

The dashboard wheel rolls over at calendar midnight. If you stay up past
midnight, at 00:01 the dial flips to a fresh empty day and everything you logged
"tonight" snaps to *yesterday*. For a night that runs 18:00 → 02:00 that reads as
broken — the evening you're still living in is split across two days.

The fix users actually want: the day on the wheel begins when you **wake**, not at
midnight. Late nights stay attached to the day they belong to; the empty sleep
arc becomes the natural seam in the ring.

## Non-goals (the blast radius we are deliberately NOT touching)

The whole point of this design is that it's cheap and safe because it stays a
presentation concern. We do **not** change:

- `DayClock.today` (the app-wide `YYYY-MM-DD` source of truth) — drives task
  "today" filters, day-rollover notifications, time-travel, the today-boolean
  retirement plan.
- **Deterministic day-keyed CloudKit ids** — activity day summaries, goal
  milestones, nutrition day summary. These MUST stay on calendar midnight or
  cross-device ids diverge and sync corrupts. This is the line we do not cross.
- Task scheduling / `isOnToday` semantics.

Shifting the task "today" to the waking day is a separate, larger decision. It
can come later, *after* the wheel proves the model out. This spec is the wheel
only.

## Where midnight lives today

| Location | Current behavior |
|---|---|
| [`DayDialHero.todayStart`](../Septena/Shell/Dashboard/DayDialHero.swift) | `Calendar.current.startOfDay(for:)` — midnight |
| [`TimeOfDayWheel.Event.init`](../Septena/Shell/UI/TimeOfDayWheel.swift) | `calendar.startOfDay(for: occurredAt)`, `daysAgo` from calendar-day distance |
| [`RhythmData.load()`](../Septena/Shell/Dashboard/RhythmHomepageView.swift) | passes `todayStart` to every Event/Band init |
| `RhythmSnapshotBuilder` | same `startOfDay` bucketing (watch/widget snapshot) |
| `RhythmHomepageView.sleepBands` / `calendarBands` | `startOfDay(for: d)` |

Wake data already exists and is already drawn (just not used as a boundary):
`OuraNight.bedtime` / `OuraNight.wakeTime` (`HH:mm` strings on a `YYYY-MM-DD`
date), rendered as the sleep arc.

## Design: a BoundaryResolver

Introduce one function that answers *"what instant does the waking day containing
`t` begin at?"* Everything on the wheel calls this instead of
`Calendar.startOfDay`.

```swift
// SeptenaCore — UI-free, testable, no SwiftData dependency.
struct WakingDay {
    /// Start instant of the waking day that contains `instant`.
    /// Layered fallback: confident main-sleep wake → fixed cutoff → midnight.
    static func start(
        containing instant: Date,
        wake: (Date) -> Date?,        // most recent confident wake at/before a day
        cutoffHour: Int = 4,          // fallback "4am" roll point
        calendar: Calendar = .current
    ) -> Date
}
```

### Resolution order

1. **Sleep-driven.** If there's a confident *main-sleep* wake time for the
   morning of `instant`'s civil day, the waking day starts there. An event at
   01:30 resolves to the day that began at *yesterday's* wake, because 01:30 is
   before this morning's wake → it belongs to the night before.
2. **Fixed cutoff (default 04:00).** No wearable, or sleep not synced yet. The
   day rolls at the cutoff hour. 02:00 is still "today"; 04:00+ is the new day.
   This is the habit-chain-app convention and the load-bearing fallback.
3. **Midnight.** Last-resort floor if even the cutoff is disabled.

### The two rules that are the whole game

These edge cases are where this design usually breaks. Decide them up front.

- **Naps must not reset the day.** "Wake" means the end of *main sleep*, not the
  most recent sleep. Heuristic: the longest sleep block that overlaps the
  night/early-morning and ends in the morning. A 20-minute afternoon nap is
  ignored for boundary purposes. (Oura already classifies long_sleep vs nap; use
  that when present, else apply the duration+time-of-day heuristic.)
- **Pre-sync mornings must degrade quietly.** You open the app at 07:00 before
  Oura has pushed last night. The resolver falls to the 04:00 cutoff and shows a
  correct-enough day. When sleep data lands minutes later and moves the boundary
  from 04:00 to your real 06:40 wake, the dial must **re-settle smoothly**, not
  visibly jump. Treat the boundary as observable state that can refine once; if
  it jumps hard, it reads as a bug. Prefer: animate, or only refine if the delta
  is small / the user hasn't interacted.

## Dial presentation

With wake anchoring the day, rotate the dial so **wake sits at the top** and the
sleep arc falls at the bottom as the seam. The empty night becomes the natural
break in the ring instead of an arbitrary midnight tick — this fits the
SolarClock night-arc already drawn. Event angles still come from each event's
real local hour/minute; only the *rotation offset* and the *day-membership
filter* change.

`daysAgo` is then computed as waking-day distance (how many waking-day boundaries
between the event's waking-day-start and today's), not calendar-day distance.

## Plumbing

- `WakingDay` + tests in SeptenaCore (pure, no UI).
- A small adapter that supplies the `wake:` closure from `OuraNight` (latest
  confident wake ≤ a given day), with a settings-backed `cutoffHour` and an
  on/off toggle (default on, cutoff 04:00).
- `DayDialHero` / `RhythmData` / `RhythmSnapshotBuilder` compute `todayStart` and
  per-event `daysAgo` via `WakingDay.start` instead of `Calendar.startOfDay`.
  Keep the same call shape so the diff is contained.
- Watch/widget snapshot (`RhythmSnapshotBuilder`) must use the identical resolver
  so the wheel agrees across surfaces — same single-source discipline as
  `NextBlocks` / `DayBucket`.

## Test matrix

- 23:30 and 01:30 of the same overnight resolve to the **same** waking day.
- 04:00+ with no sleep data → new day.
- Afternoon nap does not move the boundary.
- No `OuraNight` at all → behaves exactly as the 04:00 cutoff; never crashes.
- Pre-sync: boundary at 04:00 then refines to real wake → one smooth re-settle,
  no double-flip.
- Calendar-midnight-keyed ids (activity/nutrition/milestones) are unchanged.

## Open decisions

- Is `cutoffHour` user-configurable or fixed at 04:00 for v1? (Lean: fixed,
  expose later.)
- Does the wheel's "week" view also use waking-day `daysAgo`, or keep calendar
  rings for the multi-day overlay? (Lean: waking-day for consistency, but verify
  the recency fade still reads.)
- Eventually: promote the waking day to task "today"? Out of scope here.
