import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { escapeHtml, logEvent, randomId, sha256Base64Url } from "../util.js";
import { isValidTz } from "../tz.js";
import { accountStoreFor } from "../store/AccountStore.js";
import { emailSignInEnabled, resolveOrCreateEmailAccount, zEmailAddress } from "../api/emailSignIn.js";
import { storeFor } from "../api/session.js";
import { refreshAccounts } from "../admin/accounts.js";
import { SIGN_IN } from "../generated/registries.js";
import { PAGE_CSS, PAIR_MAX_FAILURES, PAIR_TTL_MS, zAgentName } from "./oauth.js";
import { MCP_READ_SCOPE, MCP_WRITE_SCOPE, createAgentKey } from "./tokens.js";

// Headless agent account creation & connection (ADR 0056,
// docs/AGENT_ACCOUNT_CREATION_SPEC.md).
//
// An agent without a browser OAuth flow (Claude Code, Codex, Gemini CLI,
// OpenClaw, scripts) starts with:
//   1. POST /v1/agent/signup/start { email, agentName, access?, timeZone? }
//      -> 202 { status: "pending", requestId, pollSecret, expiresInSeconds, intervalSeconds }
//   2. Septena emails a single-use confirmation link to `email`:
//      GET  /agent/confirm/:token -> shows agentName, access, new vs existing, Terms
//      POST /agent/confirm/:token -> creates/resolves email account & approves (or declines)
//   3. POST /v1/agent/signup/poll { requestId, pollSecret }
//      -> 202 while pending, 410 on denied/expired, 200 with a scoped `sk1.` agent key
//         (never an `sa1.` app session).

const FROM = { email: "signin@septena.app", name: "Septena" };
const REQUEST_ID_PREFIX = "as_";
const REQUEST_ID_RE = /^as_[A-Za-z0-9_-]{16,48}$/;
const SECRET_RE = /^[A-Za-z0-9_-]{20,64}$/;

export const AGENT_SIGNUP_TTL_MS = PAIR_TTL_MS;
export const AGENT_SIGNUP_START_MAX_PER_IP = 10;
export const AGENT_SIGNUP_POLL_MAX_FAILURES_PER_IP = PAIR_MAX_FAILURES;

const NO_STORE = { "Cache-Control": "no-store" };

export const zAgentSignupStartBody = z.object({
  email: zEmailAddress,
  agentName: zAgentName,
  access: z.enum(["read", "write"]).default("write"),
  timeZone: z.string().max(64).refine((tz) => isValidTz(tz), "invalid timeZone").optional(),
}).strict();

export const zAgentSignupPollBody = z.object({
  requestId: z.string().regex(REQUEST_ID_RE),
  pollSecret: z.string().regex(SECRET_RE),
}).strict();

function signupStoreFor(env: Env, requestId: string) {
  return env.PAIRING.get(env.PAIRING.idFromName(`agent-signup:${requestId}`));
}

async function ipRateKey(prefix: string, ip: string): Promise<string> {
  const bucket = Math.floor(Date.now() / AGENT_SIGNUP_TTL_MS);
  const ipHash = await sha256Base64Url(ip.trim());
  return `${prefix}:${ipHash}:${bucket}`;
}

async function ipRateCount(env: Env, prefix: string, ip: string): Promise<number> {
  const raw = await env.STATE.get(await ipRateKey(prefix, ip));
  const n = raw ? Number.parseInt(raw, 10) : 0;
  return Number.isFinite(n) && n > 0 ? n : 0;
}

async function noteIpRateEvent(env: Env, prefix: string, ip: string): Promise<number> {
  const key = await ipRateKey(prefix, ip);
  const prev = await env.STATE.get(key);
  const next = (prev ? Number.parseInt(prev, 10) || 0 : 0) + 1;
  await env.STATE.put(key, String(next), { expirationTtl: AGENT_SIGNUP_TTL_MS / 1000 });
  return next;
}

function accessLine(access: "read" | "write"): string {
  return access === "write" ? "read and change your tasks" : "read your tasks";
}

function scopeFor(access: "read" | "write"): string {
  return access === "write" ? `${MCP_READ_SCOPE} ${MCP_WRITE_SCOPE}` : MCP_READ_SCOPE;
}

export function agentSignupEmailMessage(opts: {
  agentName: string;
  access: "read" | "write";
  confirmUrl: string;
  existingAccount: boolean;
}): { subject: string; text: string; html: string } {
  const verb = accessLine(opts.access);
  const subject = opts.existingAccount
    ? `Connect ${opts.agentName} to your Septena account`
    : `Confirm your Septena account for ${opts.agentName}`;
  const intro = opts.existingAccount
    ? `${opts.agentName} asked to connect to your Septena account. It will be able to ${verb}.`
    : `${opts.agentName} asked to create a Septena account for this email address. It will be able to ${verb}.`;
  const text = [
    intro,
    "",
    `Open this link to review and confirm (works for 10 minutes):`,
    opts.confirmUrl,
    "",
    "If you did not ask this agent to set up Septena, you can ignore this email. Nothing happens unless you open the link and confirm.",
  ].join("\n");
  const safeName = escapeHtml(opts.agentName);
  const safeUrl = escapeHtml(opts.confirmUrl);
  const safeIntro = opts.existingAccount
    ? `<strong>${safeName}</strong> asked to connect to your Septena account. It will be able to ${verb}.`
    : `<strong>${safeName}</strong> asked to create a Septena account for this email address. It will be able to ${verb}.`;
  const buttonLabel = opts.existingAccount ? "Review and connect" : "Review and confirm";
  const html = [
    `<p>${safeIntro}</p>`,
    `<p style="margin:20px 0"><a href="${safeUrl}" style="display:inline-block;padding:11px 18px;border-radius:9px;background:#1a1a1a;color:#ffffff;text-decoration:none;font-weight:600">${buttonLabel}</a></p>`,
    `<p style="font-size:13px;color:#666">Or open this link: <a href="${safeUrl}">${safeUrl}</a></p>`,
    `<p style="font-size:13px;color:#666">It works for 10 minutes. If you did not ask this agent to set up Septena, you can ignore this email. Nothing happens unless you confirm on the page.</p>`,
  ].join("");
  return { subject, text, html };
}

// ---- POST /v1/agent/signup/start ----

export type AgentSignupStartOutcome =
  | { ok: true; data: { status: "pending"; requestId: string; pollSecret: string; expiresInSeconds: number; intervalSeconds: number } }
  | { ok: false; status: 429 | 503; error: string; retryAfterSeconds?: number };

export async function startAgentSignup(
  env: Env,
  body: z.infer<typeof zAgentSignupStartBody>,
  clientIp?: string | null,
): Promise<AgentSignupStartOutcome> {
  const accounts = accountStoreFor(env);
  if (!emailSignInEnabled(env) || !accounts || !env.EMAIL) {
    return { ok: false, status: 503, error: "email_signin_off" };
  }
  if (clientIp) {
    const count = await ipRateCount(env, "rl:agentsignupstart", clientIp);
    if (count >= AGENT_SIGNUP_START_MAX_PER_IP) {
      logEvent("agent_signup_start", { ok: false, reason: "ip_limited" });
      return { ok: false, status: 429, error: "too_many_requests", retryAfterSeconds: AGENT_SIGNUP_TTL_MS / 1000 };
    }
    await noteIpRateEvent(env, "rl:agentsignupstart", clientIp);
  }
  const sendCheck = await accounts.noteAgentSignupSend(body.email);
  if (!sendCheck.ok) {
    logEvent("agent_signup_start", { ok: false, reason: sendCheck.reason });
    return { ok: false, status: 429, error: "too_many_requests", retryAfterSeconds: Math.ceil(sendCheck.retryAfterMs / 1000) };
  }

  const pollSecret = randomId(24);
  const emailSecret = randomId(24);
  const emailSecretHash = await sha256Base64Url(emailSecret);
  const expiresAt = Date.now() + AGENT_SIGNUP_TTL_MS;

  let requestId: string | null = null;
  for (let i = 0; i < 4 && !requestId; i++) {
    const candidate = `${REQUEST_ID_PREFIX}${randomId(18)}`;
    const created = await signupStoreFor(env, candidate).createAgentSignup({
      email: body.email,
      agentName: body.agentName,
      access: body.access,
      timeZone: body.timeZone,
      pollSecret,
      emailSecretHash,
      expiresAt,
    });
    if (created) requestId = candidate;
  }
  if (!requestId) {
    logEvent("agent_signup_start", { ok: false, reason: "unavailable" });
    return { ok: false, status: 503, error: "signup_unavailable" };
  }

  // Only the mailbox owner sees whether the address already has an account;
  // the HTTP reply to the agent is always the same (no email enumeration).
  const existing = await accounts.resolveIdentity("email", body.email);
  const confirmUrl = `${env.API_PUBLIC_URL}/agent/confirm/${requestId}.${emailSecret}`;
  const msg = agentSignupEmailMessage({
    agentName: body.agentName,
    access: body.access,
    confirmUrl,
    existingAccount: existing !== null,
  });
  try {
    await env.EMAIL.send({ from: FROM, to: body.email, subject: msg.subject, text: msg.text, html: msg.html });
  } catch (e) {
    logEvent("agent_signup_start", { ok: false, reason: "send_failed", error: String((e as Error)?.message ?? e).slice(0, 200) });
    return { ok: false, status: 503, error: "email_send_failed" };
  }

  logEvent("agent_signup_start", { ok: true, access: body.access });
  return {
    ok: true,
    data: {
      status: "pending",
      requestId,
      pollSecret,
      expiresInSeconds: AGENT_SIGNUP_TTL_MS / 1000,
      intervalSeconds: 3,
    },
  };
}

// ---- POST /v1/agent/signup/poll ----

export type AgentSignupPollOutcome =
  | { status: "pending" }
  | { status: "denied" }
  | { status: "gone" }
  | { status: "rate_limited" }
  | {
    status: "approved";
    data: {
      status: "approved";
      created: boolean;
      userId: string;
      agentId: string;
      agentName: string;
      access: "read" | "write";
      scope: string;
      key: string;
      mcpUrl: string;
      onboardUrl: string;
      skillUrl: string;
    };
  };

export async function pollAgentSignup(
  env: Env,
  body: z.infer<typeof zAgentSignupPollBody>,
  clientIp?: string | null,
): Promise<AgentSignupPollOutcome> {
  if (clientIp && (await ipRateCount(env, "rl:agentsignuppoll", clientIp)) >= AGENT_SIGNUP_POLL_MAX_FAILURES_PER_IP) {
    logEvent("agent_signup_poll", { ok: false, reason: "rate_limited" });
    return { status: "rate_limited" };
  }
  const store = signupStoreFor(env, body.requestId);
  const status = await store.statusAgentSignup(body.pollSecret);
  if (status === "pending") return { status: "pending" };
  if (status === "denied") {
    const consumed = await store.consumeDeniedAgentSignup(body.pollSecret);
    if (!consumed) return { status: "gone" };
    logEvent("agent_signup_denied", {});
    return { status: "denied" };
  }
  if (status !== "approved") {
    if (clientIp) await noteIpRateEvent(env, "rl:agentsignuppoll", clientIp);
    return { status: "gone" };
  }

  const taken = await store.takeAgentSignup(body.pollSecret);
  if (!taken) {
    if (clientIp) await noteIpRateEvent(env, "rl:agentsignuppoll", clientIp);
    return { status: "gone" };
  }
  const { pending, approval } = taken;

  // Refuse if the account was deleted between confirmation and poll.
  const accounts = accountStoreFor(env);
  const userStore = storeFor(env, approval.userId);
  const [identities, deletedAt] = await Promise.all([
    accounts ? accounts.listIdentitiesForUser(approval.userId) : Promise.resolve([{ userId: approval.userId }]),
    userStore.deletedAt(),
  ]);
  if (identities.length === 0 || deletedAt >= approval.approvedAt) {
    logEvent("agent_signup_poll", { ok: false, reason: "account_deleted" });
    return { status: "gone" };
  }

  const scope = scopeFor(pending.access);
  const createdKey = await createAgentKey(env, approval.userId, pending.agentName, scope, pending.timeZone);
  logEvent("agent_signup_finished", { ok: true, created: approval.created, access: pending.access });
  return {
    status: "approved",
    data: {
      status: "approved",
      created: approval.created,
      userId: approval.userId,
      agentId: createdKey.id,
      agentName: pending.agentName,
      access: pending.access,
      scope: createdKey.scope,
      key: createdKey.key,
      mcpUrl: `${env.API_PUBLIC_URL}/mcp`,
      onboardUrl: `${env.API_PUBLIC_URL}/onboard.md`,
      skillUrl: `${env.API_PUBLIC_URL}/skill.md`,
    },
  };
}

// ---- GET & POST /agent/confirm/:token ----

function parseConfirmToken(raw: string): { requestId: string; emailSecret: string } | null {
  const parts = raw.split(".");
  if (parts.length !== 2) return null;
  const [requestId, emailSecret] = parts;
  if (!REQUEST_ID_RE.test(requestId) || !SECRET_RE.test(emailSecret)) return null;
  return { requestId, emailSecret };
}

function legalHtml(): string {
  const termsLink = `<a href="${escapeHtml(SIGN_IN.legal.terms)}" rel="noopener noreferrer">${escapeHtml(SIGN_IN.copy.termsLabel)}</a>`;
  const privacyLink = `<a href="${escapeHtml(SIGN_IN.legal.privacy)}" rel="noopener noreferrer">${escapeHtml(SIGN_IN.copy.privacyLabel)}</a>`;
  return escapeHtml(SIGN_IN.copy.terms)
    .replace("{terms}", termsLink)
    .replace("{privacy}", privacyLink);
}

function htmlPage(title: string, main: string, status = 200): Response {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>${escapeHtml(title)}</title>
<style>${PAGE_CSS}
  form { margin: 0 0 10px; }
  button { width: 100%; padding: 12px; border: 0; border-radius: 10px; font: inherit; font-size: 15px; font-weight: 600; cursor: pointer; }
  button.primary { background: #1a1a1a; color: #fff; }
  button.secondary { background: transparent; color: #555; border: 1px solid #d0d0d0; }
  a { color: inherit; }
  @media (prefers-color-scheme: dark) {
    button.primary { background: #f5f5f5; color: #0a0a0a; }
    button.secondary { color: #b5b5b5; border-color: #3a3a3a; }
  }
</style>
</head>
<body><main class="card">
  ${main}
</main></body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    },
  });
}

const expiredPage = () => htmlPage(
  "Septena",
  `<h1>This link expired</h1>
  <p>Ask your agent to start again and send a new confirmation link.</p>`,
  410,
);

const alreadyHandledPage = (status: "approved" | "denied") => htmlPage(
  "Septena",
  status === "approved"
    ? `<h1>Already confirmed</h1><p>This request was already confirmed. You can return to your agent.</p>`
    : `<h1>Already declined</h1><p>This request was declined. Nothing changed.</p>`,
  200,
);

function runBackground(c: Context<{ Bindings: Env }>, work: Promise<unknown>): void {
  try {
    c.executionCtx.waitUntil(work);
  } catch {
    void work;
  }
}

/// GET /agent/confirm/:token — renders the confirmation card without mutating
/// state, so mail scanners and link previews never approve or consume it.
export async function confirmPage(c: Context<{ Bindings: Env }>): Promise<Response> {
  if (!emailSignInEnabled(c.env)) return htmlPage("Septena", `<h1>Unavailable</h1><p>Email sign-in is turned off on this server.</p>`, 503);
  const raw = c.req.param("token") ?? "";
  const parsed = parseConfirmToken(raw);
  if (!parsed) return expiredPage();

  const peek = await signupStoreFor(c.env, parsed.requestId).peekAgentSignup(await sha256Base64Url(parsed.emailSecret));
  if (peek.outcome === "not_found") return expiredPage();
  if (peek.outcome === "already_decided") return alreadyHandledPage(peek.status);

  const { pending } = peek;
  const accounts = accountStoreFor(c.env);
  const existing = accounts ? await accounts.resolveIdentity("email", pending.email) : null;
  const name = escapeHtml(pending.agentName);
  const email = escapeHtml(pending.email);
  const verb = accessLine(pending.access);
  const actionUrl = `/agent/confirm/${escapeHtml(raw)}`;

  if (existing) {
    return htmlPage(
      `Connect ${pending.agentName} to Septena`,
      `<h1>Connect ${name} to Septena</h1>
      <p><strong>${name}</strong> wants to connect to your existing Septena account (<strong>${email}</strong>). It will be able to ${verb}.</p>
      <p class="small">You can pause, rename or disconnect this agent anytime in Septena &#9656; Settings &#9656; AI &amp; Agents.</p>
      <form method="post" action="${actionUrl}"><input type="hidden" name="decision" value="approve"><button class="primary" type="submit">Approve connection</button></form>
      <form method="post" action="${actionUrl}"><input type="hidden" name="decision" value="decline"><button class="secondary" type="submit">Decline</button></form>
      <p class="small">If you did not ask ${name} to connect, tap Decline or close this page.</p>`,
    );
  }

  return htmlPage(
    "Create your Septena account",
    `<h1>Create your Septena account</h1>
    <p><strong>${name}</strong> wants to create a Septena account for <strong>${email}</strong> and connect to it. It will be able to ${verb}.</p>
    <p class="small">You can sign in to this account anytime with <strong>${email}</strong> on iPhone, iPad, Mac, Android or web.septena.app, and pause or disconnect ${name} in Settings &#9656; AI &amp; Agents.</p>
    <p class="small">${legalHtml()}</p>
    <form method="post" action="${actionUrl}"><input type="hidden" name="decision" value="approve"><button class="primary" type="submit">Create account &amp; connect ${name}</button></form>
    <form method="post" action="${actionUrl}"><input type="hidden" name="decision" value="decline"><button class="secondary" type="submit">Decline</button></form>
    <p class="small">If you did not ask ${name} to set up Septena, tap Decline or close this page.</p>`,
  );
}

/// POST /agent/confirm/:token — confirms or declines the pending agent signup.
export async function confirmSubmit(c: Context<{ Bindings: Env }>): Promise<Response> {
  const origin = c.req.header("Origin");
  if (origin && origin !== c.env.API_PUBLIC_URL) {
    return htmlPage("Septena", `<h1>Request refused</h1><p>This form can only be submitted from Septena.</p>`, 403);
  }
  const fetchSite = c.req.header("Sec-Fetch-Site");
  if (fetchSite && fetchSite !== "same-origin" && fetchSite !== "none") {
    return htmlPage("Septena", `<h1>Request refused</h1><p>This form can only be submitted from Septena.</p>`, 403);
  }
  if (!emailSignInEnabled(c.env)) {
    return htmlPage("Septena", `<h1>Unavailable</h1><p>Email sign-in is turned off on this server.</p>`, 503);
  }

  const raw = c.req.param("token") ?? "";
  const parsed = parseConfirmToken(raw);
  if (!parsed) return expiredPage();

  const form = await c.req.formData().catch(() => null);
  const decision = String(form?.get("decision") ?? "");
  if (decision !== "approve" && decision !== "decline") {
    return htmlPage("Septena", `<h1>Invalid request</h1><p>Open the link from your email and try again.</p>`, 400);
  }

  const secretHash = await sha256Base64Url(parsed.emailSecret);
  const store = signupStoreFor(c.env, parsed.requestId);
  const peek = await store.peekAgentSignup(secretHash);
  if (peek.outcome === "not_found") return expiredPage();
  if (peek.outcome === "already_decided") return alreadyHandledPage(peek.status);

  const { pending } = peek;

  if (decision === "decline") {
    const res = await store.denyAgentSignup(secretHash);
    if (res === "not_found") return expiredPage();
    if (res === "already_used") return alreadyHandledPage("denied");
    logEvent("agent_signup_confirmed", { ok: false, decision: "decline" });
    return htmlPage(
      "Request declined",
      `<h1>Request declined</h1>
      <p><strong>${escapeHtml(pending.agentName)}</strong> was not connected and nothing changed.</p>
      <p class="small">You can close this page.</p>`,
    );
  }

  const { userId, created } = await resolveOrCreateEmailAccount(c.env, pending.email);
  const res = await store.approveAgentSignup(secretHash, { userId, created, approvedAt: Date.now() });
  if (res === "not_found") return expiredPage();
  if (res === "already_used") return alreadyHandledPage("approved");

  runBackground(c, refreshAccounts(c.env, [userId]));
  logEvent("agent_signup_confirmed", { ok: true, created, access: pending.access });

  const name = escapeHtml(pending.agentName);
  const email = escapeHtml(pending.email);
  return htmlPage(
    created ? "Your Septena account is ready" : `${pending.agentName} is connected`,
    `<h1>${created ? "Your Septena account is ready" : `${name} is connected`}</h1>
    <p><strong>${name}</strong> is now connected to <strong>${email}</strong>. You can go back to your agent.</p>
    <p>To see your tasks in Septena, sign in with <strong>${email}</strong> on iPhone, iPad, Mac, Android or <a href="https://web.septena.app">web.septena.app</a>.</p>
    <p class="small">You can pause, rename or disconnect ${name} anytime in Settings &#9656; AI &amp; Agents.</p>`,
  );
}

export { NO_STORE };
