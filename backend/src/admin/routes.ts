import { Hono, type Context, type Next } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { createPlusLink, revokePlusLink } from "../api/plusLinks.js";
import { USER_ID_RE, accountStoreFor, testerStats, type BetaTesterStats } from "../store/AccountStore.js";
import { storeFor } from "../api/session.js";
import { grantRow } from "../entitlement/entitlement.js";
import { PLUS_LINK_MAX_MONTHS, PLUS_LINK_MAX_USES, addMonths } from "../store/plusLinks.js";
import { verifyAccessJwt } from "./access.js";
import { ADMIN_GRANT_ID, refreshAccounts, sweepAccounts } from "./accounts.js";
import { ADMIN_PAGES, PAGE_HEADERS, renderAdmin, type AdminPage, type AdminView } from "./page.js";
import { signupView, signupsByEmail, signupsCsv } from "./signups.js";
import { SERIES_DAYS, dayKey, recordMetrics } from "./metrics.js";
import { forgetTraffic, trafficView } from "./plausible.js";
import { macReleases } from "./releases.js";
import { BETA_CODE_MAX_USES, BETA_CODE_RE, normalizeBetaCode } from "../store/betaInvites.js";
import { refreshBetaUsage, setBetaLaunch } from "../api/beta.js";

// The admin page, https://api.septena.app/admin (ADR 0043, #198). It shows
// counts, dates and plans, never content. Its only writes are plans:
// links (make, close, take back) and one grant per account (give, take back). Cloudflare Access is in front, and the Worker checks
// the Access token itself. Fail closed: anything missing answers 404.

type Vars = { email: string };
type Ctx = Context<{ Bindings: Env; Variables: Vars }>;

export const admin = new Hono<{ Bindings: Env; Variables: Vars }>();

async function requireAdmin(c: Ctx, next: Next) {
  const origin = new URL(c.env.API_PUBLIC_URL).origin;
  const allowed = (c.env.ADMIN_EMAILS ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  const jwt = c.req.header("CF-Access-Jwt-Assertion");
  if (new URL(c.req.url).origin !== origin || !jwt || allowed.length === 0) return c.notFound();
  const who = await verifyAccessJwt(c.env, jwt);
  if (!who.ok || !allowed.includes(who.email)) {
    logEvent("admin_refused", { reason: who.ok ? "email" : who.reason });
    return c.notFound();
  }
  // Access authenticates with a cookie, so a write must come from this page.
  if (c.req.method !== "GET" && c.req.header("Origin") !== origin) return c.json({ error: "origin_not_allowed" }, 403);
  c.set("email", who.email);
  await next();
}

admin.use("*", requireAdmin);

/// Each page loads only what it shows.
const NEEDS: Record<AdminPage, { accounts?: true; links?: true; signups?: true; history?: true; traffic?: true; releases?: true }> = {
  overview: { accounts: true, signups: true, history: true, traffic: true },
  website: { signups: true, traffic: true },
  product: { accounts: true, releases: true },
  plans: { accounts: true, links: true },
  accounts: { accounts: true },
  signups: { signups: true },
};

async function renderPage(c: Ctx, page: AdminPage, opts: { query?: string; newUrl?: string; newCode?: string; error?: string; betaLookup?: { email: string; tester: BetaTesterStats | null } } = {}): Promise<Response> {
  const accounts = accountStoreFor(c.env);
  if (!accounts) return c.notFound();
  const need = NEEDS[page];
  const query = (opts.query ?? "").trim().slice(0, 200);
  const isEmail = query.includes("@");
  const now = Date.now();
  const [list, plus, signups, found, identity, history, traffic, releases] = await Promise.all([
    need.accounts ? accounts.listAccounts() : [],
    need.links ? accounts.listPlusLinks() : { links: [], uses: [] },
    need.signups ? signupView(c.env) : null,
    isEmail ? signupsByEmail(c.env, query) : [],
    isEmail ? accounts.resolveIdentity("email", query) : null,
    need.history ? accounts.listMetricDays(dayKey(now - (SERIES_DAYS + 7) * 86_400_000)) : [],
    need.traffic ? trafficView(c.env) : { state: "off" as const },
    need.releases ? macReleases(c.env) : [],
  ]);
  const beta = need.links ? { ...(await accounts.listBetaCodes()), newCode: opts.newCode, lookup: opts.betaLookup } : undefined;
  const view: AdminView = {
    admin: c.get("email"), accounts: list, links: plus.links, uses: plus.uses, signups, query, history, traffic, releases,
    emailSignups: found, emailUserId: identity?.userId ?? null, newUrl: opts.newUrl, error: opts.error, now, beta,
  };
  return new Response(renderAdmin(page, view), { status: opts.error ? 400 : 200, headers: PAGE_HEADERS });
}

for (const p of ADMIN_PAGES) admin.get(p.path || "/", (c) => renderPage(c, p.id));

// A search is a POST so an email address never lands in a URL or a log.
admin.post("/search", async (c) => renderPage(c, "accounts", { query: String((await c.req.parseBody()).q ?? "") }));

admin.get("/signups.csv", async (c) => {
  const csv = await signupsCsv(c.env);
  if (csv === null) return c.notFound();
  return new Response(csv, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="septena-signups.csv"',
      "Cache-Control": "no-store",
    },
  });
});

const back = (c: Ctx, page: AdminPage = "overview") =>
  c.redirect(`/admin${ADMIN_PAGES.find((p) => p.id === page)!.path}`, 303);

admin.post("/refresh", async (c) => {
  await sweepAccounts(c.env, 60_000);
  await Promise.all([recordMetrics(c.env), forgetTraffic(c.env)]);
  const page = String((await c.req.parseBody()).back ?? "");
  return back(c, ADMIN_PAGES.some((p) => p.id === page) ? page as AdminPage : "overview");
});

const zPlan = z.enum(["plus", "pro"]);
const zMonths = z.literal("forever").transform(() => null).or(z.coerce.number().int().min(1).max(PLUS_LINK_MAX_MONTHS));

const zLink = z.object({
  label: z.string().trim().min(1).max(60),
  plan: zPlan,
  months: zMonths,
  maxUses: z.coerce.number().int().min(1).max(PLUS_LINK_MAX_USES),
});

admin.post("/links", async (c) => {
  const input = zLink.safeParse(await c.req.parseBody());
  if (!input.success) return renderPage(c, "plans", { error: "A link needs a label (up to 60 characters), a plan, a length and a number of people." });
  const made = await createPlusLink(c.env, input.data);
  return renderPage(c, "plans", { newUrl: made?.url });
});

admin.post("/links/:id/close", async (c) =>
  await accountStoreFor(c.env)?.closePlusLink(c.req.param("id")) ? back(c, "plans") : c.notFound());

admin.post("/links/:id/revoke", async (c) => {
  const { who } = await c.req.parseBody();
  if (typeof who !== "string" || (who !== "all" && !USER_ID_RE.test(who))) return c.notFound();
  const users = await revokePlusLink(c.env, c.req.param("id"), who === "all" ? null : who);
  if (!users) return c.notFound();
  await refreshAccounts(c.env, users);
  return back(c, "plans");
});

// ---- the beta by invite code (ADR 0064) ----

const zDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).transform((d) => Date.parse(`${d}T00:00:00Z`)).refine((n) => Number.isFinite(n));

const zBetaCode = z.object({
  code: z.string().transform(normalizeBetaCode).pipe(z.string().regex(BETA_CODE_RE)),
  label: z.string().trim().min(1).max(60),
  maxUses: z.coerce.number().int().min(1).max(BETA_CODE_MAX_USES),
  ends: z.literal("").transform(() => null).or(zDay).optional(),
});

admin.post("/beta/codes", async (c) => {
  const input = zBetaCode.safeParse(await c.req.parseBody());
  if (!input.success) return renderPage(c, "plans", { error: "A beta code needs 8 to 32 letters or digits, a label and a number of people." });
  const { code, label, maxUses, ends } = input.data;
  const made = await accountStoreFor(c.env)?.createBetaCode({ code, label, maxUses, endsAt: ends ?? null });
  if (!made) return renderPage(c, "plans", { error: `The code ${code} exists already. Pick another.` });
  logEvent("beta_code_created", { codeId: made.id, maxUses });
  return renderPage(c, "plans", { newCode: made.code });
});

admin.post("/beta/codes/:id/close", async (c) =>
  await accountStoreFor(c.env)?.closeBetaCode(c.req.param("id")) ? back(c, "plans") : c.notFound());

// One tester by email: a POST, so the address never lands in a URL or a
// log. It reads the tester's account again before it shows the rows.
admin.post("/beta/tester", async (c) => {
  const email = z.string().trim().toLowerCase().max(254).email().safeParse((await c.req.parseBody()).email);
  if (!email.success) return renderPage(c, "plans", { error: "Type the tester’s email address." });
  const accounts = accountStoreFor(c.env);
  const tester = await accounts?.betaTester(email.data);
  if (tester?.grantedUserId) await refreshBetaUsage(c.env, tester).catch((e) => logEvent("beta_usage_failed", { error: String(e) }));
  const fresh = tester ? await accounts?.betaTester(email.data) : null;
  return renderPage(c, "plans", { betaLookup: { email: email.data, tester: fresh ? testerStats(fresh) : null } });
});

admin.post("/beta/launch", async (c) => {
  const input = z.object({ day: zDay }).safeParse(await c.req.parseBody());
  if (!input.success) return renderPage(c, "plans", { error: "Pick the launch day." });
  if (!(await setBetaLaunch(c.env, input.data.day))) return renderPage(c, "plans", { error: "The launch day is set already." });
  return back(c, "plans");
});

/// One account of the index, or null: an id that is not listed gets no store.
async function knownAccount(c: Ctx): Promise<string | null> {
  const id = c.req.param("userId") ?? "";
  if (!USER_ID_RE.test(id)) return null;
  return await accountStoreFor(c.env)?.hasAccount(id) ? id : null;
}

/// Gives the account a plan, or changes the one this page gave before.
admin.post("/accounts/:userId/plan", async (c) => {
  const userId = await knownAccount(c);
  const input = z.object({ plan: zPlan, months: zMonths }).safeParse(await c.req.parseBody());
  if (!userId || !input.success) return c.notFound();
  const { plan, months } = input.data;
  const now = Date.now();
  await storeFor(c.env, userId).putEntitlement(
    grantRow(ADMIN_GRANT_ID, plan, months === null ? null : addMonths(now, months), "admin page", now), "admin",
  );
  logEvent("entitlement_grant", { userId, name: "admin", plan, months });
  await refreshAccounts(c.env, [userId]);
  return back(c, "accounts");
});

/// Takes back the plan this page gave. A link's grant is the link's to end.
admin.post("/accounts/:userId/plan/end", async (c) => {
  const userId = await knownAccount(c);
  if (!userId) return c.notFound();
  const removed = await storeFor(c.env, userId).deleteEntitlement(ADMIN_GRANT_ID);
  logEvent("entitlement_grant_revoked", { userId, name: "admin", removed });
  await refreshAccounts(c.env, [userId]);
  return back(c, "accounts");
});
