// The Starlings app channel (Starlings docs/SUPPORT.md §App channel,
// packages/contracts/src/app-intake.ts). Both directions carry
// `x-starlings-timestamp` (Unix ms) and `x-starlings-signature`, the hex
// HMAC-SHA256 of `<direction>.<timestamp>.<rawBody>`. The key is
// APP_INTAKE_KEY, 64 hex characters, decoded to its 32 bytes (never the hex
// text). The wire is fixed with Starlings: a change here is a change there.

import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import type { PendingMessage } from "./store.js";

export const TIMESTAMP_HEADER = "x-starlings-timestamp";
export const SIGNATURE_HEADER = "x-starlings-signature";
/** A signature older or newer than this is refused (Starlings uses the same window). */
export const SIGNATURE_WINDOW_MS = 5 * 60 * 1000;
export const DEFAULT_INTAKE_URL = "https://septena.starlings.work/api/support/app-intake";
const FORWARD_TIMEOUT_MS = 10_000;

export type Direction = "intake" | "reply";

export const SUPPORT_PLATFORMS = ["ios", "ipados", "macos", "android", "web"] as const;

/// What the app sends with "Include diagnostics" on (spec §4). Never task content.
export const zDiagnostics = z.object({
  platform: z.enum(SUPPORT_PLATFORMS),
  osVersion: z.string().trim().max(40).optional(),
  deviceModel: z.string().trim().max(60).optional(),
  appVersion: z.string().trim().max(40).optional(),
  build: z.number().int().nonnegative().optional(),
  signedIn: z.boolean().optional(),
  plan: z.string().trim().max(20).optional(),
  lastSyncAt: z.string().trim().max(40).optional(),
  lastSyncError: z.string().trim().max(80).optional(),
  lastSyncRequestId: z.string().trim().max(80).optional(),
  storeFailures: z.number().int().nonnegative().max(1_000_000).optional(),
}).strict();
export type Diagnostics = z.infer<typeof zDiagnostics>;

/// Starlings → backend: a member's reply (appIntakeReplySchema).
export const zReply = z.object({
  message_id: z.string().min(1).max(255),
  reporter_ref: z.string().min(1).max(255),
  text: z.string().min(1).max(20_000),
  author: z.object({ name: z.string().max(200) }).strict(),
}).strict();
export type Reply = z.infer<typeof zReply>;

/** The 32 bytes APP_INTAKE_KEY decodes to, or null when it is missing or malformed. */
export function intakeKey(env: Env): Uint8Array<ArrayBuffer> | null {
  const hex = (env.APP_INTAKE_KEY ?? "").trim();
  if (!/^[0-9a-f]{64}$/i.test(hex)) return null;
  return Uint8Array.from(hex.match(/../g)!, (pair) => parseInt(pair, 16));
}

async function hmacKey(raw: Uint8Array<ArrayBuffer>, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, [usage]);
}

export function signedString(direction: Direction, timestamp: string, rawBody: string): string {
  return `${direction}.${timestamp}.${rawBody}`;
}

export async function sign(key: Uint8Array<ArrayBuffer>, direction: Direction, timestamp: string, rawBody: string): Promise<string> {
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(key, "sign"), new TextEncoder().encode(signedString(direction, timestamp, rawBody)));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Checks a signature in constant time (crypto.subtle.verify) and the timestamp window. */
export async function verify(
  key: Uint8Array<ArrayBuffer>,
  direction: Direction,
  input: { timestamp: string; signature: string; rawBody: string; now: number },
): Promise<boolean> {
  if (!/^\d{1,16}$/.test(input.timestamp)) return false;
  if (Math.abs(input.now - Number(input.timestamp)) > SIGNATURE_WINDOW_MS) return false;
  if (!/^[0-9a-f]{64}$/i.test(input.signature)) return false;
  const mac = Uint8Array.from(input.signature.match(/../g)!, (pair) => parseInt(pair, 16));
  return crypto.subtle.verify("HMAC", await hmacKey(key, "verify"), mac, new TextEncoder().encode(signedString(direction, input.timestamp, input.rawBody)));
}

/** The appIntakeSubmissionSchema body for one stored message. */
export function intakeBody(message: PendingMessage): Record<string, unknown> {
  let diagnostics: Diagnostics | null = null;
  if (message.diagnostics) {
    const parsed = zDiagnostics.safeParse(JSON.parse(message.diagnostics));
    diagnostics = parsed.success ? parsed.data : null;
  }
  const reporter: Record<string, string> = { ref: message.reporterRef };
  if (message.name) reporter.name = message.name;
  if (message.email) reporter.email = message.email;
  const text = diagnostics ? `${message.text}\n\n${diagnosticsLine(diagnostics)}` : message.text;
  const body: Record<string, unknown> = { message_id: message.id, kind: diagnostics ? "report" : "message", reporter, text };
  if (diagnostics) {
    body.report = {
      platform: diagnostics.platform,
      ...(diagnostics.appVersion ? { app_version: diagnostics.appVersion } : {}),
      ...(diagnostics.build !== undefined ? { build: diagnostics.build } : {}),
    };
  }
  return body;
}

/**
 * The diagnostics Starlings' own metadata line does not carry, as one line
 * under the text. Platform, version and build travel in `report`.
 */
export function diagnosticsLine(d: Diagnostics): string {
  return [
    d.osVersion ? `OS ${d.osVersion}` : null,
    d.deviceModel ?? null,
    d.signedIn === undefined ? null : d.signedIn ? "signed in" : "signed out",
    d.plan ? `plan ${d.plan}` : null,
    d.lastSyncAt ? `last sync ${d.lastSyncAt}` : null,
    d.lastSyncError ? `sync error ${d.lastSyncError}` : null,
    d.lastSyncRequestId ? `request ${d.lastSyncRequestId}` : null,
    d.storeFailures ? `${d.storeFailures} failed saves` : null,
  ].filter(Boolean).join(" · ") || "diagnostics: none";
}

/** Sends one stored message to Starlings. True when Starlings took it. */
export async function forward(env: Env, message: PendingMessage, fetcher: typeof fetch = fetch): Promise<boolean> {
  const key = intakeKey(env);
  if (!key) {
    logEvent("support_forward", { ok: false, reason: "not_configured" });
    return false;
  }
  const raw = JSON.stringify(intakeBody(message));
  const timestamp = String(Date.now());
  try {
    const res = await fetcher(env.STARLINGS_INTAKE_URL || DEFAULT_INTAKE_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        [TIMESTAMP_HEADER]: timestamp,
        [SIGNATURE_HEADER]: await sign(key, "intake", timestamp, raw),
      },
      body: raw,
      signal: AbortSignal.timeout(FORWARD_TIMEOUT_MS),
    });
    await res.body?.cancel().catch(() => undefined);
    logEvent("support_forward", { ok: res.ok, status: res.status });
    return res.ok;
  } catch (e) {
    logEvent("support_forward", { ok: false, reason: "network", error: String((e as Error)?.name ?? "error") });
    return false;
  }
}
