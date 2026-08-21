# Septask AppKit shell — parity backlog

**2026-08-21 — one surface system.** Every transient surface in the shell now
follows one rule, specified in `docs/SEPTASK_APPKIT_SURFACES.md` and built from
`Septask/SeptaskKitSurface.swift`: **scope picks the container.** Tier 1 is an
anchored popover for one attribute of one row (When, Deadline, Repeat, and Move
when a single row is selected); Tier 2 is a centered command panel for anything
app-wide or multi-row (Quick Find, Quick Entry, bulk Move); Tier 3 is an alert,
for irreversible or forked decisions only. Naming left the dialog entirely and
happens inline in the row, Finder-style — `KitPrompt.text` is gone, and New
Area / New Project / New Section now land a named row and open it for editing.

What changed underneath: Repeat lost its title bar, its second in-content
heading, its hardcoded `systemBlue` badge and its OK button, and became a
popover anchored to the row it edits; Move gained an anchored presentation and
falls back to the panel only for a multi-selection; the date popover's radius
14 became the shell's single 12; Quick Find and Move stopped being two copies
of the same panel-and-table construction; the four hand-written `doCommandBy`
switches became one; and the reschedule-repeating alert joined the other two in
`KitPrompt`. `scripts/lint-design.sh` gained `appkit-surface-chrome`, which
fails the build on an `NSPopover()` or a borderless panel built outside the
surface file. Built green on `SeptaskMac` and `SeptenaMac`.

**2026-08-21 bug:** `isBordered = false` on an `NSSearchField` collapses the
BEZEL geometry its cell derives the text rect from, so the text starts at x=0 —
directly on top of the magnifying glass. MZ caught it typing into ⌘⇧M Move;
⇧⌘F Quick Find had the identical setup and therefore the identical bug.
Fixed with `KitSearchFieldCell` (`SeptaskKitRowViews.swift`), which computes
`searchButtonRect` / `cancelButtonRect` / `searchTextRect` from `bounds`
explicitly — the documented customization point, chosen over restoring a bezel
neither panel wants. Both panels now share `KitSearchField.applyPanelStyle()`
so they cannot drift into the same bug twice. NOTE this is a rendering fix
verified only by compile; if the overlap persists, the cause is that modern
`NSSearchField` lays its buttons out as SUBVIEWS rather than through the cell,
in which case the rect overrides are inert and the parts need positioning as
views instead.

**2026-08-20:** one long pass, built green on `SeptaskMac` throughout.

1. **The house rule is now actually applied.** `KitProjectTargetCell`,
   `KitGroupHeaderCell` and `KitLoggedFooterCell` — the three cells the
   2026-08-09 note listed as "still unconverted and carrying the same bug" —
   are real `NSButton`s now. The first still had an `NSClickGestureRecognizer`
   (the shape proven never to fire in a cell view); the other two had the
   hand-tracked `mouseDown`/`mouseUp` + `hitTest` overrides that the same note
   retired. All three used the transparent full-bleed overlay from
   `KitNewTaskCell`. There are now **zero** gesture recognizers and **zero**
   `hitTest`/`mouseDown`/`mouseUp` overrides left in `Septask/SeptaskKit*.swift`
   — grep for them before adding a click target and keep it that way.
   `KitGroupHeaderCell` hides its overlay when the header is non-navigable, so
   "Inbox"/"Agenda" clicks still reach the table.
2. **Three parity items** — the Add Section footer (§4), ⌘N opening the
   composer (§1), and ⌘V paste-to-create (§6). Struck below.
3. **Undo is rounded out** (§6) — dates, recurrence, Today, create, duplicate
   and paste are all wired now.

4. **Grouped Today headers gained their "+"** and lost their oversized click
   target. `KitGroupHeaderCell` now carries a trailing quick-add button — the
   counterpart of SwiftUI's `HeaderQuickAddButton`, gated on the same
   `showsGroupedHeaderQuickAdd` terms (grouped Today, real list only) — which
   creates directly into that area/project via a new
   `createTask(inArea:project:)` rather than deriving filing from the filter.
   Bare title editor, not the composer: it is a quick-add affordance, the same
   weight as the foot-of-Inbox "New task" line.

   The header's navigation target is now the **title's own frame**, not the
   whole row and not the tall band of air above it. That air is the card
   separator, and making it navigate meant a click in the gap between two
   cards jumped you into a list. `TaskListView.groupHeaderBody` had already
   settled this for SwiftUI in a comment — "Tappable target is JUST the title
   (+ chevron) — not the whole row… so clicks in empty horizontal space don't
   navigate" — so this is the AppKit shell catching up, not a new opinion.
   A full-bleed overlay would also have swallowed the new "+".

5. **Selection stops at the content column.** `SeptaskKitTableView` overrides
   `mouseDown` and `menu(for:)` to ignore clicks outside
   `SeptaskKitLayout.inset(for:)`, deselecting instead — the ~10% page gutter
   was selecting whatever row happened to be level with the pointer. The five
   overlay-button cells pin their hit view to the same column via
   `KitContentColumnPin`, and every cursor rect narrowed from `bounds` to the
   control's own frame. NOTE this override is on the TABLE; the house rule
   against `mouseDown` overrides is about CELL views, whose clicks the table
   claims before they arrive.

6. **The inspector has a visible close button** — the twin of the Escape
   handling `b93d70c` added. ⌥⌘I stays the shortcut (platform-standard for an
   inspector); the button commits pending edits before closing, because a
   field's end-editing notification does not fire when the view goes away.

7. **⌘1–4 no longer die behind a panel.** `SeptaskKitCommands.shell` required
   `window.isKeyWindow`, and Quick Find, Quick Entry and the Move modal are
   all `NSPanel`s with `canBecomeKey` (Settings is its own window), so with any
   of them open the shell was not key, `canHandle` was false, and the whole Go
   menu greyed out. Navigation now runs off `canNavigate` (a shell EXISTS) and
   fronts the window before switching. Row commands stay key-gated on purpose.

8. **⌘K un-checks inside the settle window.** The reopen path called
   `reload()`, which is suppressed while `isSettling` — so the un-check reached
   the store but the row stayed looking done for the full 2.5s beat. It
   restyles in place now, via a shared `restyle(ids:to:)` used by complete,
   cancel and reopen alike. Task rows also carry no tooltips any more.

Two bugs found and fixed while doing it, both the same root cause and worth
knowing: **`SeptenaTask` is a struct, so the `rows` array holds pre-change
COPIES.** Reading a just-committed field back out of `rows` gives you the
stale value. This bit the new abandoned-⌘N-row purge (the composer commits the
title through the mutator, `rows` still says `""`, so a task the user had just
titled would have been purged out from under them) and it is why
`recordScheduleUndo` re-reads its after-state from `LocalCache.allTasks`
instead of from `rows`. `refreshTaskRowInPlace` exists for exactly this reason
— when you need a row's post-mutation truth, go to the store.

Also corrected: `commitRename` used to register a **rename** undo for a
brand-new ⌘N row, so ⌘Z after typing the first title meant "rename it back to
empty string" rather than "un-create it". New rows now register a `New Task`
undo that purges.

**2026-08-09:** AppKit VoiceOver floor (§6 Accessibility) — `TaskA11y` shared
spoken vocabulary + kit wiring (checkbox, rows, sidebar disclosure, headers,
logged footer); agent-cue `acknowledge` on composer/inspector engage.

**2026-08-08:** Drag-under-heading + group-by-heading on project pages
(§4) — `projectGrouped` / `acceptGroupedTaskDrop` / `acceptHeadingReorder`.
See the DONE entry under Headings below.

**2026-08-07 bug-report pass:** fixed a real data bug MZ caught by hand — a
task could render in Inbox AND its filed project/area at once. Root cause:
`isInTriageBand` (`SeptenaCore/Models.swift` / `Persistence.swift`) never
consulted `project`/`area` for `source == mcp` rows (an agent proposal stayed
"in Inbox" no matter where it got filed) — now guards `project == nil &&
area == nil` up front for BOTH populations before either branch. See the
"2026-08-07 correction" note in `docs/TRIAGE_BAND_SPEC.md` §3 for the full
reasoning; this is a SeptenaCore fix, so it applies to the SwiftUI shell too,
not just AppKit. Also fixed two AppKit-only rendering bugs MZ caught in the
same pass: (1) card corner-rounding going stale on a SURVIVING row after an
insert/remove/move — `SeptaskKitTaskListController.apply`'s diff path only
reloaded rows whose own `Row` value changed, never a neighbor that became
first/last purely because an adjacent row was added or removed, so a card's
new bottom row could stay square-cornered forever; `refreshCardGeometry()` now
walks on-screen row views directly after every diff. (2) The list's top/bottom
breathing room was a fixed 16pt constant while the left/right margin is
`SeptaskKitLayout.inset(for: width)` (10%, clamped 10–220) — the two only
agreed at one specific window width. `viewDidLayout` now keeps
`scrollView.contentInsets.top`/`.bottom` equal to the SAME computed pixel
value the rows use for their sides, at every width. And replaced the flat
"Move" `NSMenu` with `SeptaskKitMoveModal.swift` — a type-to-filter floating
panel matching `SeptaskKitQuickFind`'s shape (both are `KitFilterSurface`
now — see `docs/SEPTASK_APPKIT_SURFACES.md`), the AppKit counterpart of
SwiftUI's `MovePickerSheet` — and, per MZ's explicit call, restricted Move
targets to AREAS ONLY (`KitMoveMenu.destinations` no longer lists projects;
`Destination.project` stays a case for other callers — drag-and-drop refiling,
a project's own page — it's just not a Move-command choice anymore). MZ
separately reported the Next page rendering empty and the page-title chevron
not opening the nav menu — both match exactly what `d888c98` (the immediately
prior commit) already fixed; re-read the code and found no residual bug, so
this is very likely the stale-build symptom the "Suggested order" section
below already warns about. Flagged, not re-fixed — if either persists after a
clean rebuild + relaunch, it's a NEW bug, not this one.

**2026-08-09 correction:** it was not a stale build. The page-title dropdown
had never worked, and `d888c98`'s fix (a better `popUp` anchor point) was
downstream of the real defect: `KitScreenTitleCell` opened its menu from an
`NSClickGestureRecognizer`, and **a click recognizer on an `NSTableCellView`
can never fire**. `NSTableView.mouseDown` runs an event-tracking loop that
takes events off the queue with `nextEventMatchingMask:`; those never pass
back through `NSWindow.sendEvent`, which is the only place AppKit feeds
gesture recognizers. The recognizer got the mouseDown and never the mouseUp.
Fixed by hand-tracking the press (swallow mouseDown, act on mouseUp) — the
same shape `KitCheckboxView` and `KitDisclosureView` already used for this
exact hazard, and now the house rule for every click target in a cell:
**no gesture recognizers inside table/outline cell views.**
`KitLoggedFooterCell` and `KitGroupHeaderCell` carried the same latent bug and
were converted with it.

**…and that still wasn't the whole story, either.** Both of the above
explanations were wrong, and both shipped with confident comments saying
otherwise. What finally settled it was a scratch AppKit harness (a table with
a laid-out cell, geometry taken from `frameOfCell`/a laid-out subview's
`convert(bounds, to: nil)` — hand-set frames made an earlier probe silently
test empty space and report nonsense). Hit-testing the centre of each kind of
cell content:

```
NSButton              -> NSButton     ✅ receives clicks
bare custom NSView    -> that view    ✅ receives clicks
NSTextField label     -> NSTableView  ❌ the table claims it
```

**`NSTableView` claims hit-testing for label/image cell content.** Both broken
controls had an `NSImageView` glyph exactly where you click (the sidebar
chevron's image fills nearly all of its 14×14 hit view), so the click was
claimed by the table and no `mouseDown`/`mouseUp`/`hitTest` override on the
surrounding view ever ran. Fix: both are real `NSButton`s now.

**Two false signals cost three rounds.** First, the pointing-hand cursor
appeared over both chevrons the whole time, reading as "this control is live"
— `resetCursorRects` does NOT go through hit-testing, so the cursor proves the
view exists, never that clicks reach it. (Cursor rects are now scoped to the
button's own frame, so a dead area can't advertise itself again.) Second,
`KitCheckboxView` works, which looked like proof that the hand-rolled approach
was sound; it isn't, because a bare custom `NSView` that draws itself IS hit
normally — it's labels and images that get claimed.

**The sidebar fold was a SECOND, unrelated bug** hiding behind the first, and
it also had nothing to do with clicks. Measured in the same harness, an
NSOutlineView with the Septask sidebar's settings:

```
shouldShowOutlineCellForItem = false  ->  collapseItem is a NO-OP
                                          (isItemExpanded stays true, rows unchanged)
shouldShowOutlineCellForItem = true   ->  collapses correctly
```

Suppressing the native outline cell — which this sidebar does to hide the
triangle in favour of its own trailing chevron — opts the item out of
expansion **entirely**, including programmatic `collapseItem`. So the fold
could never have worked, whatever the chevron was made of. Rather than give
up the Things-style trailing chevron for a native leading triangle, the fold
now lives in the DATA: a folded area reports zero children from
`numberOfChildrenOfItem`, every row stays permanently expanded in
outline-view terms, and `collapsedKeys` (persisted) is the source of truth.
Note the trap that follows from it: `isItemExpanded` is now always true, so
the chevron direction and the didExpand/didCollapse handlers must read
`collapsedKeys` instead — and those handlers must NOT record the fold, since
the post-rebuild `expandItem(nil, expandChildren: true)` fires didExpand for
every node and would wipe every fold.

**House rule, now with evidence behind it: every click target in a
table/outline cell is a real `NSButton`.** No gesture recognizers, no
hand-tracked `mouseDown`/`mouseUp`, no `hitTest` overrides. (`KitGroupHeaderCell`,
`KitLoggedFooterCell` and `KitProjectTargetCell` were listed here as still
unconverted — they were converted on 2026-08-20; see the entry at the top.)

Lessons for the next session: a reported symptom that survives a fix usually
means the fix addressed a *different* layer of the same interaction; check the
built binary's timestamp against the fix commit before concluding a fix failed;
and when reasoning about AppKit internals, build a throwaway harness and
measure instead of arguing from memory — but take geometry from the framework,
because a probe with hand-set frames will happily test empty space and lie.

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

**2026-08-07 third pass:** ⚠️ a prior session reverted task-row titles from
wrap-to-2-lines back to single-line-truncate (`SeptaskKitTaskCell`,
`SeptaskKitTheme.rowHeight`/`taskTitleWidth` removed) — this is a **parity
regression**, not a fix: `TaskComponents.swift`'s canonical SwiftUI row uses
`.lineLimit(2)`, so long titles wrap and grow the row there. The AppKit
implementation that matched it (grow-row-by-one-line-on-wrap, guarded against
the pre-layout near-zero-width launch bug) is git history — `git log -p
--all -- Septask/SeptaskKitTheme.swift` around the `taskTitleWidth`/
`heightForTask` removal has the working version to restore if MZ wants
parity back rather than the denser single-line list. Left as-is (not
reverted) pending MZ's call — it's a deliberate-looking change even though it
diverges from SwiftUI. Also added: Tab/Shift-Tab now crosses focus between
sidebar and task list (`onFocusSidebar`/`onFocusList`, wired in
`SeptaskKitWindow.swift`) — a 2-stop loop via explicit `keyDown` interception
(consistent with this file's existing Return-key pattern), not the native
key-view loop, since NSTableView/NSOutlineView don't reliably surface Tab to
`nextKeyView` on their own. Selected-and-focused now reads differently from
selected-and-blurred: `SeptaskKitTheme.listSelectionFill(emphasized:)` keeps
one shape and swaps hue by focus — System Settings accent wash when
`NSTableRowView.isEmphasized`, light neutral gray when not — so Tab-ing to
the sidebar dims the list's old selection instead of both panes looking
identically "active." (Cannot use `.selectedContentBackgroundColor`: app
AccentColor is adaptive ink.) Area/project headers (`KitGroupHeaderCell`)
bumped chunkier — font `headline+9` → `headline+14`, icon/emoji/progress-ring
frame 18pt → 24pt (`KitGlyph.progress`/`.areaDot` gained a `diameter` param,
default unchanged, so the sidebar/screen-title call sites are untouched) —
row height's `+9` kept in lockstep. Confirmed the `wt/kit-next` worktree
(`../septena-kit-next`, branch `wt/kit-next`) already has a full Next-feed
port as a sidebar destination (`SeptaskKitNext.swift`, hosts the shared
`SeptaskNextPage`) — builds green there, but it forked before this session's
Upcoming-buckets/headings/reorder work landed on `main`, so it needs a rebase
before merging. And ⌘1–4 (Today/Upcoming/Anytime/Logbook) were checked, not
rebuilt — `SeptaskNavigationCommands.swift`'s "Go" menu already routes to
`SeptaskKitCommands.go(_:)` when the AppKit shell is frontmost; if they're
not firing for MZ it's very likely the same stale-build symptom as the
header-size report above, not a real gap.

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
- **[DONE] Create-with-attributes.** ⌘N now opens the composer on the new row
  instead of the bare field-editor rename, so a task can be given its When /
  Deadline / List / Repeat without a second gesture. ⌘R is still the fast
  bare-title path. The foot-of-Inbox "New task" line deliberately KEEPS the
  bare editor — it is a light capture affordance, and a pill rail there would
  be heavier than the click that opened it. `collapseComposer` carries the
  abandoned-new-task purge that `commitRename` already had, so a ⌘N row closed
  without a title is purged rather than folded back as an empty row.
- **[P2] Hero-glide between closed row and open editor**
  (`matchedGeometryEffect` anchors on title + checkbox). Cosmetic but it's what
  makes inline editing feel continuous rather than modal.
- **[P3] Notes inline** (shell has notes in the inspector only).

## 2. Task Conversations (agent threads)

`KitConversationView` (`Septask/SeptaskKitConversation.swift`) renders the
thread in the INSPECTOR, below Notes, per
`docs/SEPTASK_CONVERSATIONS_PLAN.md`. One surface, not three — no conversation
tab, no separate window.

- **[DONE] Transcript rows, question block, "other" free text.** Same turn
  filtering and the same "the open question IS the title" promotion as
  `ConversationCard`: provider turns show their question, or their narration
  dimmed; user turns show what was chosen or typed behind a green check.
  Options are `KitPillButton`s — the shell's existing recessed-capsule
  language, not a second button style — with an "Other…" pill that reveals a
  text field. Replies append USER turns only, with `seq: 0` so
  `appendConvoTurn` assigns the real sequence; `propose` turns still come
  exclusively from the agent/gateway.
- **[DONE] Artifact block and handoff button.** Artifact renders selectable
  (it is usually meant to be copied out). Handoff is a REAL button only when
  there is somewhere to go — the `open_url` / `mailto:` / `tel:` mapping is
  copied verbatim from `ConversationCard.actionURL`, and `.none` degrades to
  plain instruction text rather than a button that does nothing.
- **[DONE] End state, acceptance, assignee** — read-only, per the plan.
  `wontDo` reads grey and neutral rather than red: deciding not to do
  something is a valid outcome, not a failure.
- **[DONE] The Discuss pill.** In `KitComposerCell`, gated on exactly SwiftUI's
  `showsDiscuss` terms — no conversation yet AND `OnDeviceAI.isAvailable` — so
  a pill that could start nothing never appears. It calls
  `ConversationEngine.advance(task:)`, a LOCAL on-device round trip with no
  gateway in the loop, which is what makes the pill viable here at all. The
  pill reads "Thinking…" and disables while in flight.

**One deliberate deviation from the plan.** It called for
`mutator.acknowledge(id:)` when the inspector opens on an agent-cued row. The
inspector does NOT do that, because its own contract (see `show(_:)`) is that
opening to peek must never ratify: the cue IS Inbox membership for agent rows,
so acking on open would yank a proposal out of the Inbox merely because it
became the selected row. Disposition paths ack; looking does not. The plan
predates that rule — code wins.

Still open: rendering `subtasks` (epic decompose) as anything richer than the
stored ids, and any human override of assignee. Both were explicit v1
non-goals.

## 3. Row cues the shell doesn't draw

`KitCheckboxView` now draws the same cue vocabulary as `TaskCheckbox`.

- **[DONE] Today tenure dial** — gold interior deepening per carried day
  (`todayTenureFill()`), capped at 70% opacity.
- **[DONE] Unread-context corner dot** — haloed dot for a committed task with
  a started conversation (`conversation.hasStarted`).
- **[DONE] Agent cue ring** — drawn from `showsAgentCue()`.
  `mutator.acknowledge(id:)` runs when the composer or inspector opens on an
  agent-cued row, so engaging clears the glow (same as SwiftUI).
- **[DONE] Check celebration.** `KitCheckboxView.playPulse(color:reach:)` —
  the AppKit twin of `TaskCheckbox.pulse`, same numbers (0.9 → 1.9, opacity
  0.55 → 0, ease-out 0.4s). A `CAShapeLayer` rather than `draw(_:)`: the ring
  has to leave the box's 22pt hit column, so `masksToBounds` is explicitly
  false. Fires from `fire()` on the way IN only — unchecking is a correction,
  not an achievement — and `isDone` is still the pre-toggle state there, so it
  plays exactly once per completion. Only `.stamp` is ported; the other three
  feels are for non-task rows the shell doesn't draw.
- **[DONE] Promote flash.** Two halves, like SwiftUI: the gold ring at the box
  (`playTodayPromotePulse`, tighter 1.6 reach) and the row wash
  (`KitCardRowView.playPromoteWash`, same 0.22 peak). The wash is stepped by a
  timer because that row paints itself in `drawBackground` — there is no layer
  property to animate. It is NOT a second selection language: transient, the
  temporal accent rather than the selection token, never persistent.
  `cancelPromoteWash()` runs in `rowViewForRow` because row views are recycled
  and a fading wash would otherwise ride onto an unrelated task.
  The controller holds `pendingPromoteFlash`, a one-shot set — the cue plays
  against a cell that only exists after the reload the promote triggered, so
  the intent has to outlive the mutation by exactly one reload.
- **[DONE] Filing-suggestion capsule.** `KitSuggestionChipView` — a real
  `NSButton` (it is an action, and the house rule is no gesture recognizers),
  same metrics and fill as `KitChipView` so the two read as one family. It
  wears the DESTINATION's name, not the word "Suggested": "→ Kitchen" says what
  the tap will do.
  **The gate was hoisted, not copied**: `Septena/Shell/Tasks/TaskFilingSuggestions.swift`
  now owns "which rows are suggestible" and BOTH shells call it —
  `TaskListView.filingRankedSuggestions` is a one-line delegation now. It lives
  in `Shell/Tasks` rather than `SeptenaCore` because the gate reads
  `TaskRowFlags` / `SettingsKey`, which are Shell-level; `Shell/Tasks` compiles
  into both apps and the AppKit shell, so it is the shared layer here.
  Applying mirrors `TaskListView.applySuggestion` step for step, including the
  triage promote flash and undo via `TaskUndo.recordMove`.
  Still missing: suggestions in the Move MENU (the context menu's "Suggested"
  section) — the capsule covers the one-tap path only.

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
    **[DONE] Discoverability.** Project pages now end with an "Add Section"
    footer row (`Row.addSection` → `KitAddSectionCell`), the counterpart of
    `TaskListView.addSectionButton` — same copy, same meta font and secondary
    ink, and it routes to the same `menuNewSection()` the right-click path
    uses. `projectGrouped` appends it last, so it lands above the logged
    footer exactly like SwiftUI's. Unselectable, like the logged footer, so it
    stays out of arrow-nav. Still no menu-bar command or shortcut for it —
    that would need the SwiftUI arm too (the one-menu-bar rule), so it was
    left out of this pass.
  - **[DONE] Filing a task under a heading by DRAGGING it there** — project
    pages now GROUP by heading (`projectGrouped`, mirroring
    `TaskListView.projectGroupedRows`: un-headed block first, then each
    heading + members; headings fetched via `LocalCache.headings(inProject:)`
    since they never ride through `tasks(in:filter:)`). Drop uses
    `acceptGroupedTaskDrop` / `acceptHeadingReorder` (AppKit gap-model
    counterparts of `handleGroupedTaskDrop` / `handleHeadingDrop`): drop
    below a heading files under it; drop onto a task joins that task's
    group and calls `setHeading`; pure heading drags reorder among
    headings. Midpoint-exhaustion renumber via shared `applyManualOrder`.
    Headings break the card run (`isCardRow` false) so each section is its
    own card, matching SwiftUI.
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
- **[DONE] Next feed.** Sidebar row ("Next", after Today) swaps the detail
  pane to a hosted `SeptaskNextPage` (`SeptaskKitNext.swift`) — same shared
  feed body as iOS SwiftUI's `SeptaskNextPage` (`SeptaskNextFeed`: suggestions +
  chores / habits / supplements, no Tasks Today / Done log / training). AppKit
  deliberately does NOT append Next at the foot of the Today table
  (heterogeneous NSTableView rows would fight the shell); a separate sidebar
  destination is the AppKit-shaped answer. Mood / nutrition suggestion sheets
  present from the page. Open-count badge via `KitNextCount`.
- **[DONE] Reminders inbox import.** `SeptaskKitTaskList.swift`, "Reminders
  inbox" section — `remindersBlock()` sits between `agenda()` and
  `triageBand()`, the same slot SwiftUI's `remindersRow` occupies. Today only,
  and ONLY when something is pending: no setup CTAs here, matching SwiftUI's
  `showsSetupCTAs: false`, so a user who never nominated a list sees nothing
  rather than a permanent prompt. Grant-access / pick-a-list stay in the hosted
  SwiftUI Settings pane, so there is no second copy of that flow.
  Import semantics are unchanged — title + due date as a DEADLINE + notes, then
  delete the original so dedupe is automatic. Both paths are undoable through
  `TaskUndo.recordCreate`; undo deliberately does NOT re-create the row in
  Apple Reminders, since writing to another app's data on the user's behalf is
  not ours to do. Two cells: `KitRemindersHeaderCell` (title + Import All +
  spinner) and `KitReminderCell` (whole row is the button). Refreshed from
  `.EKEventStoreChanged`, which fires for every list, so `refreshReminders`
  diffs the resulting set and only reloads when the mirrored list moved.
- **[P3] Things import** (`ThingsImportView`) — one-time migration, fine in the
  classic window.
- **[P3] Task patterns section.**
- **[P3] Time travel sheet** (DayClock debug offset). The shell honors
  `SeptenaDate.today` everywhere, but can't *change* it.
- **[DONE] Welcome / onboarding gate.** `SeptaskKitWelcome.swift` hosts the
  SAME `SeptaskWelcomeView` the SwiftUI gate uses, as a sheet over the shell
  window, against the same `septask.welcome.completed` key and the same
  demo-seed bypass. Hosted rather than ported for the same reason Settings is
  (a welcome is a form surface, not a latency surface), so there is one
  welcome with two presenters. The view is now internal with an explicit
  `init(onComplete:)` — its memberwise init is `private`, because its stored
  properties are, so the AppKit host could not otherwise construct it. The
  sheet's style mask deliberately omits `.closable`: "Get Started" is the only
  exit, the AppKit counterpart of `.interactiveDismissDisabled()`. Mounted
  from `SeptaskMacAppDelegate` (both at launch and on Dock-reopen, in case the
  shell window wasn't up the first time), NOT from `SeptaskKitWindow.swift`.

## 6. Platform integration

- **[DONE] Localization.** `SeptaskKit*.swift` chrome goes through
  `String(localized:comment:)` against the shared `Localizable.xcstrings`
  (same keys as SwiftUI where they already existed — smart lists, logged
  footer plurals, delete-area/project bodies, recurrence cadences). User
  data (task/project/area titles) stays verbatim. Smoke-test with
  `-AppleLanguages (pt-BR)`.
- **[DONE] Undo / redo.** `SeptaskKitTaskListController` owns an `UndoManager`
  (overrides `NSResponder.undoManager` — there's no `NSDocument`, so
  `NSWindow.undoManager` is nil by default and won't do this for free) with
  symmetric undo/redo registration. Now covers every value-level mutator the
  shell offers: complete/reopen (single + batch + the composer's checkbox),
  delete/restore, rename, move, **When / Deadline / Clear Dates / Today toggle
  / repeat**, and **create / duplicate / paste**. Standard ⌘Z / ⌘⇧Z, standard
  Edit menu.
  - **The stack is now SHARED, not shell-owned** (`SeptenaCore/TaskUndo.swift`).
    Owning it here made ⌘Z a property of one of four task surfaces: a user who
    learned it on the Mac lost it on iPhone, where ⌘Z isn't even inert — it
    reaches whatever text field holds focus, so the mistake looks handled when
    it wasn't. `kitUndoManager` is now a computed property returning
    `TaskUndo.manager`; nothing else in this controller changed, it just
    registers its inverses somewhere the other surfaces can see. The helpers
    (`ScheduleSnapshot`, `recordCreate`, the restore-order rule) moved to core
    verbatim, and the SwiftUI list now records complete / delete / dates /
    Today / repeat against the same stack. iOS gets shake-to-undo and the
    three-finger gesture for free: the app delegates override
    `UIResponder.undoManager`, which is the last stop in the responder chain,
    so a focused text field still wins for typing.
    Recording stays EXPLICIT and never happens inside `TaskMutator` — the
    mutators are also driven by CloudKit applies, the 30-day purge, recurrence
    spawning, and the watch, and recording there would put sync traffic on the
    user's undo stack and let ⌘Z "undo" another device's edit.
  - Scheduling undo goes through **`ScheduleSnapshot`** — capture
    `scheduled` / `today` / `deadline` / `recurrence` before the change,
    replay them through the same mutators after. **Restore order is
    load-bearing:** `schedule` and `setDeadline` each carry their own Today
    side effects (`removeFromToday` even clears an already-landed scheduled or
    deadline date), so the explicit Today flag is written LAST and wins, via
    `moveToToday(id:today:)` rather than `removeFromToday`. Known fidelity
    limit: `todaySetOn` re-stamps to the current day, so undo restores Today
    membership but not the row's original tenure age (the gold dial resets).
  - Creation undo **re-creates on redo** rather than restoring — `purge` is a
    real delete, so there is no row left to bring back. That mints a new id,
    which is why `recordCreateUndo` keeps a mutable id box both closures read.
- **[DONE] Paste (⌘V) to create tasks** from clipboard text — one task per
  non-blank line, filed exactly where ⌘N would file it (`creationContext` is
  now shared by both, so they cannot disagree). `SeptaskKitTableView` answers
  `paste(_:)` on the responder chain, the mirror of its `copy(_:)`, and
  validates the item so Edit ▸ Paste greys out in Logbook / Recently Deleted
  or with a non-text clipboard. Lines are created back-to-front because
  `create` inserts at the top of its group, which is what leaves the pasted
  block in reading order. Undoable as one action.
- **[DONE, floor] Accessibility.** Custom-drawn checkbox, sidebar disclosure
  chevrons, task/heading rows, screen/group titles, and the logged footer
  expose VoiceOver roles/labels via `TaskA11y` + AppKit helpers in
  `Accessibility.swift`. Shared cue strings match SwiftUI
  (`Added by Claude…`, `Has notes`, …). Deeper work (task rotor, FKA
  regression, Dynamic Type audit) stays on `docs/BACKLOG.md`.
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
- **[P2] Claude reconnect cue.** The shell draws none. `ClaudeReconnectCue` is
  gated `#if SEPTASK && os(macOS)` inside `TaskListView`, which only renders in
  the classic window — so the default shell has no in-app recovery affordance.
  The auth path itself is fine on macOS: `ASWebAuthenticationSession` already
  presents over an `NSWindow` anchor, and the gateway holds ONE rotating token,
  so a Mac re-mint serves every device. The macOS pre-expiry NOTIFICATION now
  works (`ClaudeReconnectNudge` is gated on `canImport(UserNotifications)`, and
  `SeptaskMacAppDelegate` handles the tap), so this is the remaining half.

## 7. Smaller behavior gaps

- **[DONE] Custom recurrence.** `SeptaskKitDatePopover.swift` — interval
  `NSTextField` + `NSStepper` (1–99, clamped by a `NumberFormatter`), unit
  popup, and an after-completion / on-scheduled-date mode popup, with a live
  cadence sentence. `RecurrencePickerSheet` was rewritten to the same shape in
  the same change, so the two editors read as one control in two toolkits.
- **[DONE] Today "rolled into Today" banner** (the entry here used to call
  this a "review band" and described a bucket that does not exist — see the
  correction that follows). `SeptaskKitTaskList.swift`, "Rolled-into-Today
  banner": `rolledInBanner(_:)` counts rows ALREADY on Today whose `scheduled`
  is strictly before today, and emits one dismissible notice between the
  agenda and the Reminders block — the slot SwiftUI's `newTodosBannerRow`
  occupies. `KitRolledInBannerCell` draws its own card rather than riding
  `KitCardRowView`, so it stays a separate notice instead of merging into the
  agenda run, exactly as SwiftUI's own `.background` does.
  Dismissal writes the SAME `septena.newTodos.dismissedDate` key, so
  dismissing in one shell dismisses in the other, and it returns tomorrow.
  **Correction, kept for the record:** there is no separate `review` bucket in
  the SwiftUI shell. `TaskListView.rolledInReview` filters `items` — the rows
  already on Today — and the old `review` bucket was only ever assigned `[]`,
  which is why the banner never appeared before it was rewritten. Anyone
  "finishing the port" by adding a second section would be building something
  SwiftUI does not have.
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

The four items that were queued here (Reminders import, row cues, the
rolled-into-Today banner, Task Conversations) all landed on 2026-08-21. What is
left is the [P2]/[P3] tail:

1. **Claude reconnect cue** (§6) — the shell still draws none; the macOS
   notification half already landed.
2. **Hero-glide between closed row and open editor** (§1) — cosmetic, but it is
   what makes inline editing feel continuous rather than modal.
3. **Suggestions in the Move menu** (§3) — the one-tap capsule shipped; the
   context menu's "Suggested" section did not.
4. Everything else in §1/§4/§5/§6/§7 as it comes up.

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
