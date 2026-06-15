/**
 * Septena Practitioner Reports — minimal Cloudflare Worker (PROTOTYPE).
 *
 * Phase-1.5 transport only. NOT hardened: no App Attest yet, no expiry
 * enforcement beyond the stored timestamp, no rate limiting. See
 * docs/PRACTITIONER_REPORTS_SPEC.md for the production design (App Attest gate,
 * D1 metadata, per-report MCP token).
 *
 * Two routes:
 *   PUT  /api/reports/:id    body = { token, payload }   → store payload blob
 *   GET  /r/:token                                        → render HTML
 *
 * Storage: a single KV namespace `REPORTS`, key = view token, value = the
 * ReportPayload JSON the app computed. The app re-PUTs on foreground
 * ("auto-refreshing snapshot"). The HTML is rendered here from the same payload
 * shape the in-app Swift renderer uses, so the two surfaces match.
 *
 * Deploy (one command, once `wrangler` is authed):
 *   cd reports-worker && wrangler kv namespace create REPORTS   # first time
 *   wrangler deploy
 */

export interface Env {
  REPORTS: KVNamespace;
}

interface StoredReport {
  token: string;
  payload: ReportPayload;
  /** Full HTML rendered by the Swift ReportHTMLRenderer (the rich, charted
   *  view). Served verbatim so there's ONE renderer. `payload` is kept for the
   *  future scoped MCP endpoint. */
  html?: string;
  /** ISO8601 instant after which the link 404s. Omitted = never expires. */
  expiresAt?: string;
  updatedAt: string;
}

// Mirror of SeptenaCore/Reports/ReportModels.swift (keep in sync).
interface ReportPayload {
  v: number;
  title: string;
  note: string;
  owner: string;
  windowDays: number;
  asOf: string;
  sections: ReportSection[];
}
interface ReportSection {
  key: string; label: string; colorHex: string;
  stats: { label: string; value: string; detail?: string }[];
  charts: { title: string; kind: "line" | "bar" | "heatmap"; unit: string; points: { label: string; value: number }[] }[];
  unavailable: boolean;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // PUT /api/reports/:id  → upsert payload, keyed by its view token.
    if (req.method === "PUT" && path.startsWith("/api/reports/")) {
      try {
        const body = (await req.json()) as { token?: string; payload?: ReportPayload; html?: string; expiresAt?: string };
        if (!body.token || !body.payload) return json({ error: "token and payload required" }, 400);
        const stored: StoredReport = {
          token: body.token, payload: body.payload, html: body.html,
          expiresAt: body.expiresAt, updatedAt: new Date().toISOString(),
        };
        await env.REPORTS.put(body.token, JSON.stringify(stored));
        return json({ ok: true, url: `${url.origin}/r/${body.token}` });
      } catch {
        return json({ error: "bad request" }, 400);
      }
    }

    // DELETE /api/reports/:token  → revoke (remove the blob; link 404s).
    if (req.method === "DELETE" && path.startsWith("/api/reports/")) {
      const token = path.slice("/api/reports/".length);
      if (token) await env.REPORTS.delete(token);
      return json({ ok: true });
    }

    // GET /r/:token  → render the report HTML.
    if (req.method === "GET" && path.startsWith("/r/")) {
      const token = path.slice(3);
      const raw = await env.REPORTS.get(token);
      if (!raw) return new Response("Report not found, expired, or revoked.", { status: 404 });
      const stored = JSON.parse(raw) as StoredReport;
      if (stored.expiresAt && Date.parse(stored.expiresAt) < Date.now()) {
        await env.REPORTS.delete(token); // tidy the expired blob
        return new Response("This report link has expired.", { status: 404 });
      }
      // Serve the Swift-rendered HTML (the charted view); fall back to the
      // minimal in-Worker render only for blobs pushed without html.
      const out = stored.html && stored.html.length > 0 ? stored.html : renderHTML(stored.payload);
      return new Response(out, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    return new Response("Septena Reports", { status: 200 });
  },
};

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

/**
 * Minimal HTML render. For the prototype this is intentionally simpler than the
 * Swift renderer (stat chips + a values table per chart). The plan is to share
 * one renderer — easiest path is to compile the Swift renderer's output server
 * side, or port the SVG helpers here. Kept deliberately tiny for now.
 */
function renderHTML(p: ReportPayload): string {
  const esc = (s: string) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const sections = p.sections
    .map((s) => {
      const stats = s.stats
        .map((st) => `<div class="stat"><div class="sv">${esc(st.value)}</div><div class="sl">${esc(st.label)}</div></div>`)
        .join("");
      const body = s.unavailable && s.charts.length === 0
        ? `<p class="empty">No data in this window.</p>`
        : `<div class="stats">${stats}</div>` +
          s.charts.map((c) => `<div class="ct">${esc(c.title)} ${c.unit ? "(" + esc(c.unit) + ")" : ""}</div>`).join("");
      return `<section class="card" style="--a:${esc(s.colorHex)}"><div class="ch"><span class="sw"></span><h2>${esc(s.label)}</h2></div>${body}</section>`;
    })
    .join("");
  return `<!doctype html><meta charset=utf-8><title>${esc(p.title)}</title>
<style>body{font:15px/1.5 -apple-system,system-ui,sans-serif;background:#f4f5f7;color:#1c1c1e;margin:0}
.r{max-width:820px;margin:0 auto;padding:32px 20px}h1{font-size:26px;margin:6px 0}
.card{background:#fff;border:1px solid #e5e5ea;border-radius:16px;padding:18px;margin:16px 0}
.ch{display:flex;gap:9px;align-items:center}.sw{width:11px;height:11px;border-radius:3px;background:var(--a)}
.stats{display:flex;flex-wrap:wrap;gap:10px;margin-top:12px}.stat{background:#f7f7f9;border-radius:10px;padding:12px 14px}
.sv{font-size:22px;font-weight:700}.sl{font-size:12px;color:#6c6c70}.ct{font-size:13px;color:#6c6c70;margin-top:12px}
.foot{color:#a0a0a5;font-size:12px;margin-top:24px}</style>
<div class=r><div style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#8e8e93;font-weight:600">Septena</div>
<h1>${esc(p.title)}</h1>${p.owner ? `<div>${esc(p.owner)}</div>` : ""}
${p.note ? `<p>${esc(p.note)}</p>` : ""}
<div style="color:#8e8e93;font-size:13px">Trailing ${p.windowDays}d · Data as of ${esc(p.asOf)}</div>
${sections}
<div class=foot>Aggregated trends only — no individual entries. Generated on the owner's device. Revocable at any time.<br>Made with <a href="https://www.septena.app" style="color:#8e8e93">Septena</a> — www.septena.app</div></div>`;
}
