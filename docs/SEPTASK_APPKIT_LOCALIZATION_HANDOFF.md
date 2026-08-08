# Septask AppKit shell — localization handoff

**For a new agent.** Date: 2026-08-08. Scope: wrap every user-facing string in
`Septask/SeptaskKit*.swift` (macOS AppKit shell) so it goes through the existing
String Catalog. This is the **[P1]** gap in `docs/SEPTASK_APPKIT_PARITY.md` §6 —
it gets worse the longer it waits (more literals to sweep).

---

## Goal

Launching SeptaskMac with `-AppleLanguages (pt-BR)` (or any catalog locale)
shows chrome in that language, same as the SwiftUI classic window. User data
(task / project / area titles, notes) stays verbatim.

**Out of scope:** translating new copy into fr/de/es (those locales are still
empty catalog slots). Reuse existing English keys + pt-BR where they already
exist; new keys need an English source entry (and pt-BR if you can match
nearby SwiftUI wording — otherwise leave pt-BR empty for the cron/translator).

---

## Context (read these first)

1. `docs/SEPTASK.md` → **"AppKit shell on macOS"** — working rules for the kit.
2. `docs/SEPTASK_APPKIT_PARITY.md` §6 Localization — the backlog entry.
3. `docs/LOCALIZATION_PLAN.md` → **"Convention (the structure)"** — one catalog,
   `String(localized:comment:)`, data English / UX translated / user values
   verbatim. Do **not** invent a second catalog or `.strings` files.

Infra is already wired: `Septena/Localizable.xcstrings` is in both `Septask`
and `SeptaskMac` source lists in `project.yml`. No project.yml / xcodegen
change needed for this pass.

---

## Convention to follow

```swift
// Co-locate at the call site. Prefer matching an EXISTING catalog key
// (same English source string the SwiftUI surface already uses).
String(localized: "Show \(count) logged items",
       comment: "Project/area footer — expand completed tasks")
```

AppKit-friendly notes:

- `String(localized:)` works fine for `NSMenuItem.title`, `NSTextField.stringValue`,
  `NSAlert` copy, undo action names, placeholders — use it everywhere, not
  `NSLocalizedString`.
- Plurals that already exist as catalog format strings: prefer the catalog form
  (`"Show %lld logged items"`) when building from AppKit. SwiftUI’s
  `TaskListView.scopeLoggedToggleLabel` is the reference — match its keys
  exactly so you don’t fork translations.
- **Never** wrap user-entered / structure titles (`task.title`, `area.title`,
  `project.title`) — only the chrome around them
  (e.g. `"Delete \(project.title)?"` → localize the template, interpolate the
  verbatim title).
- Undo names (`recordUndo(name:)`) are user-visible (Edit menu) — localize them.
- SF Symbol names, pasteboard types, UserDefaults keys, row `key`s, cell
  identifiers — **not** user-facing; leave alone.

---

## Files to sweep (all `#if os(macOS)`, SeptaskMac only)

| File | What has literals |
|---|---|
| `SeptaskKitTaskList.swift` | Empty state, screen titles, Agenda/Inbox headers, context menus, logged footer, heading CRUD prompts, undo names, Move modal title |
| `SeptaskKitSidebar.swift` | Smart-list titles, New/Rename/Delete Area & Project alerts + confirm copy |
| `SeptaskKitComposer.swift` | Pill labels (When / Deadline / Repeat / …) |
| `SeptaskKitInspector.swift` | Field labels, empty selection, “No list” |
| `SeptaskKitDatePopover.swift` | Today / Tomorrow / Next Week / Clear / No Deadline |
| `SeptaskKitRowViews.swift` | Recurrence menu (Never / Daily / Weekly / …), “No List” |
| `SeptaskKitQuickFind.swift` | Search placeholder |
| `SeptaskKitQuickEntry.swift` | Placeholder + shortcut legend |
| `SeptaskKitPrompt.swift` | Default Cancel / Delete button titles if hardcoded |
| `SeptaskKitMoveModal.swift` | Panel chrome |
| `SeptaskKitWindow.swift` / `SeptaskKitSettings.swift` / `SeptaskKitNext.swift` | Likely little/none — still grep |

Rough size: ~90 unique user-facing candidates across the kit (many are
one-liners that already exist in the catalog under the same English key).

---

## Method (do this, in order)

1. **Inventory, don’t guess.** Grep `Septask/SeptaskKit*.swift` for UI constructors
   (`NSMenuItem(title:`, `KitPrompt.`, `labelWithString:`, `recordUndo(name:`,
   screen-title string literals, footer copy). Skip comments / identifiers.
2. **Reuse before create.** For each literal, search `Septena/Localizable.xcstrings`
   (and the SwiftUI twin in `Septena/Shell/Tasks/` / `Shell/Sidebar/`) for the
   same English source. If it exists, use that exact key string so pt-BR comes
   free. Examples already in the catalog:
   - `"Today"`, `"Upcoming"`, `"Anytime"`, `"Logbook"`, `"Inbox"`
   - `"Show %lld logged items"` / `"Hide %lld logged items"`
3. **Wrap call sites** with `String(localized:comment:)`. Keep comments short and
   feature-scoped (`"SeptaskKit: context menu"`, `"Project heading delete confirm"`).
4. **New keys only when needed.** Add the English source to
   `Septena/Localizable.xcstrings` (Xcode’s catalog editor, or careful JSON edit).
   Do **not** hand-edit `project.pbxproj`. After catalog changes,
   `xcodegen generate` is fine but usually unnecessary for `.xcstrings` content.
5. **Build once:** `scripts/build.sh SeptaskMac 'platform=macOS'`.
6. **Mark done** in `docs/SEPTASK_APPKIT_PARITY.md` §6 — flip Localization to
   **[DONE]** and drop it from the suggested-order list.

**Do NOT** launch the app, boot a simulator, or download runtimes — compile is
the only green gate (see root `CLAUDE.md`). Ask the user to smoke-test with
`-AppleLanguages (pt-BR)`.

---

## Gotchas

- **SwiftUI auto-`Text("…")` does not apply here.** AppKit never auto-extracts;
  every literal must be an explicit `String(localized:)`.
- **Menus rebuild.** Several menus build titles in `menuNeedsUpdate` /
  `refreshPlacementMenuItems` (“Move to Today” ↔ “Remove from Today”). Localize
  at assignment time, every open — don’t cache an English title at init.
- **Interpolation:** `"Delete \(area.title)?"` must become a localized format
  with the area title as a verbatim argument — look at how SwiftUI’s sidebar
  delete copy is keyed and match it.
- **Hotspot file:** `Localizable.xcstrings` conflicts constantly across parallel
  sessions — integrate early; union-merge if needed (keep both keys).
- **Lockstep with SwiftUI** still applies for *behavior*; for strings, sharing
  the same catalog key *is* the lockstep. If you change SwiftUI copy, change the
  shared key (or both call sites), don’t leave AppKit on a fork.
- Kit files are macOS-only — don’t expect them when building the iOS `Septask`
  scheme.

---

## Definition of done

- [ ] No user-facing English string literal remains in `Septask/SeptaskKit*.swift`
      (identifiers / symbols / keys excluded).
- [ ] Shared concepts reuse existing catalog keys (logged footer, smart-list
      titles, recurrence labels, delete-section / delete-project copy).
- [ ] `scripts/build.sh SeptaskMac 'platform=macOS'` green.
- [ ] `docs/SEPTASK_APPKIT_PARITY.md` §6 Localization marked **[DONE]**.
- [ ] User asked to verify with a non-English `-AppleLanguages` launch.

---

## Suggested first hour

Start with `SeptaskKitTaskList.swift` (largest) + `SeptaskKitSidebar.swift`
(smart-list titles + structure CRUD alerts — those already have SwiftUI twins).
That clears most of what a daily driver sees. Then composer / date popover /
recurrence / quick find.
