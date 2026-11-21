# Touch multi-select (swipe to select) & multi-task drag — spec

**Status:** building (2026-11-21 — M0–M2 implemented; M3 optional). Defaults in §10 stand unless mz overrules.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0002](adr/0002-own-backend-replaces-icloud.md).
**Builds on:** `Septena/Shell/Tasks/TaskListView.swift`, `Septena/Shell/UI/SelectableScrollList.swift`, `Septena/Shell/Tasks/TaskListChrome.swift`, `Septena/Shell/Tasks/TaskComponents.swift`, `Septena/Shell/Sidebar/SidebarView.swift`, `Septena/Shell/Sidebar/AreasProjectsView.swift`, `Septask/SeptaskRootView.swift`, `SeptenaCore/CloudKit/TasksBackend.swift`, `SeptenaCore/TaskUndo.swift`, [DRAG_AND_DROP.md](DRAG_AND_DROP.md), [DesignSpec.md](DesignSpec.md) (§4.5).
**Coordinates with:** [IOS_SWIPE_ACTIONS_SPEC.md](IOS_SWIPE_ACTIONS_SPEC.md) (#132 — see §3.1 for swipe-direction alignment).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

---

## 1. Goal

Let a user on iPhone and iPad **swipe a task to select it** (Things-style touch multi-select), tap or swipe additional tasks into the selection, and **drag the whole selected stack straight into a project** (or area, Today, heading, or list position) — plus act on the selection via a compact bottom action bar — while keeping macOS and iPad pointer selection unified on the exact same `selection: Set<String>` state.

**Design principles:**
- **Zero layout shift:** Entering touch multi-select does **not** slide checkboxes sideways or introduce iOS `EditMode` circles. Selected rows use the app's one canonical selection fill (`Theme.listSelectionFill` via `TaskCardChrome`, per `DesignSpec.md` §4.5).
- **One state, one payload, one undo stack:** Touch multi-select drives the existing `TaskListView.selection: Set<String>`, `TaskDragIDs(ids:)`, and `TaskUndo` — never a parallel selection store or duplicate move logic.
- **Scroll-safe & native-first:** Horizontal swipe-to-select never steals vertical scroll or interactive back-swipe; drag-and-drop uses native `TaskDragIDs` / `.draggable` / `.onDrop`.

---

## 2. What exists today vs. what needs to be made

Code audit as of 2026-11-21:

### Already exists
- **Unified selection model:** `@State private var selection: Set<String> = []` + `ListSelectionScope` in `TaskListView.swift` + `SelectableScrollList.swift`.
- **Canonical row selection fill:** `TaskCardChrome(isSelected:)` (`TaskListChrome.swift:131`) paints `Theme.listSelectionFill` in both standard and Liquid Glass modes and suppresses inner separators between selected rows.
- **Multi-ID drag payload:** `TaskDragIDs(ids:)` (`TaskComponents.swift:11`) and `dragPayload(for:)` (`TaskListView.swift:513`) already bundle `orderedActionIDs()` whenever `selection.contains(task.id) && selection.count > 1`.
- **Multi-ID drop handlers:** `SidebarTaskDrop` (`SidebarView.swift:1786`), `handleTodayMoveDrop`, `handleGroupedListMoveDrop`, `handleUpcomingDateDrop`, `handleReorderDrop`, `handleGroupedTaskDrop`, and `applyMove(_ ids:areaId:projectId:)` all accept `[String]` with one `TaskUndo` entry + toast.
- **Batch actions:** `openWhenForSelected()`, `openMoveForSelected()`, `toggleSelected()`, `deleteSelected()`, and `copyTasks()` already exist in `TaskListView.swift`.
- **macOS AppKit parity:** `SeptaskKitTaskList.swift` + `SeptaskKitSidebar.swift` already support `⌘`/`⇧`-click multi-select and dragging multiple tasks onto sidebar Projects, Areas, Today, Upcoming, and Anytime.

### Missing (what this spec introduces)

| # | Gap in current code | Where | Section |
|---|---|---|---|
| 1 | **No swipe-to-select gesture.** `TaskListView` intentionally uses `SelectableScrollList` (`ScrollView`/`LazyVStack`), not SwiftUI `List`, so `.swipeActions` cannot attach; rows currently have zero horizontal swipe gesture. | `TaskListView.swift`, `TaskListChrome.swift` | §3 |
| 2 | **No touch multi-select mode on iPhone or touch iPad.** `usesSelectionModel` is `false` on compact iPhone (`TaskListView.swift:1413`), and iPad `TouchOrPointerTap` (`SelectableScrollList.swift:195`) only selects on pointer hover — finger tap has no way to enter or extend a selection. | `TaskListView.swift`, `SelectableScrollList.swift` | §4 |
| 3 | **No iOS touch multi-select action bar & `MagicPlusOrb` coordination.** `taskBatchActionBar` (`TaskListView.swift:1358`) is gated on `usesSelectionModel && selectionScope.isMulti`, lacks `When` and `Done`, uses a plain Mac strip, and overlaps `MagicPlusOrb` on iPhone. | `TaskListView.swift`, `TaskListToolbars.swift`, `SeptaskRootView.swift` | §5 |
| 4 | **Plain drag preview.** `.draggable` (`TaskListView.swift:3254`) renders a bare `"N tasks"` text pill instead of a stacked-card preview with count badge. | `TaskListView.swift`, `TaskListChrome.swift` | §6.1 |
| 5 | **`AreaDetailView` project rows are not drop targets.** `AreasProjectsView.swift:192` renders projects right above loose area tasks, but `projectRow(project)` has no `TaskMoveDrop` — you can't drag tasks into an Area's own projects. | `AreasProjectsView.swift` | §6.2 |
| 6 | **Compact iPhone sidebar rejects task drags.** `SidebarTaskDrop` (`SidebarView.swift:1846`) has `guard usesPushNavigation else { return false }`, blocking drops onto Projects/Areas in the Tasks index even during two-finger cross-tab/back navigation. | `SidebarView.swift` | §6.2 |
| 7 | **No one-handed iPhone drag-to-off-screen-project path.** When viewing Today, Inbox, or Project A on compact iPhone, target Project B is off-screen. | `SeptaskRootView.swift` / `TaskListView.swift` | §6.3 |
| 8 | **Multi-task move reverses order at destination.** `TasksBackend.moveToList` (`TasksBackend.swift:1241`) stamps `TaskOrder.topPosition(in: context)` per call, so looping `[A, B, C]` lands them upside down as `[C, B, A]`. | `TasksBackend.swift`, `Outbox.swift` | §7 |
| 9 | **Stale `selection` after drop.** Dropping tasks into another list via `SidebarTaskDrop` or `AreaDetailView` doesn't clear `TaskListView.selection` / exit touch selection mode. | `TaskListView.swift` | §7 |

---

## 3. Swipe-to-select gesture (iOS / iPadOS)

### 3.1 Gesture & direction (coordination with #132)

- **Swipe left (trailing → leading):** **Toggle selection** *(default, matches Things 3 iOS)*.
  - Pull left past `36pt` commit threshold → `Haptics.tick()` fires once; release toggles `task.id` in `selection` and springs the row cleanly back to `0pt` (`a11yAnimate(.snappy(duration: 0.22))`).
  - Rubber-band clamp at `~56pt` max travel so the row feels physical and never opens an empty void.
  - Because this is a **momentary pull-and-release toggle** (not a sticky action tray), it never gets stuck open or requires a second tap.
- **Swipe right (leading → trailing):** Reserved for #132's quick-schedule action (**When…** or **Today**, per `docs/IOS_SWIPE_ACTIONS_SPEC.md`). Keeping **left = Select** and **right = When / Today** makes the two specs completely orthogonal instead of fighting over the same edge. *(Note: if #132 later ships configurable trailing actions, "Select" stays the default trailing pull.)*

### 3.2 Scroll-safe gesture arbitration on `SelectableScrollList`

A plain SwiftUI `.gesture(DragGesture())` on a `ScrollView` row steals vertical scrolling. Because the deployment target is iOS 26.0, implement a clean `#if os(iOS)` modifier (`.taskRowSwipeToSelect(...)`) using first-party SwiftUI **`UIGestureRecognizerRepresentable`** wrapping a `UIPanGestureRecognizer`:

1. **`gestureRecognizerShouldBegin`:**
   - Reject immediately if `abs(velocity.y) >= abs(velocity.x) * 0.7` → vertical scroll wins on frame 1 with zero lag.
   - Reject if touch started within `24pt` of the screen's leading edge → `NavigationStack` interactive edge-back gesture always wins.
   - Reject right-to-left check when swipe-left isn't active (only claims horizontal leftward pulls; rightward pulls pass through to #132 or scroll).
2. **Arbitration with `.draggable` (long-press lift) and tap:**
   - `.draggable` activates only after a stationary long-press; a moving horizontal pan cancels long-press cleanly.
   - Once `isTouchSelecting` is active, a horizontal swipe never triggers tap-to-toggle on release.
3. **Zero private APIs, zero event monitors** — pure `UIGestureRecognizerRepresentable`.

### 3.3 Visual & accessibility feedback during swipe

- Row content translates left inside its card slice (`clipShape(position.cardShape)` so outer card corners stay sharp).
- Behind the trailing edge of the row, reveal a single calm glyph:
  - Unselected row: `circle` (muted) → morphs to `checkmark.circle.fill` in `Color.accentColor` with a subtle scale pop when crossing the `36pt` commit threshold.
  - Already-selected row: `checkmark.circle.fill` → morphs to `minus.circle` when crossing `36pt` to signal deselection.
- **Reduce Motion (`@Environment(\.accessibilityReduceMotion)`):** Replace horizontal slide with a subtle opacity/badge pulse on pull; commit still toggles cleanly.
- **VoiceOver:** Mirror on every selectable task row as `.accessibilityAction(named: isSelected ? "Deselect" : "Select") { toggleTouchSelection(task.id) }`.

### 3.4 Where swipe-to-select is disabled

- macOS (always disabled; Mac uses click / `⌘`-click / `⇧`-click).
- While an inline editor is open (`expandedEditId != nil`) — swiping is suppressed (or collapses the editor first without selecting).
- Non-task rows: section headings (`isHeading == true`), quick-add rows, calendar agenda rows, Get Started notice rows.
- `filter == .recentlyDeleted` in Phase 1 *(default; can add batch Restore / Delete Permanently in a follow-up)*.

---

## 4. Touch multi-select mode (iPhone & iPad touch)

### 4.1 Unified state machine (avoiding the iPad pointer trap)

Keep the existing `@State private var selection: Set<String> = []` as the single source of truth, plus one iOS-only mode flag:

```swift
#if os(iOS)
@State private var isTouchSelecting = false
#endif
```

Why `isTouchSelecting` is separate from `!selection.isEmpty`:
- On **iPad with a trackpad/keyboard**, a single pointer click sets `selection = [id]` as the keyboard cursor. That must **not** flip the screen into touch multi-select mode or change subsequent taps into toggles.
- On **iPhone or iPad touch**, swiping a task sets `isTouchSelecting = true` and inserts `task.id` into `selection` (closing any open inline editor first).

### 4.2 Interaction rules while `isTouchSelecting == true`

| Gesture | Behavior |
|---|---|
| **Tap any task row** | Toggles `task.id` in `selection` (with subtle `Haptics.tap()`). Does **not** open inline editor. |
| **Tap a row's checkbox** | Also toggles `task.id` in `selection` (prevents accidental completion while rapidly building a selection). Checkboxes soften slightly (`opacity: 0.45`) while `isTouchSelecting` is true to cue that rows are in selection mode *(default)*. |
| **Swipe left on any task row** | Also toggles `task.id` in `selection` (consistent muscle memory). |
| **Long-press + drag a selected row** | Lifts **all selected tasks** as one `TaskDragIDs(ids: orderedActionIDs())` stack (§6). |
| **Long-press + drag an unselected row** | Lifts just that 1 row (standard iOS/macOS behavior; leaves `selection` untouched unless dropped out of view). |
| **Long-press (without dragging)** | Opens `TaskListRowContextMenu` scoped to the bulk selection (`actionTarget(for:)` already handles this). |
| **Deselect last selected row** | When `selection` becomes empty, `isTouchSelecting` automatically resets to `false`. |
| **Tap `Done` / tap empty canvas / switch filter or tab** | Clears `selection = []` and sets `isTouchSelecting = false`. |

### 4.3 Visual treatment (DesignSpec §4.5 compliance)

- Selected rows paint `Theme.listSelectionFill` via the existing `TaskCardChrome(isSelected:)` — identical to iPad/Mac pointer selection, zero competing highlight system.
- Checkboxes stay in their normal leading column (no `EditMode` leading circle shift).
- On iPhone (`!usesPushNavigation`), `SelectableScrollList` receives `selectable: usesSelectionModel || isTouchSelecting` and a dedicated `toggleOnTap: isTouchSelecting` flag so `TouchOrPointerTap` routes finger taps to toggle-membership instead of `activate`.

---

## 5. Multi-select chrome & action bar (iOS / iPadOS)

### 5.1 Visibility rules

- **Touch multi-select (`isTouchSelecting && !selectionScope.isEmpty`):** Show the touch selection bar starting at **1 selected task** (not 2!), because swiping a single task is also a fast way to hit `When` / `Move` / `Delete` or add more tasks.
- **Pointer / keyboard multi-select (macOS, iPad trackpad):** Keep showing the bar only when `selectionScope.isMulti` (2+ selected tasks), preserving today's calm single-cursor experience.

### 5.2 Top & bottom chrome (iOS 26)

- **Top navigation bar (while `isTouchSelecting`):**
  - Trailing: **`Done`** button (prominent tint or standard bold Done) to exit selection mode immediately.
  - Leading (optional compact button when `usesPushNavigation` or inside bar): **`Select All`** (or `Deselect All` when all visible tasks in the current list are selected).
- **Bottom floating selection bar (`.safeAreaInset(edge: .bottom)`):**
  - Compact glass bar / floating capsule matching iOS 26 chrome, displaying:
    1. Count label (`"3 selected"` — compact pill or leading label).
    2. **When** (`calendar`) → `openWhenForSelected()`.
    3. **Move** (`arrow.right` / `folder`) → `openMoveForSelected()`.
    4. **Complete** (`checkmark.circle`) → `toggleSelected()`.
    5. **Delete** (`trash`, destructive role) → `deleteSelected()`.
    6. **More (`ellipsis.circle`)** menu → *Move to Today* / *Remove from Today* (context-aware), *Copy Titles* (`copyTasks`), *Select All*, *Cancel Tasks*.
  - **Every action** reuses the existing `TaskListView` batch functions (single `TaskUndo` entry + toast) and clears `selection` / `isTouchSelecting` once the action commits.
- **`MagicPlusOrb` coordination (`SeptaskRootView.swift`):**
  - Publish `isTaskMultiSelectActive: Bool` on `NavigationState` (updated from `TaskListView` while `isOnScreen && isTouchSelecting`; cleared on disappear/route change).
  - `SeptaskRootView` hides (fades + disables hit-testing on) `MagicPlusOrb` while `nav.isTaskMultiSelectActive == true`, so the floating `+` orb never overlaps the bottom selection bar on iPhone.

---

## 6. Dragging multiple tasks into a project

### 6.1 Lift gesture & stacked card preview

- Lifting any row in `selection` (via long-press on iOS/iPadOS, or click-drag on macOS/iPad pointer) produces `TaskDragIDs(ids: orderedActionIDs())` — strictly in visible list order, excluding non-task rows (`TaskNoticeStep`, headings unless dragging a single heading).
- Replace the bare `"N tasks"` pill (`TaskListView.swift:3254`) with a shared **`TaskDragStackPreview`**:
  - **1 task:** Compact rounded card (`Theme.cardSurface` / `.regularMaterial`, 10pt radius, subtle border + shadow) showing the task title (1 line, truncated cleanly).
  - **2+ tasks:** The primary dragged task's card on top, 1–2 subtle offset backing cards (`2pt`/`4pt` Y offset, slightly narrowed) behind it to convey a physical stack, plus a top-trailing accent count badge (`3`, `12`) using high-contrast ink.
- **Note on SwiftUI `.draggable` preview:** `.draggable(payload) { preview }` renders the preview snapshot at lift time; keep `TaskDragStackPreview` lightweight and pure SwiftUI with explicit fixed max width (`~260pt`) so UIKit/AppKit snapshots it crisply on the first frame.

### 6.2 Every Project drop surface (cross-platform matrix)

| Surface | Platforms | Target | Current state | Change needed |
|---|---|---|---|---|
| **Sidebar Project / Area / Today rows** | Mac (AppKit) | `SeptaskKitSidebar` | ✅ Works | Fix batch order (§7) |
| **Sidebar Project / Area / Today rows** | iPad Split | `SidebarView` (`SidebarTaskDrop`) | ✅ Works | Fix batch order + clear source selection (§7) |
| **Tasks index Project / Area / Today rows** | **iPhone Compact** (two-finger tap Back or Tasks tab while dragging) | `SidebarView` (`SidebarTaskDrop`) | ❌ Blocked by `guard usesPushNavigation` (`SidebarView.swift:1846`) | Remove `usesPushNavigation` guard for task drops; allow `SidebarTaskDrop` to accept `TaskDragIDs` on compact iPhone too |
| **Area Detail → Projects card** | **iPhone, iPad, Mac** | `AreaDetailView.projectRow` (`AreasProjectsView.swift:192`) | ❌ Not a drop target | Attach `TaskMoveDrop` onto each `projectRow(project)` with `Theme.listSelectionFill` highlight + single `TaskUndo.recordMove` + toast |
| **Today & Anytime grouped project headers** | **iPhone, iPad, Mac** | `TaskListView.groupHeader` (`todayMoveDrop` / `handleGroupedListMoveDrop`) | ✅ Wired | Fix batch order + clear selection after drop (§7) |
| **In-project heading & reorder gaps** | **iPhone, iPad, Mac** | `headingRow` + `TaskReorderDrop` | ✅ Wired | Verify multi-ID relative order + clear selection on drop |
| **One-handed iPhone off-screen project drop** | **iPhone Compact** | Floating **Quick-Drop Project Tray** (Phase M3) | ❌ Missing | See §6.3 |

### 6.3 One-handed iPhone drag into an off-screen project (Phase M3)

On iPhone compact (`!usesPushNavigation`), if the user is in **Today**, **Inbox**, or **Project A**, the target **Project B** is not on screen:

1. **Immediate (Phases M0–M2, zero custom drag-session hacks):**
   - **On-screen projects** work immediately by direct drag: `AreaDetailView` project rows, Today/Anytime project headers.
   - **Two-finger native iOS drag** works across screens: lift selected stack with one finger → tap **Tasks** tab or **Back** with the other finger → drop directly onto any Project row in `SidebarView`.
   - **One-handed quick move:** Tap **Move** in the bottom selection bar → `MovePickerSheet` (search + 1-tap project pick).
2. **Progressive enhancement (Phase M3 — one-handed "Drag to Move" shelf):**
   - While a native `TaskDragIDs` drag is active on compact iPhone (`!usesPushNavigation`), hovering the dragged stack over the **Move** button in the bottom selection bar (or a compact `"Drop here to pick a Project…"` drop dock at the bottom edge) for `0.4s` springs open an **in-window overlay Project/Area Drop Tray** (a `ZStack` overlay inside `SeptaskRootView` / `TaskListView` — *not* a `.sheet`, so the active `UIDragSession` is never interrupted!).
   - Each Project (grouped by Area, plus Inbox / Today) in the tray carries `TaskMoveDrop` (`Theme.listSelectionFill` hover wash).
   - Releasing the finger over any Project drops the whole stack into that project with one `TaskUndo` + toast and dismisses the tray; dragging away / cancelling dismisses cleanly.

*Note on `AGENTS.md` standard-SwiftUI rule:* Native `onDrop` on an in-window `ZStack` overlay is 100% standard SwiftUI/UIKit drag-and-drop; keeping it as Phase M3 lets M0–M2 ship cleanly first and lets mz test whether two-finger drag + Move bar already covers the itch or whether the M3 spring-loaded tray earns its keep.

---

## 7. Backend, ordering, undo & selection-lifecycle invariants

### 7.1 Preserve relative order on batch move (bug fix in `TasksBackend`)

Today, `TasksBackend.moveToList(id:area:project:)` (`SeptenaCore/CloudKit/TasksBackend.swift:1241`) sets `entity.position = TaskOrder.topPosition(in: context)` on every single call. Moving `[A, B, C]` in a loop stamps `A=0, B=-1, C=-2`, **reversing** the selection to `[C, B, A]` at the destination.

**Fix:** Add a batch helper on `TasksBackend` and `TaskMutator`:

```swift
func moveToList(ids: [String], area: String?, project: String?, acknowledge: Bool = true)
```

Behavior:
1. Filter out no-op tasks already in the exact `(area, project)` destination.
2. Compute the destination's starting `topPosition` once (or iterate `ids.reversed()` when stamping `TaskOrder.topPosition`) so **`ids[0]` ends up at the very top, followed by `ids[1]`, `ids[2]`, …** in their exact original relative order.
3. Clear `heading = nil` on every moved non-heading task entering a new home (`DRAG_AND_DROP.md` §4).
4. If `acknowledge == true`, clear agent cue / ratify triage band tasks as today (`today = true`, `todaySetOn = today` when ratifying from Inbox).
5. **Single undo step:** Every caller (`TaskListView.applyMove`, `SidebarTaskDrop`, `AreaDetailView` project drop, `SeptaskKitSidebar`) records ONE `TaskUndo.recordMove(before:...)` covering the entire batch, and posts ONE toast (`"Moved N tasks to <Project>"` with Undo).

*(Backend sync / MCP note: this is purely a client-side batching/order fix over existing `moveToList` field writes — no new schema columns, no ADR required, and both MCP servers remain unchanged.)*

### 7.2 Selection cleanup after drop or batch mutation

- Whenever `TaskListView.load()` runs, prune `selection` to IDs still present in `keyboardOrderedTaskIds`. If `selection` becomes empty, set `isTouchSelecting = false`.
- After a successful local batch move/complete/delete or drop that moves tasks out of the current list (including cross-view `SidebarTaskDrop` or `AreaDetailView` project drop), clear `selection = []` and `isTouchSelecting = false` so the user lands back in normal browse mode instead of looking at an empty selection bar.
- **Reorder drop within the same list (`handleReorderDrop` / `handleGroupedTaskDrop`):** Keep selection intact on macOS/iPad pointer (standard desktop behavior so you can immediately reorder again or press a shortcut), OR clear `isTouchSelecting` on touch *(default: keep selection on pointer, clear after reorder on touch — see §10)*.

### 7.3 Shared-app parity (`Septena` & `Septask`)

- All swipe, touch-selection, stacked preview, `AreaDetailView` project drop, and `SidebarTaskDrop` code lives in shared folders (`Septena/Shell/Tasks`, `Septena/Shell/Sidebar`, `Septena/Shell/UI`, `SeptenaCore`). Both `Septena` and `Septask` inherit it automatically.
- `NavigationState.isTaskMultiSelectActive` lives on `NavigationState` (already injected in both app roots), so `SeptaskRootView` hides `MagicPlusOrb` with zero new `@Environment` launch-crash risk.

---

## 8. Phases

| Phase | Scope | Files touched | Depends on |
|---|---|---|---|
| **M0 — Batch move order fix + Project drop gaps** | Add `TaskMutator.moveToList(ids:area:project:)` preserving relative `[A, B, C]` order; add `TaskMoveDrop` to `AreaDetailView` project rows (`AreasProjectsView.swift`); remove `usesPushNavigation` block in `SidebarTaskDrop` (`SidebarView.swift:1846`); prune/clear stale `selection` after drop; upgrade `.draggable` preview to `TaskDragStackPreview`. | `TasksBackend.swift`, `Outbox.swift`, `AreasProjectsView.swift`, `SidebarView.swift`, `TaskListView.swift`, `TaskListChrome.swift`, `SeptaskKitSidebar.swift` | None |
| **M1 — Swipe-to-select & Touch Multi-Select Mode** | Build scroll-safe `#if os(iOS)` `UIGestureRecognizerRepresentable` horizontal swipe-to-select modifier (`36pt` pull-and-release, haptic tick, trailing check cue, Reduce Motion + VoiceOver `.accessibilityAction`); wire `isTouchSelecting` state machine in `TaskListView` + `SelectableScrollList` (`TouchOrPointerTap` tap-to-toggle, softened checkboxes, auto-exit when empty). | `TaskListChrome.swift`, `SelectableScrollList.swift`, `TaskListView.swift` | M0 |
| **M2 — iOS Multi-Select Action Bar & Chrome** | Build compact iOS 26 bottom selection bar (`When`, `Move`, `Complete`, `Delete`, `More ⋯`) + top `Done` / `Select All` chrome; show from 1+ selected task on touch (2+ on pointer); hide `MagicPlusOrb` while `nav.isTaskMultiSelectActive`; verify all batch actions record one `TaskUndo` + toast. | `TaskListView.swift`, `TaskListToolbars.swift`, `NavigationState.swift`, `SeptaskRootView.swift` | M1 |
| **M3 — One-handed iPhone Quick-Drop Project Tray *(optional)*** | Spring-load an in-window Project/Area drop overlay when hovering a dragged task stack over the bottom `Move` target on compact iPhone (`!usesPushNavigation`), allowing full one-handed drag-into-any-project from Today, Inbox, or another Project. | `TaskListChrome.swift`, `TaskListView.swift`, `SeptaskRootView.swift` | M2 |

---

## 9. Verification

Build verification (per `AGENTS.md`):
- `scripts/build.sh SeptaskMac 'platform=macOS'` (and iOS schemes when watchOS runtime matches, or Xcode.app on device).
- `scripts/lint-design.sh` green (no raw `withAnimation`, no white-on-accent-fill, no row dead zones).

Manual test checklist for mz (iPhone + iPad + Mac):
- [ ] **Swipe-to-select (iPhone & iPad touch):** Swipe left past threshold on a task → haptic tick, row springs back wearing `Theme.listSelectionFill`, bottom selection bar appears, `MagicPlusOrb` hides cleanly.
- [ ] **Scroll safety:** Fast vertical scrolling in Today/Project/Anytime never accidentally triggers swipe-to-select; leading edge-swipe back still pops `NavigationStack`.
- [ ] **Multi-select building & exit:** Tap 2 more rows → all 3 selected, count reads `"3 selected"`; tap one again → deselects; deselect all (or tap `Done`) → exits selection mode cleanly.
- [ ] **Drag multiple tasks → Project (Area view):** In an Area with loose tasks and projects above, swipe-select 3 tasks, long-press-drag stack (shows stacked card + `3` badge) onto a Project row → row highlights with `Theme.listSelectionFill`, drop moves all 3 into the Project **in their original order**, 1 toast with Undo, selection clears.
- [ ] **Drag multiple tasks → Project (iPad / Mac Sidebar & Today grouped headers):** Same multi-task drop works on sidebar Projects/Areas/Today and Today/Anytime group headers; Undo reverses all 3 in one step.
- [ ] **Drag multiple tasks → Project (iPhone cross-screen):** Lift 3-task stack in Inbox/Today with one finger, tap Tasks tab or Back with the other, drop onto any Project row in the Tasks index → moves all 3 cleanly.
- [ ] **Batch bar actions:** `When`, `Move`, `Complete`, `Delete`, `Copy` all work on 1+ selected tasks with single Undo.
- [ ] **iPad pointer parity:** Trackpad click on 1 row selects cursor without entering touch multi-select mode; `⌘`/`⇧`-click still works identically.

---

## 10. Open questions

Defaults stand unless mz overrules:

| Question | Default |
|---|---|
| Swipe direction for Select | **Swipe left** = toggle Select *(default, Things 3 iOS convention)*; swipe right stays reserved for #132 (When / Today). |
| Touch multi-select row visual | Pure **`Theme.listSelectionFill`** with softened checkboxes (`opacity: 0.45`) and **no** leading `EditMode` circles *(default — zero layout shift, strict DesignSpec §4.5 compliance)*. Alternative: add a quiet trailing checkmark glyph while selecting. |
| Threshold for showing touch action bar | **1+ selected task** when entered via touch swipe *(default — lets swipe-1 → When/Move/Delete work in 2 moves)*; **2+ tasks** for Mac/iPad pointer selection. |
| Selection state after in-list reorder on touch | Clear touch selection mode after dropping a reorder *(default)* vs. keep selected so you can immediately act again. |
| Scope of Phase M3 (one-handed iPhone Quick-Drop Project Tray) | Build **M0–M2 first**, evaluate two-finger cross-tab drag + Move button in real use, then build M3 if one-handed off-screen drag still feels needed *(default)* — or include M3 in the initial pass. |
| Multi-select in `Recently Deleted` | Excluded in Phase 1 *(default)*; add batch Restore / Delete Permanently in a follow-up if wanted. |
