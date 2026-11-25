# Task page spec

Status: accepted 2026-11-23 (ADR 0029). Not built.

One task page, two depths, one picker per attribute. The registry declares
the structure; each platform renders it in its standard toolkit (ADR 0028).

## 1. The page in the registry

`registry/surfaces.json` gets a `taskPage` block:

| Field | Meaning |
|---|---|
| `blocks[]` | Ordered. Each block: `id`, `kind`, `depths`, `featureId`, optional `editOnly`. |
| `kind` | Closed set: `header`, `notes`, `attributes`, `checklist`, `attachments`, `references`, `conversation`, `provenance`, `history`. Each platform writes one renderer per kind. |
| `depths` | `["inline", "page"]` or `["page"]`. |
| `attributes` block | Renders the `taskAttributes` entries in their registry order. It holds no list of its own. |

First cut:

| Block | Kind | Inline | Page |
|---|---|---|---|
| header | header (checkbox, title) | yes | yes |
| notes | notes | yes | yes |
| attributes | attributes (pills inline, rows on the page) | yes | yes |
| checklist | checklist | yes (from its pill) | yes |
| attachments | attachments | yes (from its pill) | yes |
| references | references, suggestions from the links in the text, Add Reference (page only) | yes | yes |
| conversation | conversation | no | yes |
| provenance | provenance ("Added by": the agent's name or "You", and when) | no | yes |
| history | history | no | yes |

The generator checks:

- Every block `kind` is in the closed set.
- Every `featureId` exists in `capabilities.json`.
- A platform that claims `task.page` `ships` has a renderer for every kind.
  This is check 4 of ADR 0028.

The registry holds no geometry, spacing, focus or motion.

## 2. Depths and hosts

| Platform | Inline (row tap) | Page (`task.open`) | Deeper level from the page |
|---|---|---|---|
| iPhone | expand in row | push onto the one stack (ADR 0024) | sheet |
| iPad | expand in row | trailing inspector pane | popover or sheet |
| Mac (Septena window) | AppKit inline composer | native split-view inspector, ⌥⌘I | popover |
| Mac (classic window) | expand in row | docked SwiftUI inspector | popover |
| Android | (none yet) | pushed `TaskDetailScreen` | dialog or bottom sheet |
| Watch | none | `TaskDetailView`: the blocks the watch capability allows | none |

Rules:

- A row tap opens inline on every platform that has inline. Open is the way
  to the page. It is never the default tap.
- On a wide screen the inspector follows the selection. On iPhone and
  Android, Back leaves the page.
- Inline and page edit the same draft rules and commit through
  `TaskMutator`. Opening the page from an open inline editor folds (and so
  saves) the inline editor first.

## 3. One picker per attribute

Every attribute with `surfaceTier` `popover` (When, Deadline, Reminder,
Repeat, List/Move, Tags) has exactly one picker view per platform. Every entry
point opens that picker:

- the composer pill (inline)
- the attribute row on the page
- the row context menu
- the menu bar Task menu
- the keyboard shortcut

In `registry/actions.json` an action gets `opensAttribute: "<attribute id>"`
(for example, `task.when` → `when`, `task.move` → `list`, `task.tags` →
`tags`). The generator checks:

- Every `opensAttribute` names an attribute in `taskAttributes`.
- Every `popover` attribute is opened by exactly one action.

The presentation container may differ by platform (a popover on a wide
screen, a sheet on iPhone, a dialog on Android). The content is the same view.

**On the page, a picker is embedded, never modal** (decided 2026-11-24). A
tap on an attribute row folds that row's card open and draws the picker in
it. A second tap on the row folds it closed and is Cancel. A commit (a day,
Save, OK, a list) writes the draft and folds the card. The picker view is the
same one the sheet shows; embedded, it drops its navigation bar, its Cancel
and its own vertical scroll. Pickers that open a further level (When's month
calendar, When's Repeat row) open it in the page too. The inline depth's pills
keep the sheet. The conversation runs inside the Discuss card on the page,
not as a separate block below the attributes.

Per shell on 2026-11-23:

- **AppKit:** already one picker per attribute (`SeptaskKitDatePopover`,
  `SeptaskKitRepeatPopover`, `SeptaskKitReminderPopover`,
  `SeptaskKitTagPopover`, `SeptaskKitMovePicker`). Keep it. Make the
  inspector and the composer route through the action IDs.
- **SwiftUI:** two editors per attribute. The pills expand private inline
  panels (`InlineWhenPanel`, `InlineDatePanel`, `InlineReminderPanel`,
  `InlineRepeatPanel`, `TaskTagsPanel` in `TaskAttributeBar.swift`), and the
  row menu opens the sheets in `TaskPickerSheets.swift`. Merge each pair into
  one view. The pill and the menu then present it the same way. On iPhone
  this is a sheet, so the inline editor no longer expands panels in place.
- **Android:** the detail screen has its own date dialog and repeat editor,
  and task rows have no context menu yet. When #300 adds the menu, it opens
  the same dialogs.

The When picker contents follow #300: Today first (Remove from Today when the
task is already on Today), Clear, and a Repeat row with Pause/Resume and
Create Next Copy.

## 4. Actions and menus

- New action `task.open` ("Open"). It opens the page on the platform's host.
  It replaces `task.editDetails` and `task.toggleInfo` in the row menu and
  the menu bar Task menu (#300 item 6).
- `task.toggleInfo` stays as the View menu item and ⌥⌘I on iPad and Mac (it
  toggles the inspector pane). Its `featureId` moves from `mac.keyboard` to
  `task.page`.
- ⌘R stays as inline rename (`task.editDetails`, keyboard only).

## 5. Phases

1. **Registry.** `taskPage` blocks, `task.open`, `opensAttribute`,
   capability `task.page` per platform, the generator checks, the generated
   Swift and Kotlin types. Fold in #218 (labels from the registry).
2. **SwiftUI pickers.** One view per attribute; pill, menu and shortcut open
   it. Delete the duplicate panels.
3. **SwiftUI page.** The drawer renders from `taskPage.blocks`; iPhone pushes
   the page; iPad and the classic Mac use the docked inspector; `task.open`
   is wired; inline reads the `inline` depth.
4. **AppKit page.** `SeptaskKitInspector` renders from the blocks; the
   inspector, composer and row menu call the pickers by action ID.
5. **Android.** `TaskDetailScreen` renders from the blocks; the row menu
   (#300) opens the same dialogs.

Each phase builds all four Apple schemes (or `SeptaskMac` where the watch
runtime gap blocks iOS). Phase 5 builds through the Android workflow.

## 6. Unknowns

- The SwiftUI drawer's edit path has been unused since inline editing
  landed. Phase 3 starts by reviewing it.
- iPad: the inspector must not publish `focusedSceneValue` from the split
  detail (AGENTS.md trap).
- iPhone inline editor: pills that open sheets instead of panels change the
  feel of the quick edit. mz tests this after phase 2.
