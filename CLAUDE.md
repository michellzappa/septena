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

**Build once per logical unit, never concurrently.** Make a coherent change, then
run **one** verifying build before leaving the tree green — not after every file
touch. With 3–5 parallel sessions plus the hourly commit-cron, concurrent
`xcodebuild`/`xcodegen` against shared state corrupts incremental builds, so
**build through `scripts/build.sh`** (defaults to the iOS `Septena` scheme): it
takes a shared `mkdir` lock at `/tmp/septena-build.lock.d` so builds serialize
across every session and the cron. The compile is the only green gate before the
cron pushes — a tree that doesn't build must never be left behind.

Debug builds use `SWIFT_OPTIMIZATION_LEVEL: -Osize` on purpose: plain `-Onone`
makes SwiftUI/SwiftData/Observation 10–50× slower on-device. Trade-off:
step-debugging is imprecise (locals "optimized out"). For a true breakpoint
session, temporarily flip Debug back to `-Onone`.

There's no `.env`. The only build-time credential is the optional Withings dev
pair: copy `Config/Secrets.example.xcconfig` → `Config/Secrets.xcconfig`
(gitignored). The app builds and runs fine without it.

## Versioning & changelog

Full guide: `docs/VERSIONING.md`. The rules that bite:

- **Two numbers, two owners.** `MARKETING_VERSION` (SemVer, user-facing) lives
  in `project.yml` and is **bumped by hand only when cutting a release**. The
  build number `CURRENT_PROJECT_VERSION` lives in `Config/Base.xcconfig` (NOT
  project.yml — a project-level value would override the xcconfig) and is
  **stamped from the git commit count** by `scripts/stamp-version.sh` at archive
  time. Never hand-bump the build number; never move it back into project.yml.
- **SemVer, pre-1.0.** Bump MINOR (`0.2.0`) for a batch of user-facing
  features, PATCH (`0.1.1`) for fixes-only. `1.0.0` = public App Store launch.
- **Cutting a release is one deliberate act, done in a single session** (so the
  hotspot `project.yml` + changelog don't conflict across parallel sessions):
  `scripts/changelog-draft.sh` → curate `Septena/Resources/changelog.json` →
  bump `MARKETING_VERSION` → `git tag vX.Y.Z` → `scripts/stamp-version.sh` →
  archive. Do NOT bump the version or touch the changelog during ordinary
  feature work — the cron commits green units without a version bump.
- **The changelog is one canonical JSON, two consumers.**
  `Septena/Resources/changelog.json` is bundled into the app (Settings ▸ About ▸
  What's New + the auto "What's New" sheet on update, read by `SeptenaCore/
  Changelog.swift`) AND mirrored to the website at build time
  (`../septena-site/scripts/sync-changelog.mjs` → `/changelog`). **Author here,
  never in two places.** It is NOT generated from the runtime DB — that's
  life-data; release notes come from git. A highlight's optional `section` key
  drives its accent color on both surfaces.

## Branch & integration discipline

**A committer-cron handles commits.** A scheduled job commits green work on
`main` automatically — agents do NOT need to `git commit` (or offer to) as part
of finishing a task. Just leave the working tree in a green, build-verified
state; the cron picks it up. Don't worry about "uncommitted across sessions"
below — that's the cron's job now. (You still must never `git push`, create
branches, or rewrite history unless explicitly asked.)

**Default to committing on `main`. Do NOT create branches unless the user
explicitly asks for one.** The user never asks for branches — every stray
branch in this repo's history was agent-created, and that is exactly what caused
the divergence: each session forked a new branch off a frozen `main`, so two big
features once edited sections, MCP, `Localizable.xcstrings`, and
`CloudKitSchema.md` independently and the *same* display-name commit landed
twice. Work on `main`; commit green units directly. Avoid recreating that:

- **Integrate early.** Land green, build-verified work on `main` as you go. If a
  branch ever does exist (user asked, or mid-consolidation), merge it back the
  same session — don't let it outlive the task or fork siblings off its base.
- **Don't leave work uncommitted across sessions.** Commit logically-complete,
  build-verified units. "BUILT uncommitted" is the anti-pattern that caused the
  divergence — uncommitted trees are also lost to crashes.
- **Rebase before you build on top.** If a feature depends on another branch's
  work, rebase onto it (or onto latest `main`) first, don't develop blind.
- **Hotspot files conflict constantly** because every feature appends to them:
  `Localizable.xcstrings` / `InfoPlist.xcstrings` (string catalogs),
  `CloudKitSchema.md` (the deploy changelog), `project.pbxproj`. Conflicts here
  are almost always **union merges** (keep both additions; renumber changelog
  rows). Frequent integration is the real fix — they drift in proportion to how
  long branches live.
- **When asked to consolidate branches**, first map each with
  `git rev-list --count main..<b>` / `<b>..main`, dry-run merges with
  `git merge-tree`, and confirm a deleted branch's content isn't unique before
  dropping it (a stale branch's work is often already redone on `main`).

**Running parallel sessions? Use git worktrees, not one shared tree.** The user
typically runs 3–5 Claude sessions at once; in a single working tree they silently
clobber each other's files (no conflict, no warning — just lost work). One worktree
per session fixes it structurally: separate working dir (no file collisions) and
separate path-keyed DerivedData (no build contention). Use the helpers:

```bash
scripts/wt-new <name>     # creates ../septena-<name> on a short-lived wt/<name> branch
#  …work the session in that dir, build with scripts/build.sh, commit on the branch…
scripts/wt-done <name>    # green-gated merge back to main (build the MERGED tree,
                          # finalize + push only if green, else abort), then cleanup
```

The `wt/<name>` branch is the **sanctioned exception** to "no branches" precisely
because `wt-done` merges it back the *same session* and deletes it — that's the
opposite of the long-lived forks that caused the divergence. Hotspot files
(`*.xcstrings`, `project.pbxproj`, `CloudKitSchema.md`) still conflict at merge;
that's the *good* failure mode — a conflict you resolve (union merge) beats a
silent clobber. `wt-done` refuses to merge a dirty main or an uncommitted worktree;
commit on the branch first (or let the cron do it).

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
4. `docs/IDENTIFIERS.md` — stable id/title model and wire contracts across app,
   CloudKit, and the MCP gateway.
5. `README.md` — full architecture narrative.
6. `docs/*_HANDOFF.md`, `docs/*_PLAN.md`, `docs/BET1_*` — historical
   migration/feature notes. **Often stale; verify against code before acting.**

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
- `appstore/` — App Store packaging (iPhone/iPad/Mac/Watch): copy in
  `docs/APPSTORE.md`, panel visuals in `appstore/panels.config.mjs`, surfaces in
  `appstore/devices.mjs`. `appstore/capture.sh <device>` shoots raw screens
  (iPhone/iPad via `SeptenaUITests`, Mac via `SeptenaMacUITests`), `npm run viz`
  renders + validates + opens the review webapp, `fastlane deliver` uploads.
  Mac is a separate ASC app (own deliver run). See `docs/APPSTORE.md`.

## Conventions

- **All documentation lives in `docs/`.** Any new `.md` — plan, handoff, spec,
  design note, feature write-up — goes in `docs/`, never the repo root. Root is
  reserved for the canonical set only: `README.md`, `CLAUDE.md`, `SECURITY.md`,
  `LICENSE`, `NOTICE`, `project.yml`. Reference docs by their `docs/…` path.
- Match surrounding code: comment density, naming, idiom.
- Don't add FastAPI/server client code — the repo is CloudKit-first; remaining
  FastAPI references are migration history slated for cleanup.
- **Two MCP servers, edited in lockstep.** There are TWO: the **in-app** server
  (`SeptenaCore/MCP/` — `LocalMCPServer` + `MCPDispatch` + `MCPToolCatalog`,
  macOS, for Claude Code) and the **hosted gateway** (separate repo
  `../septena-mcp-gateway`, Cloudflare Worker / TS, for consumer chat). **Any MCP
  tool change must land in BOTH, plus the docs/skills, in the same change** —
  never one without the others, or the two surfaces silently diverge. The
  gateway's `skill.md` is generated from `SectionRegistry.fullSkillMarkdown()`, so
  keep in-app section skill briefs in sync with the gateway's tools.
