# Practitioner Reports — Prototype (what's built)

Companion to [PRACTITIONER_REPORTS_SPEC.md](PRACTITIONER_REPORTS_SPEC.md). The
spec is the destination; this is the **prototype that shipped first** so the
builder, the live-data payload, and the renderer can be exercised with real
data before any infra exists.

## What works today (macOS, no infra)

**Settings ▸ Reports.** Pick an audience preset (Doctor / Therapist / PT / Coach
/ Custom) → it pre-checks sensible sections → edit the section list, trailing
window (30/60/90/365), title, and note → **Save**. Saved reports list with
preview / edit / delete.

Tapping a report **computes the payload from live local data** (off-main via
`MirrorReader`) and renders the exact web view a recipient would see, in a
`WKWebView`. From the preview you can **Open in Browser** (writes a temp `.html`
and opens it in your default browser — the real, shareable artifact with your
real data) or **Save HTML…** to keep a copy.

Aggregates only — no individual timestamped rows — matching the spec's privacy
decision.

### Sections with live aggregates
`habits`, `supplements`, `chores`, `gut`, `training`, `nutrition`, `mood`,
`activity` (see `ReportPayloadBuilder.supportedKeys`). All read the on-device
SwiftData mirror via `ChecklistMirror` / a `FetchDescriptor` — no network. Other
selected sections render an honest "no trends yet" note (they need their
Patterns view from `docs/DRAWER_MODES_SPEC.md` first).

## Code map

| Piece | File |
|---|---|
| Models (bundle, payload, presets, local store) | `SeptenaCore/Reports/ReportModels.swift` |
| Live-data payload builder | `SeptenaCore/Reports/ReportPayloadBuilder.swift` |
| Self-contained HTML + inline-SVG renderer | `SeptenaCore/Reports/ReportHTMLRenderer.swift` |
| macOS hub + builder + WKWebView preview + export | `Septena/Shell/Reports/ReportsSettingsPane.swift` |
| Settings wiring (`.reports` destination) | `Septena/Shell/Settings/SettingsView.swift` |
| One-command-deploy Worker (the future link) | `reports-worker/` |
| Push client (compiled, not yet wired) | `SeptenaCore/Reports/ReportPublisher.swift` |

The HTML renderer lives in `SeptenaCore` and is the single source the future
Worker will mirror — one renderer, both surfaces.

## The real link — LIVE (deployed 2026-06-15)

The Worker is deployed and the app is wired:

- **Endpoint:** `https://septena-reports.mz-508.workers.dev` (KV namespace
  `REPORTS`, deployed from `reports-worker/` via `npx wrangler deploy`).
- **In-app:** open a report's preview → **Create Link**. This pushes the live
  aggregate payload via `ReportPublisher.push(...)`, mints a 40-hex-char token,
  stores `token` + `linkURL` on the bundle, copies the URL, and shows it in a
  banner. Re-creating refreshes the same token's payload. The row shows
  "🔗 shared".
- The base URL is `ReportEndpoint.baseURL` (override via the
  `septena.reports.baseURL` UserDefaults key).

Verified end-to-end with a **synthetic** payload: PUT → `{ok,url}`, GET
`/r/<token>` → HTTP 200 with the rendered report, unknown token → 404. The first
push of *real* data happens only when the user taps Create Link.

> ⚠️ This prototype Worker has **no App Attest gate, no token expiry, no revoke,
> no rate limiting** — anyone with the URL can read it until the KV entry is
> deleted. Those are the spec's Phase-1 hardening (track #3). Treat current
> links as disposable; don't share real health data widely yet.

Redeploy after Worker edits: `cd reports-worker && npx wrangler deploy`.

## Not built (deferred to the spec phases)
- Secure token auth / App Attest gate / expiry + revoke enforcement.
- Auto-refresh push on foreground.
- The scoped, read-only MCP endpoint (per-report opt-in).
- Sleep / Body / GitHub aggregates (no local SwiftData mirror to read at
  report-time) and Symptoms / Medications / Goals (await Drawer-Modes Patterns).
- Correlations block in the payload.
