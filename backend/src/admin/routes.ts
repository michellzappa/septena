import { Hono, type Context, type Next } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { createPlusLink, revokePlusLink } from "../api/plusLinks.js";
import { USER_ID_RE, accountStoreFor } from "../store/AccountStore.js";
import { PLUS_LINK_MAX_MONTHS, PLUS_LINK_MAX_USES } from "../store/plusLinks.js";
import { verifyAccessJwt } from "./access.js";
import { refreshAccounts, sweepAccounts } from "./accounts.js";
import { PAGE_HEADERS, renderAdmin } from "./page.js";
import { signupView, signupsByEmail, signupsCsv } from "./signups.js";

// The admin page, https://api.septena.app/admin (ADR 0043, #198). It shows
// counts, dates and plans, never content. Its only writes are Plus links:
// make, close, revoke. Cloudflare Access is in front, and the Worker checks
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

async function renderPage(c: Ctx, opts: { query?: string; newUrl?: string; error?: string } = {}): Promise<Response> {
  const accounts = accountStoreFor(c.env);
  if (!accounts) return c.notFound();
  const query = (opts.query ?? "").trim().slice(0, 200);
  const isEmail = query.includes("@");
  const [list, plus, signups, found, identity] = await Promise.all([
    accounts.listAccounts(),
    accounts.listPlusLinks(),
    signupView(c.env),
    isEmail ? signupsByEmail(c.env, query) : [],
    isEmail ? accounts.resolveIdentity("email", query) : null,
  ]);
  const html = renderAdmin({
    admin: c.get("email"), accounts: list, links: plus.links, uses: plus.uses, signups, query,
    emailSignups: found, emailUserId: identity?.userId ?? null, newUrl: opts.newUrl, error: opts.error, now: Date.now(),
  });
  return new Response(html, { status: opts.error ? 400 : 200, headers: PAGE_HEADERS });
}

admin.get("/", (c) => renderPage(c));

// A search is a POST so an email address never lands in a URL or a log.
admin.post("/search", async (c) => renderPage(c, { query: String((await c.req.parseBody()).q ?? "") }));

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

const back = (c: Ctx) => c.redirect("/admin", 303);

admin.post("/refresh", async (c) => {
  await sweepAccounts(c.env, 60_000);
  return back(c);
});

const zLink = z.object({
  label: z.string().trim().min(1).max(60),
  months: z.literal("forever").transform(() => null).or(z.coerce.number().int().min(1).max(PLUS_LINK_MAX_MONTHS)),
  maxUses: z.coerce.number().int().min(1).max(PLUS_LINK_MAX_USES),
});

admin.post("/links", async (c) => {
  const input = zLink.safeParse(await c.req.parseBody());
  if (!input.success) return renderPage(c, { error: "A link needs a label (up to 60 characters), a length and a number of people." });
  const made = await createPlusLink(c.env, input.data);
  return renderPage(c, { newUrl: made?.url });
});

admin.post("/links/:id/close", async (c) =>
  await accountStoreFor(c.env)?.closePlusLink(c.req.param("id")) ? back(c) : c.notFound());

admin.post("/links/:id/revoke", async (c) => {
  const { who } = await c.req.parseBody();
  if (typeof who !== "string" || (who !== "all" && !USER_ID_RE.test(who))) return c.notFound();
  const users = await revokePlusLink(c.env, c.req.param("id"), who === "all" ? null : who);
  if (!users) return c.notFound();
  await refreshAccounts(c.env, users);
  return back(c);
});
