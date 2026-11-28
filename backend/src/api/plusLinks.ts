import type { Context } from "hono";
import { getCookie, setCookie } from "hono/cookie";
import type { Env } from "../env.js";
import { escapeHtml, logEvent, randomId, sha256Base64Url } from "../util.js";
import { refreshAccounts } from "../admin/accounts.js";
import { accountStoreFor } from "../store/AccountStore.js";
import { grantRow, type PaidPlanId } from "../entitlement/entitlement.js";
import { addMonths, plusLinkGrantId, type PlusLink, type PlusLinkInput } from "../store/plusLinks.js";
import { PAGE_CSS, PAIR_TTL_MS, normalizePairCode, openApprovalCode, pairingFor } from "../shadow/oauth.js";
import { pairApproveUrl, pairQrSvg } from "../shadow/pairQr.js";
import { storeFor } from "./session.js";

// Plus links (ADR 0043): https://api.septena.app/plus/<token>.
//
// The page finds out which account to give the plan to with the approval code
// that signs in a device (ADR 0016), so it works for every sign-in provider
// and with every app already installed. The approval mints no session: a
// "plus" code can only finish here. No app has a code field or a link handler
// for this on purpose, because App Review forbids unlocking features in the
// app with anything but an in-app purchase (3.1.1).

type Ctx = Context<{ Bindings: Env }>;

const TOKEN_RE = /^pl_[A-Za-z0-9_-]{32}$/;
const COOKIE = "septena_plus";
const SECRET_RE = /^[A-Za-z0-9_-]{20,64}$/;

/// What the approving app shows: "Sign in on Septena plan link?".
const APPROVAL_NAME = "Septena plan link";

/// The beta grant ends this many months after the public launch (ADR 0064).
export const BETA_PRO_MONTHS_AFTER_LAUNCH = 12;
export const betaGrantEnd = (launchAt: number) => addMonths(launchAt, BETA_PRO_MONTHS_AFTER_LAUNCH);

/// Makes a link. The URL is shown once: only a hash of the token is stored.
export async function createPlusLink(env: Env, input: PlusLinkInput): Promise<{ link: PlusLink; url: string } | null> {
  const accounts = accountStoreFor(env);
  if (!accounts) return null;
  const token = `pl_${randomId(24)}`;
  const link = await accounts.createPlusLink(await sha256Base64Url(token), input);
  logEvent("plus_link_created", { linkId: link.id, plan: input.plan, months: input.months, maxUses: input.maxUses });
  return { link, url: `${env.API_PUBLIC_URL}/plus/${token}` };
}

/// Gives the account the link's plan. Null when the link does not work (any
/// more). Repeats safely with the same account.
/// `atSignIn`: the claim runs inside a sign-in (the beta email grant, ADR
/// 0064), before the session exists, for an account that was just resolved.
export async function claimPlusLink(
  env: Env, tokenHash: string, userId: string, opts: { atSignIn?: boolean } = {},
): Promise<{ linkId: string; plan: PaidPlanId; expiresAt: number | null } | null> {
  const accounts = accountStoreFor(env);
  if (!accounts) return null;
  const store = storeFor(env, userId);
  // A code approved just before the account was deleted must not bring it back.
  if (!opts.atSignIn && !(await store.hasAppSession())) return null;
  const claim = await accounts.claimPlusLink(tokenHash, userId);
  if (!claim.ok) {
    logEvent("plus_link_refused", { userId });
    return null;
  }
  await store.putEntitlement(grantRow(plusLinkGrantId(claim.linkId), claim.plan, claim.expiresAt, "plus link"), "admin");
  // A revoke that ran between the claim and the write wins.
  if (!(await accounts.plusLinkIsLive(claim.linkId, userId))) {
    await store.deleteEntitlement(plusLinkGrantId(claim.linkId));
    return null;
  }
  logEvent("plus_link_claimed", { linkId: claim.linkId, userId });
  // A beta tester's link (ADR 0064): note the account, and after launch the
  // grant ends a year after the launch date.
  const beta = await accounts.betaLinkClaimed(claim.linkId, userId);
  // The grant landed: the tester's checklist becomes a project in their
  // list, once (spec §7). Never fails the claim.
  if (beta) {
    try {
      const { seedBetaProject } = await import("./beta.js");
      await seedBetaProject(env, userId);
    } catch (e) {
      logEvent("beta_seed_failed", { userId, error: String(e) });
    }
  }
  if (beta?.launchAt) {
    const expiresAt = betaGrantEnd(beta.launchAt);
    await store.putEntitlement(grantRow(plusLinkGrantId(claim.linkId), claim.plan, expiresAt, "beta"), "admin");
    return { linkId: claim.linkId, plan: claim.plan, expiresAt };
  }
  return { linkId: claim.linkId, plan: claim.plan, expiresAt: claim.expiresAt };
}

/// Ends the link for everyone (`userId` null) or for one account.
export async function revokePlusLink(env: Env, linkId: string, userId: string | null): Promise<string[] | null> {
  const users = await accountStoreFor(env)?.revokePlusLink(linkId, userId) ?? null;
  for (const id of users ?? []) await storeFor(env, id).deleteEntitlement(plusLinkGrantId(linkId));
  if (users) logEvent("plus_link_revoked", { linkId, accounts: users.length, all: userId === null });
  return users;
}

// ---- pages ----

const PLAN_TITLE: Record<PaidPlanId, string> = { plus: "Plus", pro: "Pro" };

const PLAN_LINE: Record<PaidPlanId, string> = {
  plus: "It syncs your tasks and files to all your devices.",
  pro: "It syncs your tasks and files to all your devices, and you can connect as many agents as you like.",
};

const duration = (months: number | null) =>
  months === null ? "with no end date" : months % 12 === 0
    ? `for ${months === 12 ? "a year" : `${months / 12} years`}`
    : `for ${months === 1 ? "a month" : `${months} months`}`;

const date = (ms: number) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }).format(ms);

function page(title: string, main: string, opts: { status?: number; refresh?: string } = {}): Response {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
${opts.refresh ? `<meta http-equiv="refresh" content="3;url=${escapeHtml(opts.refresh)}">` : ""}
<title>${escapeHtml(title)}</title>
<style>${PAGE_CSS}
  button { width: 100%; padding: 12px; border: 0; border-radius: 10px; background: #1a1a1a; color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
  form { margin: 0 0 14px; }
  @media (prefers-color-scheme: dark) { button { background: #f5f5f5; color: #0a0a0a; } }
</style>
</head>
<body><main class="card">
  ${main}
</main></body>
</html>`;
  return new Response(html, {
    status: opts.status ?? 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "same-origin",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    },
  });
}

const endedPage = () => page("Septena", `<h1>This link no longer works</h1>
  <p>It was used up or taken back. Ask the person who sent it for a new one.</p>`, { status: 404 });

const startForm = (token: string, label: string) =>
  `<form method="post" action="/plus/${token}/start"><button type="submit">${label}</button></form>`;

function tokenOf(c: Ctx): string | null {
  const token = c.req.param("token") ?? "";
  return TOKEN_RE.test(token) ? token : null;
}

/// GET /plus/:token. It shows the gift and starts nothing, so a link preview
/// cannot use it up.
export async function plusLanding(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  const link = token && await accountStoreFor(c.env)?.openPlusLink(await sha256Base64Url(token));
  if (!token || !link) return endedPage();
  return page("Septena", `<h1>Someone gave you Septena ${PLAN_TITLE[link.plan]}</h1>
  <p>Septena ${PLAN_TITLE[link.plan]} is yours ${duration(link.months)}. ${PLAN_LINE[link.plan]} You don’t need a card, and it doesn’t renew.</p>
  ${startForm(token, `Add ${PLAN_TITLE[link.plan]} to my account`)}
  <p class="small">You need Septena on a device where you are signed in. <a href="https://septena.app">Get the app</a> first if you don’t have it, then open this link again.</p>`);
}

/// POST /plus/:token/start. Opens the approval code for this browser.
export async function plusStart(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  const link = token && await accountStoreFor(c.env)?.openPlusLink(await sha256Base64Url(token));
  if (!token || !link) return endedPage();
  const opened = await openApprovalCode(c.env, "plus", APPROVAL_NAME, c.req.header("CF-Connecting-IP"));
  if (!opened.ok) {
    return page("Septena", `<h1>Try again later</h1>
  <p>${opened.reason === "rate_limited" ? "There were too many attempts from your network. Wait an hour, then open the link again." : "Septena could not make a code. Open the link again in a minute."}</p>`,
      { status: opened.reason === "rate_limited" ? 429 : 503 });
  }
  setCookie(c, COOKIE, `${opened.code}.${opened.secret}`, {
    path: "/plus", httpOnly: true, secure: true, sameSite: "Lax", maxAge: PAIR_TTL_MS / 1000,
  });
  return c.redirect(`/plus/${token}/continue`, 303);
}

/// GET /plus/:token/continue. The page asks again every few seconds until the
/// account approves the code.
export async function plusContinue(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  if (!token) return endedPage();
  const [rawCode, secret] = (getCookie(c, COOKIE) ?? "").split(".");
  const code = rawCode ? normalizePairCode(rawCode) : null;
  const expired = () => page("Septena", `<h1>The code expired</h1>
  <p>Your link still works.</p>
  ${startForm(token, "Get a new code")}`, { status: 410 });
  if (!code || !secret || !SECRET_RE.test(secret)) return expired();

  const pairing = pairingFor(c.env, code);
  const s = await pairing.status(secret, "plus");
  if (s.status === "gone") return expired();
  if (s.status === "denied") {
    await pairing.consumeDenied(secret, "plus");
    return page("Septena", `<h1>You declined the code</h1>
  <p>Nothing changed on your account.</p>
  ${startForm(token, "Get a new code")}`);
  }
  if (s.status === "pending") {
    const shown = `${code.slice(0, 4)}-${code.slice(4)}`;
    return page("Septena", `<h1>Approve this code in Septena</h1>
  <p>On a device where you are signed in, open Septena &#9656; Settings &#9656; Account &#9656; Approve a sign-in. Scan this, or enter the code below it:</p>
  <div class="qr">${pairQrSvg(pairApproveUrl(c.env.API_PUBLIC_URL, code), `Code ${shown}`)}</div>
  <div class="code">${escapeHtml(shown)}</div>
  <p>Septena asks whether to sign in on “${escapeHtml(APPROVAL_NAME)}”. Approving tells this page which account gets the plan. It does not give this page your tasks.</p>
  <p class="small">The code works for 10 minutes. Keep this page open.</p>`, { refresh: `/plus/${token}/continue` });
  }

  const taken = await pairing.take(secret, "plus");
  if (!taken) return expired();
  const claim = await claimPlusLink(c.env, await sha256Base64Url(token), taken.approval.userId);
  if (!claim) return endedPage();
  c.executionCtx.waitUntil(refreshAccounts(c.env, [taken.approval.userId]));
  return page("Septena", `<h1>${PLAN_TITLE[claim.plan]} is on</h1>
  <p>${claim.expiresAt === null ? `Your account has Septena ${PLAN_TITLE[claim.plan]}, with no end date.` : `Your account has Septena ${PLAN_TITLE[claim.plan]} until ${date(claim.expiresAt)}.`} Your other devices start syncing when you sign in on them.</p>
  <p class="small">You can close this page. If Septena still shows the old plan, close it and open it again.</p>`);
}
