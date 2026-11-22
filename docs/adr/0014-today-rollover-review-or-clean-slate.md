# 0014. Today rolls over by review or by clean slate; it never carries over silently

- Status: accepted (2026-11-21)
- Date: 2026-11-21
- Deciders: mz (agent proposed)

## Context

ADR 0006 decided that Today does not carry over by itself: at rollover,
undone Today tasks go to the Inbox band as "carry over?" rows. Task fade P3
(#54, `docs/TASK_FADE_SPEC.md` §6) specifies this. It is not built.

Facts in the code today (2026-11-21):

- A task pinned to Today (`today == true`) stays on Today until the user
  removes it. `isOnToday` returns true for any open pin
  (`SeptenaCore/Models.swift`, `SeptenaCore/Persistence.swift`). Nothing
  clears a pin at rollover.
- `todaySetOn` records the day a pin was set. It drives the aging fade on
  Today. No rollover logic reads it (#77).
- Today membership is a union: a pin, or a When date that has arrived, or a
  deadline that has arrived.
- Microsoft To Do retires on 30 June 2027. Its users name My Day as a habit
  they rely on: they pick today's tasks whatever the due date, and the list
  starts empty the next morning. Septena's Today has no such mode
  (Starlings `/strategy/switcher-pains`, `/strategy/microsoft-to-do-exit-capture-plan`).

## Decision

Today has two rollover modes. Silent carry-over is removed.

*(Naming note, 2026-11-21: the default mode was originally called "Review", which collided with the agent Review stage (`#87`). Renamed to **Ask** (`"ask"`) so **Review** means one thing everywhere — agent-finished work awaiting human acceptance.)*

- **Ask (default).** At rollover, each open pin set before today moves to
  the Inbox band with one Today / Not today pair, as `TASK_FADE_SPEC.md` §6
  specifies. Today starts with only the tasks the user confirmed. This is
  the default for new users and for existing users.
- **Clean slate (My Day).** At rollover, each open pin set before today loses
  its pin. The task stays in its area or project. Nothing is deleted,
  completed or moved to the band.
- **The modes act on pins only.** A task on Today because its When date or
  deadline has arrived stays on Today in both modes. The union rule is
  unchanged.
- **Rollover is not a user gesture.** It does not record undo entries, does
  not stamp `touchedAt` and does not count a defer. In Ask, the user's tap
  on Today or Not today is the gesture, and records as §6 says.
- **One mode per account, synced.** Every device shows the same Today.
- **The rollover runs once per pin per day and is idempotent.** Two devices,
  or a device and the store, that both apply it produce one result.
  `todaySetOn` before today is the test.

## Consequences

- Existing users see a change at the first rollover after the update: their
  old pins arrive in the band instead of staying on Today. A user with many
  stale pins gets a long band once. The spec decides whether a one-time note
  explains it.
- Users who want Things behavior (pins stay) lose it. Ask prompts them each
  morning instead. This is the ADR 0006 trade: the list stays honest, and the
  user pays one tap per carried task.
- Clean slate gives To Do switchers the habit they name. The To Do importer
  (#52) still cannot pin My Day tasks, because Microsoft Graph does not expose
  My Day membership. The import preview must say so.
- `todaySetOn` becomes load-bearing. #77's "unused `todaySetOn`" item is
  resolved by wiring it, not deleting it.
- The mode is a new account setting. It needs a backend field and a wire
  contract entry (`docs/IDENTIFIERS.md`). The task backend connector and the
  in-app MCP server must agree on it if agents read Today.
- A day that starts at another hour (#140) moves the rollover moment. That
  decision is separate and does not change these modes.

## Links

- #139 (spec issue), #54 (Ask mode, fade P3), #77 (Today tech debt), #140 (day
  start time), #52 (To Do importer)
- `docs/TASK_FADE_SPEC.md` §6, `docs/TRIAGE_BAND_SPEC.md`
- ADR 0006
