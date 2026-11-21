# Registry cleanup and localization — plan

**Status:** accepted 2026-11-21. **Decisions:** [ADR 0020](adr/0020-registry-owns-copy-and-translations.md),
[ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Source:** `docs/REGISTRY_AUDIT.md`.

## Goal

Every string and list that more than one shell shows comes from
`registry/*.json`, in every language the app ships, on iPhone, iPad, Mac now
and on web, Android and Windows later. No generated code goes unused, no
registry copy is older than what ships, and the build fails when a shell
drifts.

## Phases

Phases run in order: each one needs the one before. Inside a phase, the
items touch different files and can run in parallel sessions.

| Phase | Scope | Issues | Needs |
|---|---|---|---|
| **P0 Translation pipeline** | Generator emits localized lookups (key = English, optional `l10nKey`), plural and placeholder functions; `registry/l10n/en.json` and `pt-BR.json`, seeded from the 669 existing pt-BR strings; generator writes registry entries into `Localizable.xcstrings`; `--check` reports missing translations and placeholder mismatches. Settings and the first run render pt-BR. | #214 | — |
| **P1 Registry content** | Bring registry copy up to what ships (delete templates with counts, Get started details, empty states), add what is missing (Inbox destination, weekly sweep notice, signIn device variants, rolledIn plural, bulk-move toast, text prompts, Star, Reminder, Rename, View and Window menus, `menuBar` layout), fix wording drift. Data and generator only; no shell changes. | #215, #216 (data part) | P0 |
| **P2 Shells render the registry** | 2a: notices, prompts, toasts, smart lists, Go menu, empty states (#179, #215). 2b: context menus and menu bar on both shells (#177, #216). 2c: composer, inspector, date pickers (#218, with #203, #205). 2d: About pane and `customSurface` labels; delete `TaskSettingsPane` (#217). | #179, #177, #218, #217 | P1 |
| **P3 Enforcement** | `RegistryCapabilities` gates surfaces; lint fails on registry-owned literals in shared shell files (allowlist shrinks to zero); unused generated enums fail `--check`. | #219 | P2 |
| **P4 Reach** | Add the languages mz picks (ADR 0020 open question 1): Claude drafts `registry/l10n/<lang>.json`, marked for review; App Store metadata per language. | new issue when P3 lands | P3 |

## Rules for every phase

- Work in a worktree (`scripts/wt-new`), build on mz-mini
  (`SEPTENA_NO_SIGNING=1`), merge the same session.
- `TaskListView.swift`, `SeptaskKitTaskList.swift`, `Localizable.xcstrings`
  and `project.pbxproj` are hotspots: P2 sessions merge often.
- Copy changes go through the humanizer skill.
- Update the feature map row in Starlings when a user-facing name changes.

## Done when

- `rg` finds no user-facing literal in a shared shell file outside the lint
  allowlist, and the allowlist is empty.
- Every generated registry enum has a reader.
- A pt-BR device shows pt-BR in Settings, the first run, notices, prompts,
  toasts, menus and the composer.
