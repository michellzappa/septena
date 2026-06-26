# Adding a Section (mini-app)

A "section" is one Septena mini-app — Tasks, Nutrition, Caffeine, Hydration,
etc. Each section is declared once in the **manifest** and then wired across a
fixed set of **surfaces**. This doc is the checklist: it lists every surface a
section can touch, what's required vs. optional, and where the code lives. Use
it both when adding a section and when auditing whether an existing one is
"fully fleshed out."

The canonical worked example throughout is **Hydration** — a deliberately
minimal section (no entity of its own; it's a UX layer over Nutrition's
`waterMl`). If Hydration touches a surface, every section can.

---

## The two source-of-truth declarations

| Concern | File | Type |
| --- | --- | --- |
| Catalog facts (key, label, activation, dashboard support, settings mode) | `SeptenaCore/Sections/SectionManifest.swift` | `SectionManifest` row in `.all` |
| Behaviour (destination view, onboarding, MCP skill brief, flourish, goals) | `Septena/Shell/Sections/Plugins/<Name>Plugin.swift` | `SectionPlugin` conformer, registered in `SectionRegistry.all` |

`SectionManifest` lives in **SeptenaCore** (UI-free). The plugin lives in the
**app target** because it constructs SwiftUI views. They're joined by the
string `key` (also `SectionEntity.id` in CloudKit, and the MCP tool prefix).

---

## Surface checklist

Required surfaces are what make a section feel first-class. Optional surfaces
depend on what the section does.

### 1. Manifest row — **required**

`SectionManifest.all` in `SectionManifest.swift`. One `.init(...)` with:

- `key` — stable lowercase id (matches `SectionEntity.id`, MCP tool prefix).
- `defaultLabel`, `shortDescription`.
- `activation` — `.always` / `.optional` / `.integration`.
- `onboarding` — `.core` (on by default) / `.optional` / `.hidden`.
- `supportsDashboard` — whether the Week dashboard should reserve a tile.
- `settingsEditor` — `.none` / `.appearance` / `.sectionConfig`.

Also add the SF Symbol to `iconByKey` (same file). New sections are
auto-seeded into the user's `SectionEntity` set at launch by
`SettingsMirror.seedManifestSectionIfMissing` (called from
`SeptenaServices.start`), so they appear in Settings and as a tile without
manual install — **no separate Settings or ordering wiring is needed.**

### 2. Plugin + registration — **required**

`Septena/Shell/Sections/Plugins/<Name>Plugin.swift`, a `SectionPlugin` whose
`manifest` resolves `SectionManifest.byKey["<key>"]!`. Add the type to
`SectionRegistry.all` in `SectionPlugin.swift`. Everything below is a slot on
this protocol (most have no-op defaults).

### 3. Destination view — **required** (if the section opens from dashboard/settings)

`static func destinationView() -> AnyView?`. **Wrap the content in
`SectionDrawer`** (not a bare `List`/`ScrollView`) so you inherit the standard
nav chrome, the goals strip, the "+" toolbar, and — when you pass
`currentDate` — time travel (see surface 7). Group content into
`DrawerSection { ... }` cards; use `LogEntryRow` for log rows. See
`GutDestinationView` / `HydrationDestinationView` for the idiom.

Create/edit forms should be presented with `.drawerDetail(edit:create:)` (or
the lower-level adaptive detail modifiers) and hosted by `AdaptiveEditScaffold`.
The form supplies `canSave` and `onSave`; the scaffold owns cancel/save chrome
and dismissal. New log writes should go through `SectionLog.newLog(...)` so the
same save path triggers dashboard flourishes and confirmation affordances.

### 4. Dashboard tile — **required** (if `supportsDashboard`)

This is the surface most often missed. Wiring lives in
`Septena/Shell/Dashboard/`:

- **`HomepageDomain.swift`** — add a `case <key>` AND an entry in
  `defaultOrder`. Without this the tile never renders, regardless of section
  order. This enum is the canonical identity/order for every layout mode
  (Tiles / Dense / Heatmap).
- **`WeekDashboardView.swift`** — add, mirroring an existing section:
  - a `WeekDestination` case (drives the push/sheet route),
  - `@State` for the tile's today value + history series,
  - a `CacheKey` + loads in `init`, `paintFromCache`, and `loadAll` (so cold
    launch paints from disk),
  - a `case` in `tile(for:)` → your `<name>Tile` view,
  - a `case` in `domainData(for:)` → your `<name>DomainData()` (feeds the
    Dense/Heatmap modes — keep "today's number" defined in one place),
  - a `case` in `quickAddMenu(for:)` (or `EmptyView()` if no quick-add),
  - cross-device refresh: add a `case` to `repaint`/`refresh(section:)` if the
    section is an `AddInfoSection`; otherwise refresh it explicitly in
    `repaintAllMirrors()` (Mood and Hydration do this — they bypass
    `AddInfoSection`).

**Section Tile widget** — if `supportsDashboard`, add a `*DomainData()` case in
`DashboardTileBuilder` and the section auto-appears in the iOS home-screen
"Section Tile" widget picker after the next dashboard refresh. No separate
widget wiring per section.

### 5. Quick-add — **optional**

Two patterns:

- **Routes through `AddInfoSection`** (most sections): add a case to
  `AddInfoSection`, give it an Add* page, and call `notifyTilesChanged()` after
  commit. The dashboard's `.tilesDidChange` listener repaints that one tile.
- **Self-refreshing** (Mood, Hydration): the section writes through another
  section's mutator and isn't in `AddInfoSection`. Commit directly, then call
  your own `refresh<Name>()`. Surface presets as a `contextMenu` on the tile
  (`<name>QuickAddMenu`).

### 6. Today timeline — **optional**

Add the key to `SectionManifest.todayCapableKeys` and feed the section's today
entries into `WeekDashboardTimelineCard` (the `todayTimeline` builder in
`WeekDashboardView`). Simple log sections can use `DayTimelineExtraEvent`
instead of adding a dedicated entity array to `DayTimelineView`; pass the event
id/date/time plus `sectionKey` and the timeline will use the section accent.

### 7. Time travel — **optional**

Add the key to `SectionManifest.timeTravelCapableKeys` **and** thread a
`@State viewingDate` into the destination's `SectionDrawer(currentDate:)`. The
drawer renders the calendar toolbar button + past-day pill; your `reload()`
keys off `viewingDate`, and "today-only" affordances (live summaries, quick-add,
target editors) hide when `viewingDate != SeptenaDate.today`. Adding the key
without threading `currentDate` does nothing — the date strip is a
`SectionDrawer` feature.

### 8. MCP / agent skill — **optional**

`static var mcpSkill: SectionSkill?` on the plugin declares the human-facing
brief only; it does **not** make tools callable. For app-local MCP, add matching
tool schemas in `SeptenaCore/MCP/MCPToolCatalog.swift`, dispatch/read-write
handlers in `SeptenaCore/MCP/MCPDispatch.swift`, and include list tools in
`readOnlyTools` when they only read the local mirror. If the hosted gateway is
expected to expose the same section, mirror the schema and handlers there too.

The gateway repo's `skill.md` is generated from
`SectionRegistry.fullSkillMarkdown()`, so keep the plugin brief in sync with the
actual MCP tools. A section with only `mcpSkill` text is documented for agents
but not executable.

### 9. Settings detail pane — **optional**

`static func detailPaneContent() -> AnyView?`, used when `settingsEditor` is
`.appearance` / `.sectionConfig` (catalog lists, per-section toggles, HealthKit
sync via `HKSyncSection`). `.none` sections get the identity row only.

### 10. Onboarding — **optional**

`static func onboarding(complete:) -> AnyView?` — a first-enable explainer
(`SectionExplainerView`). Must be additive only (never mutate existing data).

### 11. Goals / aim metrics — **optional**

`aimMetrics` + `evaluateAim` expose queryable targets a user can attach to a
Goal.

### 12. Commit flourish — **optional**

`static var logFlourish: LogFlourish?` — the affect axis a new log animates on.
Route writes through `SectionLog.newLog` to fire it.

### 13. Import/Export — **optional**

`exportContribution` — schema tables + a collect closure. Skipped if nil.
This covers export and the schema prompt only. Import is separate: if the
section's data cannot be restored by an existing generic importer, add an
explicit import/apply path before calling the section import-ready.

### 14. Next feed membership — **optional**

Whether the section appears in the "Next" feed (the Today checklist of
tasks / chores / habits / supplements) is declared **once** in
`SeptenaCore/NextBlocks.swift` — add a `Block` row to `NextBlocks.all` with the
`sectionKey`, the `itemKind` it emits, and a `completion` strategy
(`.recordStatus` for in-place record edits, `.event(recordType:)` for per-day
event records). That single row drives:

- `NextFeed.flat` / `NextFeed.orderedSectionKeys` — feed composition + order;
- iOS `NextOpenSection` — membership/order (its `isEmpty(_:)` + `block(for:)`
  switches still need an interactive-row case, guarded by `assertionFailure`);
- the watch's completion dispatch in `WatchConnectivity.complete`.

`NextBlocks` is dependency-free and compiled into the iOS, watch, and mac
targets (like `DayBucket`). A new ritual-backed member needs only the row + the
iOS render case; a new CloudKit record type also needs a writer in the watch's
`saveEvent(recordType:)`. Read-only suggestions (caffeine / cannabis / training
/ fast-break) are **not** members — they're nudges prepended by `NextFeed` and
never complete.

### 15. Watch app — **optional, currently bespoke**

`SeptenaWatch/` + `SeptenaWatchComplication/` do not read the manifest; each
surfaced section is hand-wired there. Treat watch presence as an explicit,
separate decision per section, not a manifest-driven default. (The Next *feed*
the watch renders is the exception — its membership is shared via `NextBlocks`,
surface 14.)

---

## "Is this section fully fleshed out?" audit grid

| Surface | Required? | Where |
| --- | --- | --- |
| Manifest row + icon | ✅ | `SectionManifest.all`, `iconByKey` |
| Plugin + registry | ✅ | `<Name>Plugin.swift`, `SectionRegistry.all` |
| Destination (in `SectionDrawer`) | ✅ if dashboard/tab | plugin `destinationView()` |
| Dashboard tile | ✅ if `supportsDashboard` | `HomepageDomain` + `WeekDashboardView` |
| Settings + ordering | ✅ (auto-seeded) | manifest only |
| Quick-add | ▫️ | `AddInfoSection` **or** self-refresh menu |
| Today timeline | ▫️ | `todayCapableKeys` + timeline card |
| Time travel | ▫️ | `timeTravelCapableKeys` + drawer `currentDate` |
| MCP skill + tools | ▫️ | plugin `mcpSkill`, `MCPToolCatalog`, `MCPDispatch` |
| Settings detail pane | ▫️ | plugin `detailPaneContent()` |
| Onboarding | ▫️ | plugin `onboarding()` |
| Aim metrics | ▫️ | plugin `aimMetrics` / `evaluateAim` |
| Flourish | ▫️ | plugin `logFlourish` + `SectionLog` |
| Import/Export | ▫️ | plugin `exportContribution` + importer if restore is supported |
| Next feed | ▫️ | `NextBlocks.all` (+ iOS render case, watch writer) |
| Watch | ▫️ bespoke | `SeptenaWatch/` |

The classic gap is a section that has a manifest row + destination (so it shows
in Settings and is reachable) but **no `HomepageDomain` case** — it silently
never renders a dashboard tile. That was exactly Hydration's state before it was
finalized.
