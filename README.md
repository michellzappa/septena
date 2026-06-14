# Septena

Septena is a private life operating system for Apple platforms. It brings tasks, goals, training, nutrition, hydration, sleep, mood, symptoms, medications, supplements, habits, chores, groceries, gut, intake trackers, activity, body metrics, and GitHub commit history into one CloudKit-backed app.

The product principle is simple: every life domain is a section, every section can be enabled or hidden without deleting data, and every write should land in the local SwiftData mirror first, then sync through CloudKit.

> Status (2026-05-30): Septena is CloudKit-first. The general FastAPI client path has been removed from this repo; remaining FastAPI references are migration history, export DTO compatibility, or comments that still need cleanup. `docs/TRAINING_MIGRATION_HANDOFF.md` and `docs/NUTRITION_MIGRATION_HANDOFF.md` are historical migration notes — verify them against code before treating them as live truth.

## Stack

- **SwiftUI** - shared app code for iOS and macOS, plus a watchOS companion
- **SwiftData** - local mirror, offline cache, and first-write surface
- **CloudKit** (`CKSyncEngine`) - private iCloud database, custom zone `septena-v1`
- **HealthKit, EventKit, WatchConnectivity, WidgetKit** - Apple platform integrations
- **App Intents** - Siri, Shortcuts, Spotlight, and section logging intents
- **XcodeGen** - `project.yml` is the source of truth for the Xcode project
- **Swift 5.10**, deployment target **iOS / macOS / watchOS 26.0**

## Quick Start

```bash
git clone https://github.com/septena/septena.git
cd septena
brew install xcodegen   # if needed
xcodegen generate
open Septena.xcodeproj
```

Schemes:

| Scheme | Target | Platform |
| --- | --- | --- |
| `Septena` | iOS app, embeds Watch app | iOS 26+ |
| `SeptenaMac` | macOS app | macOS 26+ |
| `SeptenaWatch` | watchOS app | watchOS 26+ |

CloudKit container: `iCloud.com.septena.cloud`.

You need to be signed into iCloud on the simulator or device. First launch creates the private zone, starts `CKSyncEngine`, seeds missing section rows from `SectionManifest`, fetches remote changes, refreshes settings/theme mirrors, and runs local backfills.

There is no `.env` for the app. User-facing provider credentials (e.g. the Oura token) live in Settings or the local keychain/user defaults. The one build-time credential is the optional Withings dev-app pair: copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` (gitignored) and fill it in if you want the Withings/Body integration. Without it the app builds and runs fine — Withings just shows as "not configured."

### Building under your own Apple account

The repo carries Septena's own identifiers. To build a signed copy on your own
account, swap these for yours:

- **Team ID** — `DEVELOPMENT_TEAM` in `project.yml`. To keep it out of source
  entirely, move it to `Config/Secrets.xcconfig` (gitignored) with an empty
  default in `Config/Base.xcconfig` — the same xcconfig pattern used for the
  Withings secret — then attach `configFiles: Config/Base.xcconfig` to every
  target so each one inherits it.
- **Bundle IDs** — find/replace `com.septena.cloud` in `project.yml` and the
  `*.entitlements` files with your own reverse-DNS prefix.
- **CloudKit container** — `iCloud.com.septena.cloud` in the `*.entitlements`
  files; use your own.
- **App Group** — `group.com.septena.cloud` in the `*.entitlements` files.

The `*.entitlements` files are hand-maintained (XcodeGen references them via
`CODE_SIGN_ENTITLEMENTS` but does not generate them), so the container / group /
bundle strings live there and must be edited by hand. Re-run `xcodegen generate`
after changing `project.yml`.

## Repository Layout

```text
.
|-- Septena/                       # iOS + macOS app sources
|   |-- App/                       # App entry, root tabs, intents, shortcuts, watch bridge
|   |-- Shell/                     # Dashboards, settings, sections, tasks, shared UI
|   `-- Sections/                  # Section destination views and sheets
|-- SeptenaCore/                   # Models, SwiftData, CloudKit, providers, mutators
|   |-- CloudKit/                  # CKSyncEngine plus task/area/project/settings records
|   `-- Sections/                  # SectionManifest and MCP skill model
|-- SeptenaWatch/                  # Watch companion app
|-- SeptenaWatchComplication/      # WidgetKit complications
|-- docs/                          # DesignSpec (design system) + backlog
|-- project.yml                    # XcodeGen project definition
`-- *_HANDOFF.md                   # Migration notes; verify against current code
```

## App Shell

Entry point: `Septena/App/App.swift`.

On launch the app creates the process-wide `SeptenaServices` singleton, binds mutators to `CKEngine`, injects shared environment state, and starts the sync stack. The shared runtime objects are:

- `SeptenaServices` - owns `CKEngine` plus all mutators so App Intents can write while the app is background-launched.
- `DayClock` - the app-wide date/minute ticker. Views should read this instead of calling `Date()` directly.
- `NavigationState` - paths, sheets, quick add/find, pending shortcuts, and section presentation.
- `SectionTheme` / `SettingsStore` - local mirrors of CloudKit-backed section and settings state.
- `TrainingDraftStore` - active training-session draft state.

The primary iOS shell is `RootTabView`:

| Tab | Purpose |
| --- | --- |
| **Week** | Synthesizing dashboard across enabled sections. |
| **Next** | Next 24h checklist and suggestions, mirrored to Watch. |
| **Tasks** | Full task manager with inbox, today, upcoming, projects, and areas. |
| **Goals** | Free-text and metric-backed goals tagged to sections. |

macOS uses the same app sources with a sidebar/detail shell, keyboard commands, Preferences routing to the Settings sheet, and a menu-bar quick-add entry point. watchOS has a focused `NextWatchView` plus complications fed through shared data.

## Sections

Sections are the unit of product architecture. `SectionManifest` declares catalog identity; `SectionPlugin` declares behavior.

Current sections:

| Section | What it covers |
| --- | --- |
| **Tasks** | Inbox, Today, Upcoming, Anytime, areas, projects, recurrence. |
| **Goals** | Intentions tagged to sections, with optional measurable metrics. |
| **Training** | Exercise library, session types, strength/cardio entries, routines, PRs. |
| **Nutrition** | Meals, macros, water on meals, fasting preferences, daily summaries. |
| **Hydration** | Water-only UX over nutrition entries. No separate data model. |
| **Sleep** | Oura nights and sleep summaries. |
| **Habits** | Daily routines, buckets, skips, notes, streak/history inputs. |
| **Chores** | Recurring household tasks, completions, deferrals. |
| **Supplements** | Supplement definitions and daily state. |
| **Groceries** | Shopping items and categories. |
| **Intake** | User-defined consumable trackers with methods, catalogs, and event logs. |
| **Gut** | Digestive events and Bristol-style logging. |
| **Mood** | Mood/energy check-ins and history. |
| **Symptoms** | Symptom definitions, severity logs, duration, location, triggers, and relief notes. |
| **Medications** | Medication definitions, daily/as-needed schedules, dose logs, skips, effects, and side effects. |
| **Body** | Weight/body-composition rows, Withings integration. |
| **Activity** | HealthKit movement/recovery metrics. |
| **GitHub** | Read-only commit-activity heatmap via a per-device personal access token. |

Important section rules:

- `SectionManifest.all` is the catalog. Add new section identity there first.
- `SectionRegistry.all` is the app-side plugin registry. Register section behavior there.
- `SectionEntity` is the user/account mirror: title override, color, enabled state, Today visibility, onboarding state.
- Disabling a section hides surfaces; it must not delete user data.
- MCP skill briefs, onboarding, import/export schema, quick-log actions, goal metrics, and destination views belong with the section plugin when that section owns them.

## Data Layer

The app is local-first:

- `SeptenaCore/Models.swift` - value DTOs used by views and compatibility loaders.
- `SeptenaCore/Persistence.swift` - SwiftData entities and most section CloudKit schemas.
- `SeptenaCore/CloudKit/CKEngine.swift` - `CKSyncEngine` owner, private database, custom zone, change queue, fetch/apply hooks.
- `SeptenaCore/SeptenaServices.swift` - process-wide binding between `CKEngine`, SwiftData, and mutators.
- `SeptenaCore/Outbox.swift` - task mutator and legacy schema compatibility surface.
- `SeptenaCore/ChecklistMirror.swift` - local reconstruction helpers for habit/supplement/chore/next-style data.

Current CloudKit record coverage includes tasks, areas, projects, settings, sections, goals, habits, supplements, chores, gut, mood, symptoms, medications, intake, Oura, Withings, groceries, training, activity, and nutrition. Hydration writes through nutrition records. (GitHub is read-only and token-based, with no CloudKit records.)

Mutators are the write boundary. Views and intents should not write SwiftData entities directly when a mutator exists, because the mutator performs the optimistic local update, queues the CloudKit change, saves context, and posts the right app notifications.

## Integrations

| File | Integration |
| --- | --- |
| `HealthKitBridge.swift` | Apple Health reads and selected writes. |
| `OuraProvider.swift` | Oura sleep/recovery import direct from Oura API. |
| `WithingsProvider.swift` | Withings OAuth and measurement import. |
| `RemindersBridge.swift` | EventKit Reminders import into tasks. |
| `CalendarBridge.swift` | EventKit calendar events for dashboards/Next. |
| `WatchBridge.swift` | iOS to watch checklist sync and watch mutations. |
| `AddTaskIntent.swift`, `App/Intents/` | App Intents for tasks and section logging. |
| `Plausible.swift` | Optional anonymous aggregate analytics. |

The hosted MCP gateway is `https://mcp.septena.app/mcp`. The app mirrors the section skill briefs in Settings so the LLM-facing tool catalog and the in-app section definitions can stay aligned.

## Settings And Import/Export

`SettingsView` is the app control plane:

- General customization: homepage layout, Today timeline, welcome header, alternate app icons, Home Screen Quick Actions.
- Integrations: Reminders, Calendar, Apple Health, Oura, Withings.
- Import & Export: JSON envelope export/import for participating section plugins, plus schema prompts for model-assisted conversion.
- Skills: MCP preamble and per-section briefs.
- Manage Sections: enable/disable sections, onboarding, identity, section-specific detail panes.
- Privacy/About: analytics consent and product links.

Import/export is plugin-driven through `SectionExportContribution`. Unsupported sections are intentionally skipped rather than represented with partial data.

## Watch

- `SeptenaWatch/` - watchOS app, centered on `NextWatchView`.
- `SeptenaWatchComplication/` - WidgetKit complication bundle.
- `WatchBridge` routes watch actions back through the same CloudKit-backed mutation stack as the phone app.

## Capabilities

From `project.yml` and entitlements:

- CloudKit private database: `iCloud.com.septena.cloud`
- Background remote notifications for CloudKit change pushes
- App Group for iOS/watch shared data
- HealthKit read/write categories as implemented by `HealthKitBridge`
- Reminders and Calendars full-access usage descriptions
- Alternate iOS app icons
- watchOS app and WidgetKit complication embedding
- macOS menu-bar extra

## Conventions Worth Knowing

- Use `project.yml` for project changes, then run `xcodegen generate`. Do not hand-edit generated project structure unless you intend to preserve a generated diff.
- Read `DayClock.today` / `DayClock.now` in views that care about day rollover.
- Route writes through mutators (`TaskMutator`, `ChecklistMutator`, `GoalMutator`, `NutritionMutator`, etc.).
- Section identity belongs in `SectionManifest`; section behavior belongs in `SectionPlugin`.
- Section colors and enabled state are user/account data, not hardcoded catalog facts.
- `SectionTheme` is the color access point for UI surfaces.
- App Intents must call `await SeptenaServices.shared.start()` before mutating.
- CloudKit push is not enough; foreground fetch remains the reliable refresh path.
- Historical docs can be wrong. Prefer code, then `docs/DesignSpec.md`, then handoff docs.

## Useful Docs

- `docs/DesignSpec.md` - the canonical design system (typography, color, iconography, row anatomy, spacing, motion); code should conform.
- `docs/BACKLOG.md` - tracked, non-urgent work.
- `docs/IDENTIFIERS.md` - the stable id/title model and wire contracts across the app, CloudKit, and the MCP gateway.
- `docs/TRAINING_MIGRATION_HANDOFF.md` / `docs/NUTRITION_MIGRATION_HANDOFF.md` - historical section-migration notes; verify against code before acting.

## License

MIT - see [`LICENSE`](LICENSE). Copyright (c) 2026 Michell Zappa.

The MIT grant covers the **code**, not the **brand** — see [`NOTICE`](NOTICE).
"Septena," the wordmark, and the app icon are reserved trademarks: fork and
build all you like, but ship derivatives under your own name and icon. One
bundled asset is also excluded — the Claude name/logo (an Anthropic trademark,
bundled only to identify the Claude integration).
