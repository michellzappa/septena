# Septask AppKit — transient surfaces

How the AppKit shell shows a popover, a panel, or an alert, and why there is
only one way to do each. The code is in `Septask/SeptaskKitSurface.swift`; the
`appkit-surface-chrome` rule in `scripts/lint-design.sh` keeps it that way.

## The rule

**Scope picks the container, never convenience.**

| Tier | Container | Scope | Dismissal | Commit |
|---|---|---|---|---|
| 1 | Anchored popover (`KitPopover`) | one attribute of one visible row | click-away, Esc | pick commits, or close commits |
| 2 | Centered command panel (`KitSurfacePanel`) | app-wide, or a selection with no single anchor | resign key, Esc | Return commits |
| 3 | Alert (`KitPrompt`) | irreversible or forked decisions | button | button |

Naming is none of the three. A name is edited **inline in the row that holds
it**, the way Finder renames a file. The shell no longer stops the app to ask
for a string.

Non-transient surfaces stay what they are: the inspector pane holds all task
detail, and hosted SwiftUI windows hold forms (Settings, Welcome).

## Where each surface landed

| Surface | Tier | Anchor |
|---|---|---|
| When (⌘S), Deadline (⌘⇧D) | 1 | the row, or the composer pill |
| Repeat | 1 | the row, or the composer pill |
| Move (single row) | 1 | the row, or the composer's List pill |
| Move (multi-selection) | 2 | centered — there is no single row to point at |
| Quick Find (⇧⌘F) | 2 | centered |
| Quick Entry | 2 | screen, upper third |
| Delete area / project / section | 3 | — |
| Reschedule a fixed repeat | 3 | — |
| Rename area / project / section | inline | the row |
| New area / project / section | inline | lands named, opens for editing |

## Two commit contracts

* **Pick commits and closes** — a surface that answers ONE question: a date, a
  destination, a search hit.
* **Close commits** — a surface with SEVERAL fields: Repeat, and the inspector.
  Dismissal accepts, the way a text field accepts on losing focus.

There is deliberately no third contract, and in particular **no per-change
write**. Repeat edits a draft and writes once on close, because writing on
every click of the stepper would push one CloudKit change per click. Closing
without changing anything writes nothing — a look is not an edit. Terminal rows
("Don't Repeat", "Clear (Anytime)") are the exception: they write and close on
the spot.

## What this replaced

Every item below was live before this pass and is a defect, not a preference:

1. When, Repeat and Move all edit one attribute of one selected row, and all
   three appeared somewhere different — anchored to the row, centered over the
   window, centered on the screen.
2. Repeat carried a window title bar **and** an in-content heading.
3. Repeat's heading badge was hardcoded `NSColor.systemBlue`. The app accent is
   adaptive ink and section color comes from the theme; nothing else in the
   shell paints a hue.
4. Corner radius was 12 on panels, 14 on the date popover, 14 on Repeat's inner
   card.
5. Repeat set `hidesOnDeactivate = false`, so it alone survived clicking away.
6. Quick Find and the Move picker were ~130 duplicated lines of panel and table
   construction.
7. Four separate `doCommandBy` switches implemented the same arrow / Return /
   Esc keyboard contract.
8. A task renamed inline; an area renamed in an app-modal alert.
9. Three alerts, two builders — the reschedule fork had rolled its own.

## Adding a surface

1. Decide the tier by scope, not by what is easy to build.
2. Build it from `KitPopover`, `KitSurfacePanel` or `KitFilterSurface`. A query
   over a list is `KitFilterSurface`, which renders in either tier from one
   body — pass `.rect` when you can name the row, `.window` when you cannot.
3. Take chrome from `KitSurface` (`cornerRadius`, `material`, `fieldFont`,
   `listRowHeight`, `listInset`, `padding`, `separator()`). Do not restate a
   number the token already holds.
4. Content that closes its own popover holds it through `KitPopoverHandle`.
   Capturing the popover strongly leaks the whole chain — the popover retains
   its controller, which retains the content.
