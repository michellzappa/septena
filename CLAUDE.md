# CLAUDE.md

Operational guide for working in this repo. For prose-level architecture see
`README.md`; this file is the agent cheat-sheet — commands, invariants, and the
non-obvious traps.

## What this is

Septena: a private, local-first "life operating system" for Apple platforms
(iOS / macOS / watchOS). Every life domain is a **section** that can be enabled
or hidden without deleting data. Writes land in a local SwiftData mirror first,
then sync through CloudKit (`CKSyncEngine`, private DB `iCloud.com.septena.cloud`,
zone `septena-v1`). SwiftUI throughout; Swift 5.10; deployment target 26.0.

## Build / generate

`project.yml` + XcodeGen is the **source of truth** for the Xcode project — never
hand-edit `Septena.xcodeproj` (it's regenerated). After any project change:

```bash
xcodegen generate
```

Build from CLI (the destination/scheme pattern that works here):

```bash
xcodebuild -scheme Septena    -destination 'generic/platform=iOS'   -configuration Debug build
xcodebuild -scheme SeptenaMac -destination 'platform=macOS'         -configuration Debug build
xcodebuild -scheme SeptenaWatch -destination 'generic/platform=watchOS' -configuration Debug build
```

Schemes: `Septena` (iOS, embeds Watch + widgets + live activity), `SeptenaMac`,
`SeptenaWatch`. `*.entitlements` files are **hand-maintained** (XcodeGen
references them but does not generate them) — container / app-group / bundle-id
strings live there and are edited by hand.

Debug builds use `SWIFT_OPTIMIZATION_LEVEL: -Osize` on purpose: plain `-Onone`
makes SwiftUI/SwiftData/Observation 10–50× slower on-device. Trade-off:
step-debugging is imprecise (locals "optimized out"). For a true breakpoint
session, temporarily flip Debug back to `-Onone`.

There's no `.env`. The only build-time credential is the optional Withings dev
pair: copy `Config/Secrets.example.xcconfig` → `Config/Secrets.xcconfig`
(gitignored). The app builds and runs fine without it.

## Architecture invariants (do not violate)

- **Mutators are the write boundary.** Views and App Intents must not write
  SwiftData entities directly when a mutator exists (`TaskMutator`,
  `ChecklistMutator`, `GoalMutator`, `NutritionMutator`, …). The mutator does the
  optimistic local update, queues the CloudKit change, saves context, and posts
  the right notifications.
- **Section identity vs. behavior are separate sources of truth.**
  Identity → `SeptenaCore/Sections/SectionManifest.swift` (`SectionManifest.all`,
  UI-free, in SeptenaCore). Behavior → a `SectionPlugin` in
  `Septena/Shell/Sections/Plugins/<Name>Plugin.swift`, registered in
  `SectionRegistry.all`. Joined by the string `key`.
- **Disabling a section hides surfaces; it must never delete user data.**
- **Section colors and enabled state are user/account data** (`SectionEntity`),
  not hardcoded catalog facts. `SectionTheme` is the color access point for UI.
- **Read `DayClock.today` / `DayClock.now` in views**, never `Date()` directly —
  this is what makes day-rollover and time-travel work.
- **App Intents must `await SeptenaServices.shared.start()` before mutating**
  (they can run background-launched).
- **CloudKit push is not enough** — foreground fetch remains the reliable refresh
  path; don't rely on remote-notification delivery for correctness.
- **Next-feed membership is declared once** in `SeptenaCore/NextBlocks.swift`
  (compiled into iOS + watch + mac so they can't disagree). Same single-source
  rule for `NextWire.swift` / `DayBucket.swift`.

## Section-shaped work

Adding or auditing a section? Follow `docs/ADDING_A_SECTION.md` — it's the
surface-by-surface checklist (manifest row, plugin, `SectionDrawer`-wrapped
destination, dashboard tile via `HomepageDomain` + `WeekDashboardView`,
quick-add, time travel, MCP skill, goals, flourish, import/export, Next feed,
watch). The classic bug: a section with a manifest row + destination but **no
`HomepageDomain` case**, so its dashboard tile silently never renders.

## Known traps (from prior sessions)

- **"Week" = trailing 7 days** (today + previous 6), never the calendar week.
  Use `sinceDate(daysBack: 6)`.
- **`WeekDashboardView.loadAll()` caps at ≤4 parallel HTTP calls** via
  `SeptenaClient`. New launch-time fetches must be sequential or the app
  heap-corrupts.
- **MCP gateway filters string date ranges client-side** — the CloudKit schema is
  auto-managed and Dashboard indexes are off-limits.
- **CloudKit Prod schema deploy is additive-only** and deploying schema does NOT
  move data (Prod private DB starts empty). See `docs/CloudKitSchema.md` (the
  authoritative 27-record field table) and the prod-cutover plan.

## Where truth lives (priority order)

1. **Code** — always wins.
2. `docs/DesignSpec.md` — the canonical design system (typography, color, the
   three-tier iconography rule, row anatomy, spacing, motion). When it conflicts
   with code, the code is wrong.
3. `docs/CloudKitSchema.md` — field-by-field record-type table.
4. `IDENTIFIERS.md` — stable id/title model and wire contracts across app,
   CloudKit, and the MCP gateway.
5. `README.md` — full architecture narrative.
6. `*_HANDOFF.md`, `*_PLAN.md`, `docs/BET1_*` — historical migration/feature
   notes. **Often stale; verify against code before acting.**

## Layout map

- `SeptenaCore/` — models, SwiftData (`Persistence.swift`), CloudKit
  (`CloudKit/CKEngine.swift`), providers (Oura/Withings/GitHub/HealthKit/…),
  mutators, `SeptenaServices.swift` (process-wide runtime singleton).
- `Septena/App/` — entry (`App.swift`), root tabs, App Intents, watch bridge.
- `Septena/Shell/` — dashboards, settings, tasks, goals, intelligence, shared UI.
- `Septena/Sections/` — per-section destination views and sheets.
- `SeptenaWatch/` + `SeptenaWatchComplication/` — watch app & complications
  (**hand-wired per section**, not manifest-driven, except the shared Next feed).
- `SeptenaWidgets/`, `SeptenaLiveActivitiesExtension/` — extensions.

## Conventions

- Match surrounding code: comment density, naming, idiom.
- Don't add FastAPI/server client code — the repo is CloudKit-first; remaining
  FastAPI references are migration history slated for cleanup.
- The hosted MCP gateway is a **separate repo** (`../septena-mcp-gateway`); its
  `skill.md` is generated from `SectionRegistry.fullSkillMarkdown()`, so keep
  in-app section skill briefs in sync with the gateway's MCP tools.
