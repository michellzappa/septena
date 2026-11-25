# Inbox Zero Motion

**Status:** shipped — historical (2026-11-25, #464) · **Date:** 2026-11-23 · **Issue:** [#298](https://github.com/michellzappa/septena/issues/298)

Rests on: [TRIAGE_BAND_SPEC.md](TRIAGE_BAND_SPEC.md) (the Inbox is a section on
Today, never its own list), the motion rules in `AGENTS.md` ("Motion is gated
centrally"), and the containment policy in `CommitFeedback.commit` (canvas
flourishes are for once-a-day moments).

## 1. What this is

A short, optional animation that plays when the user empties the Inbox section
on Today. The Inbox header's tray icon changes into a check mark that draws
itself, holds, and then settles into the empty tray. A matched haptic plays
with it. A setting turns it off.

It is local to the Inbox header. It is NOT a canvas flourish. The canvas is
reserved for the `.arc` (last Today task done, `TaskCelebration.completed`).
It plays at most once a day (§2a), so it stays a moment and does not become
noise.

## 2. Trigger

The animation plays when ALL of these are true:

1. The surface is Today (`filter == .today`).
2. The Inbox item count goes from ≥ 1 to 0. The count is the number the Inbox
   header shows: on iOS `renderedTodayInboxRows.count`
   (`TaskListView.triageSection`); on the Septask Mac shell the `count` that
   `triageBand(_:)` puts on the `.header(id: "inbox")` row (band plus pending
   Apple Reminders).
3. A user gesture on an Inbox row caused the drop, in this session. Gestures:
   complete (checkbox, ⌘K), move or file (menu, ⌘M, drag, filing-suggestion
   chip), move to Today when that removes it from the Inbox, schedule (When),
   delete or drop, and accept or import of a pending Apple Reminder.

It does NOT play when:

- a sync, a remote device, the MCP or an agent empties the Inbox;
- the list loads with an empty Inbox (launch, foregrounding, filter switch);
- a tag filter change hides the last Inbox row;
- the Inbox is folded (`inboxCollapsed`), because the header icon is the only
  thing on screen and the user did not act on a row;
- the same gesture also clears the last open Today task. Then only the `.arc`
  plays (one celebration per gesture, the larger one wins);
- it already played today (§2a).

### 2a. Once a day (decided by mz, 2026-11-23)

- The motion plays at most once per day per device. "Day" is the
  `DayClock.today` day, so day rollover and time travel work.
- Store the last day it played in `UserDefaults` (device scope, not synced),
  key `septena.ui.inboxZeroMotionLastDay`. Each device keeps its own budget.
- A run uses the day's budget when it starts. A run that an undo cancels
  (§5) still counts, so undo and redo cannot replay it.
- When the budget is used, a later Inbox zero that day gets no motion and no
  extra haptic. The VoiceOver announcement (§6) still posts every time.
- The budget check lives in the shared trigger helper (§8), next to the
  other §2 rules.

Implementation hint: record the gesture with the task id at the gesture site
(the same pattern as `model.noteCompleted`), and fire when the next reload
shows the count at 0 and that id is no longer in the Inbox. Do not detect the
trigger from a count change alone: §2 items 1–3 then fail for sync and tag
filters.

## 3. Choreography

The Inbox header stays on screen when the Inbox is empty (it carries the `+`
capture slot), so the motion happens inside the header. No row, section or
layout height animates beyond what the list already does.

| Time | What happens |
|---|---|
| 0 | The last row leaves with the existing settle animation (`SettleStore`, `Theme.Motion.settle`). The motion waits for the settle to end. |
| settle end | The header icon changes from the filled tray (`tray.full`) to a check mark with the SF Symbols replace content transition. The check mark draws on (SF Symbols 7 draw-on effect). The count goes to 0 with a numeric content transition. The haptic plays. |
| + ~0.9 s | The check mark changes back to the empty tray (`tray`) with the replace transition. The header is now at rest. |

Rules:

- Use only first-party APIs: `.contentTransition(.symbolEffect(.replace))`,
  `.symbolEffect(.drawOn)` or the equivalent iOS 26 / macOS 26 API, and
  `.contentTransition(.numericText())`. No custom drawing, no overlay, no
  confetti. On the AppKit Mac shell, `NSImageView`'s symbol-effect API.
- Gate the motion through `a11yAnimate` / `.a11yAnimation` (AGENTS.md motion
  rule). The symbol effects run only when the setting is on and Reduce Motion
  is off.
- The check mark uses the header's normal icon color. No accent fill, no new
  selection or highlight style (one-language rule, `docs/DesignSpec.md` §4.5).
- The deployment target is 26.0. Do not use an iOS 27-only API without an
  `#available` fallback. iOS 27 adds nothing this feature needs.

## 4. Haptic

Reuse `CheckFeel.tuck.hapticSpec()`: a low thud, then a softer close. Its
meaning ("put away, onto the pile") fits filing the last item. Play it at the
start of the check-mark draw. The haptic follows the same setting: off means
no extra haptic (the row gesture keeps its own haptic). macOS: no haptic.

## 5. Undo and interruption

- An undo (⌘Z, shake, three-finger undo) that brings a row back while the
  motion runs cancels the motion: the icon goes straight to `tray.full` and the
  count updates. No reverse animation.
- A new capture into the Inbox during the motion: the same rule applies.
- Leaving Today during the motion drops it. It does not replay on return.

## 6. Accessibility

- Reduce Motion on: no symbol effects. The icon swaps to the empty tray
  without animation. The haptic still plays (it is not motion).
- VoiceOver: post `A11y.announce("Inbox clear")` once when the trigger fires,
  also when the setting is off. The announcement is feedback, not decoration.
- The setting does not change what VoiceOver says.

## 7. Setting

A new registry setting, device scope (`registry/settings.json`):

- key `inboxZeroMotionEnabled`, storage key `septena.ui.inboxZeroMotion`,
  type bool, default `true` *(default)*, platforms `ios`, `ipados`, `macos`,
  `featureId` `settings.display`.
- Listed in Settings ▸ Display directly below "Completion animations", label
  "Inbox zero animation", detail "Play a short animation when you empty the
  Inbox."
- Strings go in `registry/l10n/en.json` and `registry/l10n/pt-BR.json`. Run
  `node scripts/gen-registries.mjs`; read the value through the generated
  `SettingsKey`.
- It is independent of "Completion animations" *(default)*: either can be off.

Android, web and Windows are out of scope. When a client adds the motion, it
adds its platform to the setting's `platforms` list.

## 8. Surfaces

| Surface | File | Work |
|---|---|---|
| Septask iOS / iPadOS (SwiftUI) | `Septena/Shell/Tasks/TaskListView.swift` (`inboxHeader`, `foldableSectionHeader`, the toggle / move / delete paths) | Trigger, header icon motion, haptic, announce. |
| Septask Mac (AppKit) | `Septask/SeptaskKitTaskList.swift` (`triageBand`, the header row cell) | Same trigger rules; symbol effect on the header's image view; announce. |
| Settings | `registry/settings.json`, `registry/l10n/*.json`, generated constants | New toggle. |
| Septena Life | none | Out of scope. It shares `TaskListView`; the code path is the same, so no `#if SEPTASK` is needed. |

Put the trigger rule (§2) in one shared helper that both shells call, so the
iOS and Mac rules cannot drift. Shared code: build all four Apple schemes.

## 9. Done when

- Emptying the Inbox by each §2 gesture plays the motion on iOS and Mac, at
  most once a day per device. A second Inbox zero the same day plays nothing.
- None of the §2 exclusions plays it.
- Turning the setting off stops the motion and the extra haptic, and keeps the
  VoiceOver announcement.
- Reduce Motion stops the symbol effects.
- `scripts/lint-design.sh` passes and all four Apple schemes compile.
- The feature map row for the Inbox (Starlings Docs
  `/product/feature-map-septena-task-app`) mentions the setting.

mz tests on device. Agents do not run the app.

## 10. Open questions

Silence means the default stands.

| Question | Default |
|---|---|
| Separate toggle, or reuse "Completion animations"? | Separate toggle *(default)*. mz asked for it as its own option. |
| On or off by default? | On *(default)*. It is quiet and local. |
| Size: header moment, or a once-a-day canvas flourish? | Header moment *(default)*. The canvas stays reserved for `.arc`. |
| Limit to once a day? | **Decided (mz, 2026-11-23):** yes, once per day per device (§2a). |
