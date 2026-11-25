# Settings UX & registry architecture (task app) — spec

**Status:** building (2026-11-21) — supersedes [SETTINGS_FLATTEN_SPEC.md](SETTINGS_FLATTEN_SPEC.md). Defaults in §8 stand unless mz overrules.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0014](adr/0014-today-rollover-review-or-clean-slate.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md), [ADR 0016](adr/0016-sign-in-beyond-apple.md), [ADR 0017](adr/0017-move-septena-life-out-of-repo.md).
**Builds on:** `registry/settings.json` (`#142`, shipped), `scripts/gen-registries.mjs`, `SeptenaCore/Generated/RegistryConstants.swift`, `backend/src/generated/registries.ts`, and [#178](https://github.com/michellzappa/septena/issues/178) (superseded by [#187](https://github.com/michellzappa/septena/issues/187)–[#190](https://github.com/michellzappa/septena/issues/190)).
**Scope:** **Septena (the task app)** across iOS, iPadOS, macOS, Web (`#21`), Android (`#20`), and Windows (`#136`). (Septena Life moved out of this repo in ADR 0017.)
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

**Changes after this spec (2026-11-22, mz):** `registry/settings.json` wins where the tables below disagree.
- Appearance is its own page (`appearance`); on desktop it stays inline in General.
- Import & Export is a depth-2 page under **Privacy & Data**. The tab and group formerly "Connections & Data" are **Connections**.
- Advanced holds only sync and storage diagnostics. MCP Skills moved to Connect Claude. Paste JSON, weekly product diagnostics (`diagnosticsEnabled`, now cleared at launch) and the AI diagnostics switches (`showModelLabels`, `pccRoutingEnabled`, `pccReasoning`, now `ui: false`) are gone.
- AI icons never use sparkles.
- Account > **Devices** (`devices_access`, depth 2) lists every signed-in app install (`GET /v1/access` `devices`), signs another device out, and holds the Apple Watch row (moved off the iOS root).
- AI & Agents > **Agents** (`agents`, depth 1, inline on the Mac tab) lists every connected agent (`GET /v1/access` `connections`), with the count (`agentsStatus` on the root row), rename and disconnect. Devices and agents are always separate lists, even though both pair with the same code flow (decided 2026-11-24).

---

## 1. Goal & first principles

Today's task-app Settings (`Septask/SeptaskSettingsView.swift`, `TaskSettingsSections.swift`, `AISettingsPane.swift`, and the initial taxonomy in `registry/settings.json`) inherited Septena Life's multi-domain root and grew incrementally. For a new user, it feels haphazard:

- **Folder-of-folders on iOS:** opening Settings shows 6 links and **zero controls**; every everyday tweak requires 1–3 taps.
- **Legacy wrappers & buried flagship actions:** `"Tasks"` is a subpage inside a task app; **Connect Claude** (Septena's core differentiating setup, and the only MCP path after local MCP removal in `7b101882`) lives inside a pane titled **"Task backend"** under `About ▸ Advanced`.
- **Heavy duplication:** `calendar_access` appears in both `Tasks` and `Connections & AI` (while `Show calendar events` sits separate from the calendar picker); `Reminders` and `Things` are duplicated across `Tasks` and `Connections & AI` while `Things` is missing from `Import & Export`; Sync is repeated in `Account` and `Task backend`.
- **Developer/beta noise in consumer surfaces:** `Show model labels`, PCC entitlement warnings, raw `MCP Skills`, `Paste JSON`, and a second overlapping telemetry control (`Share anonymous weekly diagnostics` + `Community Pulse`) sit beside everyday preferences.
- **Stale copy leaks:** Septena Life wording (*"coaches and exercises"*, *"day timeline and Next page"*, *"recolors Tasks in Septena Life"*) and pre-backend iCloud claims (*"Your tasks live only in your private iCloud"*) remain visible.
- **Registry gap:** `registry/settings.json` currently encodes the legacy 6-page tree, omits several existing surfaces/keys, and `scripts/gen-registries.mjs` emits only `syncedKeys` / `StorageKey` / `Defaults`—not the taxonomy, depth, or layout projection.

### Design rules (progressive disclosure, new-user-first)

1. **Depth follows frequency and user stage:**
   - **Depth 0 (top level):** Identity/sync state, Day-1 setup (**Connect Claude**, **Calendar**, **Reminders**, **Import & Export**), and everyday list preferences. On compact/mobile layouts (iOS, Android), everyday list controls render **inline** on the root screen rather than behind subpages. Appearance is the exception (decided 2026-11-22): the root shows one **Appearance** row that pushes the `appearance` page. On desktop the same page link is `desktopInline`, so the General tab still shows the Appearance section inline.
   - **Depth 1 (one tap):** Focused multi-step flows, pickers, and dedicated forms (**Account**, **Connect Claude**, **AI Preferences**, **Calendar**, **Reminders**, **Import & Export**, **Privacy**, **About**).
   - **Depth 2 (`About ▸ Advanced`):** Diagnostics, developer/beta aids, raw MCP reference, refused sync changes, store health, paste JSON, and opt-in weekly diagnostics. Invisible until sought.
2. **One canonical home per function (enforced by CI):** No `settingKey` or `customSurface` may appear more than once in the Settings UI tree.
3. **Live state on every navigation row:** Push rows display their current state (`Live`, `On this device`, `Connected` / `Not connected`, `Automatic`, `3 calendars`, `Off`) so users never tap just to check status.
4. **No `"Tasks"` wrapper and no `"Task backend"` concept:** Inside Septena, everything is tasks; the old `SeptaskBackendSettingsPane` dissolves into **Account** (sync), **AI & Agents ▸ Connect Claude** (pairing), and **About ▸ Advanced** (refused-sync diagnostics).
5. **Registry owns structure, clients own native chrome (ADR 0015):** `registry/settings.json` is the single source of truth for keys, defaults, scopes, groups, ordering, depth, platform gates, visibility predicates, and copy keys. Each client renders native controls (SwiftUI `Form`/`NavigationSplitView`, Web HTML/CSS, Compose) with zero hardcoded per-client IA drift.

---

## 2. Canonical inventory & disposition of every current function

Every setting and custom surface currently in `Septask/` and shared `Septena/Shell/` panes, mapped to its single canonical home in `registry/settings.json`:

### Depth 0 — Top-level (inline on mobile root; primary sidebar tabs on desktop)

| Canonical ID / Key | Kind | Scope | Mobile (iOS / Android) | Desktop Tab (macOS / Web / Win) | Platforms | Visibility | Notes / Change from today |
|---|---|---|---|---|---|---|---|
| `account_profile_card` | `customSurface` | ephemeral | Root top card → pushes `account` | `account` | all | `always` | Show live sync status subtitle (`Live`, `On this device`, `N to send`) on root card |
| `claude_pairing` | `customSurface` | ephemeral | Inline row in **AI & Agents** (live status) → pushes pairing pane | `ai_agents` (top section, inline — no extra push) | all | `always` | **Rescued from `About ▸ Advanced ▸ Task backend`.** Shows inline Sign-in CTA when signed out |
| `agentsPaused` | `setting` (`bool`) | `synced` | Inline toggle in **AI & Agents** | `ai_agents` | all | `signedIn` | Global server-enforced agent kill switch |
| `ai_preferences` (subpage: `aiMode`, `apple_intelligence_status`, `ai_explainer`) | `page` link (`statusKey: aiMode`) | mixed | Inline row in **AI & Agents** (`Automatic`) → pushes subpage | `ai_agents` (inline sections below Pause) | all (`apple_intelligence_status` Apple-only) | `always` | Fix Septena Life copy in `AISettingsPane` & iCloud copy in `AIExplainerView` |
| `calendar_detail` (owns `tasksShowCalendarEvents` + `calendarHiddenTitles`) | `customSurface` | mixed (`device` + `synced`) | Inline row in **Connections** (`Off` / `N calendars`) → pushes detail | `connections_data` (or linked detail on macOS) | all (EventKit on Apple; iCal `#128` cross-platform later) | `always` | **Unifies** master toggle `tasksShowCalendarEvents` at top of `CalendarDetail`; removes duplicate link; fixes *"Next page"* copy |
| `reminders_inbox` | `customSurface` | ephemeral (EventKit) | Inline row in **Connections** (`Off` / list name) → pushes detail | `connections_data` | `ios`, `ipados`, `macos` | `always` | Removes duplicate link from `Tasks` |
| `import_export` (owns `things_import` + JSON backup/restore + on-device counts) | `customSurface` | ephemeral | Row in **Privacy & Data** (depth 2, moved 2026-11-22) → pushes **Import & Export** | `privacy` | all (`things_import` Apple-only) | `always` | **Moves `Import from Things` here** under *"Move from another app"*; removes duplicates from `Tasks` and `Connections & AI`; moves `Paste JSON` to Depth 2 |
| `todayGroupByList` | `setting` (`bool`) | `device` | Inline toggle in **Lists** | `general` | all | `always` | Mirrors macOS `View` menu |
| `todayShowCompleted` | `setting` (`bool`) | `device` | Inline toggle in **Lists** | `general` | all | `always` | Mirrors macOS `View` menu |
| `tasksShowAging` | `setting` (`bool`) | `device` | Inline toggle in **Lists** | `general` | all | `always` | Update registry label/detail to match P2 (`c1ad4b76`): *"Fade untouched tasks"* |
| `tasksFilingSuggestions` | `setting` (`bool`) | `device` | Inline toggle in **Lists** | `general` | `ios`, `ipados`, `macos`, `android`, `windows` | `always` | On-device classifier toggle |
| `badgeShowOverdue` | `setting` (`bool`) | `device` (`sharedAppGroup`) | Inline toggle in **Lists** | `general` | `macos` | `always` | Dot on the Dock icon. Other platforms have no badge (#550) |
| `accent_color` | `customSurface` | device/local *(future synced)* | Inline swatch row in **Appearance** | `general` (Appearance section, from the `appearance` page) | all | `always` | Remove *"shared with Septena Life"* footer copy for task-app users |
| `textSizeStep` | `setting` (`int`, `-2…+2`) | `device` | Inline slider in **Appearance** | `general` (Appearance section, from the `appearance` page) | all | `always` | Mirrors macOS `View ▸ Text Size` |
| `tasksTitleLines` | `setting` (`int`, `1…3`) | `device` | Inline picker in **Appearance** | `general` (hidden on desktop) | `ios`, `ipados`, `android` | `always` | Mobile-only row wrap limit |
| `loggingAnimationsEnabled` | `setting` (`bool`) | `device` | Inline toggle in **Appearance** | `general` (Appearance section, from the `appearance` page) | all | `always` | Completion flourish toggle |

### Depth 1 — Dedicated 1-tap subpages (Account, Privacy, About)

| Page | Canonical Items | Notes / Change from today |
|---|---|---|
| **`account`** | `welcomeName` (`synced` string), `sync_account_status` (Sign in / live status / Sign out), `delete_account` (`signedIn` only) | Removes duplicate Sync from `Task backend`; moves `store_health` to Depth 2 (still surfaces inline banner only if failures > 0, or inside Advanced diagnostics). Future home for `#46` Sync subscription & ADR 0016 sign-in methods |
| **`privacy`** | Concise 1-section `privacy_summary` (accurate `api.septena.app` + Claude copy, no `"Task backend"` reference) | The usage-data picker was removed on 2026-11-25 (#436): the app sends no usage data. Moves `diagnosticsEnabled` / Community Pulse to Depth 2 *(default)* |
| **`about`** | `about_header` (icon, name, tagline, version/build), `open_help` (opens `helpURL`), `check_updates` (`macos`, `windows`), `send_feedback`, `reset_get_started`, `septena_life_link`, **Advanced →** (`advanced` subpage) | Trims multi-paragraph marketing prose; removes `"Task backend"` row in favor of unified `Advanced` |

### Depth 2 — `About ▸ Advanced` (diagnostics, power-user & beta tools)

| Canonical ID / Key | Kind | Scope | Platforms | Visibility | Notes |
|---|---|---|---|---|---|
| `mcp_skills` | `customSurface` | ephemeral | all | `always` | Demoted from consumer `Connections & AI` |
| `sync_diagnostics` (refused `sync.issues` + `store_health`) | `customSurface` | ephemeral | all | `always` (shows clean "No issues" or lists refused items + Clear + store rollbacks) | Replaces the diagnostic tail of deleted `SeptaskBackendSettingsPane` and declutters `Account` |
| `paste_json_import` | `customSurface` | ephemeral | all | `always` | Demoted from main `Import & Export` screen |
| `diagnosticsEnabled` (+ preview / Community Pulse) | `setting` (`bool`) + `customSurface` | `device` | all | `always` | Demoted from consumer `Privacy` to eliminate two-telemetry confusion *(default)* |
| `showModelLabels` | `setting` (`bool`) | `device` | `ios`, `ipados`, `macos` | `always` *(or `debugOnly`)* | Demoted from consumer `AI` ("temporary beta aid") |
| `pccRoutingEnabled` + `pccReasoning` | `setting` (`bool`, `enum`) | `device` | `ios`, `ipados`, `macos` | `minAppleOS: 27` | Demoted from consumer `AI` (entitlement-gated developer control) |

### Internal / Non-Settings Keys (stay in `registry/settings.json` `keys`, marked `"ui": false`)

These keys remain in `registry/settings.json` so `SYNCED_SETTING_KEYS` / `SETTING_VALUES` and `StorageKey` / `Defaults` stay 100% exhaustive without rendering in Settings:
- Synced internal: `rolledInDismissedOn`, `homeTimezone`, `getStartedDismissed`, `getStartedSteps`
- Device-local non-Settings UI state: `sidebarCounts` (lives in macOS/Web/Windows `View` menu, not Settings)

### Reserved Roadmap Slots (zero future IA churn)

| Upcoming Feature | Issue / ADR | Exact Registry Slot |
|---|---|---|
| Today rollover mode (`ask` / `cleanSlate`) | ADR 0014 (`#139`, `#54`) | `lists` group (inline on iOS / `general` tab on desktop), `scope: synced` |
| Day-start hour | `#140` | `lists` group, `scope: synced` |
| iOS swipe action customization | `#132` (`IOS_SWIPE_ACTIONS_SPEC.md`) | `lists` group, `platforms: ["ios", "ipados"]`, `depth: 1` subpage |
| Timed reminders / Notifications | `#97` (`TIMED_REMINDERS_SPEC.md`) | `lists` group (or promoted `notifications` section once ≥2 controls exist) |
| Sync subscription / Plus billing | `#46`, `#43` | `account` page (`subscription_status` surface) |
| Additional sign-in methods / device approval | ADR 0016 (`#168`–`#171`) | `account` page |
| Connected agents & named agent keys | `#71`, `#86` | `ai_agents` group |
| iCal subscription feed / CalDAV | `#128` | `calendar_detail` surface |
| Microsoft To Do / Todoist / TickTick / OmniFocus / Superlist importers | `#52`, `#99`, `#100`–`#102` | `import_export` surface (*Move from another app*) |
| Self-hosted server URL | ADR 0011 (`#119`) | `advanced` page (`depth: 2`) |

---

## 3. `registry/settings.json` schema & codegen evolution

Builds additively on the existing `registry/settings.json` (`version: 1` → `version: 2`, or additive fields on `v1` *(default: bump to `version: 2` so schema changes are explicit and atomic with `gen-registries.mjs`)*).

### 3.1 Additions to `keys`
- Optional `"ui": false` flag for internal/non-Settings keys (`rolledInDismissedOn`, `homeTimezone`, `getStartedDismissed`, `getStartedSteps`, `sidebarCounts`). Defaults to `true`.
- Add the three missing existing device-local keys:
  - `showModelLabels` (`storageKey: "septena.ai.showModelTags"`, `bool`, default `true`, Apple platforms)
  - `pccRoutingEnabled` (`storageKey: "septena.ai.pccRouting"`, `bool`, default `false`, Apple platforms)
  - `pccReasoning` (`storageKey: "septena.ai.pccReasoning"`, `enum: ["low", "balanced", "high"]`, default `"balanced"`, Apple platforms)
- Optional `"options"` metadata on `enum` / bounded `int` keys (`value`, `title`, optional `detail`) so every platform renders identical picker/radio labels (e.g. `aiMode`, `tasksTitleLines`, `telemetryLevel`).

### 3.2 New taxonomy structure (`desktopTabs` + `groups` + `pages`)

Replace the flat 6-page legacy `pages` array with an explicit two-surface projection over one canonical item graph:

```jsonc
{
  "version": 2,
  "keys": { /* all synced + device-local keys */ },
  "desktopTabs": [
    { "id": "account",          "title": "Account",            "icon": "settings.account",      "group": "identity", "featureId": "sync.backend" },
    { "id": "general",          "title": "General",            "icon": "settings.general",      "group": "main",     "paletteSlot": 0, "featureId": "lists.today" },
    { "id": "ai_agents",        "title": "AI & Agents",        "icon": "settings.ai_agents",    "group": "main",     "paletteSlot": 4, "featureId": "ai.reach-dial" },
    { "id": "connections_data", "title": "Connections", "icon": "settings.connections",  "group": "main",     "paletteSlot": 5, "featureId": "sync.backend" },
    { "id": "privacy",          "title": "Privacy",            "icon": "settings.privacy",      "group": "main",     "paletteSlot": 6, "featureId": "settings.display" },
    { "id": "about",            "title": "About",              "icon": "settings.about",        "group": "about",    "featureId": "settings.display" }
  ],
  "rootGroups": [
    {
      "id": "account_root",
      "mobilePresentation": "card",
      "desktopTab": "account",
      "depth": 0,
      "items": [
        { "kind": "pageLink", "page": "account", "surface": "account_profile_card", "statusKey": "syncStatus" }
      ]
    },
    {
      "id": "ai_agents_root",
      "header": "AI & Agents",
      "mobilePresentation": "inline",
      "desktopTab": "ai_agents",
      "depth": 0,
      "items": [
        { "kind": "pageLink", "page": "claude_pairing", "label": "Connect Claude", "icon": "settings.claude", "statusKey": "claudeStatus", "featureId": "agents.connector" },
        { "kind": "setting", "key": "agentsPaused", "label": "Pause all agents", "visibility": "signedIn" },
        { "kind": "pageLink", "page": "ai_preferences", "label": "AI Preferences", "icon": "settings.ai_agents", "statusKey": "aiMode", "featureId": "ai.reach-dial" }
      ]
    },
    {
      "id": "connections_data_root",
      "header": "Connections",
      "mobilePresentation": "inline",
      "desktopTab": "connections_data",
      "depth": 0,
      "items": [
        { "kind": "pageLink", "page": "calendar", "label": "Calendar", "icon": "settings.calendar", "statusKey": "calendarStatus", "featureId": "calendar.events" },
        { "kind": "pageLink", "page": "reminders", "label": "Reminders", "icon": "settings.reminders", "statusKey": "remindersStatus", "platforms": ["ios", "ipados", "macos"], "featureId": "import.reminders" },
        { "kind": "pageLink", "page": "import_export", "label": "Import & Export", "icon": "settings.data", "featureId": "sync.backend" }
      ]
    },
    {
      "id": "lists_root",
      "header": "Lists",
      "mobilePresentation": "inline",
      "desktopTab": "general",
      "depth": 0,
      "items": [
        { "kind": "setting", "key": "todayGroupByList", "label": "Group Today by list", "detail": "Off shows one flat list, with each task's list as a subtitle." },
        { "kind": "setting", "key": "todayShowCompleted", "label": "Show completed tasks" },
        { "kind": "setting", "key": "tasksShowAging", "label": "Fade untouched tasks", "detail": "Tasks untouched for 14 days fade out and move to Faded." },
        { "kind": "setting", "key": "tasksFilingSuggestions", "label": "Suggest where to file", "detail": "Learn where you usually file similar tasks." },
        { "kind": "setting", "key": "badgeShowOverdue", "label": "Overdue app icon badge", "platforms": ["macos"] }
      ]
    },
    {
      "id": "appearance_root",
      "header": "Appearance",
      "mobilePresentation": "inline",
      "desktopTab": "general",
      "depth": 0,
      "items": [
        { "kind": "customSurface", "surface": "accent_color", "label": "Accent" },
        { "kind": "setting", "key": "textSizeStep", "label": "Text Size" },
        { "kind": "setting", "key": "tasksTitleLines", "label": "Title lines", "platforms": ["ios", "ipados", "android"] },
        { "kind": "setting", "key": "loggingAnimationsEnabled", "label": "Completion animations", "icon": "settings.animations" }
      ]
    },
    {
      "id": "meta_root",
      "mobilePresentation": "inline",
      "desktopTab": null,
      "depth": 0,
      "items": [
        { "kind": "pageLink", "page": "privacy", "label": "Privacy", "icon": "settings.privacy", "featureId": "settings.display" },
        { "kind": "pageLink", "page": "about", "label": "About", "icon": "settings.about", "featureId": "settings.display" }
      ]
    }
  ],
  "pages": [
    /* Depth 1: account, claude_pairing, ai_preferences, calendar, reminders, import_export, privacy, about */
    /* Depth 2: advanced (linked only from about) */
  ]
}
```

*(On desktop `ai_agents` tab, `claude_pairing` and `ai_preferences` sections can render inline inside the single tab pane—declared cleanly via `"desktopInline": true` on those `pageLink` items—so macOS/Web/Windows users never face an unnecessary extra push inside a 820px split view.)*

### 3.3 Closed visibility predicates (ADR 0015 compliant — no DSL)
Allowed values for `visibility`: `"always"` *(default)*, `"signedIn"`, `"signedOut"`, `"whenNonEmpty"`, `"minAppleOS27"`, `"debugOnly"`.

### 3.4 Validator invariants (`scripts/gen-registries.mjs --check`)
1. **Uniqueness:** Every `setting` key (with `ui !== false`) and every `customSurface` ID appears **at most once** across the entire rendered tree (`rootGroups` + `pages`). Fails CI on any duplication.
2. **Completeness:** Every `keys` entry with `ui !== false` is referenced by at least one UI item (or explicitly owned by a declared `customSurface` via `"ownsKeys": [...]`, e.g. `calendar_detail` owns `tasksShowCalendarEvents` and `calendarHiddenTitles`).
3. **Flatten rules (carried over from `SETTINGS_FLATTEN_SPEC.md`):** No single-link root-only page; every `desktopTab` resolves to ≥1 visible group or page; no `"coming soon"` items; every `featureId` exists in `registry/capabilities.json` and every `icon` exists in `registry/icons.json`.
4. **Depth integrity:** Every `pageLink` target exists in `pages`; `depth: 2` pages are reachable only from `depth: 1` pages (never from `rootGroups`).
5. **Backend lockstep:** `backend/test/conformance.test.ts` asserts `Object.keys(SETTING_VALUES)` matches `SYNCED_SETTING_KEYS` 1:1.

### 3.5 Codegen outputs (`scripts/gen-registries.mjs`)
- **`SeptenaCore/Generated/RegistryConstants.swift`:** Keep `RegistrySettings.syncedKeys`, `StorageKey`, `Defaults`; add typed `RegistrySettingsTab`, `RegistrySettingsGroup`, `RegistrySettingsPage`, `RegistrySettingsSection`, `RegistrySettingsItem`, `RegistrySettingsOption`, and `RegistrySettingsDestinationID` (replacing hardcoded `SeptaskSettingsView.Destination` and `SeptaskSettingsLink`).
- **`backend/src/generated/registries.ts`:** Keep `SYNCED_SETTING_KEYS` and constraints; also export `SETTINGS_REGISTRY` metadata so the Web client (`#21`) can consume it directly.
- **Later Kotlin emitter (`#180`):** Emits identical Kotlin data classes for Android (`#20`) and Windows (`#136`).

---

## 4. Platform projection contract

| Surface | Layout Container | How it reads `registry/settings.json` |
|---|---|---|
| **iOS / iPadOS (compact sheet)** | `NavigationStack` + grouped `Form` | Renders `rootGroups` in order (`card` / `inline`); `pageLink` rows push `pages[id]` with live status subtitle; `about` pushes `advanced` (`depth: 2`) |
| **macOS (Settings window, ⌘,)** | `NavigationSplitView` (sidebar + `NavigationStack` detail) | Sidebar renders `desktopTabs` (6 items); detail renders groups/pages mapped to that `desktopTab` (expanding `desktopInline: true` pages directly into the detail `Form` so Connect Claude is immediately visible in `AI & Agents`) |
| **Web (`#21`) / Windows (`#136`) / iPad wide** | Split sidebar + detail panel | Same `desktopTabs` projection as macOS; automatically omits Apple-only items via `platforms` |
| **Android mobile (`#20`)** | Compose `LazyColumn` + navigation stack | Same `rootGroups` projection as iOS; automatically includes `tasksTitleLines` (`platforms` includes `"android"`) and omits EventKit/Apple Intelligence/Things SQLite. Each `customSurface` has a Compose renderer in `android/app/.../ui/` (`SettingsSurfaces.kt`, `PlanSettings.kt`, `SmartListsSettings.kt`, `CalendarFeedSettings.kt`, `AccessSettings.kt`). Android differences: Smart Lists reorder with arrow buttons (no drag), Calendar shows only the private iCal feed (`calendar.events` is planned on Android), Septena Plus shows the plan but sells nothing (Play billing is #176), and Import & Export is not built yet |

**Surface copy.** The words a custom surface spells out (status words, device names, the AI explainer, the iCal feed, the Smart Lists editor) live in `settings.json` `copy`, keyed by surface id (or `statusKey`) and copy id. Swift reads plain entries with `RegistrySettings.copy(surface, id)`; Kotlin reads all entries, templates included, with `settingsCopy(surface, id, languageTag, "name" to value)`.

---

## 5. Required surface & copy cleanups (exact targets)

1. **Dissolve `SeptaskBackendSettingsPane.swift`:**
   - Extract `ClaudePairingSection` / `ClaudePairingPane` (URL `https://api.septena.app/mcp`, Copy, Pairing code, Approve) with an inline `SeptaskSignInButton` prompt when `!TaskSyncEngine.shared.signedIn` (never a mysterious disabled button).
   - Move `sync.issues` ("Not synced") + `StoreHealthSettingsSection` into `SeptaskAdvancedPane` (`sync_diagnostics`).
   - Delete `SeptaskBackendSettingsPane.swift` and update `project.yml`.
2. **Unify Calendar settings (`ConnectedAppsDetails.swift`):**
   - Place `Toggle("Show calendar events", isOn: $showCalendarEvents)` at the top of `CalendarDetail` (`#if SEPTASK`), gated cleanly with permission state.
   - Fix copy on line 159: replace *"day timeline and Next page"* → *"Today and Upcoming"* under `#if SEPTASK`.
3. **Unify Import & Export (`SeptaskDataTransfer.swift`):**
   - Add a top *"Move from another app"* section linking to `ThingsImportView` (`#if os(iOS) || os(macOS)`).
   - Move *"Paste JSON…"* out of `Import & Export` into `SeptaskAdvancedPane` (`paste_json_import`).
4. **Fix stale copy leaks (guarded `#if SEPTASK` where shared with Septena Life):**
   - `Septena/Shell/Settings/AISettingsPane.swift` lines 270–276: remove *"Coaches, exercises, and the welcome line"* → task-app copy (*"Task conversations and filing help run privately on this device"*).
   - `Septena/Shell/Tasks/ConversationCard.swift` line 320 (`AIExplainerView`): remove *"Your tasks live only in your private iCloud"* → accurate `api.septena.app` / local-first copy.
   - `Septask/SeptaskSettingsView.swift` line 412 (`SeptaskPrivacyPane`): remove *"You pair Claude in About, under Advanced ▸ Task backend"* → *"You pair Claude under AI & Agents."*
   - `Septena/Shell/Tasks/TaskSettingsSections.swift` line 234: remove *"The accent is shared with Septena Life. Changing it here recolors Tasks there too."* → clean Septena task-app caption (or omit footer).
5. **Update Get Started deep links:**
   - `Septask/SeptaskKitTaskList.swift` (line 1254) and `Septena/Shell/Tasks/TaskListView.swift` (line 1712): `.connectAI` → `RegistrySettingsPageID.claudePairing` (macOS selects `ai_agents` tab); `.importTasks` → `RegistrySettingsPageID.importExport` (macOS selects `connections_data` tab).

---

## 6. Execution plan (issues S0–S3)

Sequenced so each issue is small, independently verifiable, and leaves `main` green. Builds directly on shipped `#142` and expands/replaces `#178`.

| Phase | Issue | Milestone | Scope | Depends on |
|---|---|---|---|---|
| **S0** | [#187](https://github.com/michellzappa/septena/issues/187) — upgrade `registry/settings.json` to new-user IA, uniqueness validator & typed codegen *(expands `#178` parts 1 & 3)* | `M2 Agent intake v0` | Update `registry/settings.json` to `version: 2` (`desktopTabs`, `rootGroups`, `pages`, `depth`, `mobilePresentation`, `visibility`, `options`, `ui: false`, plus missing keys `showModelLabels`, `pccRoutingEnabled`, `pccReasoning`); add needed semantic icon IDs in `registry/icons.json`; enforce uniqueness + depth + completeness checks in `scripts/gen-registries.mjs`; emit typed taxonomy structs to `SeptenaCore/Generated/RegistryConstants.swift` and `backend/src/generated/registries.ts`; add `SETTING_VALUES` ⇄ `SYNCED_SETTING_KEYS` test in `backend/test/conformance.test.ts`. | `#142` (done) |
| **S1** | [#188](https://github.com/michellzappa/septena/issues/188) — dissolve `Task backend`, unify Calendar & Import/Export, move dev/diagnostics to Advanced, fix stale copy | `M2 Agent intake v0` | Extract `ClaudePairingPane` (with inline sign-in prompt), unify `Show calendar events` into `CalendarDetail`, add *"Move from another app"* (`Things`) to `SeptaskImportExportPane`, create `SeptaskAdvancedPane` (`MCP Skills`, `Sync & Store diagnostics`, `Paste JSON`, `Weekly diagnostics`, `Show model labels`, PCC routing), delete `SeptaskBackendSettingsPane`, and fix all 5 stale copy strings (Septena Life / iCloud leaks). | `#187` (S0) |
| **S2** | [#189](https://github.com/michellzappa/septena/issues/189) — registry-driven iOS flat root & macOS 6-tab Settings renderer *(supersedes `#178` part 2; resolves task `cevyq9`)* | `M2 Agent intake v0` | Build registry-driven `SeptaskSettingsView` consuming `RegistrySettings` generated descriptors: flat inline root `Form` on iOS with live status badges on nav rows, 6-tab `NavigationSplitView` on macOS (with `desktopInline` expansion for `AI & Agents`), registry-ID deep links (`SeptaskSettingsLink`) for Get Started. | `#187` (S0), `#188` (S1) |
| **S3** | [#190](https://github.com/michellzappa/septena/issues/190) — cross-platform Settings renderers for Web (`#21`), Android (`#20`) & Windows (`#136`) | `M3 Factory ships code` | Consume `registry/settings.json` generated outputs in Web (TS, desktop-tab layout) and Android/Windows (Kotlin via `#180`, mobile-inline + desktop-tab layouts), auto-filtering Apple-only surfaces via `platforms` and `capabilities.json`. | `#187` (S0), `#21` / `#180` |

---

## 7. Verification

- **S0:** `node scripts/gen-registries.mjs --check`, `scripts/lint-design.sh`, `npm test` in `backend/`, and `scripts/build.sh SeptaskMac 'platform=macOS'` + `scripts/build.sh SeptenaMac 'platform=macOS'`.
- **S1 & S2:** `scripts/lint-design.sh`, `scripts/build.sh SeptaskMac 'platform=macOS'`, `scripts/build.sh SeptenaMac 'platform=macOS'` (plus iOS build when watchOS runtime matches), and manual device walkthrough by mz on iPhone, iPad, and Mac:
  - Fresh signed-out user opens Settings on iPhone → sees live status, Connect Claude, Calendar/Reminders/Import, and everyday List/Appearance toggles with zero folder-of-folders.
  - Tapping Connect Claude while signed out offers inline Sign in with Apple instead of a disabled button.
  - Get Started steps ("Connect AI", "Import tasks") land directly on Claude pairing and Import & Export.
  - Zero duplicate rows anywhere; `About ▸ Advanced` holds all dev/diagnostics tools cleanly.

---

## 8. Open questions

| Question | Default |
|---|---|
| Schema version for `registry/settings.json` | Bump `version: 1` → `2` atomically with `scripts/gen-registries.mjs` *(default)* |
| Sequencing relative to Launch / M2 vs M3 | Run S0 → S1 → S2 ahead of M3 (Launch/M2) so iOS/macOS Settings is reorganized once directly on the registry *(default)* |
| macOS sidebar tab count | 6 tabs (`Account`, `General`, `AI & Agents`, `Connections`, `Privacy & Data`, `About`) *(default)* |
| Privacy's second telemetry control (`Share anonymous weekly diagnostics` / Community Pulse) | Move to `About ▸ Advanced` so consumer Privacy has one usage-data dial (preserves code; easy to delete outright later) *(default)* |
| Existing issue `#178` | Repurpose/close `#178` in favor of S0–S2 (linking `docs/SETTINGS_UX_SPEC.md`) so Factory runs one unambiguous chain *(default)* |
