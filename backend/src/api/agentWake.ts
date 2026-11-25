import type { AgentEvent } from "../store/TaskStore.js";
import { logEvent, randomId } from "../util.js";

// Multi-user wake transport (docs/TASK_FACTORY_SPEC.md §4, §8, issue #5).
//
// Two transports share the `AgentEvent` stream from `TaskStore`:
//   1. SSE / WebSocket stream (`GET /v1/agent/events/stream`) for NAT'd Macs
//      and long-lived runners.
//   2. Signed outbound HTTPS webhooks (`agent_webhooks` table) for cloud
//      routines, OpenClaw, n8n, and tunneled hosts.
//
// Events are strictly pointers (rev, kind, taskId, at) — never task content
// (spec §10).

export const MAX_AGENT_WEBHOOKS = 10;
export const WEBHOOK_TIMEOUT_MS = 8_000;
export const SSE_HEARTBEAT_MS = 25_000;
export const SSE_RETRY_MS = 3_000;

export const WAKE_EVENT_KINDS: ReadonlySet<AgentEvent["kind"]> = new Set([
  "assigned",
  "user_turn",
  "resumed",
]);

export function isWakeEventKind(kind: AgentEvent["kind"]): boolean {
  return WAKE_EVENT_KINDS.has(kind);
}

// ---- SSE wire formatting ----

export function formatSseReady(head: number, paused: boolean): string {
  return `retry: ${SSE_RETRY_MS}\nevent: ready\ndata: ${JSON.stringify({ head, paused })}\n\n`;
}

export function formatSseEvent(event: AgentEvent): string {
  return `id: ${event.rev}\nevent: ${event.kind}\ndata: ${JSON.stringify(event)}\n\n`;
}

export function formatSseKeepalive(nowMs = Date.now()): string {
  return `: keepalive ${nowMs}\n\n`;
}

// ---- Webhook URL & SSRF validation ----

const BLOCKED_HOSTS = new Set([
  "localhost",
  "localhost.localdomain",
  "ip6-localhost",
  "ip6-loopback",
  "metadata",
  "metadata.google.internal",
  "metadata.goog",
]);

const BLOCKED_SUFFIXES = [
  ".localhost",
  ".local",
  ".internal",
  ".home.arpa",
  ".localdomain",
  ".corp",
  ".lan",
];

function parseIpv4Octets(host: string): [number, number, number, number] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const parts = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])];
  if (parts.some((n) => n < 0 || n > 255)) return null;
  return parts as [number, number, number, number];
}

function isBlockedIpv4(octets: [number, number, number, number]): boolean {
  const [a, b, c] = octets;
  if (a === 0) return true;                          // 0.0.0.0/8 current network
  if (a === 10) return true;                         // 10.0.0.0/8 RFC 1918
  if (a === 100 && b >= 64 && b <= 127) return true; // 100.64.0.0/10 CGNAT
  if (a === 127) return true;                        // 127.0.0.0/8 loopback
  if (a === 169 && b === 254) return true;           // 169.254.0.0/16 link-local / cloud metadata
  if (a === 172 && b >= 16 && b <= 31) return true;  // 172.16.0.0/12 RFC 1918
  if (a === 192 && b === 0 && c === 0) return true;  // 192.0.0.0/24 IETF protocol assignments
  if (a === 192 && b === 0 && c === 2) return true;  // 192.0.2.0/24 TEST-NET-1
  if (a === 192 && b === 168) return true;           // 192.168.0.0/16 RFC 1918
  if (a === 198 && (b === 18 || b === 19)) return true; // 198.18.0.0/15 benchmarking
  if (a === 198 && b === 51 && c === 100) return true;  // 198.51.100.0/24 TEST-NET-2
  if (a === 203 && b === 0 && c === 113) return true;   // 203.0.113.0/24 TEST-NET-3
  if (a >= 224) return true;                         // 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
  return false;
}

function expandIpv6(raw: string): number[] | null {
  let addr = raw.toLowerCase();
  // Strip zone id if present
  const zoneIdx = addr.indexOf("%");
  if (zoneIdx !== -1) addr = addr.slice(0, zoneIdx);

  // Handle dotted-quad IPv4 tail (e.g., ::ffff:127.0.0.1)
  const lastColon = addr.lastIndexOf(":");
  if (lastColon !== -1 && addr.slice(lastColon + 1).includes(".")) {
    const ipv4 = parseIpv4Octets(addr.slice(lastColon + 1));
    if (!ipv4) return null;
    const hi = ((ipv4[0] << 8) | ipv4[1]).toString(16);
    const lo = ((ipv4[2] << 8) | ipv4[3]).toString(16);
    addr = `${addr.slice(0, lastColon)}:${hi}:${lo}`;
  }

  const halves = addr.split("::");
  if (halves.length > 2) return null;

  const parseGroups = (part: string): number[] | null => {
    if (!part) return [];
    const groups = part.split(":");
    const out: number[] = [];
    for (const g of groups) {
      if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
      out.push(parseInt(g, 16));
    }
    return out;
  };

  const left = parseGroups(halves[0]);
  const right = halves.length === 2 ? parseGroups(halves[1]) : [];
  if (!left || !right) return null;

  if (halves.length === 1) {
    return left.length === 8 ? left : null;
  }
  const missing = 8 - (left.length + right.length);
  if (missing < 1) return null;
  return [...left, ...new Array<number>(missing).fill(0), ...right];
}

function isBlockedIpv6(raw: string): boolean {
  const groups = expandIpv6(raw);
  if (!groups) return true; // unparseable IPv6 literal -> fail closed

  const allZero = groups.every((g) => g === 0);
  if (allZero) return true; // :: unspecified
  if (groups.slice(0, 7).every((g) => g === 0) && groups[7] === 1) return true; // ::1 loopback

  // IPv4-mapped (::ffff:0:0/96) or IPv4-compatible (::/96)
  const firstFiveZero = groups.slice(0, 5).every((g) => g === 0);
  if (firstFiveZero && (groups[5] === 0xffff || groups[5] === 0)) {
    const octets: [number, number, number, number] = [
      (groups[6] >> 8) & 0xff,
      groups[6] & 0xff,
      (groups[7] >> 8) & 0xff,
      groups[7] & 0xff,
    ];
    if (isBlockedIpv4(octets)) return true;
  }

  // NAT64 well-known prefix 64:ff9b::/96
  if (groups[0] === 0x0064 && groups[1] === 0xff9b && groups.slice(2, 6).every((g) => g === 0)) {
    const octets: [number, number, number, number] = [
      (groups[6] >> 8) & 0xff,
      groups[6] & 0xff,
      (groups[7] >> 8) & 0xff,
      groups[7] & 0xff,
    ];
    if (isBlockedIpv4(octets)) return true;
  }

  if ((groups[0] & 0xfe00) === 0xfc00) return true; // fc00::/7 ULA
  if ((groups[0] & 0xffc0) === 0xfe80) return true; // fe80::/10 link-local
  if ((groups[0] & 0xffc0) === 0xfec0) return true; // fec0::/10 deprecated site-local
  if ((groups[0] & 0xff00) === 0xff00) return true; // ff00::/8 multicast
  if (groups[0] === 0x0100 && groups[1] === 0 && groups[2] === 0 && groups[3] === 0) return true; // 100::/64 discard
  if (groups[0] === 0x2001 && groups[1] === 0x0db8) return true; // 2001:db8::/32 documentation

  return false;
}

export type WebhookUrlResult =
  | { ok: true; url: string }
  | { ok: false; reason: string };

/// Validates an outbound webhook URL: requires `https:`, rejects credentials,
/// rejects private/loopback/link-local/metadata IPv4 & IPv6 targets, and
/// rejects local/internal hostnames.
export function validateWebhookUrl(raw: string): WebhookUrlResult {
  const trimmed = raw.trim();
  if (!trimmed || trimmed.length > 2048) {
    return { ok: false, reason: "url_length" };
  }
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return { ok: false, reason: "invalid_url" };
  }
  if (parsed.protocol !== "https:") {
    return { ok: false, reason: "https_required" };
  }
  if (parsed.username || parsed.password) {
    return { ok: false, reason: "credentials_disallowed" };
  }
  if (parsed.port) {
    const port = Number(parsed.port);
    if (!Number.isInteger(port) || (port !== 443 && port < 1024) || port > 65535) {
      return { ok: false, reason: "port_disallowed" };
    }
  }

  const host = parsed.hostname.toLowerCase().replace(/\.$/, "");
  if (!host) return { ok: false, reason: "invalid_host" };

  // Bracketed IPv6 literal
  if (host.startsWith("[") && host.endsWith("]")) {
    const inner = host.slice(1, -1);
    if (isBlockedIpv6(inner)) return { ok: false, reason: "private_address" };
    return { ok: true, url: parsed.toString() };
  }

  // Raw IPv6 without brackets (defensive)
  if (host.includes(":")) {
    if (isBlockedIpv6(host)) return { ok: false, reason: "private_address" };
    return { ok: true, url: parsed.toString() };
  }

  // Pure numeric / integer IP literal or dotted IPv4
  if (/^\d+$/.test(host) || /^0x[0-9a-f]+$/i.test(host)) {
    return { ok: false, reason: "private_address" };
  }
  const ipv4 = parseIpv4Octets(host);
  if (ipv4) {
    if (isBlockedIpv4(ipv4)) return { ok: false, reason: "private_address" };
    return { ok: true, url: parsed.toString() };
  }

  if (BLOCKED_HOSTS.has(host)) {
    return { ok: false, reason: "private_host" };
  }
  for (const suffix of BLOCKED_SUFFIXES) {
    if (host.endsWith(suffix)) return { ok: false, reason: "private_host" };
  }
  if (!host.includes(".")) {
    return { ok: false, reason: "single_label_host" };
  }

  return { ok: true, url: parsed.toString() };
}

// ---- HMAC-SHA256 signing & verification ----

function toHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

/// Signs `${timestampMs}.${rawBody}` with HMAC-SHA256 using `secret`.
/// Returns the `X-Septena-Signature` header value: `sha256=<lowercase hex>`.
export async function signWebhookPayload(
  secret: string,
  timestampMs: string,
  rawBody: string,
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(`${timestampMs}.${rawBody}`));
  return `sha256=${toHex(new Uint8Array(sig))}`;
}

/// Constant-time verification of `X-Septena-Signature`.
export async function verifyWebhookSignature(
  secret: string,
  timestampMs: string,
  rawBody: string,
  signatureHeader: string,
): Promise<boolean> {
  if (!signatureHeader.startsWith("sha256=")) return false;
  const expected = await signWebhookPayload(secret, timestampMs, rawBody);
  const enc = new TextEncoder();
  const a = enc.encode(expected);
  const b = enc.encode(signatureHeader);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ---- Outbound webhook delivery ----

export interface AgentWebhookTarget {
  id: string;
  url: string;
  secret: string;
}

export interface WebhookDeliveryResult {
  ok: boolean;
  status: number;
  deliveryId: string;
  deliveredAt: string;
}

export async function deliverWebhookEvent(
  target: AgentWebhookTarget,
  event: AgentEvent,
  fetchImpl: typeof fetch = fetch,
  timeoutMs = WEBHOOK_TIMEOUT_MS,
): Promise<WebhookDeliveryResult> {
  const deliveredAt = new Date().toISOString();
  const deliveryId = randomId(16);

  // Defense-in-depth: re-verify URL before every outbound fetch.
  const valid = validateWebhookUrl(target.url);
  if (!valid.ok) {
    logEvent("agent_webhook_blocked", { webhookId: target.id, reason: valid.reason });
    return { ok: false, status: 0, deliveryId, deliveredAt };
  }

  const timestampMs = String(Date.now());
  const rawBody = JSON.stringify({
    event: event.kind,
    rev: event.rev,
    taskId: event.taskId,
    at: event.at,
  });
  const signature = await signWebhookPayload(target.secret, timestampMs, rawBody);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(valid.url, {
      method: "POST",
      redirect: "manual",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": "Septena-Webhook/1.0",
        "X-Septena-Event": event.kind,
        "X-Septena-Delivery": deliveryId,
        "X-Septena-Timestamp": timestampMs,
        "X-Septena-Signature": signature,
      },
      body: rawBody,
      signal: controller.signal,
    });
    // Consume/cancel body so Workers runtime doesn't warn about stalled responses.
    try { await res.body?.cancel(); } catch { /* ignore */ }
    const ok = res.status >= 200 && res.status < 300;
    logEvent("agent_webhook_delivery", {
      webhookId: target.id,
      deliveryId,
      event: event.kind,
      rev: event.rev,
      status: res.status,
      ok,
    });
    return { ok, status: res.status, deliveryId, deliveredAt };
  } catch (e) {
    logEvent("agent_webhook_delivery", {
      webhookId: target.id,
      deliveryId,
      event: event.kind,
      rev: event.rev,
      status: 0,
      ok: false,
      error: e instanceof Error ? e.name : "error",
    });
    return { ok: false, status: 0, deliveryId, deliveredAt };
  } finally {
    clearTimeout(timer);
  }
}
