import { Hono, type Context, type Next } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent, randomId, sha256Base64Url } from "../util.js";
import { buildIcalFeed, icalEtag, type IcalScope } from "../ical.js";
import { isValidTz, todayYMD } from "../tz.js";
import { MAX_ATTACHMENT_BYTES, zId } from "../store/columns.js";
import { zPushBody, type Op } from "../store/ops.js";
import type { ChangeEntry } from "../store/TaskStore.js";
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
import { disconnectFamily } from "../shadow/tokens.js";
import {
  appAccountTokenFor,
  attachmentQuotaBytes,
  decide,
  historyCutoff,
  historyEdgeUpsell,
  isEnforcing,
  isRowActive,
  planCheckFailed,
  planFor,
  trialEndsAt,
  trialRow,
  upsellLine,
  usageKeys,
  type LimitBreach,
  type PlanState,
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
import { tasksRest } from "./tasksRest.js";

// Task backend API, mounted at /v1 (docs/SEPTASK_BACKEND.md in the app repo).
// Phase 0: no app or MCP tool calls this yet. The live connector is unchanged.

type Vars = {
  userId: string;
  actor: string;
  /// The session id from the access token (null for a token from before
  /// session ids). One session = one device for the sync slot.
  sid: string | null;
  /// `X-Septena-Client`, when valid. Labels the device.
  client: string | null;
  /// Set by `loadPlan`. null when the check failed in log-only mode: the call
  /// then runs with no limits.
  plan: PlanState | null;
};
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
    // Every new account starts with 14 days of Plus (spec §3). Only the
    // first sign-in writes the row; later sign-ins find it and do nothing.
    const trialStarted = await storeFor(c.env, userId).startTrialOnce(trialRow());
    if (trialStarted) logEvent("trial_started", { userId });
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
  const claims = token ? await verifyAccessToken(c.env, token) : null;
  if (!claims) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
  const client = zClientName.safeParse(c.req.header("X-Septena-Client"));
  c.set("userId", claims.userId);
  c.set("sid", claims.sid);
  c.set("client", client.success ? client.data : null);
  c.set("actor", `app:${client.success ? client.data : "unknown"}`);
  await next();
}

/// A refusal for a broken limit (enforce mode only): 402 with the limit, the
/// upsell moment (spec §3.2) and its words.
function limitRefusal(c: Ctx, error: string, breach: LimitBreach) {
  return c.json({
    error, limit: breach.limit, upsell: breach.upsell, message: breach.upsell ? upsellLine(breach.upsell) : null,
  }, 402);
}

/// The caller's plan (docs/SYNC_SUBSCRIPTION_SPEC.md §6). Runs after
/// requireUser. A failed check blocks only in enforce mode.
async function loadPlan(c: Ctx, next: Next) {
  try {
    const plan = await planFor(c.env, c.get("userId"));
    c.set("plan", plan);
    // Before enforcement, every free-account sync call says so, as the old
    // yes/no gate's would-block line did: spec §6.2 finds the user id here.
    if (plan.plan === "free" && !isEnforcing(c.env)) logEvent("entitlement_free_account", { userId: c.get("userId") });
  } catch (e) {
    if (planCheckFailed(c.env, c.get("userId"), "plan", e) === "block") return c.json({ error: "plan_check_failed" }, 503);
    c.set("plan", null);
  }
  await next();
}

/// Server sync for this device (ADR 0023): the plan's device count. A device
/// past the count keeps its local data and stops syncing until it takes the
/// slot (`POST /v1/entitlement/device`). Runs after loadPlan.
async function requireSyncDevice(c: Ctx, next: Next) {
  const plan = c.get("plan");
  const sid = c.get("sid");
  // A token from before session ids names no device; it refreshes within
  // the hour and carries one from then on.
  if (plan && sid) {
    const { syncing } = await storeFor(c.env, c.get("userId")).deviceAccess(sid, c.get("client"), plan.limits.devices);
    const breach: LimitBreach | null = syncing ? null : { limit: "devices", upsell: "second_device" };
    if (decide(c.env, c.get("userId"), "sync_device", plan, breach) === "block") return limitRefusal(c, "device_not_syncing", breach!);
  }
  await next();
}

/// Entitlement and admin routes exist only on api.septena.app, so
/// mcp.septena.app answers exactly as before.
async function apiHostOnly(c: Ctx, next: Next) {
  if (new URL(c.req.url).host !== new URL(c.env.API_PUBLIC_URL).host) return c.notFound();
  await next();
}

api.use("/sync/*", requireUser, loadPlan, requireSyncDevice);
api.use("/attachments/*", requireUser, loadPlan, requireSyncDevice);
api.use("/account", requireUser);
api.use("/ical/settings", requireUser);
api.use("/changes", requireUser, loadPlan, requireSyncDevice);
api.use("/pair/*", requireUser);
api.use("/auth/device", requireUser);
// The watch is a companion of a signed-in phone or Mac: it loads the plan
// but takes no sync device slot of its own.
api.use("/tasks", requireUser, loadPlan);
api.use("/tasks/*", requireUser, loadPlan);
api.use("/access", apiHostOnly, requireUser);
api.use("/access/*", apiHostOnly, requireUser);
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
  // Without live sync the app polls `/sync/pull` (spec §3).
  const plan = c.get("plan");
  if (plan && !plan.limits.liveSync) {
    const breach: LimitBreach = { limit: "liveSync", upsell: null };
    if (decide(c.env, c.get("userId"), "sync_live", plan, breach) === "block") return limitRefusal(c, "live_sync_not_in_plan", breach);
  }
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
  const plan = c.get("plan");
  const store = storeFor(c.env, c.get("userId"));
  const entity = q.data.entity ?? null;
  const id = q.data.id ?? null;
  // The plan's history window hides older changes; it never deletes them.
  const since = historyCutoff(c.env, plan?.limits ?? null);
  const changes = (await store.history(entity, id, q.data.before ?? null, q.data.limit, since)) as unknown as ChangeEntry[];
  if (since === null) {
    const days = plan?.limits.changeLogDays ?? null;
    if (plan && days !== null) {
      const edge = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
      if (changes.some((e) => e.at < edge)) decide(c.env, c.get("userId"), "history", plan, { limit: "changeLogDays", upsell: "history_edge" });
    }
    return c.json({ changes });
  }
  const hidden = changes.length < q.data.limit ? await store.historyHidden(entity, id, since) : null;
  // `upsell` names the moment the app shows at the end of the list: set
  // only on the free plan when older changes were hidden.
  return c.json({ changes, windowDays: plan!.limits.changeLogDays, hiddenOlder: hidden, upsell: historyEdgeUpsell(plan ?? null, hidden) });
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
  // Server attachments are a plan limit: none on the free account (files
  // stay on the device that added them), a quota on Plus.
  const plan = c.get("plan");
  const quota = plan ? attachmentQuotaBytes(plan.limits) : null;
  if (plan && quota !== null && (quota === 0 || (await store.attachmentBytes()) + length > quota)) {
    const breach: LimitBreach = { limit: "attachmentsGB", upsell: "file_elsewhere" };
    if (decide(c.env, userId, "attachment_upload", plan, breach) === "block") {
      return limitRefusal(c, quota === 0 ? "attachments_not_in_plan" : "attachment_quota", breach);
    }
  }
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

// ---- a session for a companion device (the Apple Watch) ----

/// A signed-in app mints a SEPARATE session for a device it hands it to over
/// a private channel (WatchConnectivity). Refresh tokens are single-use and
/// rotate, so two devices can never share one: each would sign the other out.
/// The new session is a sibling, revocable on its own through /auth/signout.
api.post("/auth/device", async (c) => {
  const userId = c.get("userId");
  logEvent("api_device_session", { by: c.get("actor") });
  return c.json(await issueSession(c.env, userId));
});

// ---- task views and verbs for thin clients (src/api/tasksRest.ts) ----

api.route("/tasks", tasksRest);

api.post("/pair/approve", async (c) => {
  const body = await parse(c, zPairApproveBody);
  if (body instanceof Response) return body;
  const res = await approvePairing(c.env, c.get("userId"), body);
  return res.ok ? c.json({ ok: true, client: res.client, kind: res.kind }) : c.json({ error: res.error }, res.status);
});

// ---- Devices & Access (Settings > Account > Devices & Access) ----
// Every place the account is signed in: app sessions (one per install) and
// MCP connections (Claude, ChatGPT and other connector clients).

const zSid = z.string().uuid();
const zFamilyId = z.string().regex(/^[A-Za-z0-9_-]{8,64}$/);

api.get("/access", async (c) => {
  const userId = c.get("userId");
  let cap: number | null = null;
  try {
    cap = (await planFor(c.env, userId)).limits.devices;
  } catch {
    // The list still shows; "syncing" then reads true for every device.
  }
  const summary = await storeFor(c.env, userId).accessSummary(c.get("sid"), cap);
  return c.json(summary, 200, { "Cache-Control": "no-store" });
});

/// Signs another device out. The caller's own device signs out through
/// /v1/auth/signout, which also clears its keychain.
api.delete("/access/devices/:sid", async (c) => {
  const sid = zSid.safeParse(c.req.param("sid"));
  if (!sid.success) return c.json({ error: "invalid_request" }, 400);
  if (sid.data === c.get("sid")) return c.json({ error: "current_device" }, 400);
  const userId = c.get("userId");
  const hashes = await storeFor(c.env, userId).revokeDevice(sid.data);
  if (!hashes.length) return c.json({ error: "not_found" }, 404);
  await Promise.all(hashes.map((h) => c.env.TOKENS.delete(`api-refresh:${h}`)));
  logEvent("access_device_signed_out", { userId, by: c.get("actor") });
  return c.body(null, 204);
});

api.delete("/access/connections/:id", async (c) => {
  const id = zFamilyId.safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "invalid_request" }, 400);
  const userId = c.get("userId");
  const had = await disconnectFamily(c.env, userId, id.data);
  if (!had) return c.json({ error: "not_found" }, 404);
  logEvent("access_connection_revoked", { userId, by: c.get("actor") });
  return c.body(null, 204);
});

// ---- sync entitlement (docs/SYNC_SUBSCRIPTION_SPEC.md §5–§6) ----

const zJws = z.string().min(20).max(20_000);

/// The caller's entitlement, and the appAccountToken the app must pass to
/// `Product.purchase(options: [.appAccountToken(_)])`.
api.get("/entitlement", async (c) => {
  const userId = c.get("userId");
  const appAccountToken = await appAccountTokenFor(userId);
  c.executionCtx.waitUntil(rememberAppAccountToken(c.env, userId, appAccountToken));
  const keys = { connectorWrites: usageKeys.connectorWrites(), agentRuns: usageKeys.agentRuns() };
  const state = await planFor(c.env, userId, [keys.connectorWrites, keys.agentRuns]);
  const store = storeFor(c.env, userId);
  const sid = c.get("sid");
  const devices = await store.deviceSummary(state.limits.devices);
  const now = Date.now();
  return c.json({
    userId,
    appAccountToken,
    active: state.rows.some((r) => isRowActive(r, now)),
    enforced: isEnforcing(c.env),
    entitlements: state.rows.map((r) => ({ ...r, active: isRowActive(r, now) })),
    // The reverse trial's end (ms) while it is the only active row, else null.
    trialEndsAt: trialEndsAt(state.rows, now),
    // The plan table row the server enforces (spec §6). Apps read limits
    // here and never hardcode them.
    plan: state.plan,
    limits: state.limits,
    usage: {
      connectorWritesToday: state.usage[keys.connectorWrites],
      agentRunsThisMonth: state.usage[keys.agentRuns],
    },
    device: {
      // A device that never synced yet takes a free slot on its first sync.
      syncing: sid ? (devices.find((d) => d.sid === sid)?.syncing ?? devices.filter((d) => d.syncing).length < (state.limits.devices ?? Infinity)) : true,
      syncingDevices: devices.filter((d) => d.syncing).length,
      knownDevices: devices.length,
    },
  });
});

/// Moves the sync slot to this device ("sync this device instead", spec
/// §3.2). On a capped plan the device used least recently stops syncing and
/// keeps its local data. Free on every plan.
api.post("/entitlement/device", async (c) => {
  const sid = c.get("sid");
  if (!sid) return c.json({ error: "refresh_token_first" }, 409);
  const store = storeFor(c.env, c.get("userId"));
  await store.claimDeviceSlot(sid, c.get("client"));
  logEvent("device_slot_claimed", { userId: c.get("userId") });
  return c.json({ syncing: true });
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

// ---- private read-only iCal feed (docs/TASK_TIMES_AND_ICAL_SPEC.md §3, #166) ----
// Free account feature: requires sign-in to manage settings; the .ics feed
// itself authenticates by an unguessable 32-byte base64url URL token.

const zIcalScope = z.enum(["all", "timed"]);
const zIcalUpdateBody = z.object({
  enabled: z.boolean().optional(),
  scope: zIcalScope.optional(),
  rotate: z.boolean().optional(),
}).strict();
const ICAL_TOKEN_RE = /^[A-Za-z0-9_-]{32,64}$/;

function icalKvKey(tokenHash: string): string {
  return `ical:${tokenHash}`;
}

function icalFeedResponse(apiPublicUrl: string, feed: { token: string; scope: IcalScope; createdAt: string } | null) {
  if (!feed) {
    return { enabled: false, scope: "all" as IcalScope, url: null, webcalUrl: null, createdAt: null };
  }
  const base = apiPublicUrl.replace(/\/+$/, "");
  const url = `${base}/v1/ical/${feed.token}.ics`;
  const webcalUrl = url.replace(/^https?:\/\//i, "webcal://");
  return { enabled: true, scope: feed.scope, url, webcalUrl, createdAt: feed.createdAt };
}

function ifNoneMatchHit(header: string | undefined, etag: string): boolean {
  if (!header) return false;
  const bare = etag.replace(/^W\//, "");
  for (const part of header.split(",")) {
    const tag = part.trim();
    if (tag === "*" || tag === etag || tag.replace(/^W\//, "") === bare) return true;
  }
  return false;
}

api.get("/ical/settings", async (c) => {
  const feed = await storeFor(c.env, c.get("userId")).getIcalFeed();
  return c.json(icalFeedResponse(c.env.API_PUBLIC_URL, feed), 200, { "Cache-Control": "no-store" });
});

api.post("/ical/settings", async (c) => {
  const body = await parse(c, zIcalUpdateBody);
  if (body instanceof Response) return body;
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);

  if (body.enabled === false) {
    const { prevTokenHash } = await store.deleteIcalFeed();
    if (prevTokenHash) await c.env.TOKENS.delete(icalKvKey(prevTokenHash));
    logEvent("ical_feed_disabled", {});
    return c.json(icalFeedResponse(c.env.API_PUBLIC_URL, null), 200, { "Cache-Control": "no-store" });
  }

  const existing = await store.getIcalFeed();
  const nextScope: IcalScope = body.scope ?? existing?.scope ?? "all";

  if (!existing || body.rotate === true) {
    const token = randomId(32);
    const tokenHash = await sha256Base64Url(token);
    const { prevTokenHash, feed } = await store.setIcalFeed(token, tokenHash, nextScope);
    await c.env.TOKENS.put(icalKvKey(tokenHash), userId);
    if (prevTokenHash && prevTokenHash !== tokenHash) {
      await c.env.TOKENS.delete(icalKvKey(prevTokenHash));
    }
    logEvent(existing ? "ical_feed_rotated" : "ical_feed_enabled", { scope: feed.scope });
    return c.json(icalFeedResponse(c.env.API_PUBLIC_URL, feed), 200, { "Cache-Control": "no-store" });
  }

  const feed = body.scope && body.scope !== existing.scope
    ? ((await store.setIcalScope(nextScope)) ?? existing)
    : existing;
  await c.env.TOKENS.put(icalKvKey(feed.tokenHash), userId);
  return c.json(icalFeedResponse(c.env.API_PUBLIC_URL, feed), 200, { "Cache-Control": "no-store" });
});

api.delete("/ical/settings", async (c) => {
  const { prevTokenHash } = await storeFor(c.env, c.get("userId")).deleteIcalFeed();
  if (prevTokenHash) await c.env.TOKENS.delete(icalKvKey(prevTokenHash));
  logEvent("ical_feed_disabled", {});
  return c.body(null, 204);
});

api.get("/ical/:tokenFile", async (c) => {
  const raw = c.req.param("tokenFile");
  if (!raw.endsWith(".ics")) return c.notFound();
  const token = raw.slice(0, -4);
  if (!ICAL_TOKEN_RE.test(token)) return c.notFound();
  const tokenHash = await sha256Base64Url(token);
  const userId = await c.env.TOKENS.get(icalKvKey(tokenHash));
  if (!userId) return c.notFound();

  const snap = await storeFor(c.env, userId).readIcalSnapshot(tokenHash);
  if (!snap) return c.notFound();

  const tz = snap.homeTimezone && isValidTz(snap.homeTimezone) ? snap.homeTimezone : "UTC";
  const today = todayYMD(tz);
  const etag = icalEtag(snap.rev, snap.scope, today);
  const headers = {
    ETag: etag,
    "Cache-Control": "private, max-age=300",
  };
  if (ifNoneMatchHit(c.req.header("If-None-Match"), etag)) {
    return new Response(null, { status: 304, headers });
  }

  const body = buildIcalFeed({
    tasks: snap.tasks,
    scope: snap.scope,
    today,
    nowIso: new Date().toISOString(),
    homeTimezone: snap.homeTimezone,
  });
  return new Response(body, {
    status: 200,
    headers: {
      ...headers,
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="septena-tasks.ics"',
    },
  });
});

// ---- account deletion (§10) ----

api.delete("/account", async (c) => {
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);
  const ical = await store.getIcalFeed();
  if (ical) await c.env.TOKENS.delete(icalKvKey(ical.tokenHash));
  await store.deleteAccount();
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
