# Android client spec

**Status:** proposal (2026-11-21). Replaces the architecture of
`docs/SEPTASK_ANDROID_PLAN.md`, which assumed CloudKit. Issue #20, milestone
M4.

**Rests on:** ADR 0002 (own backend), ADR 0008 (agent loop rules live in the
store), ADR 0013 (Windows on the Android Kotlin code), ADR 0015 (shared
registries), ADR 0016 (sign-in beyond Apple).

## 1. Goal

A native Android app that is an ordinary client of `api.septena.app`, on the
same account as the Apple apps. Its sync code, local store and models form a
Kotlin core with no Android imports, so the Windows app (ADR 0013, phase W0)
reuses them.

## 2. Repository and modules

The app lives in this repo under `android/`, as Bipe keeps its Android and
Windows apps beside the shared code. *(default)*

| Module | Contents | Android imports |
|---|---|---|
| `android/core` | Wire types and codecs, generated registry constants (ADR 0015), sync engine, outbox, shadows, mutators, `DayClock`, domain rules verified by `registry/conformance/*.json` | none (Kotlin/JVM) |
| `android/store` | Local store on SQLite through SQLDelight, so the same schema runs on Android and on the JVM for Windows *(default)* | none |
| `android/ui` | Compose screens and view models shared with Windows where they fit | Compose Multiplatform only |
| `android/app` | Android entry point, share target, widgets, notifications, Google Play billing | yes |

Room is not used because it ties the store to Android. *(default)*

## 3. Sign-in

Per ADR 0016:

- First screen: "I use Septena on another device" (QR and 8-character code,
  approved in the signed-in app) or "Continue with email" (6-digit code).
- The refresh token is stored with the Android Keystore. The sync engine
  serializes refreshes, because refresh tokens are single use, and retries a
  request once after a 401, as `TaskBackendClient.swift` does.
- Requests carry `X-Septena-Client: android <version>`, so the change log
  names the actor.
- The app works signed out. Writes queue in the outbox and drain after
  sign-in, as on Apple.

## 4. Sync

The protocol is `docs/SEPTASK_BACKEND.md` §6. The Apple reference is
`SeptenaCore/TaskBackend/TaskSyncEngine.swift`. The Kotlin engine keeps the
same rules:

1. **Mutators are the write boundary.** UI never writes the store. A
   mutator updates the row, enqueues an op and notifies observers.
2. **Outbox.** Persistent, coalesced per row, pushed in order in batches of
   at most 500 ops (`maxOpsPerPush`). Every op has a `clientOpId`, so a
   retried push is idempotent.
3. **Shadows** hold the last server state of each row. Upserts send only the
   changed fields.
4. **Delete grace.** A delete waits 120 seconds before it is pushed, so undo
   can revive the row.
5. **Pull** after every push, and on resume, on pull-to-refresh and on a
   WebSocket nudge (`/v1/sync/ws`, bearer header through OkHttp). Server
   values overwrite fields that have no pending op. Save `nextSince` only
   after the batch is stored. On `resetRequired`, drop the cache and pull
   from 0.
6. **Results.** `applied` and `noop` clear the op. `dropped` with reason
   `deleted` removes the local row. `rejected` moves the op to the "Not
   synced" list, as on Apple.
7. **Foreground refresh is the correctness path.** A WorkManager job pulls
   periodically. The app never depends on push delivery.
8. **IDs are minted on the client** (UUID), so creates work offline.
   Recurrence keeps its deterministic next id (FNV-1a `occurrenceID`,
   verified by conformance vectors).
9. **Attachments.** Push the metadata row first, then `PUT
   /v1/attachments/:id`. Download with `GET`. Respect the 25 MB limit.
10. **Conversations** are entity `convo` (upsert keyed by task id) plus
    `appendTurn` ops, pulled as entity `turn`.

## 5. First release scope

The same scope as Windows W2, so both clients ship one tested set:

- Inbox band, Today, Upcoming, Anytime, Repeating, Logbook, Recently Deleted.
- Areas, projects and sections.
- When and Deadline, repeat, notes, Quick Find, one undo history.
- Conversations with option pills; Stop on a task and Pause all agents.
- Share target into the Inbox. Phone and tablet layouts.

Not in the first release: attachments upload (download works), calendar
events, imports, widgets, Wear OS, on-device AI. Each gets an issue when the
first release ships. Agents need no client code: the agent loop runs in the
store (ADR 0008).

## 6. Billing

Google Play Billing writes the same entitlement row as StoreKit, with
`source: "google"` (`docs/SYNC_SUBSCRIPTION_SPEC.md` §9). The backend needs a
`POST /v1/entitlement/google` verifier and Play real-time notifications.
Until entitlements are enforced, the app ships without a paywall, like the
Apple apps today.

## 7. Backend work

| Work | Phase |
|---|---|
| `AccountStore` identity table, email code flow, device approval flow (ADR 0016) | A0 |
| Google Play entitlement verifier and webhook | A4 |
| Kotlin output from `scripts/gen-registries.mjs` (ADR 0015) | A0 |

## 8. Phases

| Phase | Done when | Depends on |
|---|---|---|
| A0 Spike | A debug build signs in by device approval and by email code, pulls one account, creates a task offline and pushes it after reconnect. The same `core` and `store` modules pass their tests on the JVM. | ADR 0016 backend work, R0 registries |
| A1 Core | Sync engine, outbox, shadows, mutators and store complete, with the conformance vectors passing on the JVM. This is phase W0 for Windows. | A0 |
| A2 First release UI | The scope in §5, judged against the iPhone app per `docs/DesignSpec.md`. | A1, registries R1 to R3 |
| A3 Distribution | Play Store internal test track, then production. | A2, mz: Play Console account |
| A4 Billing | Google Play subscription writes the entitlement row. | A3, entitlements enforced |

Gate: Android CI builds and tests on the mini (`remote-build`). The laptop
has no Android SDK. Device checks follow a written check list per build, as
Bipe does.

## 9. Open questions

| Question | Default |
|---|---|
| Repo | This repo, `android/` *(default)* |
| Local store | SQLDelight, shared with Windows *(default)* |
| Shared UI | Compose Multiplatform, so Windows reuses screens *(default)* |
| Minimum Android version | Android 10 (API 29) *(default)* |
| First release attachments | Download only *(default)* |
| Tablet layout | List-detail pane on wide screens in the first release *(default)* |
