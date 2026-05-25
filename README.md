# Septena

A personal life-OS for iOS, macOS, and watchOS. One app for tasks, projects, goals, training, nutrition, sleep, mood, supplements, habits, chores, gut, caffeine, cannabis, air quality, and activity — built on CloudKit, with Apple Watch and a menu-bar companion on Mac.

> **Status (2026-05-25):** Mid-migration from a FastAPI backend to CloudKit. Tasks, Areas, Projects, Settings, and Section visibility are CloudKit-native today; the remaining sections still read/write through the legacy API while their CloudKit records are wired up. See [MIGRATION_HANDOFF.md](MIGRATION_HANDOFF.md) for the live status.

## Stack

- **SwiftUI** — single codebase across iOS / macOS / watchOS
- **SwiftData** — local persistence and offline cache
- **CloudKit** (`CKSyncEngine`) — primary backend, private database
- **HealthKit, EventKit (Reminders + Calendar), Core Bluetooth** — system integrations
- **XcodeGen** — `project.yml` is the source of truth for the Xcode project
- **Swift 5.10**, deployment target **iOS / macOS / watchOS 26.0**

## Quick start

```bash
git clone <repo> septena-cloud
cd septena-cloud
brew install xcodegen   # if you don't have it
xcodegen generate
open Septena.xcodeproj
```

Schemes:

| Scheme | Target | Platform |
|---|---|---|
| `Septena` | iOS app (embeds Watch) | iOS 26+ |
| `SeptenaMac` | macOS app | macOS 26+ |
| `SeptenaWatch` | watchOS app | watchOS 26+ |

CloudKit container is `iCloud.com.septena.cloud`. You need to be signed into iCloud on the simulator/device; first launch creates the private zone and runs the initial sync.

There is **no `.env`** — third-party provider keys (Oura, Withings) are entered inside the app under Settings.

## Repository layout

```
.
├── Septena/                       # iOS + macOS app (shared sources)
│   ├── App/                       # Entry point, root shell, navigation, menu bar
│   ├── Shell/                     # Dashboard, sidebar, tasks, settings, shared UI
│   └── Sections/                  # One folder per life-domain section
├── SeptenaCore/                   # Shared models, persistence, CloudKit, mutators
│   └── CloudKit/                  # CKSyncEngine, per-record mappers, backends, migration
├── SeptenaWatch/                  # watchOS companion app
├── SeptenaWatchComplication/      # WidgetKit complications for the watch face
├── docs/                          # Reference notes (some stale — read with care)
├── project.yml                    # XcodeGen project definition (source of truth)
└── *_HANDOFF.md, MIGRATION_*.md   # Live notes on in-flight migrations
```

## App shell

Entry point is `Septena/App/App.swift`. On launch it stands up the `SeptenaServices` singleton (mutators + `CKEngine`), the app-wide `DayClock` (single ticker that drives midnight rollover for every view), `NavigationState`, and the theme. On foreground it triggers a CloudKit fetch and a Reminders auto-import.

The UI is structured as:

- **iOS** — four-tab `RootTabView`: **Week**, **Next**, **Tasks**, **Goals**.
- **macOS** — sidebar + detail, plus a menu-bar quick-add popover (`MenuBarMenu.swift`).
- **watchOS** — single `NextWatchView` screen driven by `WatchConnectivity`, plus complications.

`NavigationState` is the single source of truth for navigation paths, sheets, sidebar visibility, and the quick-add / quick-find modals.

## Dashboards (`Septena/Shell/Dashboard/`)

| View | What it does |
|---|---|
| `WeekDashboardView` | Synthesizing 7-day hub. One tile per enabled section with theme color, collapse, quick-actions. |
| `DayTimelineView` | Today's chronological view — tasks and every logged entry (food, training, mood…) interleaved. |
| `NextDashboardView` | "What's next" checklist for the next 24h. Mirrors to Watch. |
| `TodayLogView` | Inline quick-log surface (mood, caffeine, etc.). |
| `HeatmapHomepageView` / `DenseHomepageView` | Alternative compact layouts. |

## Sections (`Septena/Sections/`)

Each section is self-contained and can be toggled on/off in Settings → Sections (backed by `SectionEntity.isEnabled`, synced via CloudKit).

| Section | What it covers |
|---|---|
| **Activity** | HealthKit: steps, exercise minutes, VO2max, HRV, resting HR. |
| **Air** | Aranet4 CO2 sensor over Bluetooth + Open-Meteo pollen. |
| **Body** | Biometric snapshots (weight, measurements). |
| **Caffeine** | Coffee / matcha / tea logging, half-life countdown. |
| **Calendar** | Read-only view of upcoming events from device calendars. |
| **Cannabis** | Strain, form, dose, timestamp. |
| **Chores** | Recurring chore definitions + completion log. |
| **Groceries** | Categorised shopping list. |
| **Gut** | Digestive events. |
| **Habits** | Daily habit grid, streaks, history. |
| **Insights** | Aggregated cross-section analytics. |
| **Mood** | Mood + energy entries, mood catalog grid. |
| **Nutrition** | Meals, macros (carb/protein/fat targets), fasting windows. |
| **Sleep** | Oura nights with HealthKit fallback. |
| **Supplements** | Supplement library + per-day logging. |
| **Training** | Exercise library, routines, strength + cardio sessions, PRs. |

## Data layer

The split between local cache and cloud:

- **`SeptenaCore/Models.swift`** — value-type DTOs used throughout the UI (`SeptenaTask`, `Project`, `Area`, `MoodEntry`, `NutritionEntry`, `CaffeineEntry`, `OuraNight`, `AirReading`, …).
- **`SeptenaCore/Persistence.swift`** — SwiftData `@Model` entities (`TaskEntity`, `AreaEntity`, `ProjectEntity`, `SectionEntity`, etc.) with sync watermarks (`lastSyncedAt`, `pendingSync`, `deletedAt`).
- **`SeptenaCore/Outbox.swift`** — per-domain *Mutators* (TaskMutator, MoodMutator, …) that apply optimistic local writes and queue CloudKit sync.
- **`SeptenaCore/CloudKit/CKEngine.swift`** — owns `CKSyncEngine`, the private database, and the single zone; per-record mappers live alongside (`TaskRecord.swift`, `AreaRecord.swift`, `ProjectRecord.swift`, `SettingsRecord.swift`, `SectionRecord.swift`).

### Backend status by domain

| CloudKit-native | Hybrid (CloudKit mutations, legacy reads) | Still FastAPI |
|---|---|---|
| Tasks, Areas, Projects, Settings, Sections | Habits, Supplements, Chores | Goals, Groceries, Nutrition, Caffeine, Cannabis, Gut, Training |

Sync happens via silent push (`remote-notification` background mode) plus an explicit `fetchChanges()` on foreground, because APNs delivery isn't guaranteed.

## Integrations

| File | Source |
|---|---|
| `HealthKitBridge.swift` | Apple Health — steps, exercise, VO2, HRV, resting HR. |
| `OuraProvider.swift` | Oura Ring — sleep, HRV, recovery (API key in Settings). |
| `WithingsProvider.swift` | Withings — weight, body composition. |
| `AranetBridge.swift` + `AirStore.swift` | Aranet4 CO2 sensor over Core Bluetooth. |
| `PollenClient.swift` | Open-Meteo + Core Location. |
| `RemindersBridge.swift` | EventKit — auto-imports Reminders lists into Inbox on foreground. |
| `CalendarBridge.swift` | EventKit — read-only event view. |
| `AddTaskIntent.swift` | App Intents — "Add to Septena" from Siri and Shortcuts. |

A hosted MCP gateway at **mcp.septena.app** exposes the user's data to AI agents over the Model Context Protocol — the App-Store-friendly distribution surface for AI access (no CLI client).

## Watch

- **`SeptenaWatch/`** — minimal watchOS app. Single screen, `NextWatchView`, fed by `WatchConnectivity` from the iOS app. State is shared via `SharedComplicationData`.
- **`SeptenaWatchComplication/`** — WidgetKit complications: next-item, task count, mood, caffeine, activity tiles for the watch face. Refreshed via WidgetKit timelines from the shared App Group.

## Capabilities & entitlements

iOS target (see `project.yml`):

- HealthKit (read activity + recovery)
- CloudKit (`iCloud.com.septena.cloud`, private DB)
- Background mode: `remote-notification`
- App Group (Watch ↔ iOS shared container)
- Reminders (full access) and Calendars (full access)
- Embeds `SeptenaWatch`

macOS target adds the menu-bar status item; watchOS target embeds `SeptenaWatchComplication`.

## Conventions worth knowing

- **Read `DayClock.today`, not `Date()`** in views — it's the single ticker that handles midnight rollover. Direct `Date()` calls in dashboard code are a bug.
- **All mutations go through a Mutator** — never write to SwiftData directly from a view. Mutators handle optimistic write + CloudKit queue + outbox.
- **`SeptenaServices` is process-wide** so App Intents (Siri, Shortcuts, widget actions) can mutate during background launch.
- **Sections are togglable.** A section being present in `Septena/Sections/` doesn't mean it's visible — check `SettingsView` → Sections, which writes through `SectionEntity.isEnabled`.
- **Section themes** live in `SectionTheme`; tiles, accents, and detail screens pull color from there.
- **No Xcode project edits.** Change `project.yml`, run `xcodegen generate`.

## Live docs

- [MIGRATION_HANDOFF.md](MIGRATION_HANDOFF.md) — current state of the FastAPI → CloudKit migration. Read this first if you're touching the data layer.
- [TRAINING_MIGRATION_HANDOFF.md](TRAINING_MIGRATION_HANDOFF.md), [NUTRITION_MIGRATION_HANDOFF.md](NUTRITION_MIGRATION_HANDOFF.md) — section-specific migration notes.
- [CHANGELOG.md](CHANGELOG.md) — release notes.
- [TODO.md](TODO.md) — running list of in-flight work.
- `SPEC.md` and `docs/reference/` exist but predate the CloudKit move — treat as historical.

## License

Private — Michell Zappa.
