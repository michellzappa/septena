# Interactions

## The Magic Plus button

The signature Things interaction. A floating blue circle in the bottom-right corner.

### Tap behavior
- Tap → new task entry field appears at the **bottom of the current list** (or top, depending on list)
- Keyboard slides up; title field is focused
- Entry field has: title text field, date/when chip, project chip, tag chip, checklist button, notes button
- Tapping return adds the task and keeps the entry field open for more
- Tapping "Done" or dismissing keyboard commits and closes

### Drag behavior (the magic part)
- **Press and hold** the Magic Plus, then **drag**
- As you drag into the task list, a **horizontal insertion line** follows your finger between rows
- Release → new task is inserted at that exact position
- You can also drag to the **sidebar** (if visible) or to smart list shortcuts that appear around the button mid-drag:
  - Drag left: a "This Evening" target appears
  - Drag up-left: "Today" target
  - Drag up: "Upcoming/date picker" target
  - These targets fade in as a translucent ring around the button once drag starts

For our first pass: implement tap → entry field at bottom. Drag-to-insert is a V2 feature.

## Swipe gestures on task rows

| Direction | Short swipe | Long swipe (release past threshold) |
|---|---|---|
| Swipe right | Reveals "When" pill (schedule) | Instant-schedule to Today |
| Swipe left | Reveals "Complete" and "More" | Mark complete immediately |

- Swipe right shows date-scheduling options: **This Evening**, **Tomorrow**, **Someday**, and a calendar icon
- Swipe left short reveals two actions: **Complete** (green circle check) and **•••** (more)
- Swipe distance determines action: past 40% width = first action, past 70% = commit immediately on release

## Checkbox interaction

- Tap checkbox → checkmark fills with spring animation (0.25s)
- Simultaneously: title gets strikethrough, row opacity drops to 0.5
- After ~0.6s delay, row slides out of the list (or stays, depending on setting — in Things it stays briefly then moves to Logbook)
- Tapping again within the delay **uncompletes** (undo)

## Long-press interactions

- **Long-press task row** → enters multi-select mode with that row pre-selected
- **Long-press Area/Project in sidebar** → context menu (Edit, Share, Delete, Move)
- **Long-press Magic Plus** → starts drag-to-insert mode

## Pull gestures

- **Pull down on list** → reveals Quick Find search at top (NOT refresh)
- On the sidebar root, Quick Find is always visible

## Date picker ("When" sheet)

When scheduling a task, a bottom sheet appears with:
- **Today** (yellow star)
- **This Evening** (purple moon)
- **Tomorrow** (next day)
- **Someday** (stack icon)
- **Custom...** → opens a calendar picker
- **Add Reminder** → time picker
- **Clear** → removes date

The sheet is dismissed by tapping a choice or swiping down.

## Keyboard shortcuts (for later iPad)
Not relevant for iPhone-only v1.

## Haptics

Things uses light haptic feedback on:
- Checkbox complete (`.success` notification or `.light` impact)
- Swipe action commit (`.medium` impact)
- Long-press entering multi-select (`.medium` impact)
- Magic Plus drag target snap (`.light` impact)

Use `UIImpactFeedbackGenerator` / SwiftUI `.sensoryFeedback` modifier.

## Animation specs

| Action | Duration | Curve |
|---|---|---|
| Row expand (inline detail) | 0.35s | spring, response 0.4, damping 0.8 |
| Checkbox fill | 0.25s | spring, response 0.3, damping 0.7 |
| Row strike+fade on complete | 0.4s | ease-out |
| Row slide-out after complete | 0.3s | ease-in-out |
| Swipe action reveal | tracks finger | — |
| Multi-select bottom bar | 0.25s | ease-out |
| Magic Plus press | 0.15s | ease-out |
| Navigation push | system default | — |
