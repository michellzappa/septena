# 0019. One import engine, with source adapters behind a versioned bundle

- Status: accepted (2026-11-21)
- Date: 2026-11-21
- Deciders: mz (direction: "a generalized import tool with plugins, like an
  internal API, so Things, Reminders, Todoist and others can be imported");
  the placement defaults below are the author's *(default)*, mz can overrule

## Context

Septena has one importer, for Things (`SeptenaCore/ThingsImport/`). It reads
the Things SQLite file, maps rows straight onto Septena entities, and applies
them through the mutators. The mapping, the duplicate check, the id table
(`ThingsImportMapping`, in UserDefaults) and the apply loop are all
Things-specific. Reminders enter the Inbox through a separate path.

The roadmap asks for many more sources: Microsoft To Do (#52, hard date 30
June 2027), Todoist and TickTick (#100), Superlist (#101), Any.do and
OmniFocus (#102). #99 asks for one migration engine with preview, field
dispositions, idempotent retries, reconciliation and undo of a batch. If each
source repeats the Things pattern, each one re-implements these rules, and
they drift.

Two facts constrain where the engine runs:

1. **Free mode has no account** (docs/SYNC_SUBSCRIPTION_SPEC.md §3, #47). A
   free user's tasks live only on the device. An engine that runs only on
   `api.septena.app` cannot import for them, and moving in must be free.
2. **Some sources exist only on the device.** The Things database is a local
   file, and Reminders come through EventKit. The server cannot read either.

## Decision

1. **The internal API is a versioned JSON import bundle**
   (`septena.import`, version 1). Every source adapter produces a bundle, and
   the engine accepts nothing else. The bundle is plain JSON, carries stable
   source ids, and keeps each source record's original for recovery.
2. **An adapter only reads its source.** It does not write Septena data,
   check for duplicates, or know about the user's existing lists. Adding a
   source means writing one adapter and declaring its field coverage, and
   nothing else.
3. **One engine owns every rule after the bundle:** plan (dry-run preview with
   per-field dispositions), apply, reconcile, the import ledger, and undo of a
   batch. Writes go through the mutators, like every other write
   (`CLAUDE.md`, "Mutators are the write boundary").
4. *(default)* **The engine runs in the app**, in `SeptenaCore/Import/`, so
   it works with no account and no network. Imported rows sync like any other
   local edit when the user has an account.
5. *(default)* **Adapters run on the device**, including cloud sources.
   Microsoft To Do, Todoist and TickTick are read in the app, with the
   provider's own sign-in (OAuth with PKCE, read-only scopes). The provider's
   token never reaches `api.septena.app`.
6. *(default)* **The web and Android clients get a port of the engine**, in
   TypeScript, when those clients land. The bundle schema and the planner's
   expected outputs live in `registry/` as conformance fixtures (the ADR 0015
   pattern), so the two engines cannot disagree.

## Consequences

- The Things importer becomes the first adapter. Its parser stays. Its mapper,
  apply loop and id table give way to the engine (spec phase I1). Until then
  both paths exist.
- Each new source costs one adapter plus fixtures from a real export. Preview,
  undo and loss reports come for free.
- A field Septena cannot store yet (checklists #76, tags #96, star #127) stays
  in the batch's originals and shows in the preview as *preserved*. The
  engine never turns checked steps or timed alerts into note prose without the
  user's explicit choice, and it reports that choice as *transformed*.
- The import ledger is local to the device that ran the import. Undo of a
  batch works on that device only. A synced ledger can follow if it is needed.
- Two engines will exist once the web client ships. The registry fixtures are
  the cost of that, and they are the guard against drift.
- Rejected alternative: **an engine on the backend only.** It gives one
  implementation and server-side undo, but it locks free users out of moving
  in, and it cannot read Things or Reminders.
- Spec: [docs/MOVING_IN_SPEC.md](../MOVING_IN_SPEC.md).
