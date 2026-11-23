# 0029. One task page with two depths; one picker per attribute

- Status: accepted
- Date: 2026-11-23
- Deciders: mz

## Context

The task app has no canonical place to edit a task (#300, open question).
On 2026-11-23 the surfaces were:

- iPhone, iPad and the classic Mac window expand the row in place
  (`TaskComposerCard`, `.inline`).
- The Mac Septena window has its own inline composer
  (`SeptaskKitComposer`) and a separate inspector pane on ⌥⌘I
  (`SeptaskKitInspector`). Only the inspector shows the checklist,
  attachments, conversation and history together.
- The SwiftUI drawer (`TaskComposerCard`, `.drawer`: sheet on iPhone,
  docked inspector on iPad and Mac) already holds conversation and history,
  but only Upcoming uses it, to create.
- Android pushes `TaskDetailScreen`. The watch has `TaskDetailView`.
- `task.toggleInfo` is gated on `mac.keyboard`, so iPhone and iPad cannot
  reach the full set of fields.

The editors for one attribute also differ by entry point. In the SwiftUI
shell a composer pill expands a private inline panel (`InlineWhenPanel`,
`InlineRepeatPanel`, `TaskTagsPanel`, ...), and the row menu opens a
different sheet (`DatePickerSheet`, `RecurrencePickerSheet`,
`TagPickerSheet`, ...). Two editors per attribute drift. The AppKit shell
already uses one editor per attribute (`SeptaskKitDatePopover`,
`SeptaskKitMovePicker`, `SeptaskKitTagPopover`) from the row, the
composer and the inspector.

ADR 0028 lets the registry own the order of attributes and blocks on a
surface, but no geometry.

## Decision

There is **one task page**. `registry/surfaces.json` declares it as an
ordered list of blocks (header, notes, attributes, checklist, attachments,
conversation, history). Each block names the depths it appears in. The
page has **two depths**: **inline** (the quick edit in the row: title, notes,
attribute pills), which a row tap opens on every platform, and the **page**
(every block), which one action, `task.open`, opens. Each platform hosts the
page in its own idiom: iPhone and Android push it onto the navigation stack
(a sheet only for a deeper level opened from the page); iPad and Mac show it
in the trailing inspector pane. The Mac keeps both its inline composer and
the inspector.

Each attribute has **exactly one picker** per platform. The composer pill,
the page row, the row context menu, the menu bar and the keyboard shortcut
for that attribute open the same picker. In the registry an action declares
the attribute whose picker it opens, so the menu and the pill cannot point
at different editors.

## Consequences

- A new attribute or block added to the registry shows on the inline editor,
  the page, the menus and every platform's picker list with no new layout
  decision in a shell.
- iPhone and iPad gain the full page (checklist, attachments, conversation,
  history) that only the Mac inspector had.
- `task.editDetails` and `task.toggleInfo` leave the row menu for
  `task.open`. ⌘R (inline rename) and ⌥⌘I (inspector toggle on wide
  screens) keep their keys.
- The SwiftUI inline panels and the SwiftUI picker sheets merge into one
  view per attribute. On iPhone a pill then opens the same sheet as the row
  menu, not an inline panel. This changes how the inline editor feels on
  iPhone.
- The SwiftUI drawer's edit path has been unused since inline editing
  landed. It needs review before it hosts the page.
- The iPad inspector must not publish `focusedSceneValue` from the split
  detail (AGENTS.md: it kills the process).

## Links

- Spec: `docs/TASK_PAGE_SPEC.md`
- ADR 0024 (one navigation stack on iPhone), ADR 0028
- #300 (row menu), #286 (row anatomy and screen slots), #218 (composer and
  inspector labels)
