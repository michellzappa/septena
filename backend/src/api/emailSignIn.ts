import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent, sha256Base64Url } from "../util.js";
import { accountStoreFor } from "../store/AccountStore.js";
import { hasUsedTrial, markTrialUsed, startTrialOnce } from "../entitlement/entitlement.js";
import { issueSession, type IssuedSession } from "./session.js";

// Sign-in S2: email one-time code (ADR 0016 decision 2, ADR 0047, issue #169).
//
// POST /v1/auth/email/start  {email}             -> 202, a 6-digit code is mailed
// POST /v1/auth/email/verify {email, code, ...}  -> the session; a new address
//                                                  creates an account
//
// The code lives in the global AccountStore (one writer, so a verify never
// reads a stale code the way KV could), stored hashed. The start answer is the
// same whether or not the address has an account. Limits: 3 codes per address
// per 10 minutes, 5 wrong codes lock the address for the window, and per-IP
// limits on start and on failed verifies.

export const EMAIL_CODE_LENGTH = 6;
const IP_WINDOW_MS = 10 * 60 * 1000;
const IP_MAX_STARTS = 20;
const IP_MAX_VERIFY_FAILURES = 30;
const FROM = { email: "signin@septena.app", name: "Septena" };

export const zEmailAddress = z.string().trim().toLowerCase().max(254).email();

export const zEmailStartBody = z.object({ email: zEmailAddress }).strict();

export const zEmailVerifyBody = z.object({
  email: zEmailAddress,
  code: z.string().trim().regex(/^\d{6}$/),
  /// Web clients ask for `"cookie"` (docs/WEB_CLIENT_SPEC.md §4).
  sessionMode: z.enum(["body", "cookie"]).optional(),
}).strict();

/// Email sign-in is on when the send binding exists and the switch is on.
/// The switch stays off until Terms of Use and the privacy copy ship (#564).
export function emailSignInEnabled(env: Env): boolean {
  return env.EMAIL_SIGNIN === "true" && !!env.EMAIL;
}

/// What `GET /v1/auth/methods` answers. Device approval and Apple are always
/// served by this backend; a client still hides a method its platform cannot
/// run (registry/sign-in.json).
export function enabledSignInMethods(env: Env): string[] {
  const methods = ["apple"];
  if (emailSignInEnabled(env)) methods.push("email");
  methods.push("device");
  return methods;
}

export function newEmailCode(): string {
  // Rejection sampling keeps every code equally likely.
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000;
  const buf = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buf);
    if (buf[0] < limit) return String(buf[0] % 1_000_000).padStart(EMAIL_CODE_LENGTH, "0");
  }
}

export async function emailCodeHash(email: string, code: string): Promise<string> {
  return sha256Base64Url(`email-code:${email}:${code}`);
}

async function ipCount(env: Env, prefix: string, ip: string): Promise<{ key: string; count: number }> {
  const bucket = Math.floor(Date.now() / IP_WINDOW_MS);
  const key = `${prefix}:${await sha256Base64Url(ip.trim())}:${bucket}`;
  const raw = await env.STATE.get(key);
  const n = raw ? Number.parseInt(raw, 10) : 0;
  return { key, count: Number.isFinite(n) && n > 0 ? n : 0 };
}

async function ipNote(env: Env, key: string, count: number): Promise<void> {
  await env.STATE.put(key, String(count + 1), { expirationTtl: IP_WINDOW_MS / 1000 });
}

export function emailMessage(code: string): { subject: string; text: string; html: string } {
  const subject = `Your Septena code: ${code}`;
  const text = [
    `Your Septena sign-in code is ${code}.`,
    "",
    "It works for 10 minutes. If you did not ask for it, you can ignore this email. Nobody can sign in without the code.",
  ].join("\n");
  const html = `<p>Your Septena sign-in code is</p><p style="font-size:28px;font-weight:600;letter-spacing:4px;font-family:ui-monospace,Menlo,monospace">${code}</p><p>It works for 10 minutes. If you did not ask for it, you can ignore this email. Nobody can sign in without the code.</p>`;
  return { subject, text, html };
}

export type EmailStartOutcome =
  | { ok: true; expiresInSeconds: number }
  | { ok: false; status: 429 | 503; error: string; retryAfterSeconds?: number };

export async function startEmailSignIn(
  env: Env,
  body: z.infer<typeof zEmailStartBody>,
  clientIp?: string | null,
): Promise<EmailStartOutcome> {
  const accounts = accountStoreFor(env);
  if (!emailSignInEnabled(env) || !accounts || !env.EMAIL) {
    return { ok: false, status: 503, error: "email_signin_off" };
  }
  if (clientIp) {
    const { key, count } = await ipCount(env, "rl:emailstart", clientIp);
    if (count >= IP_MAX_STARTS) {
      logEvent("email_signin_start", { ok: false, reason: "ip_limited" });
      return { ok: false, status: 429, error: "too_many_requests", retryAfterSeconds: IP_WINDOW_MS / 1000 };
    }
    await ipNote(env, key, count);
  }
  const code = newEmailCode();
  const issued = await accounts.issueEmailCode(body.email, await emailCodeHash(body.email, code));
  if (!issued.ok) {
    logEvent("email_signin_start", { ok: false, reason: issued.reason });
    return { ok: false, status: 429, error: "too_many_requests", retryAfterSeconds: Math.ceil(issued.retryAfterMs / 1000) };
  }
  const msg = emailMessage(code);
  try {
    await env.EMAIL.send({ from: FROM, to: body.email, subject: msg.subject, text: msg.text, html: msg.html });
  } catch (e) {
    logEvent("email_signin_start", { ok: false, reason: "send_failed", error: String((e as Error)?.message ?? e).slice(0, 200) });
    return { ok: false, status: 503, error: "email_send_failed" };
  }
  logEvent("email_signin_start", { ok: true });
  return { ok: true, expiresInSeconds: Math.round((issued.expiresAt - Date.now()) / 1000) };
}

export type EmailVerifyOutcome =
  | { ok: true; session: IssuedSession; created: boolean }
  | { ok: false; status: 401 | 410 | 429 | 503; error: string; attemptsLeft?: number };

export async function verifyEmailSignIn(
  env: Env,
  body: z.infer<typeof zEmailVerifyBody>,
  clientIp?: string | null,
): Promise<EmailVerifyOutcome> {
  const accounts = accountStoreFor(env);
  if (!emailSignInEnabled(env) || !accounts) return { ok: false, status: 503, error: "email_signin_off" };
  let ip: { key: string; count: number } | null = null;
  if (clientIp) {
    ip = await ipCount(env, "rl:emailverify", clientIp);
    if (ip.count >= IP_MAX_VERIFY_FAILURES) {
      logEvent("email_signin_verify", { ok: false, reason: "ip_limited" });
      return { ok: false, status: 429, error: "too_many_attempts" };
    }
  }
  const checked = await accounts.checkEmailCode(body.email, await emailCodeHash(body.email, body.code));
  if (checked.status !== "ok") {
    if (ip) await ipNote(env, ip.key, ip.count);
    logEvent("email_signin_verify", { ok: false, reason: checked.status });
    if (checked.status === "invalid") return { ok: false, status: 401, error: "invalid_code", attemptsLeft: checked.attemptsLeft };
    if (checked.status === "locked") return { ok: false, status: 429, error: "too_many_attempts" };
    return { ok: false, status: 410, error: "expired_or_unknown" };
  }
  const { userId, created } = await accounts.resolveOrCreateIdentity("email", body.email);
  if (created) {
    // A new account starts with the trial, once per address: deleting the
    // account and signing up again with the same address does not give a
    // second one (spec §6.4 finding 4).
    const marker = `e_${await sha256Base64Url(`email:${body.email}`)}`;
    if (!(await hasUsedTrial(env, marker))) {
      if (await startTrialOnce(env, userId)) logEvent("trial_started", { userId });
      await markTrialUsed(env, marker);
    }
  }
  logEvent("email_signin_verify", { ok: true, created });
  return { ok: true, session: await issueSession(env, userId), created };
}
