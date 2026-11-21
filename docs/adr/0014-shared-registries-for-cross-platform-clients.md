# 0014. Keep cross-platform task-app contracts in shared JSON registries

- Status: proposed
- Date: 2026-11-21
- Deciders: mz

## Context

Septena (the task app, ADR 0007) already runs two separate UI shells on Apple
platforms — SwiftUI for iPhone/iPad (`Septena/Shell/Tasks/`, `Shell/Sidebar/`)
and AppKit for macOS (`Septask/SeptaskKit*.swift`) — plus a TypeScript backend
and MCP gateway (`backend/`). The roadmap adds three more client surfaces across
two more languages: Web in TypeScript (`#21`, M3), Android in Kotlin (`#20`, M4),
and Windows in Compose for Desktop on the Android Kotlin code (`#136`, M5,
ADR 0013).

A codebase audit on 2026-11-21 found live drift *already* occurring between the
existing SwiftUI, AppKit, and TypeScript codebases:

- **Context menus and row commands:** SwiftUI's `TaskListRowContextMenu`
  (`Septena/Shell/Tasks/TaskListContextMenu.swift`) has `Edit Details…`, flat
  `Cancel Task` / `Delete`, and omits `Clear Schedule`; AppKit's
  `buildContextMenu()` (`Septask/SeptaskKitTaskList.swift`) has `Rename`,
  `Show/Hide Info`, a `Complete ▸` submenu, and `Clear Schedule`.
  `TaskRowCommands` (`TaskCommands.swift`, 11 commands) was hand-duplicated into
  `SeptaskKitRowCommands` (`SeptaskNavigationCommands.swift`) with a different
  grouping and two extra entries (`Repeat…`, `Create Next Copy`).
  `KeyboardShortcutsCatalogue` (`KeyboardShortcutsView.swift`) still advertises
  `⌘/` for "Show / hide sidebar" after the binding moved to `⌃⌘S`.
- **Sidebar context menus:** SwiftUI (`SidebarView.swift`) offers `Mark Done`,
  `Cancel Project`, and `Move Up/Down` on projects; AppKit
  (`SeptaskKitSidebar.swift`) omits `Mark Done` and `Cancel Project` and uses
  `"Rename Project…"` vs `"Rename"`.
- **Settings:** Synced keys are maintained in two files with a "keep in
  lockstep" comment: `SeptaskSyncedSettings.keys`
  (`SeptenaCore/TaskBackend/TaskSyncSettings.swift`) and `SETTING_VALUES`
  (`backend/src/store/columns.ts`). Device-local task keys sit inside
  `SettingsKeys.swift` alongside ~35 Septena Life keys, with defaults duplicated
  across `@AppStorage` call sites, and the flattened Settings tree
  (`docs/SETTINGS_FLATTEN_SPEC.md`) is hardcoded in SwiftUI views.
- **Smart lists / destinations:** List identity, icons, shortcuts, aliases
  (`someday` → `anytime`, `triage` → `inbox`), grouping/drop rules, and empty
  states are split across `TaskFilter`, `Route` / `TaskDestinations`,
  `KitSidebarDestination`, `SeptaskNavigationCommands`, `TaskReads`, and
  `backend/src/tools/taskShared.ts`. Live drift: `TaskDestinations.smartListRoutes`
  includes `Review`, while the macOS `Go` menu omits `Review` and `Faded`.
- **Sync wire schema and domain rules:** `TaskBackendMapping.swift` copies field
  lengths (`2_000`, `100_000`, `4_000`, `25 MB`) and regexes by hand from
  `backend/src/store/columns.ts`. Pure rules — `isOnToday`, `inTriageBand`,
  `inInbox`, `daysOnToday`, `nextScheduledDate`, FNV-1a `occurrenceID`,
  `deriveConvo`, `TaskListOrder.byList`, `TaskFade.rowOpacity` — are mirrored in
  Swift and TypeScript by hand (`backend/src/tools/taskShared.ts`,
  `backend/src/recurrence.ts`).
- **Icons, tokens, and parity:** SF Symbol strings (`"sun.max.fill"`,
  `"rectangle.stack.fill"`, etc.) are hardcoded throughout Swift; selection wash
  alphas, fade opacity, the 5-step text scale, and the 16-color palette are
  mirrored between `Theme.swift` and `SeptaskKitTheme.swift`; ADR 0013 already
  calls for a shared capability parity ledger keyed by Feature ID.

Swift-only registries (such as `TaskRowCommands`, `TaskDestinations`, or
`TaskNotices`) cannot be consumed by the backend, Web, Android, or Windows.

## Decision

*(defaults chosen for mz; mz can overrule)*

The task app's cross-platform contracts live as **versioned, schema-validated
JSON registries** under a top-level `registry/` directory in this repository,
paired with **language-neutral golden conformance fixtures**
(`registry/conformance/*.json`) and a thin build-time generator
(`scripts/gen-registries.mjs`) that emits checked-in typed constants for Swift
(`SeptenaCore/Generated/`), TypeScript (`backend/src/generated/`, later `web/`),
and later Kotlin (`android/` + Windows). *(default)*

Scope is **Septena (the task app) only**. Septena Life (`SectionManifest`,
health/nutrition/habit catalogs) stays in `SeptenaCore` until the repo split
(`#84`). *(default)*

### The eight registries

| File | Owns | Replaces / unifies |
|---|---|---|
| `registry/entities.json` | Synced entity columns, required/updatable fields, regexes, size limits, canonical enum values | `backend/src/store/columns.ts` + `TaskBackendMapping.swift` + `TaskBackendWire.swift` |
| `registry/rules.json` + `registry/conformance/*.json` | Numeric domain thresholds (`cueDecayDays`, `fadeWindowDays`, `fadeMinOpacity`, `recentlyDeletedDays`, `toastDurationSec`, `maxBatchOps`, lease/budget limits) + golden input→output test vectors | Lockstep comments across `SeptenaCore`, `backend/src/tools/taskShared.ts`, `backend/src/recurrence.ts` |
| `registry/settings.json` | Synced and device-local task setting keys, types, bounds, defaults, scope, plus task-app Settings page/section taxonomy and native custom-surface hooks | `SeptaskSyncedSettings` + `SETTING_VALUES` + task keys in `SettingsKeys.swift` + `SeptaskSettingsView` / `TaskSettingsPane` |
| `registry/actions.json` | Canonical actions, platform-neutral shortcuts (`primary`/`alt`/`shift`/`ctrl` + OS-collision exclusions), closed typed availability predicates, and compositions for context menus (`task.row`, `task.recentlyDeleted`, `sidebar.area`, `sidebar.project`, `project.heading`, `notice.getStartedStep`), menu bar, swipe slots (`#132`), and shortcuts sheet | `TaskCommands.swift`, `TaskListContextMenu.swift`, `SeptaskNavigationCommands.swift`, `SeptaskKitTaskList.swift`, `SeptaskKitSidebar.swift`, `SidebarView.swift`, `KeyboardShortcutsView.swift` |
| `registry/destinations.json` | Smart lists (`today`, `review`, `upcoming`, `repeating`, `anytime`, `logbook`, `faded`, `recentlyDeleted`) and container kinds (`area`, `project`), aliases, sidebar order, visibility, shortcuts, count/grouping/drop rules, empty states | `TaskFilter`, `Route`, `TaskDestinations`, `KitSidebarDestination`, `Go` menu, `TaskReads`, `taskShared.ts` aliases |
| `registry/surfaces.json` | Notices (`signIn`, `rolledIn`, `getStarted` + steps, `fadeIntro` — priority, max 1 explainer, dismissal scope), destructive/fork prompts (Cancel-default safety contract), toast templates, and composer/inspector task attributes + commit contracts (`pickCommits` / `closeCommits`) | `TaskNotices.swift`, `KitPrompt.swift`, `SeptenaToastCopy`, `TaskAttributeBar` / `KitComposerCell` |
| `registry/icons.json` + `registry/tokens.json` | Semantic icon ID → SF Symbol / Material / Lucide map; semantic color roles (preserving OS-native surfaces and system accent), selection wash alphas, fade curve, 5-step text scale, 16-color palette, spacing/radii, column geometry | Hardcoded SF Symbols; mirrored constants in `Theme.swift`, `SeptaskKitTheme.swift`, `SelectionLanguage.swift`, `TextSizeScale.swift`, `SettingsMirror` |
| `registry/capabilities.json` | Canonical parity ledger keyed by Feature ID (`/product/feature-map-septena-task-app`) with per-platform status (`ios`, `ipados`, `macos`, `web`, `android`, `windows`, `watchos`) and evidence; every registry entry's `featureId` validates against it so unshipped capabilities never render dead or "coming soon" UI | ADR 0013 parity ledger seed + `septena-site/content/platform-parity.json` |

### What is NOT a registry

Registries hold **declarations, schemas, ordering, typed availability
predicates, and constants** — never a cross-platform UI framework:

- **Native layout, navigation containers, and platform chrome** stay native per
  platform (SwiftUI, AppKit, HTML/CSS, Compose — no JSON-driven layout tree).
- **Platform-exclusive integrations and their setup UI** (EventKit
  Calendar/Reminders, Things SQLite import, Sparkle, Apple Foundation Models,
  Share Extension, Windows DPAPI) stay native; they register only an entry point
  in `settings.json` or `actions.json` gated by `platforms`.
- **Executable logic or scripting DSLs** are forbidden in JSON. Availability
  predicates stay a small closed set of typed fields (`selection`,
  `requiresRecurrence`, `excludeDestinations`, `platforms`, `featureId`).
  Complex pure logic lives in each language and is verified by
  `registry/conformance/*.json`.

## Phases

Land in M3 before the Web (`#21`), Android (`#20`), and Windows (`#136`) clients
begin; does not block Launch.

| Phase | Issue | Scope |
|---|---|---|
| R0 Foundation & wire schema | `#141` | `registry/` layout, JSON Schemas, validator in `lint-design.sh` + CI, Swift/TS codegen, `entities.json`, `rules.json`, and `conformance/*.json` run by `backend/test/` and `SeptenaCoreTests` |
| R1 Settings | `#142` | `settings.json` unifying `SETTING_VALUES`, `SeptaskSyncedSettings`, device-local task keys/defaults, and flattened Settings taxonomy |
| R2 Actions & menus | `#143` | `actions.json` unifying context menus, menu bar, swipe slots, and platform-neutral shortcuts; fixes the four live SwiftUI ⇄ AppKit drifts |
| R3 Destinations & surfaces | `#144` | `destinations.json` and `surfaces.json` unifying smart lists, aliases, notices, destructive prompts, toasts, and task composer attributes |
| R4 Tokens, icons & parity | `#145` | `icons.json`, `tokens.json`, and `capabilities.json` (feeding ADR 0013's parity ledger and `septena-site/content/platform-parity.json`) |

## Consequences

- **One edit per capability.** Adding M2/M3 task features (checklists `#76`,
  tags `#96`, timed reminders `#97`, star `#127`, swipe actions `#132`) updates
  the registry once and propagates columns, settings, actions, icons, and
  conformance vectors across Swift, TypeScript, and Kotlin.
- **Zero cold-launch cost.** Because `scripts/gen-registries.mjs` emits
  checked-in native constants (rather than parsing JSON at launch), cold launch
  stays fast (`#80`–`#82`).
- **Two-step edit discipline.** Changing a registry entry requires running
  `scripts/gen-registries.mjs` and committing the generated files; CI fails on
  drift, just as `xcodegen generate` already works for `project.yml`.
- **Localization stays platform-native.** Registries hold stable localization
  keys (and default English strings), while Apple `.xcstrings`, Web JSON, and
  Android `strings.xml` own translations.
- **Drift stops before client count doubles.** Reconciling SwiftUI vs AppKit
  now gives Web, Android, and Windows a single truthful contract instead of two
  conflicting reference apps.

## Open questions

| Question | Default |
|---|---|
| Format & home | Top-level `registry/*.json` with JSON Schemas in this repo *(default)* |
| Consumption | Checked-in codegen (`scripts/gen-registries.mjs`) for Swift, TS, and later Kotlin; CI drift check *(default)* |
| Scope | Septena (task app) only; Septena Life stays in `SeptenaCore` until `#84` *(default)* |
| Order | Land R0–R4 in M3 before starting `#21` Web client; does not block Launch *(default)* |
| Parity ledger home | `registry/capabilities.json` as canonical source, synced to `septena-site/content/platform-parity.json` *(default)* |

## Links

- Issues: `#141` (R0), `#142` (R1), `#143` (R2), `#144` (R3), `#145` (R4)
- Clients: `#21` Web client · `#20` Android client · `#136` Windows client
- Related ADRs: ADR 0002 (own backend), ADR 0007 (Septena is the task app),
  ADR 0008 (agent loop in store), ADR 0013 (native Windows on Android Kotlin)
- Related specs: `docs/SETTINGS_FLATTEN_SPEC.md`, `docs/SEPTASK_APPKIT_SURFACES.md`,
  `docs/DesignSpec.md`, Starlings `/product/feature-map-septena-task-app`
