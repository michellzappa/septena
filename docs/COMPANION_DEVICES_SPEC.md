# Companion devices

Status: proposal (2026-11-24). Rests on ADR 0034 and ADR 0035 (both proposed).
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

### 2. Needs-you feed

`GET /v1/needs-you`: one list, newest first, of everything that waits for the
user.

| Field | Meaning |
|---|---|
| `kind` | `review` or `question` |
| `key` | Stable for one request, new when the same task asks again. Review: task id and `endStateAt`. Question: task id and turn seq. |
| `task` | id, title, area, project, as in `clientTask`, no notes |
| `text` | `reviewNote`, or the turn's `question`. Cut at a length the response states. |
| `options` | Question only: the turn's options, in order |
| `at` | `endStateAt` or the turn's time |

A question is in the list when the last turn is a provider turn with options
(`TaskStore.awaitsHuman`). One server function decides both, and the apps'
counts must agree with it. A task can be in Review and have an open question:
the question wins, one row.

The `key` is what makes arrival reliable. A device that polls sees that a key is
new. Without it, a task sent back and handed over again between two polls looks
unchanged.

### 3. Answer and send back

- `POST /v1/tasks/:id/answer` with `key` and the option's index or text. It
  appends the same user turn as the apps. A stale key (already answered, or a
  newer question) is refused as `409 stale`, and the device reloads.
- `POST /v1/tasks/:id/accept` with `key`. `complete` today accepts a task
  without checking which hand-off the user saw. It also skips the next
  occurrence of a Claude-assigned repeating task (#423), and the apps
  acknowledge an agent-made task on Accept. The new verb does all of it.
- `POST /v1/tasks/:id/send_back` with `key` and an optional note. Same effect as
  the apps' Send back.

All three are idempotent on the key, because a device on Wi-Fi retries.

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

## Phases

| Phase | What | Needs |
|---|---|---|
| CD0 (#430) | Added feed | nothing |
| CD1 (#424) | Needs-you feed, `accept` / `send_back` / `answer` | #423 |
| CD2 (#358) | Companion scope, device list | ADR 0034 accepted |
| CD3 (#425) | Live nudge | CD2 |
| CD4 (#426) | Voice transcription | ADR 0009, ADR 0035, CD2 |

CD2 gates any release outside mz's desk.

## Open questions

Collected for mz in #427.

| Question | Default |
|---|---|
| Does a companion take a sync device slot? | No, like the watch |
| Does the added feed skip imports and repeats? | Yes |
| Can a companion create tasks? | Yes, so voice has somewhere to write |
| Where is speech turned into text? | Workers AI, when ADR 0009 is accepted |
| Is voice on when a companion signs in? | Off, turned on in the app |
| Can a companion send back without words? | Yes. The agent gets "Sent back, no note" and may ask |
| Do questions from a companion's "Other" take free text? | No until CD4. The device shows the options and says "Answer on your phone" for the rest |
