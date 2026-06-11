# Consumables Generalization — Handoff

Status as of 2026-06-11. Companion to `CONSUMABLES_PLAN.md` (the milestone plan)
and `CONSUMABLES_GENERALIZATION_STUDY.md` (the why). This is the **what's left**
list for the next agent, written from the end of a long build thread.

## Where we are

The `intake` section is **live and in daily use**. Caffeine and cannabis have
both been **imported** into intake trackers (real data, via the Settings import
buttons); the user's "Cannabis" tracker holds the full imported history
strains. The old caffeine/cannabis sections still exist but are now redundant.

**Shipped this thread (all builds green unless noted):**

- Milestones 1–5: `ConsumableContainer` + golden tests; `IntakeKind/Item/Event`
  entities + `IntakeMutator` + CloudKit; record-level migrator + verification;
  full UI (destination / wizard / Manage / edit sheets); real section (manifest
  row, `IntakePlugin`, dynamic per-kind `aimMetrics(context:)`, Settings pane);
  homepage **tile-per-kind**.
- Presentation-as-sections: Settings "Trackers" sidebar group, the Intake detail
  pane as a tracker manager, icons in Manage Sections.
- Reduction reframing + **Alcohol** and **Nicotine** presets (Caffeine/Tea/
  Alcohol/Nicotine/Custom). No cannabis template ships.
- `objective` field (log/limit/reduce/quit) **unified with Goals** — the
  objective creates/edits a real `GoalEntity` via
  `GoalMutator.syncIntakeObjectiveGoal`; limit's cap = the goal target; **daily/
  weekly window toggle** on limit/reduce.
- **Milestone 6 (MCP)** — 9 generic `intake_*` tools in BOTH servers (in-app
  `MCPToolCatalog`/`MCPDispatch` + the gateway `../septena-mcp-gateway`
  `src/tools/intake.ts`); skill briefs updated; gateway **deployed**. Verified
  live: `intake_kinds_list` returns the user's trackers over the local server.
- **Watch generalization** — `NextWire.IntakeKindWire` + `NextItemsResponse
  .intakeKinds`; `WatchSnapshotPublisher` emits enabled trackers + container
  state; the watch + menu renders one row per tracker (`IntakeCaptureInput`,
  container-aware) and writes `IntakeEvent` records. Build-verified, **not
  device-tested** (sideload blocked — see `project_watch_app_install`).
- **Purge enablers** (so the cannabis purge is safe):
  - **Migrate-on-sight wired** — `applyFetchedRecord` in `SeptenaServices.swift`
    calls `IntakeMigrator.migrate(record:mutator:)` for legacy Caffeine/Cannabis
    records arriving over sync. The standing rule that survives deleting the
    legacy `@Model` classes (study §7.2). No more manual import taps needed.
  - **Legacy wire fields derive from the intake kind** —
    `WatchSnapshotPublisher` sources `cannabisUsesPerCapsule`/`cannabisLastVapeHit`
    from the `ik-cannabis` tracker (fallback legacy while classes exist), so an
    OLD physical watch keeps its capsule quick-add after the purge.
- Drawer parity polish: tile **deep-open** (tracker tile → its page, no switcher
  hop), **per-item context menus** in all four layout renderers, the **rhythm
  wheel**, the **commit flourish** (uses each kind's own `flourish` motion), and
  the **capsule-slots** accessory (`ProjectProgressIcon` ring, `N/cap`).

## What's left

### 1. The purge — Milestone 8 + 9 (the big one)

Remove `cannabis` from the iOS binary. **Inventory: ~59 files, ~552 mentions**
(`grep -ril cannabis Septena SeptenaCore SeptenaWatch`). The App Review payoff.

Open product decision first: **purge cannabis only, or retire BOTH legacy
caffeine + cannabis sections?** Both are migrated to intake; the study's phase 4
retires both. Caffeine isn't review-sensitive, so it *could* stay — but keeping
two redundant sections is debt. Recommend retiring both legacy sections, keeping
their CK record types dormant (additive-only) + migrate-on-sight forever.

To remove (cannabis; mirror for caffeine if retiring both):
- Manifest row + `HomepageDomain.cannabis` + `WeekDestination.cannabis`
- `CannabisPlugin`, `Septena/Sections/Cannabis/*` (destination, AddCannabisPage,
  BrowseCannabisDaySheet, EditCannabisEntrySheet, CannabisQuickAddMenu)
- `CannabisIntents`, the `cannabis` arm in `SectionLogIntent`/Siri panes
- `CannabisMutator`, `CannabisEventEntity` + schema (keep the **CK record type
  string** reachable for migrate-on-sight — it reads raw CKRecords by type name)
- `cannabis_*` (and `caffeine_*` if retiring) tools from the in-app
  `MCPToolCatalog`/`MCPDispatch`. **Gateway keeps its aliases** (outside App
  Review) — but see §3 (aliases must write generic records post-cutover).
- `SuggestionBlocks` cannabis row, `DemoSeed`, `Localizable.xcstrings`,
  `Plausible` event names, `SectionExplainer`, correlation features, dashboard
  wiring (state/tile/domainData/quickAdd/cache).
- **CI grep gate**: the iOS target must not contain `cannabis` (case-insensitive)
  after the purge.

**Traps:**
- `CannabisCapsule` (`SeptenaCore/CannabisCapsule.swift`) is still used by (a)
  the watch's static cannabis `CaptureInput` path and (b)
  `ConsumableContainerTests` golden identity tests. Once the watch's static
  caffeine/cannabis rows are removed (intake drives the wrist now) and the tests
  are dropped/retargeted, `CannabisCapsule` can be deleted — but verify no other
  references. The generic `ConsumableContainer` replaces it everywhere.
- `IntakeMigrator.legacyRecordTypes` + the migrate-on-sight cases must KEEP
  referencing the legacy record-type **strings** (`CannabisEvent`, etc.) — that
  path is intentionally permanent and survives `@Model` deletion. Don't delete
  the schema *enums* the migrator reads field names from, or migrate them to a
  small standalone record-shape file.
- The migrate-on-sight runs on EVERY synced legacy record forever — confirm it
  stays cheap (it's an idempotent upsert by deterministic id).

### 2. Drawer / UX polish (optional, noticeable)

- **Flourish on the other write paths** — only the drawer's direct quick-add
  fires the commit flourish. The **edit-entry sheet** save, the **homepage tile**
  context-menu commit (`commitIntake`), and the **watch** still use a plain
  haptic. Route them through the flourish too (use
  `IntakeKindPageView.motion(for:)` mapping; the kind's `flourish` token).
- **Dose-scaled flourish intensity** — old caffeine scaled the bloom by grams;
  intake fires fixed intensity. `SectionLog.newLog(intensity:)` accepts it.
- **Per-kind goals-strip filter** — a tracker page's `SectionGoalsStrip(sectionKey:
  "intake")` shows ALL intake goals, not just that tracker's. Filter to goals
  whose `metricKey` contains the kind id.
- **Non-Tiles per-kind rhythm** — `RhythmHomepageView` buckets intake events
  under the `intake` section key (one mini-wheel), not per tracker.
- **flourish / metricMode** still not editable in Manage (low priority).

### 3. Migration / data (lower urgency)

- **Kind merge** — designed (study §7.2), not built. Needed if the user ends up
  with two same-named trackers (e.g. a hand-made one + a migrated one). Surface
  in Manage + as `intake_kinds_merge` over MCP. The user resolved their case by
  archiving, so not blocking.
- **Gateway legacy aliases** — `caffeine_*`/`cannabis_*` on the gateway still
  write LEGACY records. Post-cutover they should be thin shims that write GENERIC
  `IntakeEvent` records (kind pre-bound), else an agent using a stale tool name
  forks the data (study §6.1).
- **`CannabisStrain` gateway records** (study open-Q 6) — migrate into
  `IntakeItem` via a gateway job, or leave dormant.

### 4. External gates / verification

- **Physical-watch device test** — sideload blocked; verify via TestFlight/sim.
- **Prod CloudKit deploy** (only when shipping to prod) — `IntakeKind` (incl.
  `objective`), `IntakeItem`, `IntakeEvent`. **Dev auto-registers on first
  write; Prod is locked.** Write every field once in a dev build before the prod
  deploy (`docs/CloudKitSchema.md` §). Migrate-on-sight + the import are
  dev-tested only so far.

### 5. Docs to update when the purge lands

- `docs/CloudKitSchema.md` — add the three `Intake*` field tables (+ `objective`).
- `docs/IDENTIFIERS.md` — intake id/title + recordName contract.
- `docs/ADDING_A_SECTION.md` — intake as the worked example of data-driven tiles.
- `docs/CONSUMABLES_PLAN.md` — mark milestones, record the purge.

## Key files / anchors

- Core: `SeptenaCore/IntakeModel.swift` (pure model + migration map + templates +
  `IntakeObjective`), `Persistence.swift` (entities + schemas + CK extensions),
  `SeptenaServices.swift` (`IntakeMutator` + migrate-on-sight),
  `CloudKit/Migration.swift` (`IntakeMigrator`), `ConsumableContainer.swift`,
  `NextWire.swift` (`IntakeKindWire`), `WatchSnapshotPublisher.swift`.
- App: `Septena/Sections/Intake/*` (reader, destination, kind page, wizard,
  manage, edit), `Shell/Sections/Plugins/IntakePlugin.swift` (plugin + skill +
  Settings detail pane + import buttons), `Shell/Dashboard/WeekDashboardView.swift`
  (tiles/menus/deep-open), `Shell/Settings/SettingsView.swift` (Trackers rows).
- MCP: in-app `SeptenaCore/MCP/MCP{ToolCatalog,Dispatch}.swift`; gateway
  `../septena-mcp-gateway/src/tools/intake.ts` + `src/mcp.ts` + `skill.md`.
- Tests: `SeptenaCoreTests/{ConsumableContainerTests,IntakeMigrationTests}.swift`
  (hermetic, Foundation-only; run `xcodebuild test -scheme SeptenaCoreTests
  -destination 'platform=macOS'`).

## Build / verify

`xcodegen generate` after any file add (the project is regenerated; a stale
`xcodeproj` referencing a moved file is a common red build). Then:
`xcodebuild -scheme Septena -destination 'generic/platform=iOS' build`,
`-scheme SeptenaMac -destination 'platform=macOS'`,
`-scheme SeptenaWatch -destination 'generic/platform=watchOS'`.
Local MCP server: the Mac app must be relaunched on a fresh build to pick up tool
changes; it's at `http://127.0.0.1:7717/mcp` (bearer in `~/.claude.json`).
