# 0034. Give companion devices a limited session and a small verb set

- Status: proposed
- Date: 2026-11-24
- Deciders: mz
- Builds on: [ADR 0008](0008-agent-loop-rules-live-in-the-store.md),
  [ADR 0016](0016-sign-in-beyond-apple.md),
  [ADR 0023](0023-sync-across-devices-is-plus.md)

## Context

A companion device has no task store. It asks for a ready-made view and sends
verbs (`backend/src/api/tasksRest.ts`). The Apple Watch is the first one and
the desk orb is the second. The two differ in one way. The watch is worn and
locked, and a phone signs it in. The orb stands on a desk with no lock, and
signs in by device approval (ADR 0016). Approval issues an ordinary app
session, so a person who takes the orb, or reads its flash, holds the full
account (#358).

A companion is also the natural place for "an agent needs you". The REST
surface has a Review view. It has no view of open questions and no way to
answer one or send work back. A companion learns of changes only by polling.
The live socket (`/v1/sync/ws`) requires a sync device slot.

## Decision

A device approved as a companion gets a session with a `companion` scope. The
backend enforces the scope on the route, before the handler, and refuses every
route that is not on the list.

1. **Read:** Today, Review, Completed, Upcoming, recently added, and
   open questions. A
   companion response carries no task notes.
2. **Write:** complete a task, accept or send back a review, answer an open
   question, defer a task, create a task.
3. **Never:** approve a sign-in or an agent, change settings, read history,
   read attachments, export, delete, or reach `/v1/sync/*` and `/v1/account`.
4. **Visible:** the session is in Devices & Access with its name, and the user
   can sign it out there.
5. **No device slot:** a companion does not take a sync device slot *(default)*.
   The watch already works this way.
6. **The human's hand:** a companion write counts as the user. So every write
   needs a deliberate gesture on the device. A card that arrives by itself can
   never take a gesture that started before the card was visible.

Rules stay on the server. A companion draws what the API returns.

## Consequences

- A stolen companion can do limited harm, and one sign-out ends it.
- Every new companion feature needs an entry in the scope list. That is the
  point: the list is the review.
- The backend must enforce the scope centrally. A route added later is refused
  until someone lists it.
- A companion cannot replace the phone for sign-in approval.
- If a companion takes no slot, a free account can own several. A limit, if
  one is needed, belongs in the plan table.

## Links

`docs/COMPANION_DEVICES_SPEC.md`, #358, `docs/WATCH.md`
