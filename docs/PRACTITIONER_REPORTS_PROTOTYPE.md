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

## Turning on the real link (later, ~10 min once `wrangler` is authed)

```bash
cd reports-worker
npm install
wrangler kv namespace create REPORTS      # paste the printed id into wrangler.toml
wrangler deploy                            # prints https://septena-reports.<you>.workers.dev
```

Then wire `ReportPublisher.push(payload:token:baseURL:)` into the report row
("Create link") and present `<baseURL>/r/<token>`. The Worker stores the payload
the app PUTs and serves it at `/r/:token`. This prototype Worker has **no App
Attest, no expiry enforcement, no rate limiting** — those are the spec's Phase 1
hardening, not the throwaway link.

## Not built (deferred to the spec phases)
- Secure token auth / App Attest gate / expiry + revoke enforcement.
- Auto-refresh push on foreground.
- The scoped, read-only MCP endpoint (per-report opt-in).
- Sleep / Body / GitHub aggregates (no local SwiftData mirror to read at
  report-time) and Symptoms / Medications / Goals (await Drawer-Modes Patterns).
- Correlations block in the payload.
