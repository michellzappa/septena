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
takes a shared `mkdir` lock at `/tmp/auto-build.lock.d` so builds serialize
across every session and the cron. The compile is the only green gate before the
cron pushes — a tree that doesn't build must never be left behind.

**The iOS `Septena` scheme can't build when no watchOS simulator runtime matches
the SDK the active Xcode ships** (e.g. Xcode 26.6 ships watchOS 26.5; runtimes
installed are 26.2 + 27.0). It embeds the watch app, so xcodebuild resolves a
watch destination and dies — either at the scheme precondition ("watchOS 26.5
must be installed") or further down in `actool` on the complication's asset
catalog. Same mismatch, two different-looking errors, neither self-explanatory.
**Nothing is wrong with the project** — Xcode.app builds fine because you pick a
concrete destination it can resolve. `scripts/build.sh` now detects this before
taking the lock and exits 2 with guidance. When the change doesn't touch watch
code, gate it on macOS instead — it compiles the same shared sources:

```bash
scripts/build.sh SeptenaMac 'platform=macOS'
```

If the change *does* touch watch code, **stop and tell the user** — installing a
multi-GB runtime is their call, never the agent's.

**Do NOT test — the user tests.** The compile above is the ONLY verification an
agent runs. Never launch the app, boot a simulator, run UI tests, screenshot, or
otherwise "verify it works" — when the change is built, report it and **ask the
user to test**. And **NEVER download anything to unblock a build or test**
(SDKs, simulator runtimes, platform components, packages, tools — e.g.
`xcodebuild -downloadPlatform`) unless the user explicitly asked for that
download. If the toolchain is missing something, stop and tell the user; a
multi-GB platform download is their call, never the agent's.

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
  **the git commit count**, stamped live by the committer-cron
  (`scripts/changelog-stamp.sh`) every time work lands, and re-stamped by
  `scripts/stamp-version.sh` at archive time. Never hand-bump it; never move it
  into project.yml. Every embedded target (apps, watch, widgets, complication,
  live activity) reads `$(CURRENT_PROJECT_VERSION)`/`$(MARKETING_VERSION)` so the
  whole bundle stays version-consistent — mismatched extensions fail App Store
  validation.
- **SemVer, pre-1.0.** Bump MINOR (`0.2.0`) for a batch of user-facing
  features, PATCH (`0.1.1`) for fixes-only. `1.0.0` = public App Store launch.
- **The cron keeps an `"Unreleased"` changelog entry current.** Each run,
  `scripts/changelog-stamp.sh` rewrites the single pinned `version:"Unreleased"`
  entry at the top of `changelog.json` — Claude-curated, human-readable
  highlights from the commits since the last release, carrying the live build
  number — and stamps `Base.xcconfig` to match. It self-guards against churn
  (skips when HEAD is already a refresh) and never touches released entries. So
  ordinary feature work still **doesn't** hand-edit the version or changelog —
  but the cron now does keep the unreleased notes + build number live. You just
  leave a green tree.
- **Cutting a release promotes the `"Unreleased"` entry**, one deliberate act in
  a single session (so the hotspot `project.yml` + changelog don't conflict
  across parallel sessions): in `Septena/Resources/changelog.json` rename the
  Unreleased entry's `version` → the real number + set name/summary + curate
  highlights → bump matching `MARKETING_VERSION` → `git tag vX.Y.Z` →
  `scripts/stamp-version.sh` → archive.
- **The changelog is one canonical JSON, two consumers.**
  `Septena/Resources/changelog.json` is bundled into the app (Settings ▸ About ▸
  What's New + the auto "What's New" sheet on update, read by `SeptenaCore/
  Changelog.swift` — which hides the Unreleased entry from the launch sheet via
  `latestReleased`) AND mirrored to the website at build time
  (`../septena-site/scripts/sync-changelog.mjs` → `/changelog`; both surfaces
  show the build number). **Author here, never in two places.** It is NOT
  generated from the runtime DB — that's life-data; release notes come from git.
  A highlight's optional `section` key drives its accent color on both surfaces.

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
- **Undo is ONE shared stack** (`SeptenaCore/TaskUndo.swift`), wrapping a single
  process-wide `UndoManager`. Every task surface points at it — the AppKit
  table, the SwiftUI lists, and iOS shake / three-finger undo (the app
  delegates override `UIResponder.undoManager`, the last stop in the responder
  chain, so a focused text field still wins for typing). **Record explicitly at
  the user gesture, never inside a mutator**: the mutators also run for
  CloudKit applies, the 30-day purge, recurrence spawning, and the watch, so
  recording there would put sync traffic on the undo stack and let ⌘Z "undo" an
  edit another device made.
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

## Septask — the second app target

Septask is the focused task app over the SAME private CloudKit task data:
same repo, same shared sources, a different composition root (plan + phase
findings: `docs/SEPTASK.md`). Four app schemes now exist: `Septena`,
`SeptenaMac`, `Septask`, `SeptaskMac`.

- **Shared folders own behavior; the roots own composition.** `SeptenaCore`,
  `Shell/Tasks`, `Shell/Sidebar`, `Shell/UI` (and listed shared files)
  compile into both apps — edit once, both change. App-level chrome lives in
  the roots (`Septena/App/App.swift` vs `Septask/SeptaskApp.swift`), which is
  the ONE place that isn't shared: window styles, scenes, commands, and
  environment injection must be kept in parity deliberately (the
  hidden-title-bar sidebar drift came from exactly this).
- **Septask-specific exceptions, three sizes:** (1) `#if SEPTASK` inside a
  shared file for small branches (the target sets that compilation
  condition); (2) a Septask-only implementation in `Septask/` (settings
  shell, welcome, tab bar) — composition only, never task business logic;
  (3) a `project.yml` exclude when a file shouldn't compile at all.
  **Never copy a task file into `Septask/` to tweak it** — copies drift.
- **After touching shared code, build all four schemes.** The compiler
  catches type-level seams, but NOT the runtime one: a shared view reading a
  new `@Environment(X.self)` crashes at launch in whichever app forgot to
  inject it. The required-injection list lives in `docs/SEPTASK.md` ("P1
  Findings").
- **Keep the `Septask` and `SeptaskMac` source lists in `project.yml` in
  lockstep** — they must stay identical (new shared-file inclusions go in
  both).
- Septask runs `RuntimeProfile.tasksOnly` (task/area/project mutators only,
  no provider stores) but still mirrors the WHOLE zone locally — CKSyncEngine
  fetches per-zone; non-task records are applied and invisible.
- The Septask icon is generated, not drawn — regeneration recipe and the
  raw-pixel-coordinate trap are in `docs/SEPTASK.md` ("Icon Notes").

## Known traps (from prior sessions)

- **"Week" = trailing 7 days** (today + previous 6), never the calendar week.
  Use `sinceDate(daysBack: 6)`.
- **~~`WeekDashboardView.loadAll()` caps at ≤4 parallel HTTP calls~~ — RETIRED.**
  This rule blamed a shared `SeptenaClient`, which no longer exists (it went
  with the FastAPI migration). Each provider owns a private `URLSession` — there
  is no `URLSession.shared` in the app — and every provider store is a
  synchronous `@MainActor` method, so concurrent fetches can't interleave a
  write to the shared SwiftData context. New launch-time fetches do NOT need to
  be serialized on principle. Safety here is enforced by the compiler now:
  `SWIFT_STRICT_CONCURRENCY: targeted` (project.yml), which the tree builds
  clean under. If a launch-time crash ever does reappear, chase it as a real
  race with the checker turned up — don't reinstate a parallelism cap.
- **MCP gateway filters string date ranges client-side** — the CloudKit schema is
  auto-managed and Dashboard indexes are off-limits.
- **CloudKit Prod schema deploy is additive-only** and deploying schema does NOT
  move data (Prod private DB starts empty). See `docs/CloudKitSchema.md` (the
  authoritative 27-record field table) and the prod-cutover plan.
- **macOS keyboard & focus in a `NavigationSplitView`** (a concrete case of the
  "use standard SwiftUI, never get creative" rule under Conventions): unmodified
  keys (Return, arrows) and `.onKeyPress` / unmodified `.keyboardShortcut` are
  **focus-scoped** — they only fire in the column that holds key focus, and the
  **sidebar holds it by default**, so a detail-pane `.onKeyPress(.return)` never
  fires until the detail claims focus (the "Return triggers the sidebar" trap).
  Only **modifier** menu commands (`⌘X`) are global (why `⌘T`/`⌘K`/`⌘R` work).
  Worse, **Space** in a selected row activates the row's first button — the
  checkbox — so a bare Space *completes the task* (do not bind Space; keep the
  checkbox `.focusable(false)` so it can't be Space-activated). Standard fixes
  only: native `List(selection:)` for selection + arrow nav (never hand-rolled
  tap-gesture selection — it suppresses native keyboard nav and the List's
  click-to-focus); `@FocusState`+`.focused()` to claim detail focus; **modifier
  menu shortcuts** for every keyboard action on the selected row (rename = `⌘R`,
  complete = `⌘K`, move = `⌘M` / `⌘⇧M`); double-click / right-click for mouse.
  Do NOT bind unmodified Space/Return. The shared shortcut map is
  `TaskRowShortcuts` in `Septena/Shell/Tasks/TaskCommands.swift` — bare `⌘M`
  is intentionally reclaimed by the focused task list; bare `⌘.` remains the
  system Cancel equivalent and carries a `⇧` here.
  **Two sanctioned exceptions on the task surfaces** (both deliberate,
  documented, and NOT to be "fixed" back to the naive form):
  1. The deep task lists do NOT use native `List` — they use
     `SelectableScrollList` (`Septena/Shell/UI/SelectableScrollList.swift`), a
     `ScrollView`/`LazyVStack` that re-earns native selection + arrow-nav
     (reusing the canonical selection token, reclaiming focus on release, never
     binding Space) *because* it can host inline-editable content that a native
     `List` can't. Native-`List` surfaces (sidebar, Next) keep the pure-native
     path via `ListKeyboardNavigation`. So "never hand-rolled tap-gesture
     selection" holds for native `List`; `SelectableScrollList` is the vetted
     container when a surface needs both selection AND inline editing.
  2. On iPad, row-level shortcuts ARE published via **gated hidden zero-frame
     buttons** (`rowCommandShortcutsEnabled`), the one place the "no hidden
     shortcut buttons" rule is intentionally inverted — because publishing
     `.focusedSceneValue(\.taskActions)` from a split-view detail SIGKILLs iPad
     (so those publishers stay `#if os(macOS)`).
  Otherwise the ban stands: no `NSEvent` monitors, no ungated hidden buttons.
- **Never hang `.task` / `.onAppear` / `.onReceive` off a `Group`.** A modifier
  applied to a `Group` is applied to each of the group's **children
  individually** — so a `Group` whose branches all resolve to nothing has no
  child to attach to and the modifier simply never runs. This deadlocks any view
  whose loader lives there: Septask's Next feed rendered no rows cold (no
  suggestions yet, every trio block empty, the empty row gated behind
  `hasLoaded`), so `.task` never fired, so it never loaded, so it never rendered
  rows — permanently blank below the page header, with no "Nothing here yet"
  either, and `.onReceive`/`.onChange` equally dead so nothing could recover it.
  Hang lifecycle off a container that always exists (`VStack`, `List`); Septena's
  `NextView` was unaffected only because its `.task` sits on a `List`. Verified:
  identical content fires 0 times in a `Group`, 1 time in a `VStack`. Not
  greppable (the scanner can't see what a modifier attaches to) — this note is
  the guardrail.
- **`NSTableView` batch updates apply INCREMENTALLY — never feed them
  `inferringMoves()`.** Unlike `UITableView` (all indexes relative to the
  pre-batch state), each call inside `beginUpdates()`/`endUpdates()` is relative
  to what the preceding calls left behind. A `CollectionDifference` move's
  `associatedWith` offset is in the *original* array's coordinate space, so by
  the time `moveRow(at:to:)` runs, earlier removes/inserts have shifted it and
  it grabs whichever row slid into that slot. In Septask's AppKit Today list
  this moved the *group header* instead of the task — the task rendered under
  the wrong heading and read as a duplicate, with neighboring titles offset
  (surviving rows keep their cached cells and aren't re-fetched, so nothing
  self-corrects). Use a **plain** `difference(from:)` and apply
  remove+insert; that's exactly what the incremental batch is defined for, and
  a row changing groups should leave and arrive anyway. Enforced by the
  `appkit-inferring-moves` lint rule.
- **A `.plain` row Button is only tappable where it draws.** `.buttonStyle(.plain)`
  (and the plain-derived `PlainHoverRowButtonStyle` / `InertButtonStyle`) opts the
  row out of the list cell's tap target, so SwiftUI hit-tests the drawn label
  only: the `Spacer()` and every trailing gap are dead zones, and a tap near the
  right edge of the row silently misses. The row still *looks* full width, so it
  reads as "the app ignored my tap". Fix: `.contentShape(Rectangle())` on the
  label (`LogRow` carries one, which is why log rows in drawers are fine). Two
  cases need no shape — a label with its own opaque `.background(…)` fill (that
  shape is hit-testable), and a default-styled Button inside a `Form`/`List`
  (the cell supplies the target). Enforced by the `row-dead-zone` rule
  (`scripts/lint-row-tap-targets.py`, run from `scripts/lint-design.sh`).
- **No inline `TextField` swapped into a *selectable* native `List` row.**
  Replacing a row's `Text` with a focusable `TextField` (then removing it) on
  edit corrupts a native `List`'s focus/selection on macOS — after the edit ends,
  clicks stop selecting, ↑/↓ die, and the field's selected text lingers. Every
  focus workaround just moves the breakage (claim focus → dead clicks; don't →
  orphaned focus after edit). So on macOS, **task title editing happens in the
  composer** — expand-in-place inline (in `SelectableScrollList`, which tolerates
  the field) or the drawer inspector — never a raw `Text`→`TextField` swap in a
  row, and native-`List` surfaces (sidebar) rename via an alert/the composer.
  Inline-edit-in-row is fine on iOS (no split-view focus war) and fine for a
  *non-selectable* dedicated row (the quick-add line).

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
- `Septask/` — Septask's composition root only (app entry, welcome, settings
  shell, tab bar, assets, entitlements). Task behavior never lives here.
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

- **Use standard, default SwiftUI. Never get creative.** Reach for the
  first-party, idiomatic API every time — `List(selection:)` for selection and
  arrow-key nav, `@FocusState`/`.focused()` for focus, `.onSubmit` / a focused
  `TextField` for inline editing, `.commands` + a *modifier* `keyboardShortcut`
  for global keys, native `.contextMenu` / `.swipeActions`, `NavigationSplitView`
  for sidebar+detail. If something "needs" an `NSEvent` monitor, a hidden
  zero-frame shortcut button, a hand-rolled tap-gesture selection, an AppKit
  bridge, or any clever workaround to behave, **stop** — that's the signal the
  approach is wrong, not that it needs more cleverness. Prefer the platform's
  default behavior over a bespoke one even when the default is slightly less than
  what you imagined; a standard pattern that works beats a creative one that
  fights the framework (and that we then chase across sessions). When the
  idiomatic API genuinely can't do it, say so plainly and pick the closest
  standard behavior — don't invent.
- **One selection/target language per surface — NEVER two.** There is exactly
  ONE visual treatment for "this row/item is selected, focused, hovered, pressed,
  or a drop target" on any given surface, and it is the app's canonical token
  (`Theme.listSelectionFill` via `SelectableListRowBackground`, with native
  rings suppressed by `.septenaSuppressListCellSelection()`). When a new
  interaction needs to emphasize a row (a drag drop-target, a hover, a keyboard
  focus), it **reuses that token** — it does NOT invent a second style (a
  different color, an accent fill vs. a neutral fill, an outline vs. a fill, a
  bespoke overlay, or the raw platform selection ring left un-suppressed). Two
  competing highlight systems visible on one surface at the same time (e.g. a
  blue outline on the selected row and an accent fill on the drop-hover row) is a
  **bug**, full stop — it reads as chaos. If you catch yourself adding a
  highlight, first find what the surface already uses for emphasis and reuse it.
  The three sanctioned shapes live in
  `Septena/Shell/UI/SelectionLanguage.swift` (see `docs/DesignSpec.md` §4.5):
  full-bleed `SelectableListRowBackground` for a list row, inset
  `InsetSelectionBackground` for a palette / source-list row, and
  `SelectableChip` for a chip / segment / filter. **An inset highlight on an
  ordinary list row is the "selection floating on top of the row" bug** — inset
  is only for palettes.
- **The app accent is adaptive INK, not a hue — black in light, WHITE in dark.**
  So `.background(Color.accentColor).foregroundStyle(.white)` is white-on-white
  in dark mode and the control vanishes. This shipped twice (the training
  effort-rung picker and the task week-strip day picker). Selected chips use a
  **wash plus matching ink** (`SelectableChip` / `SelectableChipStyle`), which is
  contrast-safe for any tint in both appearances. Related trap: `Color.accentColor`
  only means "the section color" *inside* a `SectionDrawer` — a view pushed from a
  settings pane inherits the monochrome ink instead, so it must read
  `theme.color(for: "<key>")` explicitly.
- **Motion is gated centrally — never bare `withAnimation` / `.animation(_:value:)`.**
  Use `a11yAnimate(_:) { … }` (drop-in for `withAnimation`, no environment
  needed), `A11yMotion.run` (when `@Environment(\.a11yMotion)` is already in
  scope), or `.a11yAnimation(_:value:)`. `LogCommit.swift` and
  `CommitMotion.swift` are the two documented exceptions — they gate once at the
  overlay.
- **`scripts/lint-design.sh` enforces the above and runs from `scripts/build.sh`
  before the build lock.** A violation fails the build. Genuinely sanctioned
  exceptions get `// septena-lint:allow <rule-id>` **on the offending line**,
  with the reasoning in a comment above. Typography rules are advisory notes
  (a drift budget being paid down), not blockers. When you rediscover a
  convention the hard way, add a `scan` rule there as well as documenting it.
- **All *app* documentation lives in `docs/`.** Any new `.md` — plan, handoff,
  spec, design note, feature write-up — goes in `docs/`, never the repo root. Root
  is reserved for the canonical set only: `README.md`, `CLAUDE.md`, `SECURITY.md`,
  `LICENSE`, `NOTICE`, `project.yml`. Reference docs by their `docs/…` path.
- **This repo is PUBLIC — keep only app-relevant docs here. Strategy lives in the
  private site repo.** Competitive strategy, positioning, and the **book**
  (manifesto / go-to-market) do NOT belong in this repo. They live in the
  **private** `../septena-site` repo under `docs/` — the book thesis is
  `septena-site/docs/THE_INSTRUMENT_MANIFESTO.md`. When the work is
  strategy/positioning/book copy, edit it *there*, not here. App engineering docs
  (schema, design spec, plans, specs) stay public in this `docs/`;
  `docs/MAKER_IDENTITY.md` stays here too because it sources in-app maker copy.
- Match surrounding code: comment density, naming, idiom.
- **Maker voice & identity** (the "made by mz" story across app, site, support,
  journal) is specified in `docs/MAKER_IDENTITY.md` — pull facts and copy blocks
  from there, never invent maker claims. Every claim must trace to its data row;
  the banned list (no "late nights" etc.) is binding.
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
- **Both MCP servers are DUAL-ERA and must stay that way.** MCP revision
  `2026-07-28` made the protocol stateless (no `initialize`, no
  `Mcp-Session-Id`, no GET stream; version + client identity ride in
  `params._meta` and mirrored HTTP headers). Both servers implement it —
  `server/discover`, `resultType`, `ttlMs`/`cacheScope`, header validation
  (`-32020`), honest version negotiation (`-32022`) — **while still answering
  the legacy `initialize` handshake**, because Claude's connector and every
  existing `claude mcp add` registration still speak the old shape. Deleting
  the legacy path takes the live connector offline. The era rules and constants
  are mirrored in `SeptenaCore/MCP/MCPRevision.swift` ⇄
  `../septena-mcp-gateway/src/protocol.ts` — edit in lockstep like everything
  else MCP.
