import type { Env } from "../env.js";
import { base64url, logEvent } from "../util.js";

// APNs HTTP/2 push sender for agent question notifications (F1b #213,
// docs/TASK_FACTORY_SPEC.md §8).
//
// Zero npm dependencies: signs ES256 provider JWTs with Web Crypto
// (`crypto.subtle`) and delivers alert pushes via Workers `fetch` (HTTP/2).
// When APNs secrets are unset, every send no-ops cleanly with a structured
// warning so task writes and local dev never fail.

export type PushPlatform = "ios" | "watchos";

export interface PushTokenRow {
  token: string;
  deviceId: string | null;
  platform: PushPlatform;
  sandbox: boolean;
  updatedAt: string;
}

export interface AgentQuestionPush {
  taskId: string;
  taskTitle: string;
  turnSeq: number;
  step: string;
  question: string | null;
  note: string | null;
  options: string[];
}

/// An agent handed work over to Review. `note` says what to check.
export interface AgentReviewPush {
  taskId: string;
  taskTitle: string;
  note: string;
}

/// A question carries `turnSeq`; a hand-off does not.
export type AgentPush = AgentQuestionPush | AgentReviewPush;

const isQuestion = (push: AgentPush): push is AgentQuestionPush => "turnSeq" in push;

export interface ApnsConfig {
  keyPem: string;
  keyId: string;
  teamId: string;
  bundleId: string;
  /// Explicit override from `APNS_SANDBOX` ("true" / "false"); null = use each token's flag.
  sandboxOverride: boolean | null;
}

export interface ApnsBatchResult {
  attempted: number;
  delivered: number;
  pruned: string[];
  skipped?: "missing_secrets" | "no_tokens";
}

export interface ApnsSendOptions {
  fetchFn?: typeof fetch;
  nowMs?: number;
}

export const APNS_PROD_HOST = "https://api.push.apple.com";
export const APNS_SANDBOX_HOST = "https://api.sandbox.push.apple.com";
export const APNS_DEFAULT_BUNDLE_ID = "com.septena.tasks";
export const AGENT_QUESTION_CATEGORY = "AGENT_QUESTION";
/// No buttons: a hand-off is accepted after a look, not from the lock screen.
export const AGENT_REVIEW_CATEGORY = "AGENT_REVIEW";
export const MAX_NOTIFICATION_OPTIONS = 3;

/// APNs requires provider JWTs to be rotated before 60 minutes (and not more
/// often than every 20 minutes). Refresh after 45 minutes (<50 min).
const JWT_CACHE_TTL_MS = 45 * 60 * 1000;

interface CachedJwt {
  cacheKey: string;
  token: string;
  issuedAtMs: number;
}

let cachedJwt: CachedJwt | null = null;
let testFetchOverride: typeof fetch | null = null;

/// Clears the in-memory ES256 provider JWT cache (for unit tests).
export function clearApnsJwtCache(): void {
  cachedJwt = null;
}

/// Installs a custom `fetch` implementation for tests, or restores default `fetch` when null.
export function setApnsFetchForTests(fn: typeof fetch | null): void {
  testFetchOverride = fn;
}

/// Reads APNs configuration from Worker env. Returns null if any required
/// secret (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`) is missing.
export function readApnsConfig(env: Partial<Env>): ApnsConfig | null {
  const keyPem = env.APNS_KEY?.trim();
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  if (!keyPem || !keyId || !teamId) return null;

  const bundleId = env.APNS_BUNDLE_ID?.trim() || APNS_DEFAULT_BUNDLE_ID;
  const rawSandbox = env.APNS_SANDBOX?.trim().toLowerCase();
  const sandboxOverride = rawSandbox === "true" ? true : rawSandbox === "false" ? false : null;

  return { keyPem, keyId, teamId, bundleId, sandboxOverride };
}

/// Decodes a PKCS#8 `.p8` PEM string (supporting both literal `\n` escapes and
/// real newlines) into raw DER bytes for `crypto.subtle.importKey("pkcs8", ...)`.
export function parsePkcs8Pem(pem: string): Uint8Array<ArrayBuffer> {
  const normalized = pem.replace(/\\n/g, "\n");
  const stripped = normalized
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----/g, "")
    .replace(/-----END [A-Z ]*PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  if (!stripped) throw new Error("APNs private key PEM is empty");
  const bin = atob(stripped);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function encodeJsonB64Url(value: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

/// Mints (or returns a cached <50 min) APNs provider JWT signed with ES256
/// using Web Crypto (`crypto.subtle`).
export async function mintApnsJwt(config: ApnsConfig, nowMs = Date.now()): Promise<string> {
  const cacheKey = `${config.teamId}:${config.keyId}:${config.keyPem.length}:${config.keyPem.slice(-24)}`;
  if (
    cachedJwt &&
    cachedJwt.cacheKey === cacheKey &&
    nowMs - cachedJwt.issuedAtMs >= 0 &&
    nowMs - cachedJwt.issuedAtMs < JWT_CACHE_TTL_MS
  ) {
    return cachedJwt.token;
  }

  const der = parsePkcs8Pem(config.keyPem);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const header = encodeJsonB64Url({ alg: "ES256", kid: config.keyId });
  const payload = encodeJsonB64Url({ iss: config.teamId, iat: Math.floor(nowMs / 1000) });
  const signingInput = `${header}.${payload}`;
  const sigBuf = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  // Web Crypto ECDSA P-256 returns raw IEEE P1363 (r || s, 64 bytes), which is
  // the exact format RFC 7515 / JWT ES256 requires.
  const token = `${signingInput}.${base64url(new Uint8Array(sigBuf))}`;
  cachedJwt = { cacheKey, token, issuedAtMs: nowMs };
  return token;
}

function clip(text: string, max: number): string {
  const clean = text.trim();
  if (clean.length <= max) return clean;
  return `${clean.slice(0, max - 1).trimEnd()}…`;
}

export interface AgentQuestionApnsPayload {
  aps: {
    alert: {
      title: string;
      body: string;
    };
    sound: "default";
    category: typeof AGENT_QUESTION_CATEGORY;
    "thread-id": string;
    "mutable-content": 1;
    "interruption-level": "time-sensitive";
  };
  taskId: string;
  turnSeq: number;
  step: string;
  options: string[];
}

/// Builds the APNs JSON payload for an agent question turn. Keeps up to 3
/// options in `userInfo.options` and summarizes them in the alert body so
/// lock-screen Option 1/2/3 buttons are unambiguous even without a service extension.
export function buildAgentQuestionPayload(q: AgentQuestionPush): AgentQuestionApnsPayload {
  const title = clip(q.taskTitle || "Septena", 120) || "Septena";
  const options = q.options
    .map((o) => o.trim())
    .filter((o) => o.length > 0)
    .slice(0, MAX_NOTIFICATION_OPTIONS)
    .map((o) => clip(o, 200));

  const promptText = clip(q.question?.trim() || q.note?.trim() || "Needs your input", 300);
  const optionLine = options.length > 0
    ? options.map((o, i) => `${i + 1}. ${clip(o, 64)}`).join(" · ")
    : "";
  const body = optionLine ? `${promptText}\n${optionLine}` : promptText;

  return {
    aps: {
      alert: { title, body },
      sound: "default",
      category: AGENT_QUESTION_CATEGORY,
      "thread-id": `agent-question:${q.taskId}`,
      "mutable-content": 1,
      "interruption-level": "time-sensitive",
    },
    taskId: q.taskId,
    turnSeq: q.turnSeq,
    step: q.step,
    options,
  };
}

export interface AgentReviewApnsPayload {
  aps: {
    alert: { title: string; body: string };
    sound: "default";
    category: typeof AGENT_REVIEW_CATEGORY;
    "thread-id": string;
  };
  taskId: string;
}

export function buildAgentReviewPayload(r: AgentReviewPush): AgentReviewApnsPayload {
  return {
    aps: {
      alert: { title: clip(r.taskTitle || "Septena", 120) || "Septena", body: clip(r.note, 300) },
      sound: "default",
      category: AGENT_REVIEW_CATEGORY,
      "thread-id": `agent-review:${r.taskId}`,
    },
    taskId: r.taskId,
  };
}

export function topicForPlatform(bundleId: string, platform: PushPlatform): string {
  return platform === "watchos" ? `${bundleId}.watchkitapp` : bundleId;
}

export function hostForToken(token: Pick<PushTokenRow, "sandbox">, config: ApnsConfig): string {
  const useSandbox = config.sandboxOverride !== null ? config.sandboxOverride : token.sandbox;
  return useSandbox ? APNS_SANDBOX_HOST : APNS_PROD_HOST;
}

function shouldPruneResponse(status: number, reason: string | null): boolean {
  if (status === 410) return true;
  if (status === 400 && (reason === "BadDeviceToken" || reason === "Unregistered")) return true;
  return false;
}

/// Sends an agent question or hand-off notification to all registered device tokens.
/// Returns tokens that APNs rejected as dead (`410 Unregistered` or
/// `BadDeviceToken`) so the caller can prune them. Never throws on missing
/// secrets or network errors.
export async function sendAgentPushes(
  env: Partial<Env>,
  push: AgentPush,
  tokens: PushTokenRow[],
  opts: ApnsSendOptions = {},
): Promise<ApnsBatchResult> {
  if (tokens.length === 0) {
    return { attempted: 0, delivered: 0, pruned: [], skipped: "no_tokens" };
  }

  const config = readApnsConfig(env);
  if (!config) {
    logEvent("apns_skipped", {
      reason: "missing_secrets",
      taskId: push.taskId,
      turnSeq: isQuestion(push) ? push.turnSeq : null,
      tokenCount: tokens.length,
    });
    return { attempted: 0, delivered: 0, pruned: [], skipped: "missing_secrets" };
  }

  let jwt: string;
  try {
    jwt = await mintApnsJwt(config, opts.nowMs);
  } catch (err) {
    logEvent("apns_jwt_failed", {
      taskId: push.taskId,
      error: err instanceof Error ? err.message.slice(0, 120) : "unknown",
    });
    return { attempted: 0, delivered: 0, pruned: [] };
  }

  const payloadStr = JSON.stringify(isQuestion(push) ? buildAgentQuestionPayload(push) : buildAgentReviewPayload(push));
  const doFetch = opts.fetchFn ?? testFetchOverride ?? fetch;
  const pruned: string[] = [];
  let delivered = 0;

  await Promise.all(
    tokens.map(async (row) => {
      const url = `${hostForToken(row, config)}/3/device/${row.token}`;
      const topic = topicForPlatform(config.bundleId, row.platform);
      try {
        const res = await doFetch(url, {
          method: "POST",
          headers: {
            authorization: `bearer ${jwt}`,
            "apns-topic": topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": `agent-${isQuestion(push) ? "q" : "r"}-${push.taskId}`.slice(0, 64),
            "content-type": "application/json",
          },
          body: payloadStr,
        });
        if (res.status === 200) {
          delivered++;
          return;
        }
        let reason: string | null = null;
        try {
          const errBody = (await res.json()) as { reason?: unknown };
          if (typeof errBody?.reason === "string") reason = errBody.reason;
        } catch {
          // non-JSON error body
        }
        if (shouldPruneResponse(res.status, reason)) {
          pruned.push(row.token);
        }
        logEvent("apns_send_failed", {
          status: res.status,
          reason,
          platform: row.platform,
          sandbox: config.sandboxOverride !== null ? config.sandboxOverride : row.sandbox,
          pruned: shouldPruneResponse(res.status, reason),
          taskId: push.taskId,
        });
      } catch (err) {
        logEvent("apns_send_error", {
          platform: row.platform,
          taskId: push.taskId,
          error: err instanceof Error ? err.message.slice(0, 120) : "network_error",
        });
      }
    }),
  );

  logEvent("apns_push_batch", {
    taskId: push.taskId,
    turnSeq: isQuestion(push) ? push.turnSeq : null,
    attempted: tokens.length,
    delivered,
    pruned: pruned.length,
  });

  return { attempted: tokens.length, delivered, pruned };
}
