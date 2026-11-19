import { Hono, type Context, type Next } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { MAX_ATTACHMENT_BYTES, zId } from "../store/columns.js";
import { zPushBody, type Op } from "../store/ops.js";
import { AppleIdentityError, userIdForAppleSub, verifyAppleIdentityToken } from "./appleIdentity.js";
import { issueSession, refreshSession, revokeSession, storeFor, verifyAccessToken } from "./session.js";
import { approvePairing, zPairApproveBody } from "../shadow/oauth.js";

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

api.use("/sync/*", requireUser);
api.use("/attachments/*", requireUser);
api.use("/account", requireUser);
api.use("/pair/*", requireUser);

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
  }).safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  return c.json(await storeFor(c.env, c.get("userId")).pull(q.data.since, q.data.limit, q.data.settings === "1"));
});

api.get("/sync/ws", async (c) => {
  if (c.req.header("Upgrade") !== "websocket") return c.json({ error: "expected_websocket" }, 426);
  return storeFor(c.env, c.get("userId")).fetch(c.req.raw);
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

// ---- pairing a Claude connector to this user (MCP preview, src/shadow/) ----

api.post("/pair/approve", async (c) => {
  const body = await parse(c, zPairApproveBody);
  if (body instanceof Response) return body;
  const res = await approvePairing(c.env, c.get("userId"), body);
  return res.ok ? c.json({ ok: true, client: res.client }) : c.json({ error: res.error }, res.status);
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
