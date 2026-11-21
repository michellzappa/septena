# 0017. Move Septena Life out of the Septena repo

- Status: accepted (2026-11-21)
- Date: 2026-11-21
- Deciders: mz

## Context

- ADR 0007 made the task app **Septena** (code targets `Septask*`) the primary
  product and moved the life OS to **Septena Life** (`Septena*` targets).
- Keeping both apps in `michellzappa/septena` meant ~55–60% of the Swift
  codebase (~70.6k lines in Life-OS-only targets and UI plus ~20k lines of
  Life-OS providers and `@Model` entities inside `SeptenaCore/`) existed only
  for a paused future product.
- Every task-app change had to compile and avoid breaking Life-OS schemes
  (`Septena`, `SeptenaMac`, `SeptenaWatch`, widgets, live activities), and the
  life-OS surfaces diluted focus while Septena concentrates on proving the task
  app business.
- Both apps currently share the local SwiftData store (`Septena.store`,
  `docs/REPO_SPLIT_PLAN.md` §0), so stripping Life-OS `@Model` tables from
  `SeptenaCore/Persistence.swift` requires splitting the store file first.

## Decision

Move Septena Life out of `michellzappa/septena` into its own private repository
(`michellzappa/septena-life`), preserving the complete git history up to commit
`7e89b7fb` (also tagged `septena-life-archive` in both repos). `michellzappa/septena`
is now strictly the Septena task app and its backend (`backend/`).

The removal lands in two safe passes:

1. **Pass 1 (targets & Life-OS UI):** Archive full history to
   `michellzappa/septena-life`, drop all nine Life-OS Xcode targets (`Septena`,
   `SeptenaMac`, `SeptenaShare`, `SeptenaWatch`, `SeptenaWatchComplication`,
   `SeptenaWidgets`, `SeptenaLiveActivitiesExtension`, `SeptenaUITests`,
   `SeptenaMacUITests`) and their ~340 exclusive files, and point CI and helper
   scripts at `Septask`, `SeptaskMac`, `SeptaskWatch`, and `SeptenaCoreTests`.
   Keep `SeptenaCore/` and `Septask*` code identifiers untouched so existing
   local SwiftData stores (`Septena.store`) remain 100% compatible.
2. **Pass 2 (`SeptenaCore` cleanup):** Split the task app onto its own local
   SwiftData store, then remove Life-OS providers, domain files, unused `@Model`
   entities, and legacy CloudKit code from `SeptenaCore/`. Code identifier
   renames (`Septask*` → `Septena*`) stay a separate spec (ADR 0007).

## Consequences

- `michellzappa/septena` drops ~70k+ lines of Life-OS code in Pass 1 alone,
  cutting CI and verification to `Septask`, `SeptaskMac`, `SeptaskWatch`, and
  `SeptenaCoreTests`.
- Nothing is lost: `michellzappa/septena-life` (private) holds the full,
  buildable Life OS with complete git history for when mz returns to it.
- Pass 1 is non-breaking for existing local stores and active task-app
  worktrees.

## Links

- ADR 0007 (Septena is the task app; the life OS becomes Septena Life)
- ADR 0002 (Own backend replaces iCloud)
- `docs/REPO_SPLIT_PLAN.md`
- Issue #84
