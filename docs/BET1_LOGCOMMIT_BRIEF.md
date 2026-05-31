# Bet 1 — System-wide "LogCommit" confirmation language

**Handoff brief for a fresh agent. Read this top to bottom before touching code.**
You have NO prior conversation context; everything you need is here.

Repo: `/Users/mz/Dev/septena-cloud` — SwiftUI app for iOS/macOS/watchOS,
CloudKit-backed, XcodeGen project (`project.yml` is source of truth).

---

## The idea (what you're building toward)

Every time the user logs something, the app should confirm it with a small
celebration whose *character matches what was logged* — the idea already
proven by the Mood meter (`Septena/Sections/Mood/MoodCommitAnimation.swift`,
where joy gets confetti, calm gets a slow bloom, etc.). Bet 1 generalizes that
one-section flourish into a reusable, app-wide "log confirmation language":

- caffeine → a warm **ripple**
- hydration → a water **drop**
- training → a **burst** (confetti)
- a habit streak crossing 7 / 30 / 100 → an **ignition** with the streak
  number popping in
- and the dashboard tiles should feel *alive* (press state + a pulse when a
  tile's value changes).

This reuses pieces that already exist: `ConfettiBurst`, the streak math, the
`.numericText()` digit transition, the 5-verb haptics, and the `Theme.Motion`
animation tokens.

---

## Status: what's DONE (committed on `main`)

**Phase 0 — Foundation** and **Phase 2 — Habit streak ignition** are complete,
build-clean, and runtime-verified (the app launches without crashing and the
wiring is in the live view tree).

Core file: **`Septena/Shell/UI/LogCommit.swift`**. It defines:

- `enum LogCommitStyle` — the choreography catalog. Currently two cases:
  `case burst(accent: Color)` and `case ignition(accent: Color, streak: Int)`.
  **You will ADD cases here** for Phase 1 (e.g. `.ripple`, `.drop`).
- `@MainActor @Observable final class LogCommitCenter` — the fire API.
  `func fire(_ style: LogCommitStyle)` bumps a `trigger` counter (same contract
  as `ConfettiBurst`). Injected into the environment at the app root.
- `struct LogCommitOverlay` — mounted ONCE at the root; watches the center and
  plays the style. **Reduce Motion is gated HERE, centrally** — when it's on,
  the visual is skipped entirely and only the call-site haptic + `A11y.announce`
  carry the confirmation. Do NOT re-gate inside individual animations.
- `private struct IgnitionView` — the streak-milestone animation (radiating
  rings + the streak number via `.numericText()`).
- `enum StreakMilestones { static let thresholds = [7, 30, 100, 365]; reached(_:) }`
- `enum HabitMilestoneStore` — `UserDefaults`-backed `[habitId: Int]` map so a
  milestone celebrates **once per crossing** (`lastCelebrated`, `setCelebrated`,
  `reconcile` which re-bases on un-toggle so re-earning re-celebrates).
- `func completeHabit(id:date:done:checklist:context:theme:logCommit:)` — the
  orchestrator foreground habit-toggle sites call instead of poking the mutator
  directly. `logCommit` is **optional** (`LogCommitCenter?`).

Supporting:
- `SeptenaCore/ChecklistMirror.swift` → `habitStreak(context:habitId:asOf:)`
  computes a single habit's current consecutive-done streak. NOTE the entity
  field is `habitID` (capital D). Reads are synchronous right after a toggle.
- Wired foreground habit-toggle sites (these celebrate streaks today):
  `Septena/Sections/Habits/HabitsDestinationView.swift` (~line 142, via
  `completeHabit`) and `Septena/Shell/Dashboard/NextItemsSection.swift`
  (`HabitRow`, ~line 558, inlined because the toggle lives on an `@Observable`
  model that can't reach `@Environment`).
- Injected live in **`Septena/App/App.swift`** (NOT `RootView.swift` — that file
  does not exist; do not look for it).

---

## ⚠️ CRITICAL GOTCHAS (learned the hard way — do not repeat)

1. **Environment injection ordering caused a boot crash.** `.environment(x)`
   only reaches the view it wraps and its descendants. `LogCommitOverlay` is
   attached with `.overlay { }` on `RootTabView()` and MUST be placed so it is a
   descendant of `.environment(logCommit)`. The working layout in `App.swift` is:
   ```swift
   RootTabView()
     .overlay { LogCommitOverlay() }   // innermost, BEFORE the env chain
     .environment(navigation)
     ... 
     .environment(logCommit)
   ```
   If you mount the overlay AFTER `.environment(logCommit)`, it falls outside the
   scope and crashes on the first frame with:
   `Fatal error: No Observable object of type LogCommitCenter found`.
   Keep the overlay innermost.

2. **Sheets / alternate hosts don't inherit the root environment.** Some views
   that read `LogCommitCenter` are also hosted in `.sheet`s (e.g. the
   Home-Screen-Quick-Action `pendingSection` sheet in `RootTabView.swift` renders
   `HabitsDestinationView`) and in the macOS/iPad split detail. SwiftUI does not
   reliably flow `.environment()` into those hosts. So views READ it optionally:
   `@Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?`
   and fire with `logCommit?.fire(...)`. **Any NEW view you wire must read it
   optionally too**, or re-inject the env at the sheet boundary. A required read
   in a non-inheriting host = instant crash.

3. **"It compiles" ≠ "it works".** A missing-environment crash is a RUNTIME
   error a build cannot catch. You MUST boot the simulator, launch the app, and
   confirm it stays alive + the log is clean before claiming anything is done.
   See the Verification section — this is non-negotiable.

4. **Keep `SeptenaCore` SwiftUI-free.** Mutators live in `SeptenaCore` and post
   `.septenaDataChanged` for *all* writes including remote syncs, backfills, and
   deletes. Do NOT fire celebrations from the mutator/notification layer — you'd
   celebrate a CloudKit pull or a deletion. Fire from the UI action site (where
   the haptic already fires), scoped to genuine user intent.

---

## What's LEFT to build

### Phase 1 — Consumable styles
Add `.ripple(accent:)` and `.drop(accent:)` cases to `LogCommitStyle`, build the
two small animations (model them on the existing mood quadrant animations and
`ConfettiBurst` — tasteful, single-accent, ~0.8–1.1s, self-cleaning), add the
branches in `LogCommitOverlay`, and fire them at the consumable log sites:

- **Caffeine**: logged from `EditCaffeineEntrySheet` (save → `CaffeineMutator`).
  Because this logs *inside a sheet*, fire the root overlay AFTER the sheet
  dismisses (a root overlay is covered by a presented sheet).
- **Hydration (water)**: `Septena/Shell/Sections/Plugins/HydrationPlugin.swift`
  `commit(ml:)` — a one-tap log, no sheet, fire immediately.
- **Training**: `SessionCompleteSheet.swift` already uses `ConfettiBurst`
  directly. Decide whether to route it through `LogCommitCenter.fire(.burst)`
  for consistency or leave it. (Re-verify current usage before changing.)

Pair every fire with the right haptic (`Haptics.success()` for completions,
`Haptics.tick()` for light logs) and an `A11y.announce("...")` so the
confirmation survives Reduce Motion / VoiceOver.

### Phase 3 — Alive dashboard
- A reusable `.pressFeedback()` modifier (scale ~0.97 on press, reduce-motion
  gated via the existing `.a11yAnimation` / `A11yMotion` helpers in
  `Septena/Shell/UI/Accessibility.swift`) applied to `ModuleTile`
  (`Septena/Shell/UI/ModuleTile.swift`). Tiles currently have no press state.
- A subtle value-change pulse on a tile when its stat changes (key the animation
  on the value, use `Theme.Motion.standard`). ModuleTile already uses
  `.numericText()` + `Theme.Motion.standard` at ~4 sites — match that pattern.

### Also worth doing
- Runtime-verify the streak ignition actually *plays* (log a habit to a 7-day
  streak in the sim and watch it fire) — Phase 2 is wired & crash-free but the
  animation itself hasn't been eyeballed.
- Minor DRY: the celebration logic is inlined in `NextItemsSection.HabitRow`
  (and was meant for `WeekDashboardView`, though that site does NOT currently
  celebrate — verify). Consider consolidating onto `completeHabit`.

---

## Conventions to follow

- **Animation tokens**: prefer `Theme.Motion.{standard,quick,expand}`
  (`Septena/Shell/UI/Theme.swift`) over hand-typed `.spring(...)` / `.easeOut`.
  Always apply motion through `.a11yAnimation(_:value:)` or `A11yMotion.run`
  so Reduce Motion suppresses it — EXCEPT inside `LogCommitOverlay`'s children,
  which are already gated at the overlay level (bare `withAnimation` is fine
  there, and the existing IgnitionView documents this).
- **Haptics** (`SeptenaCore/Haptics.swift`): 5-verb vocabulary —
  `tap / tick / pick / success / warning`. macOS is a no-op stub; call freely.
- **Accessibility** (`Septena/Shell/UI/Accessibility.swift`): `A11y.announce(_:)`
  for confirmations; `.a11yAnimation`, `A11yMotion.run`, `.a11yMinTapTarget`,
  the `A11yID` namespace.
- **ConfettiBurst** (`Septena/Shell/UI/ConfettiBurst.swift`): generic, ready to
  reuse — `ConfettiBurst(trigger:accent:count:duration:)`. It already
  self-gates on Reduce Motion.
- **Section accent**: `theme.color(for: "<sectionKey>")` where `theme` is
  `@Environment(SectionTheme.self)`. Section keys: `caffeine`, `hydration`,
  `training`, `habits`, etc.

---

## Verification (REQUIRED before claiming done)

```bash
cd /Users/mz/Dev/septena-cloud
pkill -9 -f xcodebuild 2>/dev/null            # clear any stale build-db lock
xcodegen generate                              # new files are globbed in; regen the project
xcodebuild -scheme Septena \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build 2>&1 | tail -5    # expect ** BUILD SUCCEEDED **
```

Then ACTUALLY RUN IT (a build does not catch env/runtime crashes):

```bash
SIM=$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')
[ -z "$SIM" ] && SIM=$(xcrun simctl list devices available | grep -E 'iPhone 1[56]' | head -1 | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()') && xcrun simctl boot "$SIM" && sleep 5
xcodebuild -scheme Septena -destination "id=$SIM" -configuration Debug -derivedDataPath /tmp/septena_dd build 2>&1 | tail -3
APP=$(find /tmp/septena_dd/Build/Products -name 'Septena.app' -type d | head -1)
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch --terminate-running-process "$SIM" com.septena.cloud
sleep 5
# ALIVE check — a PID number means it didn't crash on boot:
xcrun simctl spawn "$SIM" launchctl list | grep -i septena
# Scan for fatal errors:
xcrun simctl spawn "$SIM" log show --last 60s --predicate 'process == "Septena"' 2>/dev/null \
  | grep -iE 'Fatal error|No Observable|crash'   # expect NO output
```

Build notes:
- If you hit `database is locked`, run `pkill -9 -f xcodebuild` and rebuild.
- Bundle id is `com.septena.cloud`. CloudKit container `iCloud.com.septena.cloud`
  (the sim needs an iCloud account for full sync, but the app launches without).

---

## Quick file map

| What | Where |
|---|---|
| LogCommit core (you'll edit this most) | `Septena/Shell/UI/LogCommit.swift` |
| Root injection + overlay mount | `Septena/App/App.swift` (~lines 58–77) |
| Per-habit streak math | `SeptenaCore/ChecklistMirror.swift` (`habitStreak`) |
| Wired habit sites | `HabitsDestinationView.swift`, `NextItemsSection.swift` (HabitRow) |
| Mood animations (the template) | `Septena/Sections/Mood/MoodCommitAnimation.swift` |
| Reusable confetti | `Septena/Shell/UI/ConfettiBurst.swift` |
| Dashboard tiles (Phase 3) | `Septena/Shell/UI/ModuleTile.swift` |
| Animation/haptic/a11y tokens | `Theme.swift`, `Haptics.swift`, `Accessibility.swift` |
| Hydration log site | `Septena/Shell/Sections/Plugins/HydrationPlugin.swift` (`commit(ml:)`) |
| Caffeine log site | `EditCaffeineEntrySheet.swift` (save) |

**Scope discipline**: Bet 1 is celebration polish only. Don't refactor the
mutators, the section architecture, or navigation. Keep `SeptenaCore` free of
SwiftUI. Verify by running, not just building.
