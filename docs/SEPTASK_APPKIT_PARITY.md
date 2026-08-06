# Septask AppKit shell — parity backlog

**Landed since the last pass (2026-08-06):** inline composer with the
elective pill rail (§1), the three row cues — tenure dial, unread-context
dot, agent cue (§3), structure CRUD — new/rename/delete area & project
(§4), Recently Deleted route with restore/purge (§5), and undo/redo for
complete/reopen, delete/restore, rename, and move (§6, partial — dates and
recurrence still unwired). Struck below; a plan for Task Conversations (§2)
is in `docs/SEPTASK_CONVERSATIONS_PLAN.md`.

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
- **[P2] Reorder areas/projects by dragging in the sidebar**
  (`position` / `TaskStructureOrder`). The shell's sidebar accepts *task* drops
  but has no structure reordering.
- **[P2] Headings.** The shell renders project headings but can't create,
  rename, delete, or move tasks under them (`createHeading`, `setHeading`).
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
- **[P2] Upcoming date buckets.** SwiftUI groups Upcoming into day/week buckets
  (`upcomingBuckets`, `DayBucketHeader`); the shell shows one flat list.
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
3. **Round out undo** — dates, recurrence, Today toggle, create/duplicate.
4. **Structure reordering** (§4) + **headings CRUD** (§4).
5. **Accessibility pass** (§6) — the custom-drawn checkbox/chevrons/rows.
6. Everything else in §5/§6/§7 as it comes up.
