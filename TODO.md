# Septena — Things 3 Clone TODO

Central work file. Update as we go. Reference: `docs/things-reference/`.

## In progress / pending

### Persistence
- [ ] Confirm Convex backend has `areas:update` / `projects:update` mutations (client methods added)
- [ ] Wire sidebar drag-reorder to persist `sortOrder` via new mutations; drop in-memory `projectAreaOverrides` dict
- [ ] Add `notes` field to Area model + schema (so areas can have notes like projects)
- [ ] Add `areas:create` / `projects:create` mutations for creating new areas/projects from UI

### Sidebar polish
- [ ] Tune drag-reorder animation timing (may feel snappy on device)
- [ ] Area drop target when dragging an area (currently ignores dropping area onto project)
- [ ] Expand/collapse animation smoothness for nested projects
- [ ] Sidebar tap highlight: briefly pulse even if navigation is instant

### Inline new-task entry
- [ ] Wire "Today" chip → date picker sheet (Today / This Evening / Tomorrow / Someday / Custom)
- [ ] Wire tag icon → tag picker
- [ ] Wire checklist icon → add checklist items inline
- [ ] Wire flag icon → deadline picker
- [ ] Project/area assignment chip (for tasks created from sidebar)

### Task list interactions
- [ ] Swipe-right (short) → reveal schedule chips (Today / Evening / Tomorrow / Someday)
- [ ] Swipe-right (long) → instant-schedule to Today
- [ ] Swipe-left (short) → complete + more-actions
- [ ] Swipe-left (long) → instant complete
- [ ] Checkbox spring animation + strikethrough + fade + slide-out (per interactions.md)
- [ ] Haptic on checkbox complete
- [ ] Multi-select mode: long-press enters, radio circles appear, bottom action bar

### Screens not yet restyled
- [ ] `TaskDetailView` — Things-style inline detail (title, notes, checklist, metadata row)
- [ ] `AreaDetailView` — Things-style area overview
- [ ] `ProjectDetailView` — Things-style project list with pie icon
- [ ] `LogbookView` — grouped by completion date
- [ ] `ReviewView` — style to match

### Today screen
- [ ] Calendar events card at top (screenshot 3)
- [ ] Calendar integration (EventKit) to populate the card

### Magic Plus (V2)
- [ ] Drag-to-insert: press-and-drag Magic Plus to insert at specific list position
- [ ] Drag targets that appear around button: Today / Evening / Upcoming

### System / polish
- [ ] Dark mode (true-black OLED)
- [ ] Haptics throughout (checkbox, swipe commits, long-press, drag snap)
- [ ] Quick Find search implementation
- [ ] Empty states for each list (per Things conventions)
- [ ] Pull-down on list to reveal Quick Find (not refresh)

### Cleanup
- [ ] Delete unused `QuickEntryView` struct (no longer used; keep file for AgentPanelView)
- [ ] Decide fate of `ReviewView`, `AgentPanelView` (not in Things — custom for this app)

## Done

- [x] `docs/things-reference/` — visual-design, navigation, interactions, components, screens
- [x] `Theme.swift` — colors, typography, spacing tokens
- [x] `ThingsComponents.swift` — Checkbox, QuickFindBar, SmartListRow, SidebarAreaRow, SidebarProjectRow, ScreenTitle, MagicPlusButton, ThingsTaskRow, ListSectionHeader, Hairline, InlineNewTaskRow
- [x] `SidebarView.swift` — new home screen (Quick Find + smart lists + areas/projects)
- [x] `App.swift` — NavigationStack + Route enum (replaced TabView)
- [x] `TaskListView.swift` — Things-styled list, grouped by project for Today/Upcoming/Anytime
- [x] Sidebar tap highlight (rowSelected tint on tap)
- [x] Inline task entry replacing modal sheet
- [x] Sidebar drag-and-drop reorder (areas + projects + cross-area moves), in-memory only
- [x] Remove emoji suffix from area titles in sidebar
- [x] `AreaDetailView` Things-styled with inline-editable title, projects list, unassigned tasks
- [x] `ProjectDetailView` Things-styled with inline-editable title + notes, task list, Magic Plus inline entry
- [x] `areaUpdate` / `projectUpdate` Swift client methods
- [x] Task completion: haptic + stays crossed-out on page, tap again to undo, clears on navigation away

## What's missing from upstream atask (add to septena later)

### Server extensions needed (engage-server or upstream)
- [ ] **Priority** — upstream has no priority field; add `priority: Int?` to domain.Task
- [ ] **Origin tracking** — `origin: ActorType` (human/agent) on tasks, `owner: String`
- [ ] **Agent fields** — `agentStatus`, `agentAssignedMe`, `agentContext`, `agentNote`, `confidence: Int`, `needsHumanReview: Bool`
- [ ] **Review flow** — `PUT /tasks/{id}/agent-note`, `PUT /tasks/{id}/confidence`, `POST /tasks/{id}/request-review`, `POST /tasks/{id}/approve-review`, `POST /tasks/{id}/dismiss-review`
- [ ] **Agents roster** — `GET /agents`, `GET /agents/{id}` — list OpenClaw agents
- [ ] **Review task list** — `GET /tasks/review` (tasks needing human review)
- [ ] **Assign/claim/release** — `POST /tasks/{id}/assign`, `POST /tasks/{id}/agent-claim`, `POST /tasks/{id}/agent-release`
- [ ] **Conclusion rule** — `PUT /tasks/{id}/conclusion-rule`
- [ ] **SSE events** — `/events/stream` for real-time push to iOS client

### iOS client additions needed
- [ ] **SSE stream listener** — connect to `/events/stream` with ApiKey auth, update local state on push
- [ ] **Review screen** — show tasks with `needsHumanReview == true`
- [ ] **Agent panel** — show agents roster, assign tasks to agents
- [ ] **Priority UI** — sort/filter by priority
- [ ] **Connection test** — should hit `/health` first (no auth), then `/tasks?limit=1` (auth) for full verification

### Nice to have
- [ ] Sync engine (upstream has delta sync — leverage it for offline-first)
- [ ] Activity feed per task
