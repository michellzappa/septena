import { Hono, type Context, type Next } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { MAX_ATTACHMENT_BYTES, zId } from "../store/columns.js";
import { zPushBody, type Op } from "../store/ops.js";
import { AppleIdentityError, userIdForAppleSub, verifyAppleIdentityToken } from "./appleIdentity.js";
import { issueSession, refreshSession, revokeSession, storeFor, verifyAccessToken } from "./session.js";
import {
  approvePairing,
  inspectPairing,
  pollDevicePairing,
  startDevicePairing,
  zDevicePollBody,
  zDeviceStartBody,
  zPairApproveBody,
  zPairInspectBody,
} from "../shadow/oauth.js";
import {
  appAccountTokenFor,
  entitlementGate,
  isEnforcing,
  isRowActive,
  rememberAppAccountToken,
  rememberOriginalTransaction,
  userForTransaction,
} from "../entitlement/entitlement.js";
import {
  AppleJwsError,
  verifyAppleJws,
  type JwsRenewalInfo,
  type JwsTransaction,
  type NotificationV2,
} from "../entitlement/appleJws.js";
import { appleRow, rejectReason } from "../entitlement/apple.js";

// Task backend API, mounted at /v1 (docs/SEPTASK_BACKEND.md in the app repo).
// Phase 0: no app or MCP tool calls this yet. The live connector is unchanged.

type Vars = { userId: string; actor: string };
type Ctx = Context<{ Bindings: Env; Variables: Vars }>;

export const api = new Hono<{ Bindings: Env; Variables: Vars }>();

const zAppleBody = z.object({
  identityToken: z.string().min(20).max(8_000),
  nonce: z.string().min(16).max(256),
}).strict();
const zRefreshBody = z.object({ refreshToken: z.string().min(20).max(200) }).strict();
const zClientName = z.string().regex(/^[\w .()-]{1,40}$/);

function attachmentKey(userId: string, id: string): string {
  return `u/${userId}/att/${id}`;
}

async function parse<T extends z.ZodTypeAny>(c: Ctx, schema: T): Promise<z.infer<T> | Response> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const parsed = schema.safeParse(body);
  if (!parsed.success) return c.json({ error: "invalid_request", issues: parsed.error.issues.slice(0, 20) }, 400);
  return parsed.data;
}

// ---- auth ----

api.post("/auth/apple", async (c) => {
  const body = await parse(c, zAppleBody);
  if (body instanceof Response) return body;
  try {
    const { sub } = await verifyAppleIdentityToken(body.identityToken, body.nonce, c.env.APPLE_AUDIENCES.split(","));
    const userId = await userIdForAppleSub(sub);
    logEvent("api_signin", { ok: true });
    return c.json(await issueSession(c.env, userId));
  } catch (e) {
    if (e instanceof AppleIdentityError) {
      logEvent("api_signin", { ok: false, reason: e.message });
      return c.json({ error: "invalid_identity_token" }, 401);
    }
    throw e;
  }
});

api.post("/auth/refresh", async (c) => {
  const body = await parse(c, zRefreshBody);
  if (body instanceof Response) return body;
  const session = await refreshSession(c.env, body.refreshToken);
  return session ? c.json(session) : c.json({ error: "invalid_grant" }, 401);
});

api.post("/auth/signout", async (c) => {
  const body = await parse(c, zRefreshBody);
  if (body instanceof Response) return body;
  await revokeSession(c.env, body.refreshToken);
  return c.body(null, 204);
});

// Device sign-in by approval (ADR 0016, issue #170): see src/shadow/oauth.ts.
api.post("/auth/device/start", async (c) => {
  const body = await parse(c, zDeviceStartBody);
  if (body instanceof Response) return body;
  const res = await startDevicePairing(c.env, body);
  return res ? c.json(res, 200, { "Cache-Control": "no-store" }) : c.json({ error: "pairing_unavailable" }, 503);
});

api.post("/auth/device/poll", async (c) => {
  const body = await parse(c, zDevicePollBody);
  if (body instanceof Response) return body;
  const res = await pollDevicePairing(c.env, body);
  if (res.status === "pending") return c.json({ status: "pending" }, 202, { "Cache-Control": "no-store" });
  if (res.status === "gone") return c.json({ error: "expired_or_unknown" }, 410);
  return c.json(await issueSession(c.env, res.userId), 200, { "Cache-Control": "no-store" });
});

// ---- everything below needs a bearer access token ----

async function requireUser(c: Ctx, next: Next) {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  const userId = token ? await verifyAccessToken(c.env, token) : null;
  if (!userId) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
  const client = zClientName.safeParse(c.req.header("X-Septena-Client"));
  c.set("userId", userId);
  c.set("actor", `app:${client.success ? client.data : "unknown"}`);
  await next();
}

/// Paid paths (docs/SYNC_SUBSCRIPTION_SPEC.md §6). Runs after requireUser.
/// With ENTITLEMENT_ENFORCE != "true" it only logs; see entitlementGate.
async function requireSyncEntitlement(c: Ctx, next: Next) {
  if ((await entitlementGate(c.env, c.get("userId"), "sync")) === "block") {
    return c.json({ error: "subscription_required" }, 402);
  }
  await next();
}

/// Entitlement and admin routes exist only on api.septena.app, so
/// mcp.septena.app answers exactly as before.
async function apiHostOnly(c: Ctx, next: Next) {
  if (new URL(c.req.url).host !== new URL(c.env.API_PUBLIC_URL).host) return c.notFound();
  await next();
}

api.use("/sync/*", requireUser, requireSyncEntitlement);
api.use("/attachments/*", requireUser, requireSyncEntitlement);
api.use("/account", requireUser);
api.use("/changes", requireUser, requireSyncEntitlement);
api.use("/pair/*", requireUser);
api.use("/entitlement", apiHostOnly, requireUser);
api.use("/entitlement/*", apiHostOnly, requireUser);
api.use("/webhooks/*", apiHostOnly);
api.use("/admin/*", apiHostOnly);

api.post("/sync/push", async (c) => {
  const body = await parse(c, zPushBody);
  if (body instanceof Response) return body;
  const userId = c.get("userId");
  const { result, purgedAttachmentIds } = await storeFor(c.env, userId).push(body.ops as Op[], c.get("actor"));
  if (purgedAttachmentIds.length) {
    c.executionCtx.waitUntil(c.env.ATTACHMENTS.delete(purgedAttachmentIds.map((id) => attachmentKey(userId, id))));
  }
  return c.json(result);
});

api.get("/sync/pull", async (c) => {
  const q = z.object({
    since: z.coerce.number().int().min(0).default(0),
    limit: z.coerce.number().int().min(1).max(1_000).default(500),
    // `settings=1`: the client syncs the `setting` entity (TaskStore.pull).
    settings: z.enum(["0", "1"]).default("0"),
    // `checklists=1`: the client syncs the `checklistItem` entity (TaskStore.pull).
    checklists: z.enum(["0", "1"]).default("0"),
    // `tags=1`: the client syncs the `tag` entity (TaskStore.pull).
    tags: z.enum(["0", "1"]).default("0"),
  }).safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  return c.json(await storeFor(c.env, c.get("userId")).pull(
    q.data.since,
    q.data.limit,
    q.data.settings === "1",
    q.data.checklists === "1",
    q.data.tags === "1",
  ));
});

api.get("/sync/ws", async (c) => {
  if (c.req.header("Upgrade") !== "websocket") return c.json({ error: "expected_websocket" }, 426);
  return storeFor(c.env, c.get("userId")).fetch(c.req.raw);
});

// ---- change history (who changed what, with before/after values) ----

api.get("/changes", async (c) => {
  const q = z.object({
    entity: z.enum(["task", "area", "project", "attachment", "checklistItem", "tag", "convo", "setting", "turn"]).optional(),
    id: zId.optional(),
    before: z.coerce.number().int().min(1).optional(),
    limit: z.coerce.number().int().min(1).max(500).default(100),
  }).safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  const changes = await storeFor(c.env, c.get("userId")).history(
    q.data.entity ?? null, q.data.id ?? null, q.data.before ?? null, q.data.limit,
  );
  return c.json({ changes });
});

// ---- attachments (bytes proxied through the Worker; §10 limits) ----

api.put("/attachments/:id", async (c) => {
  const id = zId.safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "invalid_id" }, 400);
  const length = Number(c.req.header("Content-Length"));
  if (!Number.isInteger(length) || length < 0) return c.json({ error: "length_required" }, 411);
  if (length > MAX_ATTACHMENT_BYTES) return c.json({ error: "too_large", max: MAX_ATTACHMENT_BYTES }, 413);
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);
  const problem = await store.checkUpload(id.data, length);
  if (problem === "not_found") return c.json({ error: "push_metadata_first" }, 404);
  if (problem === "size_mismatch") return c.json({ error: "size_mismatch" }, 409);
  const body = c.req.raw.body;
  if (!body) return c.json({ error: "empty_body" }, 400);
  await c.env.ATTACHMENTS.put(attachmentKey(userId, id.data), body);
  const rev = await store.finishUpload(id.data, c.get("actor"));
  if (rev === null) {
    // Deleted while uploading: do not keep orphan bytes.
    c.executionCtx.waitUntil(c.env.ATTACHMENTS.delete(attachmentKey(userId, id.data)));
    return c.json({ error: "deleted" }, 410);
  }
  return c.json({ rev });
});

api.get("/attachments/:id", async (c) => {
  const id = zId.safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "invalid_id" }, 400);
  const userId = c.get("userId");
  const info = await storeFor(c.env, userId).downloadInfo(id.data);
  if (!info) return c.json({ error: "not_found" }, 404);
  const obj = await c.env.ATTACHMENTS.get(attachmentKey(userId, id.data));
  if (!obj) return c.json({ error: "not_found" }, 404);
  return new Response(obj.body, {
    headers: {
      "Content-Type": info.contentType,
      "Content-Length": String(obj.size),
      "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(info.filename)}`,
      "Cache-Control": "private, no-store",
    },
  });
});

// ---- approving a sign-in code: a new device or a Claude connector (src/shadow/oauth.ts) ----

api.post("/pair/inspect", async (c) => {
  const body = await parse(c, zPairInspectBody);
  if (body instanceof Response) return body;
  const res = await inspectPairing(c.env, c.get("userId"), body);
  return res.ok
    ? c.json({ kind: res.kind, client: res.client, expiresIn: res.expiresIn }, 200, { "Cache-Control": "no-store" })
    : c.json({ error: res.error }, res.status);
});

api.post("/pair/approve", async (c) => {
  const body = await parse(c, zPairApproveBody);
  if (body instanceof Response) return body;
  const res = await approvePairing(c.env, c.get("userId"), body);
  return res.ok ? c.json({ ok: true, client: res.client, kind: res.kind }) : c.json({ error: res.error }, res.status);
});

// ---- sync entitlement (docs/SYNC_SUBSCRIPTION_SPEC.md §5–§6) ----

const zJws = z.string().min(20).max(20_000);

/// The caller's entitlement, and the appAccountToken the app must pass to
/// `Product.purchase(options: [.appAccountToken(_)])`.
api.get("/entitlement", async (c) => {
  const userId = c.get("userId");
  const appAccountToken = await appAccountTokenFor(userId);
  c.executionCtx.waitUntil(rememberAppAccountToken(c.env, userId, appAccountToken));
  const rows = await storeFor(c.env, userId).entitlements();
  const now = Date.now();
  return c.json({
    userId,
    appAccountToken,
    active: rows.some((r) => isRowActive(r, now)),
    enforced: isEnforcing(c.env),
    entitlements: rows.map((r) => ({ ...r, active: isRowActive(r, now) })),
  });
});

/// A StoreKit 2 transaction the app holds (after purchase, and for every item
/// of Transaction.currentEntitlements on restore).
api.post("/entitlement/apple", async (c) => {
  const body = await parse(c, z.object({ signedTransaction: zJws, signedRenewalInfo: zJws.optional() }).strict());
  if (body instanceof Response) return body;
  const userId = c.get("userId");
  let tx: JwsTransaction;
  let renewal: JwsRenewalInfo | undefined;
  try {
    tx = await verifyAppleJws<JwsTransaction>(body.signedTransaction);
    if (body.signedRenewalInfo) renewal = await verifyAppleJws<JwsRenewalInfo>(body.signedRenewalInfo);
  } catch (e) {
    if (e instanceof AppleJwsError) {
      logEvent("entitlement_apple", { ok: false, reason: e.message });
      return c.json({ error: "invalid_signed_transaction" }, 400);
    }
    throw e;
  }
  const appAccountToken = await appAccountTokenFor(userId);
  if (!tx.appAccountToken || tx.appAccountToken.toLowerCase() !== appAccountToken) {
    logEvent("entitlement_apple", { ok: false, reason: "account_mismatch", userId });
    return c.json({ error: "account_mismatch" }, 403);
  }
  if (renewal && renewal.originalTransactionId !== tx.originalTransactionId) {
    return c.json({ error: "renewal_mismatch" }, 400);
  }
  const reject = rejectReason(c.env, tx);
  if (reject) {
    logEvent("entitlement_apple", { ok: false, reason: reject, userId });
    return c.json({ error: reject }, 422);
  }
  const row = appleRow(tx, { renewal });
  const store = storeFor(c.env, userId);
  const written = await store.putEntitlement(row, "app");
  await Promise.all([
    rememberOriginalTransaction(c.env, userId, tx.originalTransactionId),
    rememberAppAccountToken(c.env, userId, appAccountToken),
  ]);
  logEvent("entitlement_apple", { ok: true, userId, status: row.status, written });
  const rows = await store.entitlements();
  const now = Date.now();
  return c.json({ active: rows.some((r) => isRowActive(r, now)), entitlement: rows.find((r) => r.id === row.id) ?? null });
});

/// App Store Server Notifications V2. Configure in App Store Connect as
/// https://api.septena.app/v1/webhooks/apple (Production and Sandbox URLs).
/// Answers 200 for anything verified, so Apple stops retrying; 400 only for
/// a payload that fails verification.
api.post("/webhooks/apple", async (c) => {
  const body = await parse(c, z.object({ signedPayload: z.string().min(20).max(60_000) }));
  if (body instanceof Response) return body;
  let n: NotificationV2;
  let tx: JwsTransaction | undefined;
  let renewal: JwsRenewalInfo | undefined;
  try {
    n = await verifyAppleJws<NotificationV2>(body.signedPayload);
    if (n.data?.signedTransactionInfo) tx = await verifyAppleJws<JwsTransaction>(n.data.signedTransactionInfo);
    if (n.data?.signedRenewalInfo) renewal = await verifyAppleJws<JwsRenewalInfo>(n.data.signedRenewalInfo);
  } catch (e) {
    if (e instanceof AppleJwsError) {
      logEvent("apple_webhook", { ok: false, reason: e.message });
      return c.json({ error: "invalid_signed_payload" }, 400);
    }
    throw e;
  }
  const evt = { type: n.notificationType, subtype: n.subtype, uuid: n.notificationUUID };
  if (!tx) {
    // TEST, CONSUMPTION_REQUEST, summary notifications: nothing to record.
    logEvent("apple_webhook", { ok: true, ...evt, ignored: "no_transaction" });
    return c.json({ ok: true });
  }
  const reject = rejectReason(c.env, tx);
  if (reject) {
    logEvent("apple_webhook", { ok: true, ...evt, ignored: reject });
    return c.json({ ok: true });
  }
  const userId = await userForTransaction(c.env, tx.originalTransactionId, tx.appAccountToken);
  if (!userId) {
    // The app has not posted this purchase or read its token yet. Its own
    // POST /v1/entitlement/apple records the row when it does.
    logEvent("apple_webhook", { ok: true, ...evt, ignored: "unknown_user" });
    return c.json({ ok: true });
  }
  const row = appleRow(tx, { renewal, notification: n });
  const written = await storeFor(c.env, userId).putEntitlement(row, "webhook");
  await rememberOriginalTransaction(c.env, userId, tx.originalTransactionId);
  logEvent("apple_webhook", { ok: true, ...evt, userId, status: row.status, written });
  return c.json({ ok: true });
});

// ---- admin: grant rows (mz, testers, press) ----
// Disabled (404) unless the ADMIN_TOKEN secret is set. The caller sends it as
// `X-Admin-Token`. Exact commands: docs/SYNC_SUBSCRIPTION_SPEC.md §6.

async function adminAllowed(c: Ctx): Promise<boolean> {
  const secret = c.env.ADMIN_TOKEN;
  const given = c.req.header("X-Admin-Token");
  if (!secret || !given) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(secret)),
    crypto.subtle.digest("SHA-256", enc.encode(given)),
  ]);
  // Equal-length digests, compared without an early exit.
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

const zUserId = z.string().regex(/^u_[A-Za-z0-9_-]{20,64}$/);
const zGrantName = z.string().regex(/^[a-z0-9][a-z0-9._-]{0,39}$/);

api.post("/admin/grants", async (c) => {
  if (!c.env.ADMIN_TOKEN) return c.notFound();
  if (!(await adminAllowed(c))) return c.json({ error: "forbidden" }, 403);
  const body = await parse(c, z.object({
    userId: zUserId,
    name: zGrantName,
    note: z.string().max(200).optional(),
    expiresAt: z.string().datetime().optional(),
  }).strict());
  if (body instanceof Response) return body;
  const now = Date.now();
  const store = storeFor(c.env, body.userId);
  await store.putEntitlement({
    id: `grant:${body.name}`,
    source: "grant",
    productId: null,
    expiresAt: body.expiresAt ? Date.parse(body.expiresAt) : null,
    originalTransactionId: null,
    status: "active",
    environment: null,
    note: body.note ?? null,
    signedAt: now,
  }, "admin");
  logEvent("entitlement_grant", { userId: body.userId, name: body.name });
  const rows = await store.entitlements();
  return c.json({ active: rows.some((r) => isRowActive(r, now)), entitlements: rows });
});

api.delete("/admin/grants/:userId/:name", async (c) => {
  if (!c.env.ADMIN_TOKEN) return c.notFound();
  if (!(await adminAllowed(c))) return c.json({ error: "forbidden" }, 403);
  const userId = zUserId.safeParse(c.req.param("userId"));
  const name = zGrantName.safeParse(c.req.param("name"));
  if (!userId.success || !name.success) return c.json({ error: "invalid_request" }, 400);
  const removed = await storeFor(c.env, userId.data).deleteEntitlement(`grant:${name.data}`);
  logEvent("entitlement_grant_revoked", { userId: userId.data, name: name.data, removed });
  return removed ? c.body(null, 204) : c.json({ error: "not_found" }, 404);
});

// ---- admin: account move copy (docs/CLOUDFLARE_ACCOUNT_MOVE.md) ----
// Same gate as the grant routes. Export runs on the old account, import on
// the new one; import refuses a store that already holds data.

const zCopyTable = z.string().regex(/^[a-z_][a-z0-9_]{0,63}$/);

async function copyStore(c: Ctx) {
  if (!c.env.ADMIN_TOKEN) return c.notFound();
  if (!(await adminAllowed(c))) return c.json({ error: "forbidden" }, 403);
  const userId = zUserId.safeParse(c.req.param("userId"));
  if (!userId.success) return c.json({ error: "invalid_request" }, 400);
  return storeFor(c.env, userId.data);
}

api.get("/admin/copy/:userId/snapshot", async (c) => {
  const store = await copyStore(c);
  if (store instanceof Response) return store;
  return c.json({ tables: await store.copySnapshot() });
});

api.get("/admin/copy/:userId/export", async (c) => {
  const store = await copyStore(c);
  if (store instanceof Response) return store;
  const table = zCopyTable.safeParse(c.req.query("table"));
  const after = z.coerce.number().int().min(0).safeParse(c.req.query("after") ?? "0");
  const limit = z.coerce.number().int().min(1).max(1000).safeParse(c.req.query("limit") ?? "500");
  if (!table.success || !after.success || !limit.success) return c.json({ error: "invalid_request" }, 400);
  return c.json(await store.copyExport(table.data, after.data, limit.data));
});

api.post("/admin/copy/:userId/import/begin", async (c) => {
  const store = await copyStore(c);
  if (store instanceof Response) return store;
  const result = await store.copyImportBegin();
  return result.ok ? c.json(result) : c.json({ error: result.reason }, 409);
});

api.post("/admin/copy/:userId/import", async (c) => {
  const store = await copyStore(c);
  if (store instanceof Response) return store;
  const body = await parse(c, z.object({
    table: zCopyTable,
    rows: z.array(z.record(z.union([z.string(), z.number(), z.null()]))).max(1000),
  }).strict());
  if (body instanceof Response) return body;
  return c.json({ written: await store.copyImport(body.table, body.rows) });
});

api.post("/admin/copy/:userId/import/end", async (c) => {
  const store = await copyStore(c);
  if (store instanceof Response) return store;
  return c.json({ tables: await store.copyImportEnd() });
});

// ---- account deletion (§10) ----

api.delete("/account", async (c) => {
  const userId = c.get("userId");
  await storeFor(c.env, userId).deleteAccount();
  const prefix = `u/${userId}/`;
  let cursor: string | undefined;
  do {
    const page = await c.env.ATTACHMENTS.list({ prefix, cursor });
    if (page.objects.length) await c.env.ATTACHMENTS.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  logEvent("api_account_deleted", {});
  // Refresh-token KV entries now point at an empty store and fail rotation.
  // Access tokens live out their hour against an empty store.
  return c.body(null, 204);
});
