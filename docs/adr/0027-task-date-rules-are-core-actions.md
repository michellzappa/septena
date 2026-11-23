# 0027. Task date rules are actions in the shared core

- Status: proposed (2026-11-23)
- Date: 2026-11-23
- Deciders: mz
- Builds on: [ADR 0025](0025-shared-rust-core.md) (one shared Rust core)
- Spec: [TASK_DATES_SPEC.md](../TASK_DATES_SPEC.md)

## Context

A task has five date fields: the When date (`scheduled`), the deadline, the
Today pin (`today` + `todaySetOn`), the time slot and the reminder. Together
they decide where a task shows (Today, Upcoming, Anytime, Inbox band) and
whether it is overdue.

An audit on 2026-11-23 (spec §7) found the rules in many copies:

- **Writes.** Each user action is a sequence of mutator calls that each
  shell writes itself. "Pick a future When date" has five call sites on Apple
  platforms, with two different sequences: on iOS an overdue deadline
  survives, on Mac it is deleted. "Clear When" had three copies until
  ee15d83c; on iOS it left the deadline in place. The backend MCP tools, the
  REST verbs and the Android mutator each have their own versions again.
- **Reads.** "On Today" exists in five copies (Swift ×2, TypeScript, Kotlin,
  Rust). "Overdue" exists in seven copies with two meanings (`<` and `<=`).
  The backend copy of "on Today" does not exclude faded tasks.
- **The core is not used.** The Rust core already exports
  `taskViewMembership`, but no Apple code and no backend code calls it.
  The core holds no write rule at all.
- **Nothing tests the writes.** The conformance fixtures cover view
  membership, recurrence and reminders. No fixture covers what an action does
  to the fields.

Each copy was correct when it was written. They drift because nothing forces
them to agree. A user sees the drift as "I cleared the date and it is still
there", which breaks trust in the app.

## Decision

Every rule that changes or interprets a task's date fields lives once, in
`core/crates/septena-core`, as:

1. **A closed set of date actions** (spec §4). Each action is a pure function
   `(task snapshot, action, today) → field patch`. A shell never composes
   `schedule` + `moveToToday` + `setDeadline` itself. It names the action, the
   mutator asks the core for the patch, and the mutator writes the patch in one
   save.
2. **One read model** (spec §5). On Today, overdue, due state, Upcoming,
   Anytime, rolled in and days on Today all come from the core's membership
   function. No platform re-derives them.
3. **Field invariants** (spec §3) that every write must satisfy. The core
   normalises a patch so that it satisfies them, and the conformance fixtures
   check every action against them.
4. **Conformance fixtures for every action**, run by the Rust, Swift, JVM and
   WASM harnesses and by the backend tests.

The Apple mutator (`TaskMutator`), the backend write path and the Android
mutator each expose one method per action and nothing lower-level to UI code.
A lint rule stops a shell from calling the low-level setters.

## Consequences

- One action means one result on iOS, Mac, the watch, MCP, REST and Android.
  A rule changes in one place, and the fixtures prove every platform follows.
- Undo stays per action: the shell records one snapshot before the action, as
  it does today.
- The shells lose freedom. A surface that wants a variant (for example a
  drag that should also clear the deadline) needs a named action in the core,
  not a local sequence.
- The work depends on the ADR 0025 phases: Apple and the backend must link
  the core (C4, C3) before their copies can go. Until then, a platform can port
  a rule only if it passes the same fixtures.
- Some current behaviours change on one platform or another, because the
  platforms disagree today and only one answer can survive. Spec §8 lists each
  case for mz to decide.

## Links

- Spec: [TASK_DATES_SPEC.md](../TASK_DATES_SPEC.md)
- [ADR 0025](0025-shared-rust-core.md), [SHARED_CORE_SPEC.md](../SHARED_CORE_SPEC.md)
- Commit ee15d83c (Clear When made one mutator write)
