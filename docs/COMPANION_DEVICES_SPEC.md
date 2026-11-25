# Companion devices

Status: building (2026-11-24; CD0, CD1 and CD3 built). Rests on ADR 0034 and ADR 0035 (both accepted 2026-11-25). CD2 and CD4 are for later.
This spec is the backend contract. The desk orb's firmware and its own roadmap
are in `michellzappa/tinyseptena` (private).

## What exists

`/v1/tasks` (`backend/src/api/tasksRest.ts`): views `today`, `review`,
`completed`, `upcoming` and others; `POST /v1/tasks`; verbs `complete`,
`today`, `untoday`, `tomorrow`, `defer`, `cancel`. No device slot. The response
carries `accent`, `today`, `completedAt` and `reviewNote`.

## What is missing

### 1. Companion scope (#358)

ADR 0034. The device approval names a purpose, the session carries a scope, and
one middleware checks the scope against a list of routes. A test asserts that
every route not on the list refuses a companion token. The approval screen says
what the device can do. Devices & Access lists the session.

An orb that is already signed in keeps its full session until it signs in
again, so the release notes say to sign it out once.

### 2. What waits for the user

Built as two views of `GET /v1/tasks`, newest first, so a device reads them
like every other list. A companion response carries no task notes in the
questions and added views.

- `view=review`: `reviewNote` (what to check) and `reviewAt` (when it was
  handed over).
- `view=questions`: open tasks whose last turn is an agent's question with
  options (`TaskStore.readOpenQuestions`, the rule of `awaitsHuman`). Each has
  `question`, `options` and `turnSeq`. A stopped task is not in it.

A request is identified by the task id with `reviewAt`, or the task id with
`turnSeq`. That is what makes arrival reliable: a task sent back and handed
over again between two reads has a new `reviewAt`.

### 3. Answer, accept, send back

- `POST /v1/tasks/:id/answer` with `inReplyTo` (the `turnSeq`) and `option` (its
  index) or `chosen` (its text). The turn takes the question's own step.
- `POST /v1/tasks/:id/accept` with an optional `reviewAt`. Same effect as Accept
  in the apps: complete, start the next occurrence of a repeat, and acknowledge
  a task an agent added.
- `POST /v1/tasks/:id/send_back` with an optional `note` and `reviewAt`. Same
  effect as Send back in the apps. Without a note the agent reads "Sent back
  without a note."

A request that is no longer the open one is refused with `422` and
`reason: "stale"`. A repeat of an answer or an accept that landed returns `200`.

### 4. Live nudge

`GET /v1/tasks/live`: the socket `/v1/sync/ws` serves, without the device slot
and open to the companion scope. It carries only a revision number, and the
device refetches. Polling stays as the fallback. An idle device costs one
hibernated socket in place of a poll every 30 seconds.
`plan.limits.liveSync` still applies *(default)*.

### 5. Voice (ADR 0035)

`POST /v1/voice/transcribe`: body is 16 kHz, 16-bit, mono audio, at most 20
seconds *(default)*. That is 32 KB per second, so at most 640 KB. Response:
`{text, language}`. Nothing is written. The device shows the text, then sends
`POST /v1/tasks` or `answer` with it. The route refuses when voice is off for
the account, checks the size before it reads the body, and logs duration and
result, never text or audio.

### 6. Added feed (#430)

A companion shows a task at the moment it is created, by the user on another
device or by an agent. Today alone cannot tell "created" from "moved to
Today", and it misses tasks that go straight to a project or a later day.

`GET /v1/tasks?view=added`: open tasks created in the last 24 hours, newest
first, at most 50 plus `total`. Each row is a `clientTask` with two more fields,
`createdAt` (ms) and `addedBy`: `agent` when `source` is `mcp`, else `you`. The
store already has both columns. A spawned repeat occurrence is not in the
list: nobody added it. Nor is an import.

### 7. Do (ADR 0041)

Not built. `GET /v1/tasks` adds `doing`; a companion may start a Do, stop it and
confirm it. The routes and the orb's behavior are in `docs/DO_SPEC.md` §7. CD2
puts these routes on its list.

## Phases

| Phase | What | Needs |
|---|---|---|
| CD0 (#430) | Added feed | done |
| CD1 (#424) | Questions view, `accept` / `send_back` / `answer` | done |
| CD2 (#358) | Companion scope, device list | nothing; not started |
| CD3 (#425) | Live nudge | done, before CD2: open to every session |
| CD4 (#426) | Voice transcription | CD2, a price decision (ADR 0009), the terms check in ADR 0035 |

CD2 gates any release outside mz's desk.

## Open questions

mz accepted the ADRs in #427; the defaults below stand.

| Question | Default |
|---|---|
| Does a companion take a sync device slot? | No, like the watch |
| Does the added feed skip imports and repeats? | Yes |
| Can a companion create tasks? | Yes, so voice has somewhere to write |
| Where is speech turned into text? | Workers AI |
| Is voice on when a companion signs in? | Off, turned on in the app |
| Can a companion send back without words? | Yes. The agent gets "Sent back, no note" and may ask |
| Do questions from a companion's "Other" take free text? | No until CD4. The device shows the options and says "Answer on your phone" for the rest |
