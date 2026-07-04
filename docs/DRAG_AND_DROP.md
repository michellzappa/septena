# Task Drag &amp; Drop — Design Note

Scope: **tasks first** — dragging tasks to reorder, to re-home into areas /
projects / Today, and to file under project headings; plus the sidebar-side
moves (project → area, reordering areas/projects). Structured to extend to other
draggable domains later, but this note is normative for tasks only.

Companion docs: `docs/ORDERING_AND_HEADINGS_PLAN.md` (the `position` /
`kind=="heading"` model), `docs/SEPTASK.md` (shared-folder / composition-root
rules), `docs/IDENTIFIERS.md` (the id/FK contracts a drop rewrites).

---

## 1. First principles

A task drag only ever changes **two orthogonal things**, and every drop must be
expressible as some combination of them:

1. **Membership** — which container owns the task: `area`, `project`, `heading`
   FKs, plus the `today` pin. "Where does it live."
2. **Order** — the task's `position: Double` *within* whatever list currently
   renders it. "Where in the list."

There is **one drag gesture** and **one payload** (`TaskDragIDs`, multi-select
aware, over `UTType.septenaTaskDragIDs`). A single lift can resolve to any of
four drops:

| Drop | Membership change | Order change |
|------|-------------------|--------------|
| Reorder in place | none | set `position` between neighbors |
| Re-home to area/project (sidebar) | set `area`/`project`, clear the other + `heading` | land at top/bottom of destination |
| File under heading (in-project) | set `heading` | set `position` within the section |
| Pin to Today (sidebar) | set `today` | (keeps existing) |

**The unifying rule for both cross-platform *and* cross-app correctness:**
behavior keys off **surface co-visibility** and **shared code**, never off
device or app identity. Concretely —

- The only thing that varies by form factor is **whether the drop target is
  on-screen at the same time as the drag source.** That is already captured by
  one app-root signal, `usesPushNavigation`. Gate drop affordances on it; don't
  branch on `UIDevice.idiom`.
- The behavior lives in the **shared** `Shell/Tasks` + `Shell/Sidebar` folders,
  which compile into both apps. Write it once → Septena and Septask both get it.
  There is no per-app drag code, and there must never be.

Everything below is a consequence of these two facts.

---

## 2. Platform matrix

`usesPushNavigation` is resolved once at the app root and published to every tab
(`RootTabView` / `SeptaskApp`). It is **true on iPad-regular and Mac** (sidebar +
list co-visible in a `NavigationSplitView`) and **false on iPhone and compact
iPad** (Slide Over, narrow multitasking — sidebar is a separate pushed screen).
Despite the name, `true` = the split canvas, `false` = the push stack. Behavior
must derive entirely from this, so an iPad in Slide Over automatically behaves
like an iPhone with zero extra code — the foldable/parity invariant.

| Capability | iPhone / compact (`usesPushNavigation == false`) | iPad-regular / Mac (`== true`) |
|---|---|---|
| Reorder within a list (drag) | ✅ | ✅ |
| File under a heading (drag) | ✅ (within the visible project list) | ✅ |
| Move heading + its section (drag) | ✅ | ✅ |
| **Re-home to area/project (drag → sidebar)** | ❌ impossible (not co-visible) → **"Move…" sheet is the path** | ✅ `SidebarTaskDrop` |
| **Pin to Today (drag → sidebar)** | ❌ → context-menu "Move to Today" | ✅ |
| Lift gesture | long-press to lift | click-hold (Mac, immediate) / long-press (touch) |
| Multi-select drag | selection + drag (where multi-select exists) | ⌘/⇧-click selection, then drag |

Non-negotiables that fall out of this:

- **Every drag action needs a non-drag twin.** On compact, re-home *only* exists
  as a menu/sheet — so `MovePickerSheet` ("Move…"), "Move to Area/Section", and
  "Move to Today" are load-bearing, not conveniences. A drag capability without a
  menu twin is broken on iPhone by construction.
- **Keyboard / VoiceOver parity** (house rule: kbnav must work with Full Keyboard
  Access *off*). Drag reorder currently has **no** keyboard or VO equivalent —
  add `⌘[` / `⌘]` (or Move Up/Down menu commands) for the selected row, and keep
  the "Move…" menu reachable by keyboard. This is the accessibility floor, not a
  nice-to-have.
- **Auto-scroll** near list edges during a drag: the custom `DropDelegate` does
  not inherit it from `.onMove`, and it matters most on the small iPhone canvas.
  Must be added explicitly.

---

## 3. Cross-app (Septask ⇄ Septena) — shared by construction, policed by injection

The drag/drop code is in shared folders, so **parity is automatic** — but two
seams can silently break it, and both are composition-root, not compiler,
failures:

1. **Environment injection.** Anything the drag path reads via
   `@Environment` (today: `taskMutator`, `usesPushNavigation`, `theme`) must be
   published from **both** roots — `Septena/App/App.swift` /
   `RootTabView.swift` **and** `Septask/SeptaskApp.swift`. `taskMutator`,
   `areasMutator`, `projectsMutator`, `ckEngine` are injected in both today.
   `usesPushNavigation` has a **default value**, so a root that forgets to
   publish it doesn't crash — it silently disables sidebar drop. That's a
   *sneakier* failure than the usual launch crash. **Any new `@Environment` the
   drag path takes on → add to both roots in the same change.**
2. **Runtime profile.** Septask runs `RuntimeProfile.tasksOnly`, but the task /
   area / project mutators all exist there, so every re-home and reorder works.
   No drag capability may depend on a provider store.

**Verification gate:** after any change here, build **and launch** all four
schemes — `Septena`, `SeptenaMac`, `Septask`, `SeptaskMac`. The compiler catches
type seams; only a launch catches a missing injection.

---

## 4. Membership algebra — the normative drop table

Every drop resolves to exactly this set of field writes. This is the contract the
implementation (and the two MCP servers) must match. `heading` is cleared on any
move that leaves the owning project; `position` is always set deterministically.

| Drop target | `area` | `project` | `heading` | `today` | `position` |
|---|---|---|---|---|---|
| Reorder in same list | — | — | — | — | between neighbors |
| Area row | `= X` | `nil` | **`nil`** | — | **top or bottom of area list** |
| Project row | `nil` | `= Y` | **`nil`** | — | **top or bottom of project** |
| Heading row / under heading | (project's) | (unchanged) | `= H` | — | within section |
| Today row | — | — | — | `= true` (+`todaySetOn`) | keeps existing |
| Project dragged onto Area (sidebar) | project.`area = X` | — | — | — | sidebar order (see §6) |

"—" = unchanged. **top or bottom** is an open decision (§6, Decision A).

The current gap: the sidebar/menu re-home path (`SidebarTaskDrop.rehome` →
`moveToArea`/`moveToProject`) implements the `area`/`project` columns but **not**
the bold `heading = nil` and **not** the deterministic `position` — so a re-homed
task keeps a stale heading FK from its old project and lands at an arbitrary
sort spot. The in-list grouped-drop path (`handleGroupedTaskDrop`) *does* set
both. **The two paths must converge on this table.**

---

## 5. Current state vs. target (prioritized gaps)

| # | Gap | Where | Priority |
|---|-----|-------|----------|
| 1 | **Two re-home paths diverge.** Sidebar/menu re-home doesn't clear `heading` or set a landing `position`; in-list drop does. Unify in the backend so drag, menu, and MCP all inherit §4. | `TasksBackend.moveToArea`/`moveToProject`; `SidebarTaskDrop.rehome` | **P0 (model defect)** |
| 2 | ✅ **DONE** — sidebar area/project order now syncs. `position: Int` on `AreaEntity`/`ProjectEntity` rides the reserved `reservedInt1` CK slot (additive, rides prod cutover); Move Up/Down renumbers 1…N via `Areas/ProjectsMutator.reorder(orderedIDs:)`; `NavigationState.positionOrdered` sorts by it, falling back to the legacy `UserDefaults` order until the first reorder migrates everyone. | `Persistence`, `Area/ProjectRecord`, `Areas/ProjectsBackend`, `SidebarView`, `NavigationState` | ~~P1~~ |
| 3 | **Reorder disabled on date/tier-sorted lists** (Today, Upcoming) — `TaskReorderDrop.perform` is nil there. Decide: keep as derived-sort, or allow manual arrangement within Today like Things. | `TaskComponents`; `TaskListView` | P1 (decision) |
| 4 | **No drag-to-schedule** (drag task → a day in Upcoming to set `scheduled`). `schedule(id:date:)` exists; gesture unwired. Only meaningful where calendar + list co-visible. | — | P2 |
| 5 | **Project → Area is menu-only.** Dragging a project row onto an area (sets `project.area`) is the natural sidebar gesture and is missing. | `SidebarView`; `AreasProjectsView` | P2 |
| 6 | **No auto-scroll / spring-loading.** Custom `DropDelegate` doesn't get edge auto-scroll free; collapsed areas don't expand on hover-drag. | `TaskReorderDropDelegate`; `SidebarTaskDrop` | P2 |
| 7 | **No keyboard / VoiceOver reorder.** Add Move Up/Down commands + keep "Move…" keyboard-reachable. | `TaskCommands` | P1 (a11y floor) |
| 8 | **Two CloudKit writes per area drop.** `rehome(.area)` calls `moveToArea` *and* `moveToProject(nil)` → two `commitAndPush`. Fold into one mutator once §4 lands. | `SidebarTaskDrop.rehome` | P3 (cleanup, folds into #1) |

---

## 6. Open decisions (need a call before P0/P1 land)

- **Decision A — where a re-homed task lands.** Top or bottom of the destination
  list? Things drops at the top of the area/project; Reminders appends. Recommend
  **top** (most-recently-moved is most salient), consistent for drag *and* the
  "Move…" sheet.
- **Decision B — is sidebar arrangement user data?** ✅ **Decided yes + shipped**
  (gap #2). Area/project order follows the user across devices via a synced
  `position` field, like section color/enabled state — arrangement is user
  intent, not a device preference.
- **Decision C — is Today manually arrangeable?** Keep Today as a derived
  tier-sort (deadline/overdue → later → undated, then `position` within tier), or
  let the user drag freely within it? Recommend **keep derived** — Today's order
  carries meaning (urgency), and free reorder invites drift; but allow reorder
  *within* a tier (already the case).
- **Decision D — drag-to-schedule (gap #4) and project→area drag (gap #5):**
  in or out of this pass? Recommend **defer** both to a follow-up; they're
  additive and not part of the core model fix.

---

## 7. Implementation guidance

- **Fix the model in the backend, not the view.** Put the §4 field-write rules in
  `TasksBackend` (`moveToArea`/`moveToProject` clear `heading` when leaving the
  project and assign `TaskOrder.top/bottomPosition` in the destination). Then the
  sidebar drop, the "Move…" sheet, and MCP all inherit correct behavior — no
  view-layer duplication.
- **MCP lockstep.** Re-home semantics are exposed by both MCP servers (in-app
  `SeptenaCore/MCP/` and the hosted gateway). If §4 changes what a move writes,
  update **both** servers + the skill markdown in the same change — never one
  without the others.
- **Keep the custom `DropDelegate`** — it's justified (live hover position,
  insertion line, *one* gesture that reorders *or* re-homes cross-context, which
  `.onMove` can't do). This is the sanctioned exception to "prefer `.onMove`";
  the price is that auto-scroll and a11y (gaps 6, 7) must be added by hand.
- **Don't branch on device/app.** Every conditional in the drag path should read
  `usesPushNavigation` (co-visibility) or a capability of the target — never
  `#if SEPTASK` and never `UIDevice.idiom`.

---

## 8. Test checklist

Run per change, across **4 schemes × 3 form factors**:

- [ ] iPhone: reorder in a project; "Move…" sheet re-homes; drag-to-sidebar is
      correctly absent (no phantom drop highlight).
- [ ] iPad-regular: drag task → area / project / Today rows; drag under headings;
      move a heading (members follow).
- [ ] iPad Slide Over: behaves exactly like iPhone (drop gated off).
- [ ] Mac: same as iPad-regular; List selection + arrow nav still work after a
      drag (no focus/selection corruption — see the macOS List traps in CLAUDE.md).
- [ ] Re-homed task **loses its old `heading`** and **lands at the decided
      end** (Decision A) of the destination.
- [ ] Multi-select drag preserves relative order of the selection.
- [ ] Septask (iOS + Mac): all of the above — drop targets render, mutators fire.
- [ ] Keyboard: Move Up/Down + "Move…" reachable with Full Keyboard Access off.
