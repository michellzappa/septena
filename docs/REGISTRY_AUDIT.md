# Registry audit: hard-coded structure and copy (2026-11-21)

- Status: audit, no code moved
- Scope: Septena the task app (`Septask/`, `Septena/Shell/`, `SeptenaCore/`)
- Rests on: ADR 0015 (`docs/adr/0015-shared-registries-for-cross-platform-clients.md`),
  `registry/README.md`, `scripts/gen-registries.mjs`
- Base commit: `dd7813f7`

## Summary

The registries R0 to R4 exist and generate `SeptenaCore/Generated/RegistryConstants.swift`.
Two surfaces render fully from them: Settings (`Septask/SeptaskSettingsView.swift`)
and the first run (`Septask/SeptaskFirstRun.swift`). Most other surfaces still
hold their own copy and structure in Swift.

Five findings matter more than the per-file list:

1. **Registry copy is not localized.** The generator emits plain English
   `String` literals. `Text(someString)` renders a `String` verbatim, so
   Settings and the first run show English to every user. The app catalog
   (`Septena/Localizable.xcstrings`) has 1,178 keys and 669 pt-BR
   translations. The Swift copy that the registry is meant to replace *is*
   localized (`String(localized:)`). So a move to the registry today removes
   translations. **Localization (#214) must land before #177 and #179.**
2. **`RegistrySurfaces` has zero consumers.** Prompts, toasts, notices,
   `taskAttributeOrder` and `maxConcurrentExplainers` are generated and unused.
   `RegistryCapabilities` also has zero consumers, so no surface gates on
   `featureId` as ADR 0015 says it must.
3. **Some registry copy is older than the shipped copy.** The registry says a
   deleted area's projects "stay, detached from the area". The app
   (`ContainerDeleteCopy`, `SeptenaCore/TaskUndo.swift:640`) says the tasks move
   to Recently Deleted and the delete can be undone, with task and project
   counts. A blind move to the registry would ship the wrong copy.
4. **The registry is missing items the app ships.** No `inbox` destination; no
   `weeklySweep` notice; no Toggle Star, Reminder…, task Rename, View menu or
   Window menu actions; no `menuBar` composition (the registry README says one
   exists; `actions.json` has only `actions`, `contextMenus`, `swipeActions`,
   `shortcutsSheet`).
5. **The two shells still drift on copy.** Examples: Mac sidebar "Delete
   Area…" vs registry "Delete Area"; Mac section delete prompt has no message,
   iOS has "Its tasks stay in the project."; empty states differ between iOS,
   Mac and the registry (table below).

## What already reads the registry

| Generated enum | Consumers (non-generated Swift) |
|---|---|
| `RegistrySettings` | Settings renderer, `TaskSyncSettings`, `SettingsMirror`, `AppearancePreferences`, AI policy files, `AppIconCatalog` |
| `RegistryFirstRun` | `SeptaskFirstRun.swift`, `SeptaskClaudePairingPane.swift` |
| `RegistryDestinations` | `NavigationState.swift` (icons), `KeyboardShortcutsView.swift` |
| `RegistryActions` | `KeyboardShortcutsView.swift` only (general + task-list sheet) |
| `RegistryIcons` | 6 files (settings, first run, data transfer, one context-menu item) |
| `RegistryTokens` | Theme, text scale, selection language, appearance picker |
| `RegistryRules` / `RegistryEntity*` | `TaskFade.swift`, `TaskBackendMapping.swift` |
| `RegistrySurfaces` | **none** |
| `RegistryCapabilities` | **none** |

## Hard-coded areas

"Touches" lists the files and the risk. It is not a time estimate.

### A. Notices: `Septena/Shell/Tasks/TaskNotices.swift` → `surfaces.json` `notices`

| Item | In Swift | In registry | Gap |
|---|---|---|---|
| `signIn` | title, button, detail with three device variants (Mac, iPad, iPhone) | title, button | registry has no detail and no per-platform variant |
| `rolledIn` | "1 task rolled into Today" / "N tasks rolled into Today" | no title | registry needs a plural title |
| `getStarted` | title + 3 steps; Mac-only detail "Or press ⌃⌥Space anywhere on your Mac" | title + 3 steps | registry has no platform variant for the `addTask` detail |
| `fadeIntro` | title + detail | title + detail | same copy, duplicated |
| `weeklySweep` | plural title, "Review" button | **missing** | add the notice |
| Symbols | literal SF Symbols (`"arrow.down.circle"`, `"circle.dashed"`) | `icon` IDs | Swift ignores `RegistryIcons` |

Touches: `TaskNotices.swift` (both shells read it), `surfaces.json`, generator
(notice struct with plural and platform variants). Risk: low once #214 exists.
Covered by #179 item 2; the gaps above are not.

### B. Prompts: SwiftUI dialogs and `SeptaskKitPrompt` call sites → `surfaces.json` `prompts`

| Prompt | iOS | Mac | Registry | Gap |
|---|---|---|---|---|
| Delete area / project | `ContainerDeleteCopy` (dynamic, counts, "You can undo this.") | same | static, older wording | registry needs templates with `{name}`, `{tasks}`, `{projects}` and the four count cases |
| Delete section | one-line title with message folded in (`TaskListView.swift:764`) | title only (`SeptaskKitTaskList.swift:4138`) | title + message | shells disagree |
| Delete permanently | `Label` in a menu (`TaskListView.swift:3501`) | "Delete this task permanently?" / plural (`SeptaskKitTaskList.swift:2903`) | "Delete Permanently?" | three wordings |
| Delete account, reschedule repeat | literals at call sites | literals | present | duplicated |
| New / Rename Section, New Area, Rename Project / Area, Error | `.alert("…")` literals in `TaskListView`, `SidebarView`, `AreasProjectsView`, `SeptaskRootView` | AppKit sheets | **missing** | add `textPrompts` (title, placeholder, confirm) |

Touches: 6 files across both shells, `surfaces.json`, generator. Risk: medium,
because the delete copy is dynamic and plural. Covered by #179 item 3, except
the templates and text prompts.

### C. Toasts: `SeptenaToastCopy` (`Septena/Shell/UI/Accessibility.swift:368`) → `surfaces.json` `toasts`

- `SeptenaToastCopy` returns **plain, unlocalized** strings. The iOS toast is
  English for every user today, independent of the registry.
- `TaskListView.swift:3047` builds "Moved N tasks to X" inline. The registry has
  no bulk-move template.
- `RegistrySurfaces.toastDurationSeconds` is unused.

Touches: `Accessibility.swift`, `TaskListView.swift`, `SeptaskKitToast.swift`,
`SeptaskKitTaskList.swift`. Risk: low. Covered by #179 item 3 except the bulk
template.

### D. Smart lists and empty states → `destinations.json`

- Titles live in `TaskFilter.label` (`SeptenaCore/Models.swift:866`), the Go
  menu (`SeptaskNavigationCommands.swift:218`), sidebar rows
  (`SidebarView.swift:775`), and `AddTaskPage.swift:60`.
- `inbox` is not a destination in the registry (it is in `capabilities.json`
  as `lists.inbox`).
- The Go menu has Today, Review, Upcoming, Repeating, Anytime, Logbook. It
  omits Starred, Faded and Recently Deleted.

| List | Registry empty title / detail | iOS (`TaskListView.swift:1982`) | Mac (`SeptaskKitTaskList.swift:379`) |
|---|---|---|---|
| Review | "Nothing to review" / "Tasks an agent proposes as done…" | "Nothing to review" / "Tasks Claude finishes appear here…" | "Nothing to review" |
| Recently Deleted | "Recently Deleted is empty" / "…stay here for 30 days…" | "No Recently Deleted Tasks" / "…appear here for 30 days…" | not checked |
| Faded | "No Faded Tasks" / same | same | not checked |
| Generic | per list | "Nothing here yet" + "Type above…" / "Click + or double-click…" / "Tap +…" | own |

Touches: `Models.swift`, `NavigationState.swift`, `SidebarView.swift`,
`SeptaskKitSidebar.swift`, `SeptaskNavigationCommands.swift`,
`TaskListView.swift`, `SeptaskKitTaskList.swift`, `AddTaskPage.swift`. Risk:
medium; #202 (merge Recently Deleted into Logbook) changes the same rows, so
sequence after or with it. Covered by #179 item 1, except `inbox`, the empty
states and the generic empty copy.

### E. Menus and commands → `actions.json`

- `TaskRowCommands` (`TaskCommands.swift:97`) and `SeptaskKitRowCommands`
  (`SeptaskNavigationCommands.swift:46`) hold their own titles. Neither reads
  `RegistryActions.titles`.
- Context menus: `TaskListContextMenu.swift`, `SidebarView.swift` (~34
  literals), `SeptaskKitSidebar.swift` (~22), `SeptaskKitTaskList.swift`
  (~110, of which most are menus).
- Actions the app ships that the registry lacks: `task.toggleStar` (ST1),
  `task.reminder` (TR2), `task.rename` (Mac), `app.showSidebarCounts`,
  `app.toggleInspector`, text size (increase, decrease, reset, picker),
  `app.classicWindow`, `app.septenaWindow`, the Go menu as a composition, and
  `project.move` / `project.moveToArea` (Mac sidebar).
- Wording drift: Mac "Delete Area…" / "Delete Project…" vs registry without
  ellipsis; iOS "Rename Project" alert vs registry "Rename".

Touches: 6 files, `actions.json` (new actions + `menuBar` composition),
generator. Risk: medium; menu-bar commands carry platform-reserved shortcut
traps (AGENTS.md: iOS aborts on a UIKit-owned shortcut). #177 covers the
renderer; the missing actions and the `menuBar` composition are a precondition.

### F. Settings and About → `settings.json`

- The About pane (`SeptaskSettingsView.swift:730`) renders literals: "Septena",
  "Tasks that think with you", "Version …", "Check for Updates…", "Show Get
  Started Again", "Send feedback", the Septena Life blurb and button,
  "Advanced", "About".
- In `settings.json` these are `customSurface` items. `reset_get_started`,
  `send_feedback`, `check_updates`, `about_header` and `septena_life_link`
  have **no `label`**; `reset_first_run` has one. The "Advanced" link from
  About has no registry item.
- 22 `customSurface` items in total. Most own native UI and must stay native
  (Things import, calendar detail, Claude connector). Their entry-point label,
  icon and footer copy can still come from the registry.
- `TaskSettingsPane` (`Septena/Shell/Tasks/TaskSettingsSections.swift`, ~40
  literals) has no caller. It is dead code compiled into both apps.

Touches: `SeptaskSettingsView.swift`, `settings.json`, generator (the
`customSurface` item already has `label`). Risk: low.

### G. Composer, inspector and date pickers → `surfaces.json` `taskAttributes` (+ new `datePickers`)

- `RegistrySurfaces.taskAttributeOrder` is unused. Pill labels are literals in
  `SeptaskKitComposer.swift` ("When", "Deadline", "Repeat", "Discuss") and
  `TaskAttributeBar.swift` (~20).
- `SeptaskKitDatePopover.swift` holds ~71 literals: quick picks, repeat editor
  ("Every", "After it's checked off", ordinals, weekdays), reminder and
  time-zone options. The iOS pickers (`TaskPickerSheets.swift`, ~19) hold their
  own.
- `SeptaskKitInspector.swift` (~25): "Change When", "Add Reminder…", "Star",
  "Remove Star", "No list", "In {area}".

Touches: 5 files, a new `datePickers` block in `surfaces.json`. Risk: medium;
weekday and ordinal names must come from the platform locale (`Calendar`,
`DateFormatter`), not the registry. Only the structure (which presets, in
which order) and the labels the OS does not provide belong in the registry.

### H. Stays native (not a registry move)

Recorded so nobody tries to move them:

- Things import (`ThingsImportView.swift`, ~44), Reminders, EventKit calendar
  detail, Sparkle, Apple Intelligence status, Share Extension: platform-only
  integrations. ADR 0015 keeps their UI native; only the Settings entry point
  is registry data.
- App Intents and widget titles use `LocalizedStringResource` and Apple's
  metadata extraction. They stay in Swift.
- Accessibility labels in `TaskA11y.swift` (~18): many compose dynamic state.
  Move only the fixed ones, and only after #214.
- Conversation UI (`ConversationCard.swift`, `SeptaskKitConversation.swift`)
  and sign-in (`SeptaskSignIn.swift`): candidates later, after the agent-loop
  UI settles (M2).

## Proposal: localizing registry strings (#214)

### Rule

Registry JSON stays English-only and holds the source string. Translations
live in the platform catalogs, as ADR 0015 already states. The generator is
the bridge: it emits code that looks a string up, not a constant.

### Apple (Swift)

`SeptenaCore` compiles as source into each app target, so `Bundle.main` and
`Septena/Localizable.xcstrings` cover it. The generator emits:

- For each user-facing string field: `String(localized: "<English>", comment: "<registry path>")`.
  Example for the Get started title: key `Get started with Septena`, comment
  `registry surfaces.notices.getStarted.title`.
- **Key = the English text**, not a dotted ID. This is the convention the
  catalog already uses, so the 669 existing pt-BR translations (for example
  "Delete Permanently", "Nothing on Today", "Welcome to Septena") match with no
  re-translation. A dotted ID would orphan them.
- An optional `l10nKey` field on any registry string overrides the key when
  the same English word needs two translations (for example "Today" the list
  vs "Today" the date). The generator then emits
  `String(localized: "<l10nKey>", defaultValue: "<English>", comment: …)`.
- Templates (`{date}`, `{count}`, `{name}`) become generated functions with
  Swift interpolation, for example `static func deferred(date: String) -> String`,
  which produces the catalog key `Deferred to %@`. Plural strings use one
  `%lld` key with catalog plural variations; the registry declares
  `"plural": "count"` with `one` / `other` forms, and the generator seeds the
  English plural entry in the catalog.
- Xcode extracts the literals from the generated file on build, so the catalog
  gains the keys with no extra step. Strings stay `String` values (static lets,
  evaluated once per launch; iOS relaunches the app when its language changes).
- `gen-registries.mjs --check` adds an advisory report: registry keys with no
  pt-BR translation. It does not fail the build.

### Web and backend (TypeScript)

- The generator writes `registry/l10n/en.json`: `{ key: { text, comment } }`
  for every user-facing registry string, keyed the same way as Apple.
- `scripts/export-registry-strings.mjs` copies each translated language out
  of `Localizable.xcstrings` into `registry/l10n/<lang>.json`. The Apple
  catalog stays the single translation master while only Apple apps ship.
- Generated TS exposes `t(key, vars)` over the JSON. Templates use ICU
  `MessageFormat` syntax for plurals, which `Intl.PluralRules` supports.

### Android and Windows (Kotlin)

- The Kotlin emitter (#180) writes `res/values/registry_strings.xml` and
  `res/values-<lang>/registry_strings.xml` from the same `registry/l10n/*.json`.
- Resource names are derived from the registry path
  (`surfaces_notices_getstarted_title`), because Android names cannot hold
  free text. A generated map links the registry key to the resource ID.
- Plural strings become `<plurals>`. Compose for Desktop (Windows) reads the
  same resources through Compose Multiplatform resources.

### Order

#214 must land before #177 and #179. Each move then keeps its translations,
and the registry-rendered Settings and first run get their pt-BR copy back.

## Issues

| Issue | Title | Milestone | Why that milestone |
|---|---|---|---|
| #214 | Localize registry strings through the generator | Launch | Settings and the first run already render registry copy in English to pt-BR users |
| #215 | Reconcile registry copy with the shipped Swift copy | M3 | Precondition of #179; the moves are M3 |
| #216 | Add the missing actions and a `menuBar` composition to `actions.json` | M3 | Precondition of #177 |
| #217 | Drive the About pane and `customSurface` labels from `settings.json`; remove dead `TaskSettingsPane` | M3 | Same M3 registry track as #178 |
| #218 | Composer, inspector and date-picker structure and labels from `surfaces.json` | M3 | Web (#21) needs the composer contract before it starts |
| #219 | Gate surfaces on `RegistryCapabilities` and lint registry-owned literals | M3 | Stops new drift while the moves land |

Existing issues extended by comment: #177 (menus) and #179 (destinations,
notices, prompts, toasts) now depend on #214, #215 and #216.
