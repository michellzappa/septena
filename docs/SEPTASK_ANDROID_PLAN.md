# Septask Android — bridge app plan

**Status:** Proposal / unstarted. Companion to `docs/SEPTASK.md` (the Apple
Septask plan, P0–P4 landed). This doc covers (a) the backend work that makes
any non-Apple client possible, and (b) a native Android app with maximum
behavioral parity with the SwiftUI Septask.

Internal codename: **Septask Android**. The backend work lives in the
**gateway repo** (`../septena-mcp-gateway` — not currently checked out on this
machine); the Android app is a **new repo** (`septask-android`), since nothing
in this Xcode tree can be shared with Kotlin.

---

## 0. Is CloudKit a weird requirement for an Android app?

Split the question in two:

**CloudKit as the *storage backend*: not weird — it's the product.** Septena's
thesis is "your tasks live in *your* private iCloud, not a Septena-hosted
database." Replacing CloudKit to serve Android means standing up a hosted task
DB, which deletes the privacy story, adds server liability, and forks the data
model away from the three shipping Apple clients. Non-starter.

**CloudKit as a *client dependency on Android*: yes, weird — so Android never
touches it.** There is no CloudKit SDK for Android, no `CKSyncEngine`, no
silent push, and the web-auth token is fragile. The design rule:

> **Android speaks only to the gateway. The gateway speaks CloudKit Web
> Services. All Apple-specific weirdness is quarantined server-side, in code
> we already run in production.**

The gateway (Cloudflare Worker) already reads/writes the private DB via
CloudKit Web Services with a per-user rotating `ckWebAuthToken`
(`docs/agent-provenance-gateway-handoff.md`). Android is "just" a second
consumer of that proven path — a native client instead of Claude.

**Honest framing: this is a bridge/companion, not a standalone product.**
An Android user must have an Apple ID with Septena/Septask data in it. The
realistic customer is an existing user who carries an Android phone or
switched phones. Do not plan an Android-only onboarding path.

**Option 0 to keep in mind:** `docs/SEPTASK.md` §7 (web editable project
links, P5) plus a responsive task web app on the same gateway session model
might serve most of the Android need with far less work. This plan assumes we
want the real native app (offline mirror, widgets, share-sheet capture); if
scope pressure hits, Option 0 is the fallback, and every backend phase below
(B0–B3) is reusable for it unchanged.

---

## 1. Architecture

```text
Septena/Septask (Apple)          Claude (MCP)          Septask Android
   SwiftData mirror                  │                   Room mirror
        │ CKSyncEngine               │ MCP tools              │ Sync API (HTTPS/JSON)
        ▼                            ▼                        ▼
              ┌────────────────────────────────────────┐
              │  Gateway (Cloudflare Worker)           │
              │  per-user rotating ckWebAuthToken      │
              └───────────────────┬────────────────────┘
                                  │ CloudKit Web Services
                                  ▼
              private DB  iCloud.com.septena.cloud  zone septena-v1
```

- CloudKit stays the single convergence point (same invariant as
  Septena↔Septask parallel running, `docs/SEPTASK.md` §5).
- The Android app is a **fourth first-class client** with its own local
  mirror, mutator write boundary, and outbox — the same architecture shape as
  the Apple apps, reimplemented in Kotlin, synced through the gateway instead
  of `CKSyncEngine`.
- **Why not Android → CloudKit Web Services directly?** It works on paper,
  but then every Android install holds a raw `ckWebAuthToken`, reimplements
  token rotation + conflict handling in Kotlin, and the app breaks each time
  Apple twitches. Centralizing in the gateway means one implementation of the
  fragile part, already exercised daily by the MCP path.

### Data caveats (measured, small)

- CloudKit Web Services **cannot read `encryptedValues`**. Only legacy
  Task/Project `notes` ever used encryption; the schema already writes
  plaintext `notesText` and reads it first
  (`SeptenaCore/CloudKit/TaskRecord.swift:166`). Android is blind only to
  never-rewritten legacy notes. Acceptable; document in-app.
- Everything else Septask needs — Task, Area, Project, TaskConversation,
  Section row for `"tasks"` (accent), task-relevant Settings — is plaintext
  and already in `docs/CloudKitSchema.md`.
- Prod schema is additive-only and auto-managed; the sync API must tolerate
  fields it doesn't know (same posture as `createWithFieldFallback`).

---

## 2. Backend plan (gateway repo)

All phases land in `../septena-mcp-gateway`. Each is independently
deployable; nothing here touches the Apple apps.

### B0 — Spike: prove the loop (≈ Septask P0)

- Script or scratch route: complete the CloudKit web-auth flow in a plain
  browser (dev environment), persist the token, then `records/query` tasks
  and `records/modify` one task. Confirm the edit shows up in Septena.
- Confirm `/changes/zone` (record zone changes + `syncToken`) works against
  `septena-v1` — this is the delta-sync primitive everything rests on.
- Kill condition: if zone-changes semantics through Web Services prove
  unreliable (pagination, tombstones, token invalidation), stop and reassess
  before any Android code exists.

### B1 — Identity & connection

- **App session:** Sign in with Apple *web* flow (needs a Services ID +
  redirect URI on the worker; unlike the native flow in
  `community-worker/src/apple.ts`, the web flow needs an ES256 client
  secret). Verify identity token → mint a long-lived HMAC session, exactly
  the `apple.ts` pattern (`X-Septena-Session` equivalent).
- **CloudKit connection:** `GET /android/connect` starts the CloudKit
  web-auth redirect (Apple-hosted sign-in + 2FA — renders fine in a Chrome
  Custom Tab); the callback stores the `ckWebAuthToken` bound to the session
  identity.
- **Token custody:** one **Durable Object per user** owns the rotating token
  and serializes all CloudKit calls for that user (every CK response returns
  a replacement token; concurrent use from racing requests corrupts it).
  The DO is also where a `Reconnect iCloud` state is detected (401 from CK)
  and surfaced to the client as a typed error.

### B2 — Delta sync (read path)

- `GET /android/sync?token=<syncToken>` → wraps `/changes/zone`:
  `{ changed: [records], deleted: [recordNames], newToken, moreComing }`.
- Full zone on first call (no token). Android applies **everything relevant
  to the task domain and ignores the rest** — the same "zone fetches all,
  apply what you know" reality as Septask P0 (`docs/SEPTASK.md` §5).
- Records pass through in CloudKit Web Services JSON shape (recordName,
  recordChangeTag, fields) — do NOT invent a second wire model; Android's
  record↔entity mapping mirrors `TaskRecord.swift` field-for-field, keyed
  off `docs/CloudKitSchema.md` and `docs/IDENTIFIERS.md`.

### B3 — Mutations (write path)

- `POST /android/ops` — batch of typed operations (`task.create`,
  `task.update`, `task.complete`, `task.defer`, `task.delete`, same for
  area/project, `section.setColor`), executed via `records/modify` with
  `recordChangeTag` optimistic concurrency.
- Per-op result: `ok | conflict(serverRecord) | dropped(fields)`. On
  conflict the client refetches and reapplies — native CloudKit conflict
  posture, no bespoke merge layer (same rule as `docs/SEPTASK.md` §5).
- Reuse the `createWithFieldFallback` pattern so ops survive schema lag.
- **Provenance:** stamp `sourceClient: "SeptaskAndroid"`. Whether `source`
  is `"app"` (peer client) or a distinct value is an open decision — align
  with `docs/agent-provenance-spec.md` before B3 ships; Android is a
  first-class user surface, so it should NOT trigger the "created by agent,
  unacknowledged" cue.

### B4 — Hardening

- Re-auth UX: expired `ckWebAuthToken` (password change, Apple-side expiry —
  expect weeks-to-months lifetime, plan for worst case) → typed 401 →
  Android shows a one-tap reconnect (Custom Tab again). This is the known
  fragility (`docs/PRACTITIONER_REPORTS_SPEC.md` calls it "fragile and
  re-auth-prone") — it can't be eliminated, only made painless.
- Cheap polling: short-circuit `/sync` when the zone token is current.
- Metrics: token age, re-auth rate, conflict rate, sync latency.
- **No push in v1.** CloudKit Web Services has no webhooks; there is nothing
  to forward to FCM. Foreground fetch + pull-to-refresh + WorkManager
  periodic sync — which matches the app-wide invariant that push is a hint
  and foreground fetch is the correctness path. (A later cron-poll → FCM
  nudge is possible; it would be the Darwin sibling-nudge equivalent:
  carries no data, only "fetch now".)

### Lockstep rule

This adds a **third external surface** over the same records (in-app MCP,
hosted gateway MCP, Android sync API). The CLAUDE.md lockstep rule extends:
any change to task record fields or semantics must land in the Swift record
codecs, both MCP servers, **and** the Android sync API + Kotlin codecs in the
same change window. `docs/CloudKitSchema.md` remains the single field table
all four read from.

---

## 3. Android app plan (`septask-android`, new repo)

### Stack (chosen for structural parity, not fashion)

| Septask (Apple) | Septask Android | Notes |
|---|---|---|
| SwiftUI | Jetpack Compose (Material 3) | declarative peer; theme from `docs/DesignSpec.md` |
| SwiftData mirror | Room | local-first mirror, same role |
| `CKSyncEngine` | `SyncEngine` (Kotlin) → gateway B2/B3 | delta pull + outbox push |
| `TaskMutator` / `Outbox.swift` | `TaskMutator` / `Outbox` (Kotlin) | **same names, same write-boundary invariant** |
| `DayClock` | `DayClock` (Kotlin) | day rollover; nothing reads system clock directly |
| `@Observable` + `@Environment` | ViewModel + `StateFlow` / CompositionLocal | |
| `NavigationSplitView` | `ListDetailPaneScaffold` (adaptive) | phone = single pane, tablet = two-pane |
| WidgetKit | Glance widgets | Today list + quick-add |
| App Intents | App Shortcuts + share-sheet capture | quick-add from anywhere |
| Reminders inbox (EventKit) | — (no equivalent) | out of scope |
| Today calendar strip | CalendarContract provider | genuine parity possible, P-late |
| Things import | — (Things has no Android) | Apple side owns import |
| On-device AI / local MCP | — v1 | AI reaches tasks via the hosted gateway regardless |

### Architecture invariants (carried over verbatim)

1. **Mutators are the write boundary.** Compose UI never writes Room
   entities directly; mutators do optimistic local update → enqueue outbox
   op → notify. Identical contract to `SeptenaCore/Outbox.swift`.
2. **Local mirror first.** The app is fully usable offline; the outbox
   drains when connectivity returns; `/sync` reconciles.
3. **Read `DayClock.today`, never `Date()`/`System.currentTimeMillis()`** in
   UI — keeps rollover behavior identical across platforms.
4. **Week = trailing 7 days** wherever it surfaces (logbook grouping).
5. **Foreground refresh is the correctness path** — sync on `onResume`, on
   pull-to-refresh, and periodically via WorkManager; never assume a push.
6. **Same identity model** — record names/ids per `docs/IDENTIFIERS.md`;
   ids are minted client-side (UUID) exactly like the Swift mutators so
   creates are offline-capable.

### Feature parity target (v1 = Septask v1 surface)

- Smart lists: **Today / Upcoming / Anytime / Logbook** (the
  `TaskDestinations.smartListRoutes` set), plus the **triage band** and
  **Recently Deleted** (`NavigationState.swift` filter cases).
- Sidebar/home with smart-list grid + Areas → Projects tree (drag-to-list on
  tablet where feasible).
- Task rows per `docs/TASK_ROW_LANGUAGE_SPEC.md`; composer with the
  `TaskDraft` field set: title, notes, today, scheduled, deadline,
  recurrence (unit/interval/after-completion), area/project — including the
  quick-add token parser (`#project`, `@area`, natural dates) from
  `TaskDraft.swift`'s detector, per `docs/QUICK_ADD_CONTRACT.md`.
- Complete / defer / move-to-today / repeat-on-completion semantics identical
  to `TaskMutator`.
- Task conversations: **read + append** (they're CloudKit records;
  `conversationJSON` field) — rendering parity with `ConversationCard`, no
  on-device reasoning.
- Shared accent: read/write the `"tasks"` `SectionEntity.color` — changing
  it on Android recolors Septena/Septask, by design (same as Septask P3).
- Welcome + Settings in Septask's design language: iCloud connect state,
  sync status, accent picker, badge/notification prefs (device-local),
  privacy explainer ("your tasks stay in your iCloud; the bridge holds a
  scoped token, never your Apple password" — factually true and worth
  saying).

Explicitly **not** v1: Watch (Wear OS), on-device AI, local MCP server,
Reminders/Things import, Next feed (out of Septask's scope on Apple too).

### Phases (each leaves trunk green and shippable)

**A0 — Premise proof** (needs B1+B2): sign in, connect iCloud, raw online
task list, complete a task via a single hardcoded op. Install next to an
iPhone running Septena; confirm convergence both ways. *Kill condition:
if the auth/connect UX is too hostile for a normal user (multi-step Apple
sign-in fails in Custom Tabs, tokens die in days), stop — fall back to
Option 0.*

**A1 — Mirror + sync engine** (needs B3): Room schema (Task, Area, Project,
Conversation, Section, SyncState), record codecs, `SyncEngine` (token
cursor, tombstones, conflict-refetch), `Outbox` with retry/backoff,
mutators. This is the largest single chunk; everything after is UI.

**A2 — Task UI parity:** smart lists, triage band, sidebar, composer with
token parser, task detail, recurrence, logbook, recently deleted, search.
Judged against Septask on feel and density, per `docs/DesignSpec.md`.

**A3 — Welcome, Settings, accent, conversations.**

**A4 — Platform polish:** Glance widgets, share-sheet quick-add, App
Shortcuts, tablet two-pane, hardware-keyboard shortcuts (Ctrl+1–4 mirroring
⌘1–4), calendar strip via CalendarContract, re-auth UX refinement.

### Sizing honesty

A1 is roughly the effort of Septask P0–P2 combined — it's a from-scratch
reimplementation of the mirror/mutator/outbox spine in a new language, with
none of the source-inclusion leverage the Apple Septask enjoyed. Total is a
multi-month track even before design polish. That is the real cost of the
bridge; Option 0 exists because of it.

---

## 4. Open decisions (resolve before the phase that needs them)

1. **Provenance value for Android writes** (`source` field) — before B3.
2. **Repo licensing/visibility** for `septask-android` — Septena is public;
   presumably the Android client is too.
3. **Public name** — same guidance as `docs/SEPTASK.md` §1 (don't block on
   it).
4. **CloudKit environment strategy** — dev vs prod container for A0 testing
   (prod private DB is the user's real data; spike against dev).
5. **Gateway repo availability** — `../septena-mcp-gateway` is not checked
   out on this machine; B-phases need it cloned locally or worked in a
   session that has it.
