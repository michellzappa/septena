# Haptics

Status: **building** (H1–H4 landed 2026-11-23; H5 open). Rests on no ADR.

How Septena uses haptics on iPhone, iPad, Mac and Apple Watch: one
vocabulary of meanings, one place that maps a meaning to a feel, and the
current Apple API for each platform.

## 1. Why this spec exists

An audit on 2026-11-23 found:

- 140 imperative call sites through `SeptenaCore/Haptics.swift`. 96 of them
  played `tick()`, a medium impact, for every kind of event: menu picks,
  navigation, renames, saves. A completion, a selection and a write felt the
  same.
- Generators were built with the view-less initializers, which the iOS SDK
  marks "to be deprecated" in favour of `init(view:)` (iOS 17.5).
- No use of SwiftUI's `.sensoryFeedback`, which has been the declarative API
  since iOS 17 and gained `.selection(.on/.off)`, `.press(_:)` and
  `.release(_:)` in iOS 26.
- The CoreHaptics engine ran with audio support and never shut down. Its
  reset handler restarted a dead engine instead of rebuilding it.
- `Haptics.aiGeneration()` had no caller.

**What the iOS 27.2 SDK adds.** Checked against the headers of Xcode's
iPhoneOS27.2 SDK: nothing new for haptics since iOS 26. The newest API is the
iOS 26 `SensoryFeedback` additions above, and the iOS 17.5 view-anchored
UIKit generators (`init(view:)`, `impactOccurred(at:)`,
`UICanvasFeedbackGenerator`). The deployment target is 26.0, so all of it is
available with no `#available` checks.

## 2. The vocabulary

Pick the verb by what the gesture **means**. The feel is decided once, in
`Haptics.swift`.

| Verb | Meaning | Examples | iOS feel |
|---|---|---|---|
| `press()` | A touch that starts something | Lift a drag, open the composer, open a When or Move sheet, Magic Plus | soft impact |
| `selection()` | Choose among options; move between targets | Picker row, calendar day, fold or unfold a section, drag over a new drop target, touch-select a row, navigation | selection |
| `commit()` | A write landed | Rename, schedule, move, reorder, star, add, copy, duplicate, restore, reply | light impact |
| `threshold()` | A gesture crossed its commit point | Pull-to-add armed, spring-load fired | medium impact |
| `success()` | Something finished | Project done, review accepted, task completed from a menu, the planned length of a Do | success notification |
| `warning()` | A destructive or cancelling write | Delete, delete permanently, cancel, let faded tasks go, clear the logbook | warning notification |
| `play(_:)` | A composed pattern | Task checkbox stamp, commit flourishes (`CommitMotion`) | CoreHaptics |

`Haptics.projectStatusChanged(to:)` maps a project status to `success`,
`warning` or `commit`, so the sidebar and the project page cannot disagree.

Rules:

1. **Meaning, not strength.** Never choose a verb because it "feels right
   here". If no verb fits, the gesture probably needs no haptic.
2. **Clearing a value is a `commit`, not a `warning`.** Clearing a date or a
   reminder destroys nothing.
3. **Accepting an agent proposal is a `commit`** (it files the task on
   Today). Accepting a *review* completes the task, so it is a `success`.
4. **Draft edits are a `selection`.** Starring a draft, picking a duration
   preset or applying a parsed token changes the composer, not the store.
5. **Opening a sheet is a `press`.** Its write plays its own `commit` later.

## 3. Declarative or imperative

- **Local view state** (a filter chip, a toolbar toggle) uses SwiftUI's
  `.sensoryFeedback(_:trigger:)` on the view, with the same meaning table.
  Binary toggles use the iOS 26 `.selection(.on)` / `.selection(.off)`.
  Implemented: the tag/star filter bar in `TaskListView` and
  `StarFilterToolbarButton`.
- **Task data never drives `.sensoryFeedback`.** Sync, undo and the watch
  change task data too. The phone must not buzz for a write the user did not
  make. Writes play an imperative verb at the user gesture, the same rule as
  undo (`AGENTS.md`, "Undo is ONE shared stack").
- **Everything else** calls a `Haptics` verb at the gesture.

## 4. Platforms

- **iOS / iPadOS.** UIKit generators built with `init(view:)` on the key
  window of the foreground-active scene. The bank moves when another window
  becomes key and detaches from the old one. With no foreground window (an
  App Intent in the background) a verb does nothing. iPads without a Taptic
  Engine ignore every call.
- **CoreHaptics** (`play`). `playsHapticsOnly = true` (no audio session
  work), `isAutoShutdownEnabled = true` (the engine powers down when idle).
  A reset or stop drops the cached engine; the next `play` builds a new one.
  Auto-shutdown can delay the first beat after idle; see §6.
- **macOS.** No haptics on purpose. The Mac HIG keeps haptics for force
  clicks and for dragging onto alignment guides. The Force Touch trackpad
  already answers every click, and Septena has neither guides nor
  force-click actions. The verbs compile to no-ops. `.sensoryFeedback` sites
  are left to SwiftUI's own platform mapping.
- **watchOS.** `SeptaskWatch/WatchStore.swift` calls
  `WKInterfaceDevice.current().play(_:)`. That is the current watch API, and
  its mapping (`success` for complete and add, `click` for moves and cancel,
  `retry` for undo) matches the table above. No change.

## 5. Enforcement

`scripts/lint-design.sh` rule `haptics-direct-generator` fails the build on
any `UI…FeedbackGenerator` or `CHHapticEngine(` outside
`SeptenaCore/Haptics.swift`.

## 6. Plan

| Phase | Work | State |
|---|---|---|
| H1 | Rewrite `Haptics.swift`: verbs, window-anchored generators, `@MainActor`, CoreHaptics engine settings, delete `aiGeneration` | done |
| H2 | Remap every call site by meaning (§2) | done |
| H3 | `.sensoryFeedback` for local filter state (§3) | done |
| H4 | Lint rule, this spec, DesignSpec pointer | done |
| H5 | mz tests on iPhone: completion stamp timing after idle (auto-shutdown), the filter on/off feel, commit vs. press vs. threshold. Tune feels in `Haptics.swift` only | open |

## 7. Open questions

| Question | Default if silent |
|---|---|
| Should navigation (`NavigationState.go`) play anything? System apps do not. | `selection()`, the lightest feel |
| A user setting to turn haptics off in the app? | No. iOS Settings ▸ Sounds & Haptics ▸ System Haptics silences the UIKit verbs; unverified for `play` patterns |
