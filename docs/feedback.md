# Feedback & Feature Board — Design

Status: **designed, not built** · Last updated: 2026-06-04

A two-part in-app feature, reachable from Settings ▸ About:

1. **Feedback** — a quick in-app sheet that posts to a pre-authenticated API on
   `septena.app`, which stores submissions in Supabase (private; only the
   maintainer reads them). Ships first.
2. **Feature board** — a public list anyone can submit to and upvote, with
   moderation. Schema + API designed now; UI built later. The app-side App
   Attest + posting plumbing is shared, so the board is mostly UI when its turn
   comes.

Replaces the `mailto:` stub currently at `AboutSettingsPane`
(`Septena/Shell/Settings/SettingsView.swift`).

---

## 1. Security model

The app is **open-source (MIT)**, so nothing baked into the binary can act as a
secret. Any API key, Supabase token, or shared password in the source is public.
The security therefore rests on two layers, neither of which depends on source
secrecy:

| Layer | Mechanism | Answers | Notes |
|---|---|---|---|
| **Gate** (auth / anti-abuse) | **App Attest** assertion on every write | "Is this the genuine app on a real Apple device?" | Hardware-backed (Secure Enclave). Unforgeable even with full source. Anonymous. |
| **Identity** (dedup) | **HMAC of the CloudKit user record ID** | "Which person? (one vote each)" | Per-iCloud-account. Survives reinstall, spans devices. Worker stores only the HMAC, never the raw ID. |

### Why not the CloudKit ID alone

A CloudKit user record ID is an **identifier, not a credential**. It names a
user but proves nothing: it isn't secret, isn't signed, and the Worker can't
verify it belongs to the caller (server-to-server CloudKit keys reach only the
*public* DB — see `memory/reference_cloudkit_web_services_auth.md`). Over an open
web API anyone could replay any ID. So the CloudKit ID cannot be the gate.

### Why App Attest makes the CloudKit ID trustworthy

App Attest proves the request came from the genuine, unmodified app. The genuine
app obtained the CloudKit ID from the real local CloudKit API for the
actually-signed-in account — so once Attest establishes "only the real app could
have sent this," the Worker can **trust** the CloudKit ID it receives without
re-verifying it. The original goal ("only works from the app") becomes literally
true, and the CloudKit ID is safe to use as the dedup key.

### Decisions (locked)

- **Attest-only, no fallback.** Every write requires a valid assertion. Clients
  where `DCAppAttestService.isSupported == false` (Simulator, Intel/T2-less
  Macs, no iCloud account) get **no in-app write path** — they see the legacy
  `mailto:` link instead. No weak path exists to attack.
- **Dedup = per iCloud account**, via HMAC of the CloudKit user record ID.
- **Feedback is private; the feature board is public.** Different visibility →
  different moderation needs (see §6). Feedback needs only spam defense; the
  board needs a pending→approved gate.
- **Email**: optional reply-to field, captured for the maintainer. No outbound
  notification email is sent.
- **Backend home**: a **dedicated Worker** on `septena.app/api/*`, separate from
  `septena-mcp-gateway`. The gateway is an authenticated gateway to personal
  data; this is an anonymous public surface — isolate the blast radius.

---

## 2. Topology

The app **never talks to Supabase directly** (that would mean shipping the
Supabase key in open-source code). Everything flows through the Worker, which
holds all secrets.

```
  Septena app  ──App Attest assertion──▶  Cloudflare Worker (septena.app/api/*)
   (iOS/iPadOS)                             │  • verifies attestation vs Apple
                                            │  • rate-limits via KV
                                            │  • HMACs the CloudKit ID
                                            │  • validates + caps content
                                            ▼
                                       Supabase (Postgres)
                                       • feedback (private)
                                       • feature board (public, moderated)
                                       • maintainer moderates in dashboard
```

**Worker-only secrets** (set via `wrangler secret put`, never in the app):
`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `VOTER_HMAC_SALT`. Apple's App Attest
root CA is public and bundled.

**KV namespaces:** `ATTEST` (keyId → {pubkey, counter}), `CHALLENGES`
(nonce → ts, short TTL), `RL` (rate-limit buckets). Reuse the patterns already in
`septena-mcp-gateway`.

---

## 3. App side — the Feedback sheet (v1)

Upgrade the `mailto:` row in `AboutSettingsPane`. Follow the `AdaptiveEditScaffold`
convention (inspector on iPad/Mac, sheet on iPhone) for the form and the
`PlausibleClient` actor shape for the poster.

**Gating:** on appear, if `DCAppAttestService.isSupported == false` → render the
existing `mailto:mz@envisioning.com` link, not the sheet.

**Sheet fields:**
- `category` picker — Bug · Idea · Praise · Other (drives triage).
- `TextEditor` message, capped at 2,000 chars (enforced both ends).
- Optional email — "Leave your email if you'd like a reply." (No outbound mail;
  this is purely for the maintainer to reach out from the dashboard.)
- Read-only attached metadata, shown so it's not surprising: app version, build,
  platform, OS version (same values `PlausibleClient` already computes).

**`FeedbackClient` (new actor):**
1. One-time per install: `generateKey()` → store `keyId` in Keychain →
   `attestKey(...)` → register attestation with the Worker.
2. Per submit: fetch a challenge, build payload, `generateAssertion(...)`, POST
   with the assertion header.
3. Read `container.userRecordID()` and send it in the body over the attested
   channel; the Worker HMACs and stores only the hash. (If no iCloud account, the
   client is already in the unsupported/`mailto` path.)

This client + the App Attest plumbing is the shared "groundwork" the feature
board reuses.

---

## 4. Supabase schema

Two tables, because the two surfaces have opposite visibility — which simplifies
moderation.

```sql
-- Feedback is PRIVATE — only the maintainer reads it. No public moderation
-- workflow, just spam defense. Email optional.
create table feedback (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  category    text not null check (category in ('bug','idea','praise','other')),
  message     text not null check (char_length(message) between 1 and 2000),
  email       text,                       -- optional reply-to
  app_version text, build text, platform text, os_version text,
  voter_hash  text not null,              -- HMAC(ck_user_id), for abuse trails
  is_spam     boolean not null default false
);

-- Feature requests are PUBLIC — moderated before appearing on the board.
create type fr_status as enum ('pending','approved','rejected','merged');
create table feature_request (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  title       text not null check (char_length(title) between 3 and 120),
  detail      text check (char_length(detail) <= 2000),
  status      fr_status not null default 'pending',  -- approve in the dashboard
  author_hash text not null,
  merged_into uuid references feature_request(id)     -- fold duplicate asks
);

create table feature_vote (
  request_id  uuid not null references feature_request(id) on delete cascade,
  voter_hash  text not null,             -- HMAC(ck_user_id): one vote per person
  created_at  timestamptz not null default now(),
  primary key (request_id, voter_hash)   -- ballot-stuffing impossible at the DB
);
```

The `primary key (request_id, voter_hash)` is the heart of upvote integrity —
duplicate votes are a no-op at the database level.

**RLS posture:** the `anon` role gets **no** direct access. Only the Worker
(service role) reads/writes. The public board read goes through the Worker too,
which only ever selects `status = 'approved'`. Supabase is never internet-facing;
it's pure storage + the maintainer's moderation dashboard.

---

## 5. Worker API

```
POST /api/attest/challenge   → { nonce }        one-time, KV-stored, short TTL (replay defense)
POST /api/attest/register    → verify attestation vs Apple root CA, store pubkey+counter
POST /api/feedback           → [assertion-gated] insert feedback
POST /api/features           → [assertion-gated] insert feature_request (status 'pending')
POST /api/features/:id/vote  → [assertion-gated] upsert feature_vote (duplicate → 204)
GET  /api/features           → PUBLIC, cached: approved items + vote counts (no gate)
```

**Every gated route:** verify the App Attest assertion (signature vs stored
pubkey, counter strictly increasing, body-hash + nonce match, nonce unconsumed)
→ KV rate-limit by `voter_hash` and by IP → validate/cap content → HMAC the
CloudKit ID → write.

### App Attest verification (per Apple's "Validating Apps That Connect to Your Server")

- **Register** (`/api/attest/register`): parse the CBOR attestation, verify the
  cert chain to Apple's App Attest Root CA, check the nonce, check
  `keyId == SHA256(pubkey)` and the rpId hash == `SHA256(appID)`, store pubkey +
  initial sign counter in KV.
- **Assert** (every write): issue a fresh challenge; client signs
  `SHA256(payload ‖ challenge)`; Worker verifies the signature with the stored
  pubkey, requires the counter to strictly increase, and consumes the challenge.

### Rate limits (starting points, tune later)

- Feedback: 5/hour per `voter_hash`, 20/hour per IP.
- Feature submit: 10/day per `voter_hash`.
- Votes: 60/hour per `voter_hash`.

### Content validation

Length caps (both ends), strip control chars, reject all-caps/repeated-char
spam, a honeypot field, basic URL-density heuristic. Akismet/LLM moderation
optional later.

---

## 6. Moderation

- **Feedback** (private): no status workflow. Spam is flagged (`is_spam`) by
  heuristics or by the maintainer; nothing is ever shown publicly.
- **Feature board** (public): `feature_request.status` defaults to `pending`.
  `GET /api/features` returns only `approved`. The maintainer flips status in the
  Supabase dashboard (a tiny admin UI can come later). `merged_into` folds
  duplicate asks; vote counts can sum across a merged set.

---

## 7. Build order

1. **Now**: feedback sheet (gated on `isSupported`) + `FeedbackClient` + App
   Attest register/assert + `/api/attest/*` and `/api/feedback` on the Worker +
   the `feedback` table. The Attest plumbing is the reusable groundwork.
2. **Later**: `feature_request` / `feature_vote` tables, `/api/features*`
   routes, the public board UI (submit + upvote), and a moderation view.

## 8. Open items

- Exact Worker repo location (its own repo vs. alongside the marketing site).
- Whether the public board read is cached at the Cloudflare edge (likely yes,
  short TTL) to keep Supabase reads near zero.
- macOS native App Attest support is the gating factor for ever bringing the
  in-app write path to the Mac app; until then Mac stays on `mailto`.
