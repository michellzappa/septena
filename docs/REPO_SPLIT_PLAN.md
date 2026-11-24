# Repo split: Septena Life moves to `septena-life`

Status: done 2026-11-21, superseded by ADR 0017 — historical. Docs it names that
are no longer here are under the tag `septena-life-archive`.

Rests on: ADR 0007 (Septena is the task app), ADR 0002 (own backend),
`docs/SEPTASK_BACKEND.md` §11 (this plan replaces §11), `docs/SEPTASK.md`,
issue #68 (decision), issue #83 (gateway moves into `backend/` here).

Decisions taken in #68:

- This repo (`michellzappa/septena`) stays the task app (Septena). It keeps its
  history, issues, factory and MIT licence, and stays public.
- The life OS (Septena Life) moves to a new repo `michellzappa/septena-life`.
- The gateway moved into `backend/` in this repo (#83, done 2026-11-20, with
  history). Deploys run from `backend/`. The old
  `/Users/mz/Dev/septena-mcp-gateway` checkout is frozen; mz archives it after
  a week.

Names in this doc: "task app" = the `Septask*` targets (ships as Septena).
"Life app" = the `Septena*` targets (ships as Septena Life). Code identifiers
do not change in this split (ADR 0007: a rename needs its own spec).

## 0. What makes this hard today

Read this first. The two apps are joined at three points, not only by source
files:

1. **One SwiftData store.** Both apps open the same `Septena.store`: on the Mac
   at `~/Library/Septena/Septena.store` (`MacStoreLocation` in
   `SeptenaCore/Persistence.swift`), on iOS in the app-group container
   `group.com.septena.cloud`. `LocalStore` declares one schema with every
   entity of both apps. If the two repos ship different schemas against the
   same file, the older app hits the `fatalError` in `LocalStore.init` on
   that device. The store must split before the schemas can differ.
   (The task outbox is already separate: `TaskSync-Septask-v*.store`,
   `SeptenaCore/TaskBackend/TaskSyncStore.swift`.)
2. **The task app compiles almost all of `SeptenaCore`.** `project.yml`
   target `Septask` includes `SeptenaCore` as a folder and excludes 17 files.
   `CKEngine` still compiles into it, because the task mutators take the
   engine as a parameter (it never starts).
3. **The task app reuses life-app files by path:** `Septena/Shell/Tasks`,
   `Septena/Shell/Sidebar`, `Septena/Shell/UI`, five `Septena/App/*` files,
   eight `Septena/Shell/Settings/*` files, `Septena/Localizable.xcstrings`,
   and more (list in §2.3). 76 `#if SEPTASK` / `#if !SEPTASK` branches sit
   in shared code.

So the split is mostly work inside this repo (Phase A, §6). Creating the
new repo is the short part.

## 1. Target mapping

| Target (project.yml) | Bundle id | Goes to |
|---|---|---|
| `Septena` (iOS) | `com.septena.cloud` | septena-life |
| `SeptenaMac` | `com.septena.cloud` | septena-life |
| `SeptenaWatch` | `com.septena.cloud.watchkitapp` | septena-life |
| `SeptenaWatchComplication` | `com.septena.cloud.watchkitapp.next` | septena-life |
| `SeptenaWidgets` | `com.septena.cloud.widgets` | septena-life (task widgets removed, §2.2) |
| `SeptenaLiveActivitiesExtension` | `com.septena.cloud.liveactivities` | septena-life |
| `SeptenaShare` | `com.septena.cloud.share` | removed (it captures tasks; life drops tasks). *(default)* |
| `SeptenaCoreTests` | `com.septena.cloud.coretests` | split: life tests to septena-life, task and shared tests stay (§2.4) |
| `SeptenaUITests`, `SeptenaMacUITests` | `com.septena.cloud.uitests`, `.macuitests` | septena-life |
| `Septask` (iOS) | `com.septena.tasks` | stays |
| `SeptaskMac` | `com.septena.tasks` | stays |
| `SeptaskWatch` | `com.septena.tasks.watchkitapp` | stays |
| `SeptaskWatchComplication` | `com.septena.tasks.watchkitapp.today` | stays |
| `SeptaskShare` | `com.septena.tasks.share` | stays |
| `SeptaskUITests`, `SeptaskMacUITests` | `com.septena.tasks.uitests`, `.macuitests` | stays |
| new: `SeptenaKit` (SPM package) | none | lives here (§2.1) |

Schemes follow their targets: `Septena`, `SeptenaMac`, `SeptenaWatch`,
`SeptenaCoreTests` (life half) go; `Septask`, `SeptaskMac`, `SeptaskWatch`
stay.

## 2. Source mapping

### 2.1 The shared package: `SeptenaKit`

- **Name:** `SeptenaKit`. One library product, one target.
- **Host:** this repo. *(default)* Reason: the task app is the primary product
  (ADR 0007) and the design system (`docs/DesignSpec.md`) and the MCP protocol
  constants (`MCPRevision.swift` ⇄ `backend/src/protocol.ts`) both live with it.
  Life is fixes-only and rarely changes shared code.
- **Layout:** `Package.swift` at the repo root (SPM can only resolve a remote
  package whose manifest is at the repo root), sources in
  `SeptenaKit/Sources/SeptenaKit/`, tests in `SeptenaKit/Tests/SeptenaKitTests/`.
  The manifest declares only that target, so a consumer builds nothing else.
- **This repo consumes it** as a local package: `project.yml`
  `packages: SeptenaKit: { path: . }`, then `- package: SeptenaKit` on each task
  target. If XcodeGen or Xcode misbehave with a root-path package, the fallback
  is a third repo `septena-kit` (open question Q2).
- **septena-life consumes it** by URL, pinned to a commit:
  `packages: SeptenaKit: { url: https://github.com/michellzappa/septena, revision: <sha> }`.
  *(default)* Reason: this repo tags app releases `vX.Y.Z`
  (`docs/VERSIONING.md`, `.github/workflows/release-macos.yml` runs on `v*`).
  SPM reads every semver tag as a package version, so `from:`/`exact:` pins
  would follow task-app releases, not package changes. A revision pin is
  exact and needs no tag scheme. For local work, septena-life switches the
  entry to `path: ../septena` and never commits that.
- **Rule for what goes in:** a file goes to `SeptenaKit` only if both apps
  still compile it after Phase A steps 2 and 3, and it holds logic or design
  that must not drift (one source of truth). Everything else belongs to
  one side. App-level files that both apps compile today but that only wire
  one app (roots, settings panes) do NOT go in the package: each repo keeps
  its own copy and prunes the other app's branches (§2.3).
- **Access:** moved types become `public`. User-facing strings in package
  views move to a package catalog `SeptenaKit/Sources/SeptenaKit/Localizable.xcstrings`
  and use `bundle: .module`. *(default)*

Candidates (confirmed by compile in step 4, not by this list):

- From `SeptenaCore/`: `DayClock.swift`, `DateParser.swift`,
  `LocaleFormatting.swift`, `Logging.swift`, `KeychainStore.swift`,
  `Haptics.swift`, `AdaptiveColor.swift`, `Telemetry.swift`,
  `ConnectionHealth.swift`, `StoreHealthState.swift`, `AIModelTag.swift`,
  `AIPolicy.swift`, `ReasoningProvider.swift`, `SeptenaAppGroup.swift`,
  `CalendarBridge.swift`, `Community/*`, and the MCP transport and protocol:
  `MCP/MCPProtocol.swift`, `MCP/MCPRevision.swift`, `MCP/MCPAccessScope.swift`,
  `MCP/LocalMCPServer.swift`.
- From `Septena/Shell/UI/`: the design system: `Theme.swift`,
  `SelectionLanguage.swift`, `Accessibility.swift` (`a11yAnimate`),
  `CommitMotion.swift`, `LogCommit.swift`, `PlatformShims.swift`,
  `TextSizeScale.swift`, `ListKeyboardNavigation.swift`,
  `ListSelectionScope.swift`, `SelectableScrollList.swift`, `SeptenaPage.swift`,
  `GroupedListSection.swift`, `PaletteSwatch.swift`, `EmojiPicker.swift`,
  `SyncIndicator.swift`, `StoreHealthNotice.swift`, `SteppedDatePicker.swift`,
  `KeyboardShortcutsView.swift`, `AIModelTagBadge.swift`, `ProfileAvatar.swift`,
  `SkyAtmosphere.swift`, `SkyTopWash.swift`, `SolarClock.swift`,
  `AmbientLight.swift`.
- From `Septena/Shell/`: `Settings/SettingsChrome.swift`,
  `Settings/SettingsColor.swift`, `Intelligence/OnDeviceAI.swift`,
  `Intelligence/OnDeviceReasoningProvider.swift`,
  `Intelligence/Components/FlowLayout.swift`, and the drawer plumbing that task
  views use from `Sections/SectionDrawer.swift` (`macSheetFrame`, the
  `usesPushNavigation` / `rowHInset` environment keys), extracted into its own
  file. The drawer itself stays with life.
- Tooling: `scripts/lint-design.sh` and `scripts/lint-row-tap-targets.py` stay
  here and also lint `SeptenaKit/`. septena-life gets a copy at clone time.
  *(default: copy; it is shell tooling, not app code)*

### 2.2 `SeptenaCore`: task-only, life-only, shared

**Task-only (stays here, moves to a new folder `TasksCore/` in step 5):**

- `TaskBackend/*` (`TaskBackendClient`, `TaskBackendMapping`, `TaskBackendWire`,
  `TaskStoreMode`, `TaskSyncApply`, `TaskSyncEngine`, `TaskSyncSettings`,
  `TaskSyncStore`). The cutover tools `TaskBackendImporter.swift` and
  `TaskStoreRollback.swift` are deleted after the cutover, not moved.
- `TaskUndo.swift`, `TaskConvo.swift`, `ConvoDerived.swift`,
  `TaskListOrder.swift`, `TaskStructureOrder.swift`, `TaskRecordNames.swift`,
  `TaskAttachments.swift`,
  `SharedTaskCapture.swift`, `RemindersBridge.swift`, `SeptaskDiagnostics.swift`,
  `TasksWatchWire.swift`, `TasksWatchBuilder.swift`, `ThingsImport/*`.
- `CloudKit/TasksBackend.swift`, `CloudKit/AreasBackend.swift`,
  `CloudKit/ProjectsBackend.swift`, `CloudKit/TaskReads.swift`: these are the
  task store facades, not CloudKit code. They move to `TasksCore/` and drop
  their CloudKit branches (step 3).
- `TaskMutator` and the area/project mutators (today in `Outbox.swift`).
- The task entities from `Persistence.swift`: `TaskEntity`,
  `TaskAttachmentEntity`, `ProjectEntity`, `AreaEntity`.

**Life-only (goes to septena-life):**

- All CloudKit sync: `CloudKit/CKEngine.swift`, `CloudKitRecordRegistry.swift`,
  `SchemaSeedRegistrar.swift`, `Migration.swift`, every `*Record.swift`
  (`Coach*`, `Goal*`, `Section`, `Settings`, and the task/area/project/attachment
  records, which are then deleted with life's tasks).
- Providers: `OuraProvider`, `WithingsProvider`, `ReadwiseProvider`,
  `GitHubProvider`, `HealthKitBridge`, `PhotosBridge`, `WakingDay+Oura`.
- Section logic: `Sections/SectionManifest.swift`, `SectionTheme`,
  `HomepageDomain`, `Training*`, `ExerciseKey`, `CanonicalExerciseName`,
  `DefaultExerciseLibrary`, `Nutrition*`, `Macro*`, `IntakeModel`,
  `ConsumableContainer`, `Fasting`, `GutSymptomMigrationMap`, `MoodVocabulary`,
  `MilestoneEngine`, `ConsistencyStats`, `HeatmapLevels`, `WakingDay`,
  `Suggestion*`, `Next*`, `DayBucket`, `Rhythm*`, `Tile*`, `WatchSnapshotPublisher`,
  `DailyMessage`, `ChecklistMirror`, `MirrorReader`, `SettingsMirror`,
  `ResponseCache`, `Reports/*`, `ClaudeGatewayProvider`, `ClaudeReconnectNudge`,
  `BadgeManager`, `TrainingLiveActivity`.
- Tasks inside life that leave with tasks (step 2): `TasksWatchSnapshotPublisher`,
  `TasksWidgetBuilder`, `TasksWidgetSnapshotStore`, `TasksWidgetWire`,
  `SeptenaWidgets/TasksTodayWidget.swift`, `SeptenaWidgets/AddTaskControl.swift`,
  `Septena/App/AddTaskIntent.swift`, `Septena/App/Intents/TaskIntents.swift`,
  `Septena/App/Intents/OpenNewTaskControlIntent.swift`,
  `Septena/Shell/Tasks/TasksDestinationView.swift`, the Tasks section.

**Mixed files that must be cut in two (step 5):**

| File | Task half (stays) | Life half (goes) |
|---|---|---|
| `Persistence.swift` (4518 lines) | task entities, the task app's `LocalStore` schema | life entities, life `LocalStore`, `MacStoreLocation` |
| `Outbox.swift` | `TaskMutator`, area/project mutators | the other mutators |
| `SeptenaServices.swift` | task start-up path (`RuntimeProfile.tasksOnly`) | full start-up path |
| `Models.swift`, `LaunchMigrators.swift`, `DemoSeed.swift`, `NotificationKit.swift` | task parts | life parts |
| `MCP/MCPDispatch.swift`, `MCP/MCPToolCatalog.swift` | task tools | life tools |
| `RuntimeProfile.swift`, `SiblingNudge.swift` | deleted: each repo has one app | deleted |

### 2.3 App-level files shared by path today

Rule: these become per-repo files. septena-life is a full-history copy
(§6 step 6), so it already has them; each side deletes the other app's
`#if SEPTASK` branches after the split. *(default)*

- `Septena/Shell/Tasks/*`, `Septena/Shell/Sidebar/*`: stay here (move to
  `Septask/Tasks/`, `Septask/Sidebar/` in step 5). Life deletes them.
- `Septena/App/ContentView.swift`, `NavigationState.swift`,
  `ShortcutAction.swift`, `SeptenaTab.swift`, `OpenNewTaskRouting.swift`:
  each repo keeps its own.
- `Septena/Shell/Settings/SettingsKeys.swift`, `SettingsStore.swift`,
  `SeptenaPlus.swift`, `AISettingsPane.swift`, `LocalMCPSettingsPane.swift`,
  `ConnectedAppsDetails.swift`: each repo keeps its own.
- `Septena/Shell/Capture/AddInfo/*`, `Septena/Shell/Capture/QuickFindView.swift`,
  `Septena/Shell/Sections/TimeTravelSheet.swift`: each repo keeps its own.
- `Septena/Localizable.xcstrings`: each repo keeps its own copy and prunes
  unused keys later. Keys used by `SeptenaKit` move into the package catalog.
- `ShareExtension/ShareViewController.swift`: stays here (task share only).
- `Septena/Shell/UI/IntensityGlyph.swift`, `ModuleTile.swift`,
  `BiometrySymbol.swift`, `ConsistencyHeatmap.swift`, `SectionGlyph.swift`,
  `TimeOfDayWheel.swift`, `DayBucketHeader.swift`, `HomeChrome.swift`,
  `MilestonePresenter.swift`, `MilestoneUnits.swift`, unit files
  (`DistanceUnit`, `VolumeUnit`, `WeightUnit`, `WeightCadence`), `SkillCopy.swift`,
  `SharedAppEnvironment.swift`, `LogRow.swift`: life, unless step 4 shows the
  task app needs one, then it goes to `SeptenaKit`.

### 2.4 Everything else in the repo

| Path | Goes to |
|---|---|
| `Septena/` (rest), `SeptenaWatch/`, `SeptenaWatchComplication/`, `SeptenaWidgets/`, `SeptenaLiveActivitiesExtension/`, `SeptenaUITests/`, `SeptenaMacUITests/` | septena-life |
| `Septask/`, `SeptaskWatch/`, `SeptaskWatchComplication/`, `SeptaskUITests/`, `SeptaskMacUITests/`, `ShareExtension/` | stays |
| `SeptenaCoreTests/` | life tests (Fasting, IntakeModel, Gut, Exercise, Training*, WakingDay, ConsumableContainer, SuggestionBlocks) go; ThingsImport tests stay as `SeptaskCoreTests`; DateParser and Logging tests move to `SeptenaKitTests` |
| `Septena/Resources/changelog.json` | septena-life (only the life app bundles it). The task app gets its own changelog later. |
| `reports-worker/` | septena-life (practitioner reports are life) *(default)* |
| `community-worker/` | stays (both apps call it through `SeptenaCore/Community`) *(default)* |
| `backend/` (landed in #83) | stays. It also serves life's tools on `mcp.septena.app`. |
| `appstore/metadata`, `metadata-mac`, `panels.config.mjs`, `capture.sh` life paths | septena-life |
| `appstore/metadata-septask*`, `panels.septask.mjs`, `raw-septask`, `screenshots-septask` | stays |
| `appstore/` render tooling (`render.mjs`, `validate.mjs`, `serve.mjs`, `devices.mjs`, `theme.mjs`, `components.mjs`, `apps.mjs`, `viz/`) | both (copy at clone) *(default)* |
| `fastlane/Deliverfile` | both; this repo's default `app_identifier` becomes `com.septena.tasks` |
| `scripts/build.sh`, `lint-*`, `wt-new`, `wt-done`, `stamp-version.sh`, `check-version-wiring.sh` | both (copy at clone) |
| `scripts/changelog-stamp.sh`, `changelog-draft.sh` | septena-life (they edit `changelog.json`) |
| `scripts/build-macos-release.sh`, `cut-macos-release.sh`, `generate-update-site.sh`, `.github/workflows/release-macos.yml`, Sparkle | stays (task app Mac direct distribution) |
| `Config/Base.xcconfig`, `Config/Septena.storekit` | both. `Config/Secrets.xcconfig` (Withings) is life-only and gitignored. |
| `tools/logo-configurator` | stays |
| docs | §5 |

## 3. Bundle ids, iCloud, App Store

Nothing user-visible or registered changes. ADR 0007 holds:

- Bundle ids stay as in §1. Each repo signs only its own ids, same team
  (`SEPTENA_DEVELOPMENT_TEAM`).
- iCloud container `iCloud.com.septena.cloud`: life only. The task app already
  has no iCloud entitlement (`Septask/Septask.entitlements`).
- App group `group.com.septena.cloud`: both apps keep it. *(default)* Reason:
  ADR 0007 says app groups do not change; `TaskStoreMode` and
  `SharedTaskCapture` ride it. After step 1 neither app shares store files
  through it.
- App Store Connect: "Septena Life" (`com.septena.cloud`, Apple ID 6836809299,
  iOS + macOS) ships from septena-life with `docs/APPSTORE.md` and
  `appstore/metadata*`. "Septena" (`com.septena.tasks`, Apple ID 6836809027)
  ships from here with `docs/APPSTORE-SEPTASK.md`.
- Build numbers: `CURRENT_PROJECT_VERSION` is the git commit count
  (`docs/VERSIONING.md`). septena-life starts from this repo's full history,
  so its count keeps rising and App Store builds stay monotonic. A fresh repo
  without history would restart at 1 and App Store Connect would refuse it.

## 4. Store split (the data part)

- Step 1 gives the task app its own store file: `SeptenaTasks.store` (Mac:
  `~/Library/Septena/SeptenaTasks.store`; iOS: app-group container, own
  name) with the task-only schema.
- First launch on the new store: empty store, full pull from the backend.
  The outbox (`TaskSync-Septask-v*.store`) is untouched, so unsent edits still
  push. *(default: fresh pull, no row copy; the backend is the source of truth
  since the cutover)*
- The task app no longer opens `Septena.store`. The life app keeps it.
- Order constraint: the life app may drop task entities from its schema only
  after every device runs a task app that no longer opens `Septena.store`.
  On mz's devices that is one install of the step 1 build.

## 5. CI, factory, docs, CLAUDE.md

**This repo after the split:**

- `.github/workflows/ci.yml`: build `SeptaskMac`, `Septask` (iOS),
  `SeptaskWatch`; `swift test` for `SeptenaKit`; `pnpm typecheck` in `backend/`
  (from #83). Drop the `Septena*` steps.
- `scripts/build.sh`: default scheme `SeptaskMac 'platform=macOS'`.
- `CLAUDE.md`: rewrite "What this is" (task app + `SeptenaKit` + `backend/`);
  remove section-shaped work, the Septena/Septask "four schemes" rule, section
  invariants, life traps (keep the task, focus, list and motion traps). Add a
  `SeptenaKit` rule: a change to `SeptenaKit` public API needs a revision bump
  PR in septena-life before life can use it. Replace "Two MCP servers" with:
  `backend/` here, in-app task MCP here, life's in-app MCP in septena-life.
- `docs/agents/factory.md`: drop life targets from builds; gate on
  `SeptaskMac` and `swift build`; note that life issues live in septena-life.
- `docs/README.md`: move life docs out of the index (list below); index this
  plan; change `SEPTASK_BACKEND.md` §11 to point here.
- `README.md`: the task app only, with a link to septena-life.

**septena-life:**

- `ci.yml`: today's three `Septena*` builds and the life half of
  `SeptenaCoreTests`. Same watchOS runtime caveat as today.
- `CLAUDE.md`: today's file minus Septask and task sections, plus: "SeptenaKit
  comes from michellzappa/septena at a pinned revision; change it there, then
  bump the pin here"; "MCP tool changes for `mcp.septena.app` land in
  `backend/` in the septena repo".
- No factory. Life is fixes-only (ADR 0007). *(default)*
- Docs that move (`git mv` in life, delete here with a pointer line in
  `docs/README.md`): `ADDING_A_SECTION.md`, `SECTION_DRY_AUDIT.md`,
  `BUCKET_CONSISTENCY_SPEC.md`, `ACTIVITY_CLOUD_HISTORY_PLAN.md`,
  `CONSUMABLES_*`, `GOAL_MILESTONES_PLAN.md`, `PINNED_GOALS_PLAN.md`,
  `MARKERS_PLAN.md`, `CAPTURE_DISCOVERY_SPEC.md`, `SELF_DISCOVERY_PLAN.md`,
  `PRACTITIONER_REPORTS_*`, `PER_SET_LOGGING_SPEC.md`, `TRAINING_PT_SPEC.md`,
  `MUSCLE_TAXONOMY_16.md`, `GUT_SYMPTOMS_MIGRATION_PLAN.md`,
  `NUTRITION_MIGRATION_HANDOFF.md`, `TRAINING_MIGRATION_HANDOFF.md`,
  `CloudKitSchema.md`, `PROD_CUTOVER.md`, `APPSTORE.md`,
  `SETTINGS_REORG_PROPOSAL.md`, `WAKING_DAY_WHEEL.md`, `DRAWER_MODES_SPEC.md`.
- Docs that stay here and life links to: `DesignSpec.md` (with `SeptenaKit`),
  ADRs, `IDENTIFIERS.md`, `MAKER_IDENTITY.md`, `VERSIONING.md` (life gets a
  copy).
- Private site repo `../septena-site`: `scripts/sync-changelog.mjs` reads
  `changelog.json` from `../septena-life`.
- Open issues about the life app: `gh issue transfer <n> michellzappa/septena-life`.
  *(default)*

## 6. Ordered steps

Prerequisites:

- P1. The task cutover is done (`docs/SEPTASK_BACKEND.md` §9): the backend owns
  tasks on every device, and the life app has frozen its CloudKit task types.
  §11 puts the split after the cutover; this plan keeps that order.
- P2. mz creates the empty repo `michellzappa/septena-life` and says so in #84.
- P3. mz says go on this plan in #84.

Each step is one commit (or one short series) on `main`, and ends with a green
build of the named schemes. Gates use the Mac schemes (watchOS runtime gap,
`CLAUDE.md`); CI covers iOS and watch.

**Phase A: in this repo, nothing moves out yet**

1. **Store split.** The task app opens `SeptenaTasks.store` with a task-only
   schema (§4). Gate: `SeptaskMac`, `SeptenaMac`. mz installs the task app on
   his devices before step 2.
2. **Life drops tasks.** The `Septena*` targets stop compiling
   `Septena/Shell/Tasks`, `Septena/Shell/Sidebar` task parts, task intents,
   task widgets, `SeptenaShare`, the task CloudKit records, and the task
   entities in life's schema (§2.2). Gate: `SeptenaMac`, `SeptaskMac`.
3. **Task app drops CloudKit.** Task mutators and the four store facades stop
   taking `CKEngine`; `Septask` excludes `SeptenaCore/CloudKit/` as a folder.
   Gate: `SeptaskMac`, `SeptenaMac`.
4. **Carve `SeptenaKit`.** Add root `Package.swift`, move the files that both
   apps still compile (§2.1 rule) to `SeptenaKit/Sources/SeptenaKit/`, make
   them `public`, add `import SeptenaKit`, link the package from every target
   that used them (widgets and watch included). Gate: `swift build`,
   `SeptaskMac`, `SeptenaMac`.
5. **Separate the rest by folder.** Move task-only `SeptenaCore` files to
   `TasksCore/`, `Septena/Shell/Tasks` and `Sidebar` to `Septask/`, cut the
   mixed files (§2.2 table). After this, `project.yml` lists no path that both
   app families compile, except the package. Gate: `swift build`,
   `SeptaskMac`, `SeptenaMac`.

**Phase B: create septena-life (additive; this repo does not change)**

6. Push this repo's full `main` to `michellzappa/septena-life` (keeps history,
   blame and the commit-count build number).
7. In septena-life, one commit: delete the task-app paths (§1, §2.4), point
   `project.yml` at `SeptenaKit` by URL and revision, copy tooling, rewrite
   `CLAUDE.md`, `README.md`, CI, docs index. Gate: `SeptenaMac`, then CI green
   on septena-life.
8. mz installs the life app from septena-life on his devices (dev build or
   TestFlight) and confirms it opens his existing `Septena.store`.

**Phase C: this repo drops the life app**

9. One commit here: delete the life targets and paths (§1, §2.4), the life
   docs (with pointers), life CI steps; rewrite `CLAUDE.md`, `README.md`,
   `docs/README.md`, `docs/agents/factory.md`, `SEPTASK_BACKEND.md` §11.
   Gate: `swift build`, `SeptaskMac`, CI green.
10. Transfer the life issues, update `../septena-site` changelog sync, close #84.

**Rollback**

- Phase A: each step is an ordinary commit; `git revert` it. Step 1: the old
  `Septena.store` stays on disk untouched, so a reverted task app reopens it.
  Edits made in between are on the backend and come back on the next pull.
- Phase B: additive only. If septena-life does not build or does not open
  the store, archive the repo. Nothing in this repo changed.
- Phase C: step 9 is one deletion commit; `git revert` restores the life app
  here. Do not run step 9 until step 8 is confirmed.

## 7. Open questions

Silence means the default stands.

| # | Question | Default |
|---|---|---|
| Q1 | septena-life public or private? | Public, MIT. Its whole history is already public in this repo, so private hides nothing old. |
| Q2 | Where does `SeptenaKit` live? | This repo, root `Package.swift`. Alternative: a third repo `septena-kit` with its own semver tags (cleaner pins, one more repo to run). |
| Q3 | How does life pin it? | By commit `revision`, because this repo's `v*` app tags would read as package versions. |
| Q4 | Does Septena Life keep any task surface? | No (ADR 0007: life stops carrying tasks after the cutover). Tasks section, task intents, task widgets and `SeptenaShare` leave life. |
| Q5 | Task widgets for the task app (Today widget, Add Task control)? | Separate follow-up issue. It needs a new bundle id `com.septena.tasks.widgets` that mz registers. |
| Q6 | App group | Both apps keep `group.com.septena.cloud`. |
| Q7 | Life issues and factory | Transfer open life issues to septena-life; no factory there. |
| Q8 | `reports-worker`, `community-worker` | `reports-worker` to septena-life; `community-worker` stays here (both apps use it). |
| Q9 | Store split data | Fresh pull from the backend; no copy of task rows from `Septena.store`. |
| Q10 | When | After the task cutover (P1), as §11 said. |
| Q11 | Rename `Septask*` code identifiers to `Septena*` here? | Not in this split. A separate rename spec (ADR 0007). |
