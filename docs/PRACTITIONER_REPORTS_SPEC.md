# Practitioner Reports — Secure Shareable Section Bundles

Spec for sharing a **scoped, time-bounded, read-only view** of your Septena data
with a practitioner (doctor, therapist, PT, coach) who does **not** have the app
or an Apple ID. The user builds a report in-app — *Reports ▸ Doctor ▸ pick
sections & range* — and gets a secure web link. A report can optionally also
expose a **read-only MCP endpoint** scoped to exactly the same data, so a
practitioner can point their own Claude at it.

Status: **design locked, not built.** Code is the source of truth; when this spec
and the code disagree, fix one of them deliberately.

## What a report *is*

A report is a saved, reusable tuple — nothing more:

```
Report = { audience-title, [section keys], date-window, mcp-enabled } → token
```

It composes primitives the app already has rather than introducing a reporting
engine:

- **Sections** ([`SectionManifest`](../SeptenaCore/Sections/SectionManifest.swift))
  are the scoping unit. A PT report is `training + activity + sleep + goals`; a
  therapist report is `mood + sleep + symptoms`; a GP report is
  `symptoms + medications + nutrition + gut`. You never share a section you
  didn't check.
- **Patterns mode** (see [DRAWER_MODES_SPEC.md](DRAWER_MODES_SPEC.md)) is the
  report payload, near-verbatim: charts, heatmaps, rhythm wheels, trends,
  range-windowed, **read-only**. A practitioner report is the Patterns surface
  of N sections, rendered for the web. **No individual timestamped rows / Log
  view is ever shared** (decision below).
- **Correlations** are the highest-value thing to hand a practitioner — "what
  moved together over 90 days." A report includes the correlations whose inputs
  are all within the shared section set.

## Decisions (locked)

| Question | Decision | Consequence |
|---|---|---|
| **Freshness** | **Auto-refreshing snapshot.** The app re-pushes an updated payload whenever it's foregrounded while the report is active & unexpired. | Practitioner sees near-current data; the **private CloudKit DB is never exposed to the web** — the app stays the only reader. Pairs cleanly with a live MCP endpoint. |
| **Access** | **Unguessable link only** (128-bit token in the URL). No PIN/email gate in v1. | Lowest friction. Security rests on token entropy + short default expiry + one-tap revocation. PIN is a noted future option. |
| **Content depth** | **Patterns only — charts + aggregates.** No raw timestamped rows. | Clinically legible, far less exposing. Matches the Patterns-mode contract; reuses those views. |
| **MCP** | **Per-report opt-in.** Each report has an *Enable MCP* toggle (default off); when on it exposes only that report's sections/range as read-only tools via a **distinct** read token. | Revoking the report kills both the web link and the MCP endpoint. MCP is an *extension* of a report, not a separate concept. |

## In-app flow & IA

A **Reports** hub (lives in Settings; also reachable as "Share as report…" from a
section's Patterns drawer). Top level lists **audience presets** + the user's
existing reports.

```
Reports
├─ + New report
│   ├─ Doctor      ▶  pick sections (pre-checked: symptoms, medications, nutrition, gut) · range · [Create]
│   ├─ Therapist   ▶  pre-checked: mood, sleep, symptoms
│   ├─ PT          ▶  pre-checked: training, activity, sleep, goals
│   ├─ Coach       ▶  pre-checked: goals, habits, training, nutrition
│   └─ Custom      ▶  no pre-checks
└─ Active reports
    ├─ "Dr. Lindqvist — Endocrinology"   · 4 sections · 90d · refreshed 2h ago · 🔗 · ⓜ MCP off
    └─ "Anna (PT)"                        · 4 sections · 30d · refreshed today · 🔗 · ⓜ MCP on
```

Presets are just **default section sets** the user edits once; the report
remembers its bundle and regenerates on its own. Building a report:

1. Pick audience preset (or Custom) → section checklist pre-filled, fully
   editable against the live section list.
2. Pick **range** (30 / 60 / 90 / 365 d) — reuses the Patterns range picker.
3. Give it an **audience title** (shown on the report header) + optional short
   note to the practitioner.
4. **Create** → token minted, first payload pushed, link presented to copy/share.
5. Optional: flip **Enable MCP** → a second (read-only) token + endpoint URL
   appear.

Managing a report: see last-refreshed time, copy link, toggle MCP, edit
sections/range (re-pushes), **Revoke** (deletes payload + tokens server-side; the
link 404s immediately).

## Data freshness: how "auto-refreshing snapshot" works

We deliberately do **not** let the Worker read the user's private DB (that would
need a per-user `ckWebAuthToken` — fragile and re-auth-prone; see
[CloudKit Web Services auth](../README.md)). Instead the **app** is the refresher,
which also lines up with the invariant that *foreground fetch, not push, is the
reliable refresh path*:

- On foreground (and on relevant `.septenaDataChanged` for an in-scope section),
  for each **active, unexpired** report the app recomputes its Patterns payload
  locally and `PUT`s it to the Worker keyed by report id, gated by App Attest.
- Cheap-skip: hash the computed payload; don't re-upload if unchanged
  (same pattern as the Activity day-summary upsert).
- The Worker stores only the **latest** payload blob per report. The web view and
  the MCP endpoint both read that one blob — they never diverge.
- "Refreshed 2h ago" = last successful push. If the user hasn't opened the app in
  a week, the practitioner simply sees a week-old snapshot with an honest
  "as of" timestamp. Degrades gracefully; never stale-but-claiming-live.

## Payload format

A deterministic, versioned JSON document computed in-app — the **aggregates the
Patterns views already produce**, not raw entities. Sketch:

```jsonc
{
  "v": 1,
  "title": "Anna (PT)",
  "note": "Knee rehab — weeks 4–8",
  "owner": "Michell Z.",          // user display name, opt-out-able
  "window": { "days": 30, "asOf": "2026-06-14T09:00:00Z" },
  "sections": [
    {
      "key": "training",
      "label": "Training",
      "charts": [ /* series the Patterns view renders: Z2, volume, muscle-load */ ],
      "summary": { /* headline aggregates, e.g. sessions/wk, total volume */ }
    },
    { "key": "sleep",  "...": "..." },
    { "key": "activity", "...": "..." }
  ],
  "correlations": [ /* only those whose inputs ⊆ shared sections */ ]
}
```

- **Aggregates only**, by decision — no per-event timestamps, no free-text notes
  unless a section's Patterns view already surfaces them.
- Versioned (`v`) so the web renderer and MCP can evolve independently of old
  links.
- Computed by reusing each dual section's `patternsBody` data source, so the
  practitioner literally sees the same charts the user sees in Patterns mode.

## Web view (`septena.app/r/<token>`)

- Static, fast, mobile-friendly read-only page rendering the payload: header
  (owner, title, note, "data as of …", window), then one block per section
  mirroring its Patterns charts, then a correlations section.
- No login. The token *is* the credential.
- Honest privacy footer: *"Aggregated trends only — no individual entries.
  Generated on the owner's device. This link can be revoked at any time and
  expires on <date>."*
- The **clinical PDF is a later render of this same payload**, not a separate
  pipeline (print stylesheet / server-side render of `/r/<token>`).

## MCP extension (per-report, opt-in)

When *Enable MCP* is on, the report exposes a **read-only** MCP endpoint scoped to
exactly its sections + range, backed by the **same payload blob** (not CloudKit):

- A **distinct** read-only token (so the user can hand the web link to a human and
  the MCP credential to that human's AI, and revoke independently if desired —
  though Revoke kills both).
- Tools are the **read subset** of the existing gateway vocabulary, filtered to
  the report's sections — e.g. `training_entries_list`, `sleep_summary`,
  `correlations_list` — but served from the frozen aggregate payload, so they
  return only what the web view shows. No mutators, ever.
- Practitioner pastes the endpoint + token into their own Claude and asks
  questions over the scoped data.

**This is a third MCP surface** — distinct from the in-app loopback server and
the consumer hosted gateway. Per the MCP-lockstep rule it must not silently
diverge: it should reuse the gateway's tool **schemas/naming** where they
overlap, but it is backed by the report payload store, is read-only, and is
scoped per token. Document it as such so a future agent doesn't conflate it with
"the two MCP servers."

## Backend architecture

Reuses the **dedicated Cloudflare Worker** + App Attest plumbing already specced
for [Feedback](feedback.md) — *not* the MCP gateway repo, *not* CloudKit Web
Services.

```
 Septena app ──App Attest assertion──▶  Worker (septena.app/api/reports/*)
  (iOS/iPad/Mac)   PUT latest payload     │ • verify attestation vs Apple
                                          │ • upsert payload blob by report id
                                          ▼
   practitioner ──GET /r/<token>────────▶ Worker ── reads blob ──▶ D1 + R2/KV
   practitioner's AI ──MCP <mcpToken>──▶  Worker (read-only tools over same blob)
```

- **App Attest** gates every write (create/refresh/revoke) — same hardware-backed
  anti-abuse as Feedback; no API key shipped in the open-source client.
- **D1** holds report metadata: `report_id`, `view_token`, `mcp_token`,
  `mcp_enabled`, `expires_at`, `revoked_at`, `last_refresh_at`, owner HMAC.
- Payload blob in **R2** (or a D1 row / KV) keyed by `report_id`.
- Tokens are 128-bit random, distinct from `report_id`; both web and MCP tokens
  resolve to the same blob.
- **Lifecycle:** default expiry **90 days**, user-selectable (30 / 90 / 365 /
  never), revocable anytime. Expired/revoked → 404 on web + MCP; the app stops
  pushing.

## Privacy posture (the differentiator)

Because Septena is local-first and going MIT, this can make a claim no QS
competitor can: **only the aggregate trends the user explicitly selected ever
leave the device, the raw log never does, the data was computed on-device, and
the share is token-gated, expiring, and revocable.** For health data handed to a
clinician, that's the pitch — Septena never becomes a custodian of raw records.

## Build phases

1. **Phase 1 — web report, snapshot push.** Reports hub + builder (presets,
   section checklist, range, title), payload computation reusing Patterns data
   sources, App Attest `PUT`, Worker + D1/R2 storage, `/r/<token>` renderer,
   expiry + revoke + auto-refresh on foreground. Ships the whole core loop.
2. **Phase 2 — MCP extension.** Per-report toggle, second read token, read-only
   scoped tools over the payload blob; sync schemas with the gateway vocabulary.
3. **Phase 3 — clinical PDF.** Print/server render of `/r/<token>`; no new data
   path.

## Open questions / out of scope

- **Depends on [DRAWER_MODES_SPEC.md](DRAWER_MODES_SPEC.md) landing first** for
  the six pure-data loggables (symptoms, medications, etc.) to have a Patterns
  surface to share. Until then those sections can only contribute a minimal
  summary block, or are report-ineligible. Decide per section.
- Optional **PIN/passcode** as a second factor for medical-section reports
  (deferred; link-only for v1).
- **Per-section depth override** (raw rows for one section) — explicitly rejected
  for v1 (aggregates only) but the payload `v` leaves room.
- Owner identity: default to the user's display name with an opt-out to share
  anonymously / under initials.
- watchOS / widgets: no surface — report creation is iPhone/iPad/Mac only.
