// Contact Support (ADR 0054, docs/SUPPORT_SPEC.md §5), mounted at /v1/support.
//
// Sender: a bearer session → `user:<userId>`. Signed out, the app sends its
// support key in X-Septena-Support-Key (32 random bytes, base64url) →
// `install:<sha256>`; only the hash is kept, and the message needs an email.
// A request with both moves the signed-out conversation to the account.
// Never log a message body, an email or a support key.

import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { authenticate } from "../api/session.js";
import { logEvent, sha256Base64Url } from "../util.js";
import { supportStoreFor, SUPPORT_RETENTION_MS, type SupportStore } from "./store.js";
import { SIGNATURE_HEADER, TIMESTAMP_HEADER, forward, intakeKey, verify, zDiagnostics, zReply } from "./starlings.js";

export const SUPPORT_KEY_HEADER = "X-Septena-Support-Key";
export const MAX_PER_MINUTE = 5;
export const MAX_PER_DAY = 30;
/** Signed-out sends per IP per day, across support keys. */
export const MAX_PER_IP_DAY = 30;
export const MESSAGE_MAX_CHARS = 4_000;
const RETRY_BATCH = 50;
/** No-reply: the person answers in the app (the mail says so). */
const FROM = { email: "noreply@septena.app", name: "Septena" };

export const zSupportMessageBody = z.object({
  message_id: z.string().uuid(),
  text: z.string().trim().min(1).max(MESSAGE_MAX_CHARS),
  email: z.string().trim().toLowerCase().email().max(320).optional(),
  name: z.string().trim().min(1).max(120).optional(),
  diagnostics: zDiagnostics.optional(),
}).strict();

type Ctx = Context<{ Bindings: Env }>;
type Sender = { ref: string; userId: string | null; installRef: string | null };

const zSupportKey = z.string().regex(/^[A-Za-z0-9_-]{43}$/);

/** Who is asking, or a 401 Response. */
async function sender(c: Ctx): Promise<Sender | Response> {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  const keyHeader = c.req.header(SUPPORT_KEY_HEADER);
  let installRef: string | null = null;
  if (keyHeader !== undefined) {
    if (!zSupportKey.safeParse(keyHeader).success) return c.json({ error: "invalid_support_key" }, 400);
    installRef = `install:${await sha256Base64Url(keyHeader)}`;
  }
  if (token) {
    const claims = await authenticate(c.env, token);
    if (!claims) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
    return { ref: `user:${claims.userId}`, userId: claims.userId, installRef };
  }
  if (installRef) return { ref: installRef, userId: null, installRef };
  return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
}

function store(c: Ctx): DurableObjectStub<SupportStore> | Response {
  return supportStoreFor(c.env) ?? c.json({ error: "not_configured" }, 503);
}

async function ipOverLimit(env: Env, ip: string | undefined): Promise<boolean> {
  if (!ip) return false;
  const day = Math.floor(Date.now() / 86_400_000);
  const key = `rl:support:${await sha256Base64Url(ip.trim())}:${day}`;
  const n = Number.parseInt((await env.STATE.get(key)) ?? "0", 10) || 0;
  if (n >= MAX_PER_IP_DAY) return true;
  await env.STATE.put(key, String(n + 1), { expirationTtl: 86_400 });
  return false;
}

function background(c: Ctx, work: Promise<unknown>): void {
  try {
    c.executionCtx.waitUntil(work);
  } catch {
    void work;
  }
}

export const support = new Hono<{ Bindings: Env }>();

support.post("/messages", async (c) => {
  if (!intakeKey(c.env)) return c.json({ error: "not_configured" }, 503);
  const who = await sender(c);
  if (who instanceof Response) return who;
  const stub = store(c);
  if (stub instanceof Response) return stub;

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const parsed = zSupportMessageBody.safeParse(body);
  if (!parsed.success) return c.json({ error: "invalid_request", issues: parsed.error.issues.slice(0, 20) }, 400);
  const msg = parsed.data;
  if (!who.userId && !msg.email) return c.json({ error: "email_required" }, 400);

  if (who.userId && who.installRef) await stub.moveConversation(who.installRef, who.ref);

  const now = Date.now();
  if ((await stub.countInboundSince(who.ref, now - 60_000)) >= MAX_PER_MINUTE
    || (await stub.countInboundSince(who.ref, now - 86_400_000)) >= MAX_PER_DAY) {
    logEvent("support_message", { ok: false, reason: "rate_limited" });
    return c.json({ error: "too_many_requests" }, 429, { "Retry-After": "60" });
  }
  if (!who.userId && (await ipOverLimit(c.env, c.req.header("CF-Connecting-IP")))) {
    logEvent("support_message", { ok: false, reason: "ip_limited" });
    return c.json({ error: "too_many_requests" }, 429, { "Retry-After": "3600" });
  }

  const added = await stub.addInbound({
    id: msg.message_id,
    reporterRef: who.ref,
    text: msg.text,
    email: msg.email ?? null,
    name: msg.name ?? null,
    diagnostics: msg.diagnostics ? JSON.stringify(msg.diagnostics) : null,
    now,
  });
  if ("conflict" in added) return c.json({ error: "message_id_taken" }, 409);
  const { message, created } = added;
  if (created) {
    background(c, (async () => {
      const pending = { id: message.id, reporterRef: who.ref, text: msg.text, email: msg.email ?? null, name: msg.name ?? null,
        diagnostics: msg.diagnostics ? JSON.stringify(msg.diagnostics) : null };
      if (await forward(c.env, pending)) await stub.markSent(message.id);
    })());
  }
  logEvent("support_message", { ok: true, created, signedIn: !!who.userId, diagnostics: !!msg.diagnostics });
  return c.json({ message }, 202, { "Cache-Control": "no-store" });
});

support.get("/messages", async (c) => {
  const who = await sender(c);
  if (who instanceof Response) return who;
  const stub = store(c);
  if (stub instanceof Response) return stub;
  if (who.userId && who.installRef) await stub.moveConversation(who.installRef, who.ref);
  return c.json(await stub.conversation(who.ref), 200, { "Cache-Control": "no-store" });
});

support.post("/read", async (c) => {
  const who = await sender(c);
  if (who instanceof Response) return who;
  const stub = store(c);
  if (stub instanceof Response) return stub;
  await stub.markRead(who.ref, Date.now());
  return c.body(null, 204);
});

support.post("/replies", async (c) => {
  const key = intakeKey(c.env);
  if (!key) return c.json({ error: "not_configured" }, 503);
  const rawBody = await c.req.text();
  if (rawBody.length > 64_000) return c.json({ error: "too_large" }, 413);
  const ok = await verify(key, "reply", {
    timestamp: c.req.header(TIMESTAMP_HEADER) ?? "",
    signature: c.req.header(SIGNATURE_HEADER) ?? "",
    rawBody,
    now: Date.now(),
  });
  if (!ok) {
    logEvent("support_reply", { ok: false, reason: "bad_signature" });
    return c.json({ error: "unauthorized" }, 401);
  }
  let json: unknown;
  try {
    json = JSON.parse(rawBody);
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const parsed = zReply.safeParse(json);
  if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
  const reply = parsed.data;
  const stub = store(c);
  if (stub instanceof Response) return stub;
  const saved = await stub.addReply({
    id: reply.message_id, reporterRef: reply.reporter_ref, text: reply.text, authorName: reply.author.name, now: Date.now(),
  });
  if (saved.created && saved.email) background(c, mailReply(c.env, saved.email, reply.text));
  logEvent("support_reply", { ok: true, created: saved.created, mailed: saved.created && !!saved.email });
  return c.body(null, 204);
});

export function replyMail(text: string): { subject: string; text: string } {
  return {
    subject: "Septena support replied",
    text: `${text}\n\nTo answer, open Septena, then Settings, About, Contact Support.\n\nSeptena`,
  };
}

async function mailReply(env: Env, to: string, text: string): Promise<void> {
  if (!env.EMAIL) return;
  const mail = replyMail(text);
  try {
    await env.EMAIL.send({ from: FROM, to, subject: mail.subject, text: mail.text });
    logEvent("support_reply_mail", { ok: true });
  } catch (e) {
    logEvent("support_reply_mail", { ok: false, error: String((e as Error)?.message ?? e).slice(0, 200) });
  }
}

/** Cron: send pending messages again, oldest first, and drop rows past retention. */
export async function sweepSupport(env: Env): Promise<{ sent: number; purged: number }> {
  const stub = supportStoreFor(env);
  if (!stub) return { sent: 0, purged: 0 };
  let sent = 0;
  if (intakeKey(env)) {
    for (const message of await stub.pending(RETRY_BATCH)) {
      if (!(await forward(env, message))) break;
      await stub.markSent(message.id);
      sent += 1;
    }
  }
  const purged = await stub.purgeBefore(Date.now() - SUPPORT_RETENTION_MS);
  if (sent || purged) logEvent("support_sweep", { sent, purged });
  return { sent, purged };
}
