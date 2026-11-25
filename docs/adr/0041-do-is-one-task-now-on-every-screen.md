# 0041. Do is one task now, and every screen shows it

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz
- Builds on: [ADR 0006](0006-tasks-fade-by-default.md),
  [ADR 0008](0008-agent-loop-rules-live-in-the-store.md),
  [ADR 0023](0023-sync-across-devices-is-plus.md),
  [ADR 0025](0025-shared-rust-core.md)
- Extends: [ADR 0034](0034-companion-devices-get-a-limited-session.md)
  (a companion may start and stop a Do)

## Context

Septena knows what the user wants (the lists), what fades and what agents work
on. It does not know what the user does now. A list also invites the user to
reorganize it in place of doing the work. Procrastination is mostly the wish
to avoid a feeling, so the start is the hard part, not the planning.

Facts from the code today:

- The orb can pin one task to its middle. The pin is on that orb only.
- The store sends a live nudge to every open client after a change. The Mac
  keeps its socket open in the background. The orb has its own live socket.
- A locked iPhone gets a push for an agent's question and for nothing else.
  Android has no push.
- Apple gives an app no switch for the system Focus.

## Decision

The user can **Do** one task. Do is a state of the account: at most one task,
with a start and an optional length.

1. **Full where you start it, a notice everywhere else.** The device where the
   user starts Do shows that one task. Every other device shows one quiet line
   and works as normal. No device is locked. "Full or notice" is a choice that
   each device keeps to itself; the synced state has no device roles.
2. **The orb is the exception.** It shows one thing at a time, so Do takes its
   whole face. Do replaces the orb's local pin.
3. **A session is a synced row, and also the history.** The row holds the task,
   start, optional length, end, exit and one optional line. The open row is the
   current Do. The store keeps at most one open. A Stop names its row, so an old
   Stop can never end a newer Do.
4. **The timer counts up.** A length is optional. There are no cycles, no
   breaks and no settings page. No device sends ticks.
5. **Leaving is not a failure.** Exits are Done, Stop for now and Later. There
   are no streaks, no scores, no red timer and no word for abandoned.
6. **Only a person starts a Do.** An agent may propose one that the user taps.
   No agent can start, change or end a Do, and no agent can claim the task
   that the user does.
7. **Interruptions wait, information does not.** During a Do, agent questions
   appear in the lists and counts as usual. Pushes and orb pulses for them wait.
8. **Do is free on the device you use.** Do on several devices is sync (ADR
   0023). The watch and the orb take no device slot.

## Consequences

- Septena gains a state that every client must render. A client that does not
  know it ignores it, and the store still ends the Do when the task closes.
- The orb's "pin is orb only, no timer" default is reversed.
- A wrong notice is cheap, because nothing is blocked. So push is polish, and
  Android needs no push service in the first version.
- Septena cannot silence an iPhone or a Mac. Do only changes Septena. A user
  can join Do to a system Focus with a Shortcut.
- A user will forget to end a Do. After a limit the Do is stale: the notice
  goes, pushes resume, and the next device asks.
- The sessions are private activity data. They belong to the account, go into
  the export, leave with the task, and never enter analytics.

## Links

`docs/DO_SPEC.md`, `docs/COMPANION_DEVICES_SPEC.md`, `docs/TASK_FADE_SPEC.md`
