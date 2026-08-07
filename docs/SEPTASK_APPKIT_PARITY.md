# Septask AppKit shell — parity backlog

**Landed since the last pass (2026-08-06):** inline composer with the
elective pill rail (§1), the three row cues — tenure dial, unread-context
dot, agent cue (§3), structure CRUD — new/rename/delete area & project
(§4), Recently Deleted route with restore/purge (§5), and undo/redo for
complete/reopen, delete/restore, rename, and move (§6, partial — dates and
recurrence still unwired). Struck below; a plan for Task Conversations (§2)
is in `docs/SEPTASK_CONVERSATIONS_PLAN.md`.

**2026-08-07 follow-up pass:** the project/area page header (icon + big
title) generalized into ONE standard component shown on every page, not just
project/area; the "Show N logged items" footer (§7, below); the tenure
outline now fades gray→gold in lockstep with the fill instead of a binary
gray/gold jump, matching `TaskCheckbox` exactly (§3); plus bug fixes that
aren't parity items but are worth knowing landed: card corner-rounding
seams, double-height rows on first launch, ⌘N occasionally not entering
edit mode, and the logged-footer disclosure not visually expanding.

**2026-08-07 second pass:** structure drag-reorder for areas/projects (§4),
heading create/rename/delete (§4), Upcoming day-bucketing (§5). New shared
file `SeptaskKitPrompt.swift` (`KitPrompt.text`/`.confirmDestructive`) —
every NSAlert-based prompt in the shell goes through it now; use it for the
next one instead of writing another `NSAlert` block inline.

What the AppKit shell (`Septask/SeptaskKit*.swift`) still lacks versus the
SwiftUI task surface it's replacing on macOS. Context, decision, and working
rules live in `docs/SEPTASK.md` ("AppKit shell on macOS"); this file is only
the gap list.

Status legend: **[P1]** blocks daily-driver use · **[P2]** real feature loss ·
**[P3]** polish / rarely reached · **[—]** deliberately not porting.

Verified against the code on 2026-08-06. The SwiftUI shell is still one menu
item away (Go ▸ Classic Window, ⌥⌘0), so everything below is *reachable* today
— it just isn't in the fast shell.

---

## 1. Task editing — the biggest hole

The shell has field-editor rename (Return / ⌘R / double-click) and a 4-field
inspector (⌥⌘I: title, notes, When, Deadline, Repeat). The SwiftUI shell has a
much richer editor.

- **[DONE] Inline expand-in-place composer with the elective pill rail.**
  `SeptaskKitComposer.swift` — Return/double-click expands the row into title +
  pill rail (Today / When / Deadline / List / Repeat / Notes), each pill
  reusing the same popover/menu the row commands use. Tab walks the pills.
  Autosaves on collapse. ⌘R stays a separate fast bare-title rename.
  Discuss/conversation pill NOT included — depends on §2.
- **[ ] Create-with-attributes.** Still open: ⌘N makes a bare titled row; the
  composer isn't offered at creation time the way it is for editing. Small
  follow-up: open the composer immediately after ⌘N instead of the bare
  field-editor rename.
- **[P2] Hero-glide between closed row and open editor**
  (`matchedGeometryEffect` anchors on title + checkbox). Cosmetic but it's what
  makes inline editing feel continuous rather than modal.
- **[P3] Notes inline** (shell has notes in the inspector only).

## 2. Task Conversations (agent threads) — entirely absent

`ConversationCard` + `ConversationEngine` + `TaskConvo`. Nothing in the shell
renders or writes these, and the data is live (the MCP gateway writes it).

- **[P2] Transcript rows, question blocks with choice buttons, "other" free
  text reply.**
- **[P2] Artifact blocks and handoff buttons** (open URL / run action).
- **[P2] Acceptance / end-state / assignee** (`setConvoAcceptance`,
  `setConvoEndState`, `setConvoAssignee`).
- **[P2] The Discuss pill** that starts a conversation from the composer.

## 3. Row cues the shell doesn't draw

`KitCheckboxView` now draws the same cue vocabulary as `TaskCheckbox`.

- **[DONE] Today tenure dial** — gold interior deepening per carried day
  (`todayTenureFill()`), capped at 70% opacity.
- **[DONE] Unread-context corner dot** — haloed dot for a committed task with
  a started conversation (`conversation.hasStarted`).
- **[DONE, half] Agent cue ring** — drawn from `showsAgentCue()`. NOT wired:
  `mutator.acknowledge(id:)` is never called, so a row's cue can't be cleared
  from the shell — engaging with it here doesn't turn the glow off. Small
  follow-up: call `acknowledge` wherever the composer/inspector opens on an
  agent-cued row.
- **[P3] Check celebration** (`CheckFeel.stamp` — stamp + pulse ring at the
  box). The shell's completion feedback is the settle beat only.
- **[P3] Promote flash** — amber ring when a row is pinned to Today.
- **[P3] Filing-suggestion capsule** — the "→ Suggested" chip from
  `SuggestionEngine`, and suggestions surfaced in the Move menu.

## 4. Structure CRUD — read-only today

The shell reads areas/projects and can *file into* them, but can't manage them.

- **[DONE] New Project / New Area.** `SeptaskKitSidebar.swift` — NSAlert +
  text field, reachable from the sidebar's right-click menu (blank space, or
  "New Project in ⟨Area⟩" from an area row) and from the Task menu / Task
  Menu bar item, routed the same way ⌘N is.
- **[DONE] Rename / delete project and area.** Right-click → alert; delete
  copy matches the SwiftUI sidebar's exactly ("Tasks in this project will be
  moved to the inbox." / "Projects in this area will be detached but not
  deleted."). Bounces to Today if the deleted item is the one on screen, same
  rescue as SwiftUI.
- **[DONE] Reorder areas/projects by dragging in the sidebar.**
  `SeptaskKitSidebar.swift`, "Structure drag-reorder" section. A second
  pasteboard type (`.septaskStructureItem`, distinct from `.septaskTask` so
  the single drop handler can tell "reorder the sidebar" from "file a
  dragged task" apart) carries the dragged node's `key`. Calls the EXACT
  same `reorder(orderedIDs:)` API and the same move-before-target math as
  `SidebarView.reorderArea`/`reorderProject` — areas reorder as one flat id
  list, projects reorder among same-parent siblings only (loose-together, or
  together within one area). Cross-parent drops (which would REPARENT, not
  reorder) are rejected — validated via `areaNodeRange`/`organizeStartIndex`,
  the index boundaries within `roots` where the loose-project block ends and
  the area block begins.
- **[DONE] Headings — create / rename / delete.** `SeptaskKitTaskList.swift`,
  "Headings (project sections)" section. Same `TaskMutator` calls SwiftUI
  uses (`createHeading`, plain `update(id:title:)` for rename, `delete` for
  delete), same confirmation copy ("Delete this section? Its tasks stay in
  the project."). Entry points: right-click a heading row (Rename / Delete
  Section), right-click blank space on a project page (New Section).
  Double-click/Return on a heading now falls back to the bare-title editor
  instead of no-op (the composer's pill rail makes no sense for a heading).
  - **[P2] NOT done: filing a task under a heading by DRAGGING it there**
    (SwiftUI's `handleGroupedTaskDrop`/`handleHeadingDrop`). The shell's
    existing intra-list drag (`SeptaskKitTaskListController.acceptDrop`)
    reorders position and skips heading rows when finding neighbors, but
    never calls `mutator.setHeading`, and project pages don't visually GROUP
    rows by heading membership the way SwiftUI's `groupRows`/`visibleItems`
    do — they render in flat position order. Doing this properly needs (a)
    grouping the `.project`/`.area` render path by `heading` before laying
    out rows (mirroring `groupedByList`'s pattern, not the raw `pool.map`
    it uses today), then (b) extending `acceptDrop` to detect a heading
    target and call `setHeading` accordingly. Skipped this pass — scoped as
    a "same logic" CRUD pass, not a render-path rework — deliberately, not
    forgotten.
- **[P3] Project detail / notes**, area attachment (repo / calendar / feed
  context feed).

## 5. Views and routes missing

- **[DONE] Recently Deleted (trash).** Sidebar row (gated on count > 0, like
  SwiftUI). Checkbox tap / ⌘K / Return / double-click all mean "restore" in
  this view (repurposing has no better native affordance than the checkbox
  itself asking "bring this back?"); ⌘⌫ here means permanent delete
  (`purge`, no undo — it's a real SwiftData delete). Right-click menu is
  Restore / Delete Permanently only — the normal menu's rename/dates/etc.
  don't apply to a deleted row.
- **[DONE] Upcoming date buckets.** `SeptaskKitTaskList.swift`,
  `upcomingBuckets(_:)`/`upcomingDayKeys(for:)` — line-for-line port of
  `TaskListView.upcomingBuckets`/`upcomingDayKeys`: bucket key is the
  earliest FUTURE of scheduled/deadline, days are the union of task-days and
  event-days (an all-day-event-only day still gets a row), multi-day events
  span every day they cover, day labels come from the real
  `SeptenaDate.scheduleHeaderLabel` (not reimplemented). `agenda()` (Today's
  woven-block-at-top agenda) is now Today-only; Upcoming's calendar events
  weave per-day instead. Correction to the previous entry here: there's no
  week-level super-header — `DayBucketHeader` (grepped by name earlier) is
  actually the Habits/Mood TIME-OF-DAY bucket header (morning/afternoon/
  evening), unrelated to Upcoming; `upcomingBuckets()` only ever groups by
  day. So this port is complete, not partial.
- **[P2] The embedded Next fold** (`SeptaskNextFold`, `NextItemsSection`,
  `NextSuggestionsSection`).
- **[P2] Reminders inbox import** (`RemindersInboxSection`).
- **[P3] Things import** (`ThingsImportView`) — one-time migration, fine in the
  classic window.
- **[P3] Task patterns section.**
- **[P3] Time travel sheet** (DayClock debug offset). The shell honors
  `SeptenaDate.today` everywhere, but can't *change* it.
- **[P3] Welcome / onboarding gate.** Only on the SwiftUI window — a fresh
  install launching into the shell sees no welcome. Needs a decision before
  anyone but MZ installs this.

## 6. Platform integration

- **[P1] Localization.** Every string in `SeptaskKit*.swift` is a hardcoded
  English literal. The SwiftUI surface goes through `Localizable.xcstrings`,
  which already carries translations for the same concepts. This is the one
  gap that gets *worse* the longer it waits (more literals to sweep).
- **[DONE, partial] Undo / redo.** `SeptaskKitTaskListController` owns an
  `UndoManager` (overrides `NSResponder.undoManager` — there's no
  `NSDocument`, so `NSWindow.undoManager` is nil by default and won't do this
  for free) with symmetric undo/redo registration, wired for: complete/reopen
  (single + batch + the composer's checkbox), delete/restore, rename, move.
  Standard ⌘Z / ⌘⇧Z, standard Edit menu. NOT wired: When/Deadline changes,
  recurrence changes, Today toggle, create/duplicate. The SwiftUI shell still
  has no undo at all, so this is net-new capability, not parity.
- **[P2] Paste (⌘V) to create tasks** from clipboard text (multi-line → one
  task per line). Copy already works via Edit ▸ Copy.
- **[P2] Accessibility.** The custom-drawn checkbox, sidebar chevrons, and card
  rows have no accessibility labels/roles yet, so VoiceOver reads them poorly.
- **[P3] In-list search field.** Quick Find (⇧⌘F) covers global search; there's
  no filter-within-this-list field, and the shell has no toolbar to host one.
- **[P3] No toolbar at all** — the SwiftUI window has search + add buttons.
- **[P3] External drag/drop.** Task drags are `forLocal: true` only: can't drag
  a task out to Mail/Finder as text, and dropping text/files into the list
  doesn't create tasks.
- **[P3] Multi-window.** The shell is a single-window singleton
  (`SeptaskKitWindowController.current`); SwiftUI had a `WindowGroup`.
- **[P3] Live text-size refresh** — rows pick up a new text size on the next
  reload, not immediately.
- **[P3] Services / Share / Print menus.**

## 7. Smaller behavior gaps

- **[P2] Recurrence presets only** — Never / Daily / Weekly / Every 2 Weeks /
  Monthly. No custom interval and no `afterCompletion` toggle (the model has
  both). A rule set elsewhere displays correctly but can't be edited here.
- **[P3] Today "review" band** — overdue-scheduled rows that the SwiftUI Today
  response separates out (`review`) are just ordinary Today rows in the shell.
- **[DONE] "Show N logged items" footer** on project/area pages — same copy,
  same UserDefaults key as `TaskListView.scopeLoggedExpandedData`, so
  expand/collapse state agrees between both shells.
- **[P3] Logbook has no bulk clear/purge.**
- **[P3] Calendar events are inert** — no click-through to Calendar.app.
- **[P3] Keyboard Shortcuts sheet** (⌘/ in SwiftUI). The menu bar is arguably
  the better answer on macOS, so this may be a **[—]**.

## Deliberately not porting

- **[—] Settings and other form surfaces.** Hosted SwiftUI in an AppKit window
  (⌘, → `SeptaskKitSettingsWindow`). Not latency surfaces; porting is drift.
- **[—] iOS/iPad task UI.** Unchanged and still SwiftUI.

---

## Suggested order — remaining

1. **Task Conversations** (§2) — plan in `docs/SEPTASK_CONVERSATIONS_PLAN.md`.
   Biggest remaining feature loss; the data is live today.
2. **Localization sweep** (§6) — do before the literal count grows further.
3. **Drag-a-task-under-a-heading** (§4) — the one piece left out of the
   headings pass; needs the `.project`/`.area` render path grouped by
   `heading` first (see that entry for the exact shape).
4. **Round out undo** — dates, recurrence, Today toggle, create/duplicate.
5. **Accessibility pass** (§6) — the custom-drawn checkbox/chevrons/rows.
6. Everything else in §5/§6/§7 as it comes up.

## Handoff notes for whoever picks this up next

- **Build/verify loop**: `xcodegen generate` then
  `scripts/build.sh SeptaskMac 'platform=macOS'` — this is the ONLY green
  gate; nobody tests by running the app (see root `CLAUDE.md`). Also run
  `scripts/lint-design.sh` before calling something done.
- **Every `SeptaskKit*.swift` file starts with `#if os(macOS)`** and is
  compiled into `SeptaskMac` only — don't expect these types to exist when
  building the `Septask` (iOS) scheme.
- **Read `docs/SEPTASK.md`'s "AppKit shell on macOS" section FIRST** — it has
  the actual working rules (mutators as the write boundary, `.custom`
  `rowSizeStyle` being load-bearing for both height AND font, the neutral
  selection-fill rule, motion routing through `KitMotion`) that this backlog
  doc doesn't repeat.
- **Two recurring bug classes worth knowing about going in**, both hit more
  than once this pass:
  1. Any `configure()`-style method on a reused `NSTableCellView`/composer
     cell must NOT blindly overwrite `titleField`/`notesView` on every call
     — only on a genuinely NEW item. A refresh-after-side-effect call (a
     pill press, a background sync) landing while the user is mid-edit will
     silently revert what they typed. See `SeptaskKitInspectorController
     .show(_:)` and `KitComposerCell.refreshPills` vs `.configure` for the
     fixed pattern (split "full load" from "read-only-fields-only refresh").
  2. `TaskMutator`/`AreasMutator`/`ProjectsMutator` write calls post their
     change-notification SYNCHRONOUSLY, before the call returns. Any
     "restyle now, mutate, reload later" sequence (the settle beat, the
     composer's toggle-complete) MUST set its own reentrancy guard (see
     `isSettling`/`composingTaskId`) BEFORE the mutator call, not after —
     otherwise the synchronous notification's own reload runs first and
     undoes the state you were about to set up.
