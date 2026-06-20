# Feedback & Feature Board — Design

Status: **designed, not built** · Last updated: 2026-06-04

A two-part in-app feature, reachable from Settings ▸ About:

1. **Feedback** — a quick in-app sheet that posts to a pre-authenticated API on
   `septena.app`, which stores submissions in Cloudflare D1 (private; only the
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
secret. Any API key or token in the source is public. Security therefore rests on
two layers, neither of which depends on source secrecy:

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
have sent this," the Worker can **trust** the CloudKit ID it receives. The
original goal ("only works from the app") becomes literally true, and the
CloudKit ID is safe to use as the dedup key.

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
  data; this is an anonymous public surface — isolate the blast radius. Likely
  lives in/beside the `../septena-site` repo (the marketing site, also on
  Cloudflare).

### Storage: Cloudflare D1, not Supabase

The whole stack stays on Cloudflare. The app never talks to the database
directly (that would mean shipping a DB key in open-source code) — the Worker
mediates everything, so none of Supabase's headline features (Auth, RLS,
realtime, auto-REST) would ever be used. **D1** (serverless SQLite) covers the
full workload and is strictly simpler here:

- One vendor, one `wrangler` deploy. D1 sits beside the KV namespaces the Worker
  already uses.
- **No database service key to protect.** D1 is a Worker *binding*, not a
  networked service — the only remaining secret is `VOTER_HMAC_SALT`. There is no
  internet-facing database at all; nothing but the Worker can reach the binding.
  (This replaces what would have been a "lock down Supabase RLS" section — D1
  needs no RLS because it's not reachable from anywhere else.)
- Vote-dedup integrity is identical: SQLite enforces the composite primary key
  and `INSERT … ON CONFLICT DO NOTHING`.

The one trade vs. Supabase is the lack of a built-in table editor for reading
feedback / approving board items — covered by the small admin view in §6 (or
`wrangler d1 execute` in the interim).

---

## 2. Topology

The app **never talks to the database directly.** Everything flows through the
Worker, which holds the only secret and owns the D1 binding.

```
  Septena app  ──App Attest assertion──▶  Cloudflare Worker (septena.app/api/*)
   (iOS/iPadOS)                             │  • verifies attestation vs Apple
                                            │  • rate-limits via KV
                                            │  • HMACs the CloudKit ID
                                            │  • validates + caps content
                                            ▼
                                       Cloudflare D1 (SQLite, same account)
                                       • feedback (private)
                                       • feature board (public, moderated)
```

**Worker secret** (via `wrangler secret put`, never in the app): `VOTER_HMAC_SALT`.
**Bindings:** `DB` (D1); KV `ATTEST` (keyId → {pubkey, counter}), `CHALLENGES`
(nonce → ts, short TTL), `RL` (rate-limit buckets). Apple's App Attest root CA is
public and bundled. Reuse the KV/cron patterns already in `septena-mcp-gateway`.

---

## 3. App side — the Feedback sheet (v1)

Upgrade the `mailto:` row in `AboutSettingsPane`. Follow the `AdaptiveEditScaffold`
convention (inspector on iPad/Mac, sheet on iPhone) for the form and the
`TelemetryClient` actor shape for the poster.

**Gating:** on appear, if `DCAppAttestService.isSupported == false` → render the
existing `mailto:mz@envisioning.com` link, not the sheet.

**Sheet fields:**
- `category` picker — Bug · Idea · Praise · Other (drives triage).
- `TextEditor` message, capped at 2,000 chars (enforced both ends).
- Optional email — "Leave your email if you'd like a reply." (No outbound mail;
  this is purely for the maintainer to reach out.)
- Read-only attached metadata, shown so it's not surprising: app version, build,
  platform, OS version (same values `TelemetryClient` already computes).

**`FeedbackClient` (new actor):**
1. One-time per install: `generateKey()` → store `keyId` in Keychain →
   `attestKey(...)` → register attestation with the Worker.
2. Per submit: fetch a challenge, build payload, `generateAssertion(...)`, POST
   with the assertion header.
3. Read `container.userRecordID()` and send it in the body over the attested
   channel; the Worker HMACs and stores only the hash. (No iCloud account → the
   client is already in the unsupported/`mailto` path.)

This client + the App Attest plumbing is the shared "groundwork" the feature
board reuses.

---

## 4. D1 schema

SQLite (D1) dialect. Two tables, because the two surfaces have opposite
visibility — which simplifies moderation.

```sql
-- Feedback is PRIVATE — only the maintainer reads it. No public moderation
-- workflow, just spam defense. Email optional. ids are crypto.randomUUID()
-- generated in the Worker (SQLite has no native UUID). Booleans are 0/1.
create table feedback (
  id          text primary key,
  created_at  text not null default (datetime('now')),
  category    text not null check (category in ('bug','idea','praise','other')),
  message     text not null check (length(message) between 1 and 2000),
  email       text,                       -- optional reply-to
  app_version text, build text, platform text, os_version text,
  voter_hash  text not null,              -- HMAC(ck_user_id), for abuse trails
  is_spam     integer not null default 0
);

-- Feature requests are PUBLIC — moderated before appearing on the board.
create table feature_request (
  id          text primary key,
  created_at  text not null default (datetime('now')),
  title       text not null check (length(title) between 3 and 120),
  detail      text check (length(detail) <= 2000),
  status      text not null default 'pending'
                check (status in ('pending','approved','rejected','merged')),
  author_hash text not null,
  merged_into text references feature_request(id)   -- fold duplicate asks
);

create table feature_vote (
  request_id  text not null references feature_request(id) on delete cascade,
  voter_hash  text not null,             -- HMAC(ck_user_id): one vote per person
  created_at  text not null default (datetime('now')),
  primary key (request_id, voter_hash)   -- ballot-stuffing impossible at the DB
);
```

The `primary key (request_id, voter_hash)` is the heart of upvote integrity —
duplicate votes are a no-op. Public board read (counts):

```sql
select fr.id, fr.title, fr.detail, fr.created_at,
       count(fv.voter_hash) as votes
from feature_request fr
left join feature_vote fv on fv.request_id = fr.id
where fr.status = 'approved'
group by fr.id
order by votes desc, fr.created_at desc;
```

Nothing but the Worker can reach `DB`, so there's no RLS to configure — the
database is never internet-facing.

---

## 5. Worker API

```
POST /api/attest/challenge   → { nonce }        one-time, KV-stored, short TTL (replay defense)
POST /api/attest/register    → verify attestation vs Apple root CA, store pubkey+counter
POST /api/feedback           → [assertion-gated] insert feedback
POST /api/features           → [assertion-gated] insert feature_request (status 'pending')
POST /api/features/:id/vote  → [assertion-gated] INSERT … ON CONFLICT DO NOTHING (dup → 204)
GET  /api/features           → PUBLIC, edge-cached: approved items + vote counts (no gate)
```

**Every gated route:** verify the App Attest assertion (signature vs stored
pubkey, counter strictly increasing, body-hash + nonce match, nonce unconsumed)
→ KV rate-limit by `voter_hash` and by IP → validate/cap content → HMAC the
CloudKit ID → write to D1.

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
  `GET /api/features` returns only `approved`. `merged_into` folds duplicate
  asks; vote counts can sum across a merged set.
- **Admin surface**: a small authed `/admin` page on the Worker (behind
  Cloudflare Access) to list pending items and flip status — replaces what
  Supabase's table editor would have given. Until that's built, `wrangler d1
  execute "UPDATE feature_request SET status='approved' WHERE id=…"` is enough.

---

## 7. Build order

1. **Now**: feedback sheet (gated on `isSupported`) + `FeedbackClient` + App
   Attest register/assert + `/api/attest/*` and `/api/feedback` on the Worker +
   the `feedback` D1 table. The Attest plumbing is the reusable groundwork.
2. **Later**: `feature_request` / `feature_vote` tables, `/api/features*`
   routes, the public board UI (submit + upvote), and the `/admin` view.

## 8. Open items

- Exact Worker location (own repo vs. inside `../septena-site`).
- Edge-cache TTL for the public `GET /api/features`.
- macOS native App Attest support is the gating factor for ever bringing the
  in-app write path to the Mac app; until then Mac stays on `mailto`.
