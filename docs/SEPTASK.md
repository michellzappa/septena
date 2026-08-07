# Septask - separate Tasks app plan

**Status:** P0–P4 landed, plus the app icon. Septask ships on iOS/iPad +
native macOS with the real task UI, its own welcome and Settings, the
same-device Darwin nudge, and its own icon — Septena's exact disc geometry,
white discs on dark gray (#2C2C2E). Remaining before shipping: localization
of new strings, on-device signed convergence test, App Store packaging.
Web project links (P5) follow the native-sharing work per
`docs/NATIVE_PROJECT_SHARING_SPEC.md`. Internal codename: **Septask**.

**macOS is moving to AppKit** for the task surfaces — see "AppKit shell on
macOS" below before touching `SeptaskMac`.

## AppKit shell on macOS (2026-08-06)

**Decision: SeptaskMac's task surfaces are being ported to AppKit.** SwiftUI's
keyboard path (key event → focus resolution → state change → view-graph diff →
render, spread across runloop passes) is structurally slower than AppKit's
synchronous responder chain, and no amount of SwiftUI tuning closes it. The
whole "macOS keyboard & focus" trap section in `CLAUDE.md` is the archaeology
of trying. Confirmed by side-by-side test on live data: materially faster and
more Mac-native.

**Shape of it.** The AppKit shell lives in `Septask/SeptaskKit*.swift`, inside
the existing `SeptaskMac` target — NOT a new target (a new bundle id would need
its own iCloud container provisioning, and its own empty mirror to sync before
it could be judged).

**It is now the default window on macOS.** The SwiftUI `WindowGroup` is
`.defaultLaunchBehavior(.suppressed)` + `.restorationBehavior(.disabled)`
there, and `SeptaskMacAppDelegate` opens the AppKit window at launch. The
classic SwiftUI window is still one menu item away (Go ▸ Classic Window, ⌥⌘0)
because it hosts everything the shell hasn't covered yet — including the
first-run welcome gate, which the AppKit shell does NOT show.

- `SeptaskLaunch.swift` — the launch sequence both roots share, plus the macOS
  `NSApplicationDelegate`. Launch work lives here, not in a scene's `.task`.
- `SeptaskKitWindow.swift` — `NSSplitViewController` window controller.
- `SeptaskKitSidebar.swift` — `NSOutlineView` source list (views + areas /
  projects, open counts, drop targets).
- `SeptaskKitTaskList.swift` — `NSTableView` list, row cell, keyboard, drag &
  drop, the animated row diff, and `KitDayFormat`.
- `SeptaskKitRowViews.swift` — drawn primitives: checkbox, chip, sidebar
  glyphs, the card row background, the recurrence menu.
- `SeptaskKitTheme.swift` — the ONLY place kit code reads fonts/colors.
- `SeptaskKitInspector.swift` — ⌥⌘I inspector: title, notes, dates, repeat.
- `SeptaskKitQuickFind.swift` — ⇧⌘F search panel.
- `SeptaskKitQuickEntry.swift` — global ⌃Space capture panel.
- `SeptaskKitDatePopover.swift` — ⌘S / ⌘⇧D date popovers.
- `SeptaskKitSettings.swift` — hosts the SwiftUI settings view.
- `SeptaskKitNext.swift` — hosts the SwiftUI Next page (sidebar destination).

**What's still missing** versus the SwiftUI surface is tracked as a prioritized
checklist in `docs/SEPTASK_APPKIT_PARITY.md` — read that before picking up
shell work, and keep it current as items land.

**Rules for working on it:**

- **Presentation and interaction only.** Reads go through `LocalCache` /
  `StructureCache`, writes through `TaskMutator` — the mutator write boundary
  is unchanged. Any list/grouping semantics the AppKit shell needs that live in
  a SwiftUI view get **hoisted into core**, never re-derived here; a second
  copy of "what belongs in Today" is exactly the drift this repo forbids. The
  grouped-Today order mirrors `TaskListView.orderedFromGroupedOpen` and reads
  the same `SettingsKey.todayGroupByList`.
- **Lockstep with the SwiftUI task surface**, like the two MCP servers: a
  change to task interaction or presentation lands in both shells in the same
  change, until the SwiftUI shell is retired.
- **Keyboard bindings come from `TaskRowShortcuts`** (`TaskCommands.swift`) so
  the two shells never teach conflicting muscle memory. The Space trap applies
  here too: never bind it, and the checkbox sets `refusesFirstResponder`.
- **One menu bar, either shell.** The menus are still SwiftUI `Commands`.
  They act on the focused SwiftUI scene when there is one, and otherwise fall
  back to `SeptaskKitCommands`, which routes to the frontmost shell window.
  Add a command in BOTH arms or it goes dead in one of the two shells. Row
  commands keep the `TaskRowShortcuts` bindings on both paths.
- **Settings and other form surfaces stay SwiftUI**, hosted in
  `NSHostingController` (⌘, → `SeptaskKitSettingsWindow`). They are not
  latency surfaces; porting them is pure drift. A hosted shared view still
  needs the full environment chain — use `septenaSharedEnvironment`, or it
  crashes at launch (see "P1 Findings").
- **Hosted views take their observables from `SeptaskMacRuntime`, never fresh
  instances.** The shell has no SwiftUI scene holding a `SettingsStore` /
  `SectionTheme` / `DayClock`, so that enum owns one of each for the process.
  Constructing a second `SettingsStore` for a hosted window is a silent bug:
  the user's edits land in a copy nothing else reads, and a second `DayClock`
  drops the debug day offset.
- **Motion routes through `KitMotion`** (the AppKit mirror of `A11yMotion`),
  which reads `NSWorkspace.accessibilityDisplayShouldReduceMotion`. Never
  animate rows directly.
- **Standard AppKit only** — the same "never get creative" rule as SwiftUI.
  `NSTableView`/`NSOutlineView` selection, the field editor for inline rename
  (the native answer to the `Text`→`TextField` corruption trap), `NSPopover`
  for scoped editors, `NSMenu` for closed choice sets, native drag & drop.
- **Selection is ALWAYS the neutral token**, focused or not:
  `SeptaskKitTheme.listSelectionFill` (= `Theme.listSelectionFill` =
  `.unemphasizedSelectedContentBackgroundColor`), drawn full-bleed on the card
  for a list row and inset+rounded for a source-list row. Do NOT let AppKit
  draw its emphasized selection: `.selectedContentBackgroundColor` follows the
  **app accent, which here is adaptive INK**, so the "standard" treatment
  paints selected rows solid black in light mode — the AppKit face of the
  accent-is-ink trap in `CLAUDE.md`. Row views also pin
  `interiorBackgroundStyle` to `.normal`, or AppKit flips row text to white
  against that neutral fill.
- **The global ⌃Space hotkey** uses Carbon `RegisterEventHotKey` (sandbox-safe,
  no accessibility permission). It contends with Things' identical binding
  while Things is running — that's the OS, not a bug.

## Icon Notes (2026-07-02)

Septask's icon is generated, not designed by hand — regenerate rather than
retouch. Source of truth for geometry is `Septena/AppIcon.icon/Assets/
discs.svg`, and every shipped Septena asset rasterizes the SVG's raw
`cx`/`cy`/`r` **as 1024-canvas pixels, ignoring the viewBox transform** —
match that convention or the discs land ~11px off. The Septask set
(`Septask/AppIcon.icon` bundle with dark-gray fill + white discs,
`Septask/Assets.xcassets` appiconset light/dark, `Septask/AppIcon.icns`)
reuses Septena's own alpha channels for the light PNG and icns, so corner
rounding and margins are bit-identical; the dark variant is transparent-bg
white discs, self-masking, same as Septena's.

## P4 Findings (2026-07-02)

- **`SeptenaCore/SiblingNudge.swift`**: Darwin-notification hint between the
  two apps. Posted from `CKEngine` after `.sentRecordZoneChanges` confirms
  accepted saves/deletes; observed in `SeptenaServices.start()` (both
  profiles) with a 400ms debounce → `fetchChanges()`. Per-profile
  notification names so an app never re-fetches off its own send. Carries no
  data — CloudKit stays the only data path; foreground refresh remains the
  correctness guarantee (a suspended sibling misses the ring).
- **Badge decision**: `SettingsKey.badgeShowOverdue` is device-local
  UserDefaults, so each app opts into the overdue badge independently
  (default off). Enabling it in both apps double-badges — acceptable;
  user-resolvable; no cross-app coordination built.

## P3 Findings (2026-07-02)

- **Shared, not copied**: the task settings rows moved from TasksPlugin's
  `TasksDetailContent` into `Shell/Tasks/TaskSettingsSections.swift` (both
  shells mount the same rows; full-app-only rows — Open-in, Show-in-Next,
  the SettingsView AI deep link — are `#if !SEPTASK`-gated inside it).
  Also extracted to shared files: the palette picker
  (`Shell/UI/PaletteSwatch.swift`), `ClaudeGatewayDetail` (+ its private
  timer — extract private helpers together), and `SkillCopy`
  (`Shell/UI/SkillCopy.swift`).
- **Septask-local shell** (`Septask/`): `SeptaskSettingsView` (composition
  only) and `SeptaskWelcome` (gate + view, completion under
  `septask.welcome.completed`).
- **Accent is the shared `SectionEntity.color`** via
  `SettingsMirror.setSectionColor("tasks")` + `theme.setColor` — changing it
  in Septask recolors Septena's Tasks surfaces, by design.
- **Smoke-test trap**: building with `CODE_SIGNING_ALLOWED=NO` strips the
  ad-hoc entitlements simulator builds normally embed, and `CKContainer`
  init then traps at launch. Simulator smoke tests must build through
  `scripts/build.sh` (ad-hoc signed); `CODE_SIGNING_ALLOWED=NO` is for
  compile verification only.

## P2 Findings (2026-07-02)

- **`SeptaskMac` mirrors the `SeptenaMac` pattern**: separate target, same
  source list as `Septask` (keep the two lists in lockstep), `PRODUCT_NAME:
  Septask`, own hand-written `Septask/SeptaskMac.entitlements`, generated
  `Septask/Info-Mac.plist`.
- **Menu commands**: SeptaskApp mounts the task-scoped subset of App.swift's
  commands — Go (⌘1–4 smart lists, no tab hop needed), the Task menu
  (focused-scene row actions), ⌘/ sidebar, ⌘N New To-Do. Quick Find /
  Add Info / Settings / cheat-sheet are deliberately absent until P3 mounts
  their sheet hosts.
- **Platform-conditional seams hide from the other platform's compiler**:
  SectionDrawer's `#if os(macOS)` settings branch referenced the gated
  `settingsDestination` and only failed once a macOS target compiled it.
  When adding a `#if !SEPTASK` gate, grep the file for `os(macOS)` /
  `os(iOS)` branches touching the same symbol.
- **EventKit usage descriptions** (Reminders inbox, Today calendar strip)
  are required in BOTH Info.plists — the task UI requests access at runtime.

## P1 Findings (2026-07-02)

The seam list held. Everything resolved by source inclusion or relocation —
zero task files copied:

- **Included by source** (same files, both targets): `Shell/Tasks` minus
  `TasksDestinationView.swift`, `Shell/Sidebar`, `Shell/UI` minus
  `IntensityGlyph.swift` + `ModuleTile.swift` (both reach into non-task
  domains, neither is used by task surfaces), `App/ContentView.swift` (IS the
  tasks surface), `App/NavigationState.swift`, `App/ShortcutAction.swift`,
  `App/OpenNewTaskRouting.swift`, `Shell/Sections/SectionDrawer.swift` (owns
  `macSheetFrame` + the `usesPushNavigation`/`rowHInset` env keys),
  `Shell/Sections/TimeTravelSheet.swift`, AddInfo's Section/Router/Row,
  `Shell/Intelligence` (OnDeviceReasoningProvider, OnDeviceAI, FlowLayout).
- **Relocated** (own file so shells can include them; invisible to the full
  app): `SettingsKey` → `Shell/Settings/SettingsKeys.swift`, `SeptenaPlus`
  constants → `Shell/Settings/SeptenaPlus.swift`, `SeptenaTab` →
  `App/SeptenaTab.swift`.
- **`#if !SEPTASK` gates** (full-app-only spots inside included files):
  `NavigationState.settingsDestination`, SidebarView's Task Settings menu
  entry, ContentView's `.next` route, SectionDrawer's SettingsView sheet,
  CommitMotion's SectionRegistry flourish lookup, SeptenaPage's TabSwitcher,
  OpenNewTaskRouting's app-delegate stash.
- **Runtime seam the compiler can't catch:** any `@Environment(X.self)` read
  in an included view crashes at launch if the shell doesn't inject it —
  `IPadChromeModel` (read by SeptenaPage's nav-depth reporter) did exactly
  that. Septask's composition root must inject: NavigationState,
  SectionTheme, TaskMutator, AreasMutator, ProjectsMutator, ChecklistMutator
  (the Next fold's trio rows read it), CKEngine, DayClock, LogCommitCenter,
  IPadChromeModel, and the model container. When new surfaces land, re-audit
  environment reads before shipping.

## P0 Findings (2026-07-02)

The complexity audit ran; the kill condition does **not** trigger. Verdict:
task-only runtime extraction is *moderate* — operational coupling (everything
binds in `start()`), not structural (no UIKit/shell types in the runtime).

- **`RuntimeProfile` gates the runtime.** `SeptenaCore/RuntimeProfile.swift`
  is compile-time (`SEPTASK` compilation condition set by the target in
  `project.yml`, following the `WIDGET_EXTENSION` precedent), so app scenes and
  background-launched App Intents can never disagree. In `.tasksOnly`,
  `SeptenaServices.start()` binds only task/area/project mutators and skips the
  Oura/Withings/Readwise stores; `absorbRemoteChanges()` skips the life-domain
  migrators but keeps the task ones (project-graph heal, someday-status).
- **"Task-only sync" is impossible at the fetch layer.** `CKSyncEngine`
  fetches per-zone and everything lives in `septena-v1`, so Septask downloads
  all record types regardless. Decision: **apply everything** into Septask's
  mirror (invisible without UI, zero divergence from Septena's sync path)
  rather than skip-on-apply. This is the §5 "deliberate tradeoff" — forced by
  CloudKit zone mechanics, not by code quality.
- **Two known upward seams in SeptenaCore.** `NextFeed.swift` references
  `NextSuggestionsModel` (defined in `Shell/Dashboard`) — originally both it
  and its one core dependent `WatchSnapshotPublisher.swift` were excluded from
  the Septask target. Since the embedded Next fold (see "Next in Today" below)
  the Septask targets compile `NextFeed.swift` plus the Next model/row files,
  so only `WatchSnapshotPublisher.swift` stays excluded, with the `#if
  !SEPTASK` gate at its single call site.
- **Separate sync state comes free.** `CKEngineState.json` lives in each
  app's own Application Support (not the App Group), so the "separate
  mirrors" non-negotiable is structurally satisfied.
- **`SidebarRootView` is includable as-is** (task-only by design; its deps are
  `NavigationState`, the three mutators, `DayClock`). P1's seam list:
  `App/NavigationState.swift`, `Shell/Sections/SectionDrawer.swift`,
  `Shell/UI/LogCommit.swift`, `Shell/Capture/AddInfo/AddInfoSection.swift`,
  `Shell/Intelligence/OnDeviceReasoningProvider.swift` + `AIExplainerView` —
  all resolved by source inclusion (same file, both targets), never by copy.
- **Sequencing vs. native sharing:** `docs/NATIVE_PROJECT_SHARING_SPEC.md`
  Phase 0 (dev spike) may start any time, but its Phases 1–2 (identity
  namespace + shared-DB engine) wait until Septask P2 lands, so CKEngine is
  rewritten once, in one place, and Septask inherits it.

Septask is a second Apple-platform app over Septena's task system: same repo,
same task logic, same private CloudKit task data, different composition root.
It is not a fork, not an import/export sidecar, and not "Septena Lite." It is a
focused, Things-grade task app for people who want private data ownership and AI
control without opening the full life-OS shell.

The most important implementation constraint:

> Septena and Septask must run side by side on the same device as first-class
> clients over the same task data.

---

## 1. Product Thesis

Tasks is Septena's most legible surface. "A private, local-first task manager an
AI can drive" is understandable immediately; "a life operating system that
correlates your domains" is not. Septask opens the door to users who would never
start with the whole app, especially Things users who want AI and stronger data
ownership.

The target is:

- **Apple-first:** iPhone, iPad, and Mac at launch. Skip Watch for v1.
- **Private:** tasks live in the user's private iCloud/CloudKit data, not a
  Septena-hosted inference or task database.
- **Open source:** keep the codebase auditable and forkable; App Store/source
  positioning can be decided later.
- **Polished:** judged against Things on feel, density, keyboard flow, import,
  and calm task management.
- **AI-native:** not "AI someday." Septena already has the spine: MCP task
  tools, task conversations, an AI policy dial, on-device reasoning, and
  Claude handoff.

Do not over-strategize the suite. Today this is one focused app. Future focused
apps are possible, but not planned.

### Naming

Use **Septask** internally. Public surfaces can test a few names over time:

- Septask
- Septena Tasks
- Tasks by Septena

Do not use "Tend"; it reads like a gardening app. Do not block engineering on
the final public name. The target/folder can be `SeptenaTasks` or `Septask` as
long as bundle IDs and display names are explicit.

---

## 2. Non-Negotiables

- **Second target, one codebase.** Ship another app target from this repo. Never
  clone the repo or duplicate task logic.
- **Same task data.** Septena and Septask read/write the same CloudKit task,
  area, project, and task-conversation records.
- **Separate local mirrors.** Each app has its own SwiftData SQLite mirror. Do
  not put the SwiftData store in the App Group and let two processes write it.
  CloudKit is the convergence point.
- **Same write boundary.** Both apps mutate through `TaskMutator`,
  `AreasMutator`, `ProjectsMutator`, and the same conversation mutator methods.
- **Tasks are always available.** If the user hides the Tasks section in
  Septena, Septask still works. Hiding a section in the full app hides surfaces,
  not data or external clients.
- **Task-only user surface.** Septask v1 has no Week, Goals, Health,
  training, nutrition, section picker, full section registry, or life-OS
  dashboard. (Amended 2026-07-11: the Next feed — suggestions + the chores /
  habits / supplements trio — embeds at the foot of Today as an opt-out
  foldable section; see "Next in Today" below. Forward-glance + log only, not
  a section surface, and no Done Today timeline; the rest of the rule holds.)
- **Complexity is the kill condition.** If task-only runtime extraction requires
  invasive surgery through sync and services, stop and reassess before building
  a broad parallel app shell.

---

## 3. Existing Code To Reuse

The current app already has most of the product surface needed for v1.

### Task UX

- `Septena/Shell/Tasks/TaskListView.swift`
- `Septena/Shell/Tasks/TaskComponents.swift`
- `Septena/Shell/Tasks/TaskComposer.swift`
- `Septena/Shell/Tasks/TaskDetailView.swift`
- `Septena/Shell/Tasks/TaskDraft.swift`
- `Septena/Shell/Tasks/RemindersInboxSection.swift`
- `Septena/Shell/Tasks/ThingsImportView.swift`
- `Septena/Shell/Sidebar/SidebarView.swift` (`SidebarRootView`)
- `Septena/App/NavigationState.swift` / `Route` / `TaskDestinations`

`SidebarRootView` exists today and is the likely task home, but P1 should prove
that by compiling it in the new target. If it pulls too much full-app chrome,
extract the task-specific primitives rather than copying it.

### Data And Sync

- `SeptenaCore/Persistence.swift`
- `SeptenaCore/CloudKit/CKEngine.swift`
- `SeptenaCore/CloudKit/TasksBackend.swift`
- `SeptenaCore/CloudKit/TaskReads.swift`
- `SeptenaCore/Outbox.swift` (`TaskMutator`)
- `SeptenaCore/SeptenaServices.swift`
- `SeptenaCore/Models.swift`
- `SeptenaCore/TaskConvo.swift`
- `SeptenaCore/ConvoDerived.swift`

### AI / MCP

Do not re-invent this. Septask should surface the existing task AI story.

- `Septena/Shell/Tasks/ConversationEngine.swift`
- `Septena/Shell/Tasks/ConversationCard.swift`
- `SeptenaCore/AIPolicy.swift`
- `SeptenaCore/ReasoningProvider.swift`
- `Septena/Shell/Intelligence/OnDeviceReasoningProvider.swift`
- `SeptenaCore/MCP/MCPToolCatalog.swift`
- `SeptenaCore/MCP/MCPDispatch.swift`
- `Septena/Shell/Sections/Plugins/TasksPlugin.swift` (`mcpSkill`)
- `Septena/Shell/Settings/AISettingsPane.swift`
- `Septena/Shell/Settings/LocalMCPSettingsPane.swift`

The pitch is not "we will add AI." The code already supports task CRUD over MCP,
pending reasoning, task thread get/append, acceptance criteria, artifacts,
handoffs, end states, and assignee routing. The v1 product work is presenting
that coherently inside a focused task app.

### Onboarding

- `Septena/Shell/Onboarding/WelcomeView.swift` for design language only.
- `Septena/Shell/Sections/Plugins/SectionOnboarding.swift` for reusable section
  onboarding chrome.
- `TasksPlugin.onboarding` for the reusable task explainer, but **not** as a
  mandatory first-run step in Septask.

---

## 4. Source-Inclusion Model

This repo shares code by source inclusion, not packages. `SeptenaCore` is not an
SPM module. Targets include source folders directly in `project.yml`.

That remains the correct model:

```text
SeptenaCore/          models, SwiftData, CloudKit, mutators, services
Septena/Shell/UI/     shared design primitives
Septena/Shell/Tasks/  task feature views and components
Septena/Shell/Sidebar task home/navigation pieces, if extractable cleanly
Septask/              app entry, scene shell, welcome, settings, assets
```

Sketch:

```yaml
Septask:
  type: application
  platform: iOS
  sources:
    - path: SeptenaCore
    - path: Septena/Shell/UI
    - path: Septena/Shell/Tasks
      excludes:
        - TasksDestinationView.swift
    - path: Septena/Shell/Sidebar
      # exact excludes discovered in P1/P2
    - path: Septask
```

Add Mac as a separate target or platform sibling following the existing
`Septena` / `SeptenaMac` pattern. Launch goal is iPhone, iPad, and Mac.

The compiler is the seam checker. When the new target fails because a task view
reaches into Week/Next/Goals/Sections, resolve it by:

1. **Relocate:** move a real shared primitive into `Shell/UI` or a task-shared
   file.
2. **Cut:** remove a cross-domain dependency from Septask's path.
3. **Stub:** provide a thin shell alternative for full-app-only chrome.

Do not solve seam failures by copying task files into `Septask/`.

---

## 5. Data Model And Parallel Running

Both apps should be able to run at once on the same device.

Correct shape:

```text
Septena SwiftData mirror  <->  private CloudKit task records  <->  Septask SwiftData mirror
```

Wrong shape:

```text
Septena process  <->  shared App Group SQLite  <->  Septask process
```

Why: two app processes writing the same SwiftData/Core Data SQLite store is a
fragile cross-process boundary. CloudKit already is the multi-client boundary.
Use it.

Implementation notes:

- Hand-write `Septask.entitlements`; entitlements are not generated.
- Use the same CloudKit container: `iCloud.com.septena.cloud`.
- Use the same private zone: `septena-v1`.
- Use the same App Group only for lightweight shared state/signaling where
  appropriate, not for the SwiftData store.
- Use a distinct bundle ID, likely `com.septena.tasks` or
  `com.septena.septask`.
- Foreground refresh remains mandatory in both apps.
- Add a Darwin notification nudge so a write in one app can ask the sibling app
  to fetch. The data still moves through CloudKit.
- Conflict behavior should remain CKSyncEngine/native CloudKit behavior. Do not
  invent a second local sync layer.

### Task-Only Sync

Product intent: Septask syncs only task-domain data:

- tasks
- areas
- projects
- task conversations
- task-relevant settings
- section row for key `"tasks"` where needed for accent/settings

Engineering reality: `SeptenaServices` and `CKEngine` currently know about the
whole app. P0 must measure whether a task-scoped runtime can be extracted
cleanly. If this becomes invasive, pause. The fallback may be to compile broader
core internals while exposing only task UI, but that is a deliberate tradeoff,
not the desired architecture.

---

## 6. Product Decisions

### Welcome

Septask gets its own proprietary welcome screen:

- same design language as `WelcomeView`
- different copy
- no section picker
- no life-OS framing
- no mandatory `TasksPlugin.onboarding` after welcome

If an existing Septena user installs Septask, show the Septask app welcome once
for that app, then land in tasks. The task content onboarding should be available
from Settings/help but should not block first run.

### Settings

Septask needs a dedicated Settings surface. It should share code smartly, not
mount Septena's whole Settings app.

Extract/reuse:

- task settings toggles from `TasksDetailContent`
- Things import entry
- AI policy controls where copy is task-safe
- Claude/MCP connection status and setup where task-safe
- accent picker for the shared `"tasks"` section color
- task privacy/export/about copy where reusable

Keep Septask-specific:

- app welcome reset
- app icon/name/about
- view preferences that should be local to Septask
- web project sharing/link management
- task-only privacy explainer copy

Avoid:

- Manage Sections
- Week/Next/Goals settings
- non-task integrations
- life-domain onboarding
- full `SettingsView` destination graph

Settings split rule:

- **Shared account/task settings:** same CloudKit/user-default bridge in both
  apps when the setting affects task semantics across clients.
- **App-local settings:** view presentation, sidebar/window preferences, app
  chrome, local-only toggles.
- **Septena-only settings:** anything about Week, Next, sections, Health, life
  domains, or dashboards.

### Accent

The task accent is shared.

Use `SettingsMirror.setSectionColor("tasks", hex: ...)`. This writes the same
`SectionEntity.color` that Septena uses for its Tasks tile/surfaces. Changing it
in Septask recolors Tasks in Septena too; this is desired.

### AI

Septask v1 should include the current task AI/MCP story:

- AI policy dial
- task conversations in the composer
- Claude/MCP connection path
- pending reasoning affordance if it fits the shell
- clear copy: "your AI, your data; Septena does not run hosted inference"

Do not block v1 on a redesigned conversation system. Improving conversations is
a follow-up product track. Current code is good enough to expose.

### Import

Things import is a feature inside Settings, not first-run mandatory onboarding.
Do not modify the user's Things data.

### App Store / Site

Septask should have its own icon, App Store page, and explainer on
`www.septena.app`. Pricing is intentionally undecided. Assume free for planning.

---

## 7. Web Editable Project Links

Editable web links are in scope as a planned sibling feature, reusing the
existing Cloudflare helper pattern used for other shared data.

Start with **project links**, not area links. Projects are bounded; areas can
accidentally expose too much.

Recommended model:

- A share record scoped to one project.
- An opaque high-entropy token; do not treat a project UUID as a secret.
- Optional PIN gate that unlocks a short-lived edit session.
- Explicit permission level: read-only, propose/comment, or edit.
- Revocation: deleting/turning off the share invalidates future sessions.
- Every web mutation writes through task mutation semantics, not ad hoc SQL or
  direct blind record patches.
- Append-only edit history: who/session, when, source, operation, before/after
  summary.
- The helper must never receive broad account authority when a scoped share will
  do.

This does not need to block the native Septask target. Plan the data shape early
so project detail/settings have a stable place for share controls later.

---

## 8. Phased Workflow

Each phase must leave the full Septena app green and behaviorally unchanged.
Build through `scripts/build.sh` per `CLAUDE.md`; do not run concurrent builds.
No branches unless the user explicitly asks.

### P0 - Complexity Audit And Premise Proof

Goal: prove "two apps, same task data" before polishing UI.

- Add the minimal target and entitlements.
- Start the lightest viable runtime.
- Render a raw task list from the local mirror.
- Create/complete a task through the existing mutator.
- Install next to Septena on one device.
- Confirm both apps converge through CloudKit.
- Measure whether task-only runtime/sync extraction is clean or invasive.

Do not move feature code in P0 unless the compiler forces a tiny supporting
extraction.

### P1 - Make Task UI Independently Includable

- Include `Shell/Tasks`.
- Include or extract the task home from `Shell/Sidebar`.
- Exclude full-app adapters:
  - `TasksDestinationView.swift`
  - `TasksPlugin.destinationView` usage
  - `SectionDrawer` mounting path
- Move real shared UI primitives to `Shell/UI`.
- Keep Septena behavior identical.

### P2 - Thin Septask Shell

- App entry / scene.
- iPhone/iPad/Mac task navigation.
- Environment injection:
  - `TaskMutator`
  - `AreasMutator`
  - `ProjectsMutator`
  - `DayClock`
  - `CKEngine`
  - `SectionTheme`
  - model container/context
  - navigation state or extracted task navigation state
- No `LogCommitCenter` unless needed; task code is nil-safe.
- No Week/Next/Goals/section registry.

### P3 - Septask Welcome And Settings

- Build Septask welcome in Septena's welcome design language.
- Mark Septask welcome completion separately from Septena's life-OS welcome.
- Build dedicated Septask Settings.
- Extract task settings from `TasksDetailContent` into a reusable task settings
  pane/component.
- Add Things import and AI/MCP entries.
- Add task accent picker.

### P4 - Cross-App Polish

- Darwin notification nudge between Septena and Septask.
- Foreground refresh checks.
- Badge behavior decision.
- Widget/watch snapshot decision (v1 should not ship Watch).
- Same-device edit animations should be graceful when sibling writes arrive.

### P5 - Web Project Links

- Add share record/data model.
- Add project share controls.
- Implement Cloudflare helper endpoint with scoped edit sessions.
- Add edit history.

---

## 9. Governing Invariant

> Shells own composition; shared folders own behavior; CloudKit owns data.

`Septask/` may contain:

- app entry
- scene/navigation chrome
- Septask welcome
- Septask settings shell
- app assets
- target-specific wrappers/adapters

`Septask/` may not contain:

- task business logic
- duplicated task rows/components
- duplicated task mutation paths
- a private copy of task conversations
- a separate task data model

Any reusable task view or task behavior belongs in `Septena/Shell/Tasks` or a
shared supporting folder so both apps improve together.

---

## Appendix - Key File References

- Main task feature: `Septena/Shell/Tasks/*`
- Task home candidate: `Septena/Shell/Sidebar/SidebarView.swift`
- Task routing/navigation: `Septena/App/NavigationState.swift`
- Full-app task drawer adapter to exclude: `Septena/Shell/Tasks/TasksDestinationView.swift`
- Full-app section plugin adapter: `Septena/Shell/Sections/Plugins/TasksPlugin.swift`
- Task onboarding source: `TasksPlugin.onboarding`
- Shared onboarding scaffold: `Septena/Shell/Sections/Plugins/SectionOnboarding.swift`
- Full-app welcome design reference: `Septena/Shell/Onboarding/WelcomeView.swift`
- Accent write boundary: `SeptenaCore/SettingsMirror.swift` (`setSectionColor`)
- Data/sync: `SeptenaCore/Persistence.swift`, `SeptenaCore/CloudKit/CKEngine.swift`
- Task mutator: `SeptenaCore/Outbox.swift`
- Task backend: `SeptenaCore/CloudKit/TasksBackend.swift`
- Task conversations: `SeptenaCore/TaskConvo.swift`, `Septena/Shell/Tasks/ConversationCard.swift`
- AI policy/provider seam: `SeptenaCore/AIPolicy.swift`, `SeptenaCore/ReasoningProvider.swift`
- MCP tools: `SeptenaCore/MCP/MCPToolCatalog.swift`, `SeptenaCore/MCP/MCPDispatch.swift`
- Things import: `Septena/Shell/Tasks/ThingsImportView.swift`, `SeptenaCore/ThingsImport/*`
- Target definitions: `project.yml`


## Next in Today (2026-07-11)

Septask embeds the Next feed — suggestions plus the chores / habits /
supplements trio — at the foot of the Today list, as one foldable "Next"
section (`Septask/SeptaskNextFold.swift`, mounted from `TaskListView` under
`#if SEPTASK`, gated by Settings ▸ General ▸ "Next in Today", default on).
Rationale: Septask mirrors the whole zone anyway; the fold removes the
app-switch for the day's rituals.

**AppKit shell (2026-08-07):** the same feed is a **sidebar destination**
instead (`KitSidebarDestination.next` → hosted `SeptaskNextPage` via
`SeptaskKitNext.swift`). The shared body is `SeptaskNextFeed`; the Today
fold and the AppKit page both render it. Appending heterogeneous ritual rows
to the AppKit Today `NSTableView` was deliberately rejected.

- **Composition, not copies.** The fold renders the SAME models/rows Septena's
  Next tab uses (`NextItemsModel`, `NextSuggestionsModel`,
  `HabitRow`/`SupplementRow`/`ChoreRow`, `NextSuggestionRow`). Container
  differs: Today is a `SelectableScrollList` (not a `List`), so rows wear the
  Tasks surface's `taskCardChrome` instead of List cells. No List selection /
  keyboard cursor across Next rows.
- **Deliberate cuts from Septena's Next page:** no "Tasks Today" block (the
  Today list above IS it); no "Done Today" log (too recursive on a surface
  that's already the task log — forward glance only); no training suggestion
  (its destination is the live-session surface Septask doesn't compile). A
  divider sits between the task list and the fold; the fold's sub-block titles
  (Suggested / Chores / Habits / Supplements) render a step smaller + gray so
  they don't compete with the task section headers.
- **Runtime loosening (deliberate).** `SeptenaServices.start()` now binds
  `checklistMutator`, `intakeMutator`, and `nutritionMutator` in BOTH profiles
  (the fold's write set: trio toggles, inline intake nudges, fast-break new
  meal; mood needs no engine binding). Gut / goal / coach / activity /
  symptoms / medications / grocery / training mutators and the provider stores
  stay full-profile-only.
- **Included files** (project.yml, both Septask targets, lockstep): the three
  `Shell/Dashboard` Next files + `MirrorReader.swift`, `NextFeed.swift`
  (un-excluded), and from `Septena/Sections/`: Mood catalog + commit animation
  + check-in page (`AddMoodPage`), and Nutrition edit/new sheets +
  `NutritionCommit.swift` + MealPhoto analyzer/draft/camera. (`MealPhotoThumbnail`
  lives in `EditNutritionEntrySheet.swift`, so the new-meal sheet pulls that
  file in even though the fold no longer edits meals.) Septask iOS also gained
  the `FoundationModels.framework` dependency (meal-photo analyzer).
- **Extraction made for this:** `NutritionPlugin.commitMeal` moved to
  `NutritionCommit` (Sections/Nutrition) so the meal sheets compile without
  the plugin/registry; `HydrationPlugin.waterFoodsMarker` forwards to it.
- **Suggestion routing deltas:** intake nudges log inline (unchanged); mood
  opens `AddMoodPage` and fast-break opens `NewNutritionEntrySheet`, both from
  `SeptaskRootView`'s modal switch (`.moodCheckin`, `.addInfo(.nutrition)`).
