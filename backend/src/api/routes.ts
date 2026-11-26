import { Hono, type Context, type Next } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { support } from "../support/routes.js";
import { logEvent, randomId, sha256Base64Url } from "../util.js";
import { buildIcalFeed, icalEtag, type IcalScope } from "../ical.js";
import { isValidTz, todayYMD } from "../tz.js";
import { MAX_ATTACHMENT_BYTES, zId } from "../store/columns.js";
import { zPushBody, type Op } from "../store/ops.js";
import type { ChangeEntry } from "../store/TaskStore.js";
import { USER_ID_RE, accountStoreFor } from "../store/AccountStore.js";
import { ensureReviewerAccount, prepareReviewerAccount } from "../shadow/reviewer.js";
import { AppleIdentityError, userIdForAppleSub, verifyAppleIdentityToken } from "./appleIdentity.js";
import { HANDOFF_TTL_S, accountAlreadyDeleted, authenticate, issueSession, refreshSession, revokeSession, storeFor, withSession } from "./session.js";
import { SESSION_HEADER } from "../store/sessions.js";
import {
  clearRefreshCookie,
  cookieSessionResponse,
  isAllowedWebOrigin,
  issueWsTicket,
  readRefreshCookie,
  redeemWsTicket,
  webCorsMiddleware,
} from "./webAuth.js";
import { enabledSignInMethods, startEmailSignIn, verifyEmailSignIn, zEmailStartBody, zEmailVerifyBody } from "./emailSignIn.js";
import {
  completeCollisionLink,
  linkEmailToAccount,
  linkProviderToAccount,
  listUserIdentities,
  resolveProviderLogin,
  unlinkIdentityFromAccount,
  zLinkCompleteBody,
  zLinkEmailVerifyBody,
} from "./authLink.js";
import {
  OidcTokenError,
  acceptedAppleAudiences,
  isGoogleNativeEnabled,
  isOidcWebEnabled,
  oidcCallback,
  oidcRedeem,
  oidcStart,
  startOidcLinkUrl,
  verifyGoogleNativeToken,
  zGoogleNativeBody,
  zOidcLinkStartBody,
} from "./oidc.js";
import {
  approvePairing,
  denyPairing,
  zAgentName,
  inspectPairing,
  pollDevicePairing,
  startDevicePairing,
  zDevicePollBody,
  zDeviceStartBody,
  zPairApproveBody,
  zPairDenyBody,
  zPairInspectBody,
} from "../shadow/oauth.js";
import { MCP_READ_SCOPE, MCP_WRITE_SCOPE, createAgentKey, disconnectFamily, hasScope, isMcpAccessToken, verifyMcpAccess } from "../shadow/tokens.js";
import { pollAgentSignup, startAgentSignup, zAgentSignupPollBody, zAgentSignupStartBody } from "../shadow/agentSignup.js";
import { refreshAccounts } from "../admin/accounts.js";
import { MAX_AGENT_WEBHOOKS, validateWebhookUrl } from "./agentWake.js";
import {
  TRIAL_ROW_ID,
  appAccountTokenFor,
  decide,
  grantRow,
  historyCutoff,
  historyEdgeUpsell,
  isEnforcing,
  isRowActive,
  markTrialUsed,
  planCheckFailed,
  planFor,
  startTrialOnce,
  trialEndsAt,
  upsellLine,
  usageKeys,
  type LimitBreach,
  type PlanFailureMode,
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
import { attachmentKey, attachmentRefusal } from "./attachments.js";
import { agentUpload } from "../shadow/attachments.js";
import { notesHistoryRest } from "./notesHistoryRest.js";
import { shares } from "./shares.js";
import { projectStoreFor } from "../store/ProjectStore.js";
import { tasksRest } from "./tasksRest.js";
import { ERROR_FORMAT_HEADER, envelopeResponse } from "../errors.js";

// Task backend API, mounted at /v1 (docs/SEPTASK_BACKEND.md in the app repo).
// Phase 0: no app or MCP tool calls this yet. The live connector is unchanged.

type Vars = {
  userId: string;
  actor: string;
  /// The app session's id (null for an agent). One session = one device for
  /// the sync slot.
  sid: string | null;
  /// The session behind the call, an app's or an agent's.
  session: string;
  /// `X-Septena-Client`, when valid. Labels the device.
  client: string | null;
  /// Set by `loadPlan`. null when the check failed and failed open (sync paths
  /// or log-only mode): the call then runs with no limits.
  plan: PlanState | null;
};
type Ctx = Context<{ Bindings: Env; Variables: Vars }>;

export const api = new Hono<{ Bindings: Env; Variables: Vars }>();

// CORS for browser clients (docs/WEB_CLIENT_SPEC.md §5).
api.use("*", webCorsMiddleware);
// Contact Support (ADR 0054): its own sender rules, signed in or not.
api.route("/support", support);
// The one error envelope, for a caller that asks for it (src/errors.ts).
api.use("*", async (c, next) => {
  await next();
  if (c.req.header(ERROR_FORMAT_HEADER)?.trim().toLowerCase() === "envelope") c.res = await envelopeResponse(c.res);
});

const zAppleBody = z.object({
  identityToken: z.string().min(20).max(8_000),
  nonce: z.string().min(16).max(256),
}).strict();
const zRefreshBody = z.object({ refreshToken: z.string().min(20).max(400) }).strict();
const zClientName = z.string().regex(/^[\w .()-]{1,40}$/);

/// The app version behind a call, for the device list on the admin page.
function clientVersion(c: Ctx): string | null {
  const sent = zClientName.safeParse(c.req.header("X-Septena-Version"));
  return sent.success ? sent.data : null;
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
    const apple = await verifyAppleIdentityToken(body.identityToken, body.nonce, acceptedAppleAudiences(c.env));
    const derivedUserId = await userIdForAppleSub(apple.sub);
    const login = await resolveProviderLogin(c.env, {
      provider: "apple",
      subject: apple.sub,
      preferredUserId: derivedUserId,
      email: apple.email,
      emailVerified: apple.emailVerified,
      clientIp: c.req.header("CF-Connecting-IP"),
    });
    if (login.outcome === "needs_link") {
      return c.json({
        error: "account_exists",
        email: login.email,
        provider: login.provider,
        linkToken: login.linkToken,
        codeSent: login.codeSent,
      }, 409, { "Cache-Control": "no-store" });
    }
    if (login.outcome === "needs_link_email_off") {
      return c.json({ error: "account_exists", email: login.email, provider: login.provider }, 409, { "Cache-Control": "no-store" });
    }
    logEvent("api_signin", { ok: true });
    return c.json(await issueSession(c.env, login.userId));
  } catch (e) {
    if (e instanceof AppleIdentityError) {
      logEvent("api_signin", { ok: false, reason: e.message });
      return c.json({ error: "invalid_identity_token" }, 401);
    }
    throw e;
  }
});

// Native Android Google Credential Manager sign-in (ADR 0047, #637).
api.post("/auth/google/native", async (c) => {
  if (!isGoogleNativeEnabled(c.env)) return c.json({ error: "provider_off" }, 503, { "Cache-Control": "no-store" });
  const body = await parse(c, zGoogleNativeBody);
  if (body instanceof Response) return body;
  try {
    const google = await verifyGoogleNativeToken(c.env, body);
    const login = await resolveProviderLogin(c.env, {
      provider: "google",
      subject: google.subject,
      email: google.email,
      emailVerified: google.emailVerified,
      clientIp: c.req.header("CF-Connecting-IP"),
    });
    if (login.outcome === "needs_link") {
      return c.json({
        error: "account_exists",
        email: login.email,
        provider: login.provider,
        linkToken: login.linkToken,
        codeSent: login.codeSent,
      }, 409, { "Cache-Control": "no-store" });
    }
    if (login.outcome === "needs_link_email_off") {
      return c.json({ error: "account_exists", email: login.email, provider: login.provider }, 409, { "Cache-Control": "no-store" });
    }
    logEvent("api_signin", { ok: true, provider: "google" });
    return c.json(await issueSession(c.env, login.userId), 200, { "Cache-Control": "no-store" });
  } catch (e) {
    if (e instanceof OidcTokenError) {
      logEvent("api_signin", { ok: false, provider: "google", reason: e.message });
      return c.json({ error: "invalid_identity_token" }, 401, { "Cache-Control": "no-store" });
    }
    throw e;
  }
});

// OIDC web redirects for Google, Microsoft and Web Sign in with Apple (ADR 0047, #637).
api.get("/auth/oidc/:provider/start", oidcStart);
api.get("/auth/oidc/:provider/callback", oidcCallback);
api.post("/auth/oidc/:provider/callback", oidcCallback);
api.post("/auth/oidc/redeem", oidcRedeem);

// Finish no-silent-linking collision step with email code (ADR 0047 decision 5).
api.post("/auth/link/complete", async (c) => {
  const body = await parse(c, zLinkCompleteBody);
  if (body instanceof Response) return body;
  const cookieMode = body.sessionMode === "cookie";
  if (cookieMode && !isAllowedWebOrigin(c.env, c.req.header("Origin"))) {
    return c.json({ error: "origin_not_allowed" }, 403, { "Cache-Control": "no-store" });
  }
  const res = await completeCollisionLink(c.env, body, c.req.header("CF-Connecting-IP"));
  if (!res.ok) {
    return c.json({ error: res.error, ...(res.attemptsLeft !== undefined ? { attemptsLeft: res.attemptsLeft } : {}) }, res.status, { "Cache-Control": "no-store" });
  }
  const session = await issueSession(c.env, res.userId);
  return cookieMode
    ? cookieSessionResponse(c.env, session)
    : c.json(session, 200, { "Cache-Control": "no-store" });
});

async function parseRefreshInput(
  c: Ctx,
): Promise<{ mode: "body"; refreshToken: string } | { mode: "cookie" } | Response> {
  const raw = await c.req.text();
  if (raw.trim() === "") return { mode: "cookie" };
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  if (body !== null && typeof body === "object" && !Array.isArray(body) && Object.keys(body).length === 0) {
    return { mode: "cookie" };
  }
  const parsed = zRefreshBody.safeParse(body);
  if (!parsed.success) return c.json({ error: "invalid_request", issues: parsed.error.issues.slice(0, 20) }, 400);
  return { mode: "body", refreshToken: parsed.data.refreshToken };
}

api.post("/auth/refresh", async (c) => {
  const input = await parseRefreshInput(c);
  if (input instanceof Response) return input;
  if (input.mode === "body") {
    const session = await refreshSession(c.env, input.refreshToken);
    return session ? c.json(session, 200, { "Cache-Control": "no-store" }) : c.json({ error: "invalid_grant" }, 401);
  }
  if (!isAllowedWebOrigin(c.env, c.req.header("Origin"))) {
    return c.json({ error: "origin_not_allowed" }, 403, { "Cache-Control": "no-store" });
  }
  const cookieToken = readRefreshCookie(c.req.raw);
  if (!cookieToken) return c.json({ error: "invalid_grant" }, 401, { "Cache-Control": "no-store" });
  const session = await refreshSession(c.env, cookieToken);
  if (!session) {
    return c.json({ error: "invalid_grant" }, 401, {
      "Cache-Control": "no-store",
      "Set-Cookie": clearRefreshCookie(c.env),
    });
  }
  return cookieSessionResponse(c.env, session);
});

api.post("/auth/signout", async (c) => {
  const input = await parseRefreshInput(c);
  if (input instanceof Response) return input;
  if (input.mode === "body") {
    await revokeSession(c.env, input.refreshToken);
    return c.body(null, 204);
  }
  if (!isAllowedWebOrigin(c.env, c.req.header("Origin"))) {
    return c.json({ error: "origin_not_allowed" }, 403, { "Cache-Control": "no-store" });
  }
  const cookieToken = readRefreshCookie(c.req.raw);
  if (cookieToken) await revokeSession(c.env, cookieToken);
  return new Response(null, {
    status: 204,
    headers: { "Set-Cookie": clearRefreshCookie(c.env) },
  });
});

// Which sign-in methods this server has on (ADR 0047, docs/SIGN_IN_SURFACES_SPEC.md §3).
api.get("/auth/methods", (c) => {
  const methods: Array<{ id: string; web?: boolean; native?: boolean }> = [
    { id: "apple", ...(isOidcWebEnabled(c.env, "apple") ? { web: true } : {}) },
  ];
  const googleWeb = isOidcWebEnabled(c.env, "google");
  const googleNative = isGoogleNativeEnabled(c.env);
  if (googleWeb || googleNative) {
    methods.push({ id: "google", ...(googleWeb ? { web: true } : {}), ...(googleNative ? { native: true } : {}) });
  }
  if (isOidcWebEnabled(c.env, "microsoft")) {
    methods.push({ id: "microsoft", web: true });
  }
  for (const id of enabledSignInMethods(c.env)) {
    if (id !== "apple") methods.push({ id });
  }
  return c.json({ methods }, 200, { "Cache-Control": "no-store" });
});

// Email one-time code (ADR 0016, issue #169): see ./emailSignIn.ts.
api.post("/auth/email/start", async (c) => {
  const body = await parse(c, zEmailStartBody);
  if (body instanceof Response) return body;
  const res = await startEmailSignIn(c.env, body, c.req.header("CF-Connecting-IP"));
  if (res.ok) return c.json({ status: "sent", expiresInSeconds: res.expiresInSeconds, codeLength: 6 }, 202, { "Cache-Control": "no-store" });
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  if (res.retryAfterSeconds) headers["Retry-After"] = String(res.retryAfterSeconds);
  return c.json({ error: res.error, ...(res.retryAfterSeconds ? { retryAfterSeconds: res.retryAfterSeconds } : {}) }, res.status, headers);
});

api.post("/auth/email/verify", async (c) => {
  const body = await parse(c, zEmailVerifyBody);
  if (body instanceof Response) return body;
  const cookieMode = body.sessionMode === "cookie";
  if (cookieMode && !isAllowedWebOrigin(c.env, c.req.header("Origin"))) {
    return c.json({ error: "origin_not_allowed" }, 403, { "Cache-Control": "no-store" });
  }
  const res = await verifyEmailSignIn(c.env, body, c.req.header("CF-Connecting-IP"));
  if (!res.ok) {
    return c.json({ error: res.error, ...(res.attemptsLeft !== undefined ? { attemptsLeft: res.attemptsLeft } : {}) }, res.status, { "Cache-Control": "no-store" });
  }
  return cookieMode
    ? cookieSessionResponse(c.env, res.session)
    : c.json(res.session, 200, { "Cache-Control": "no-store" });
});

// Device sign-in by approval (ADR 0016, issue #170): see src/shadow/oauth.ts.
api.post("/auth/device/start", async (c) => {
  const body = await parse(c, zDeviceStartBody);
  if (body instanceof Response) return body;
  const res = await startDevicePairing(c.env, body, c.req.header("CF-Connecting-IP"));
  return res.ok
    ? c.json(res.data, 200, { "Cache-Control": "no-store" })
    : c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
});

api.post("/auth/device/poll", async (c) => {
  const body = await parse(c, zDevicePollBody);
  if (body instanceof Response) return body;
  const cookieMode = body.sessionMode === "cookie";
  if (cookieMode && !isAllowedWebOrigin(c.env, c.req.header("Origin"))) {
    return c.json({ error: "origin_not_allowed" }, 403, { "Cache-Control": "no-store" });
  }
  const res = await pollDevicePairing(c.env, body, c.req.header("CF-Connecting-IP"));
  if (res.status === "pending") return c.json({ status: "pending" }, 202, { "Cache-Control": "no-store" });
  if (res.status === "denied") return c.json({ error: "denied" }, 410, { "Cache-Control": "no-store" });
  if (res.status === "rate_limited") return c.json({ error: "too_many_attempts" }, 429, { "Cache-Control": "no-store" });
  if (res.status === "gone") return c.json({ error: "expired_or_unknown" }, 410, { "Cache-Control": "no-store" });
  if (!(await storeFor(c.env, res.userId).hasAppSession())) return c.json({ error: "expired_or_unknown" }, 410, { "Cache-Control": "no-store" });
  const session = await issueSession(c.env, res.userId);
  return cookieMode
    ? cookieSessionResponse(c.env, session)
    : c.json(session, 200, { "Cache-Control": "no-store" });
});

// Headless agent account creation & connection (ADR 0056, src/shadow/agentSignup.ts).
api.post("/agent/signup/start", async (c) => {
  const body = await parse(c, zAgentSignupStartBody);
  if (body instanceof Response) return body;
  const res = await startAgentSignup(c.env, body, c.req.header("CF-Connecting-IP"));
  if (res.ok) return c.json(res.data, 202, { "Cache-Control": "no-store" });
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  if (res.retryAfterSeconds) headers["Retry-After"] = String(res.retryAfterSeconds);
  return c.json({ error: res.error, ...(res.retryAfterSeconds ? { retryAfterSeconds: res.retryAfterSeconds } : {}) }, res.status, headers);
});

api.post("/agent/signup/poll", async (c) => {
  const body = await parse(c, zAgentSignupPollBody);
  if (body instanceof Response) return body;
  const res = await pollAgentSignup(c.env, body, c.req.header("CF-Connecting-IP"));
  if (res.status === "pending") return c.json({ status: "pending" }, 202, { "Cache-Control": "no-store" });
  if (res.status === "denied") return c.json({ error: "denied" }, 410, { "Cache-Control": "no-store" });
  if (res.status === "rate_limited") return c.json({ error: "too_many_attempts" }, 429, { "Cache-Control": "no-store" });
  if (res.status === "gone") return c.json({ error: "expired_or_unknown" }, 410, { "Cache-Control": "no-store" });
  try {
    c.executionCtx.waitUntil(refreshAccounts(c.env, [res.data.userId]));
  } catch {
    void refreshAccounts(c.env, [res.data.userId]);
  }
  return c.json(res.data, 200, { "Cache-Control": "no-store" });
});

// ---- everything below needs a bearer access token ----

async function requireUser(c: Ctx, next: Next) {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  const claims = token ? await authenticate(c.env, token) : null;
  if (!claims) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
  const client = zClientName.safeParse(c.req.header("X-Septena-Client"));
  c.set("userId", claims.userId);
  c.set("sid", claims.sid);
  c.set("session", claims.sid);
  c.set("client", client.success ? client.data : null);
  c.set("actor", `app:${client.success ? client.data : "unknown"}`);
  await next();
}

/// Accepts either an app session bearer token (`sa1.*`) or an MCP OAuth access
/// token (`sm2.*`) with `tasks:read` scope. Used by the agent wake event stream
/// so both the app and background runners can subscribe.
async function requireAgentOrUser(c: Ctx, next: Next) {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });

  if (isMcpAccessToken(token)) {
    const grant = await verifyMcpAccess(c.env, token);
    if (!grant) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
    if (!hasScope(grant, MCP_READ_SCOPE)) {
      return c.json({ error: "insufficient_scope", scope: MCP_READ_SCOPE }, 403);
    }
    c.set("userId", grant.userId);
    c.set("sid", null);
    c.set("session", grant.familyId ?? "");
    c.set("client", null);
    c.set("actor", `mcp:${grant.clientId}`);
    await next();
    return;
  }

  const claims = await authenticate(c.env, token);
  if (!claims) return c.json({ error: "unauthorized" }, 401, { "WWW-Authenticate": "Bearer" });
  const client = zClientName.safeParse(c.req.header("X-Septena-Client"));
  c.set("userId", claims.userId);
  c.set("sid", claims.sid);
  c.set("session", claims.sid);
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
/// requireUser. Sync paths fail open (spec §6.4 finding 6) so a store hiccup
/// never stops sync for paying users; attachments stay fail-closed in enforce
/// mode.
function loadPlan(mode: PlanFailureMode, surface: string) {
  return async (c: Ctx, next: Next) => {
    try {
      const plan = await planFor(c.env, c.get("userId"));
      c.set("plan", plan);
      // Before enforcement, every free-account sync call says so, as the old
      // yes/no gate's would-block line did: spec §6.2 finds the user id here.
      if (plan.plan === "free" && !isEnforcing(c.env)) logEvent("entitlement_free_account", { userId: c.get("userId") });
    } catch (e) {
      if (planCheckFailed(c.env, c.get("userId"), surface, e, mode) === "block") {
        return c.json({ error: "plan_check_failed" }, 503);
      }
      c.set("plan", null);
    }
    await next();
  };
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
    const { syncing } = await storeFor(c.env, c.get("userId")).deviceAccess(sid, c.get("client"), plan.limits.devices, Date.now(), clientVersion(c));
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

/// Like `requireUser`, but also allows a single-use `?ticket=` on `GET /v1/sync/ws`
/// because browser WebSockets cannot set `Authorization` (docs/WEB_CLIENT_SPEC.md §5).
async function requireSyncUser(c: Ctx, next: Next) {
  const header = c.req.header("Authorization") ?? "";
  const isWsRoute = c.req.method === "GET" && new URL(c.req.url).pathname.endsWith("/sync/ws");
  const ticket = isWsRoute && !header ? c.req.query("ticket") : undefined;
  if (ticket) {
    const origin = c.req.header("Origin");
    if (origin && !isAllowedWebOrigin(c.env, origin)) {
      return c.json({ error: "origin_not_allowed" }, 403);
    }
    const claims = await redeemWsTicket(c.env, ticket);
    if (!claims) return c.json({ error: "unauthorized" }, 401);
    c.set("userId", claims.userId);
    c.set("sid", claims.sid);
    c.set("session", claims.sid ?? "");
    c.set("client", claims.client);
    c.set("actor", `app:${claims.client ?? "unknown"}`);
    await next();
    return;
  }
  return requireUser(c, next);
}

api.use("/sync/*", requireSyncUser, loadPlan("open", "sync"), requireSyncDevice);
api.use("/attachments/*", requireUser, loadPlan("closed", "attachments"), requireSyncDevice);
api.use("/account", async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  if (c.req.method === "DELETE" && header.startsWith("Bearer ") && await accountAlreadyDeleted(c.env, header.slice(7))) {
    return c.body(null, 204);
  }
  await next();
}, requireUser);
api.use("/devices/*", requireUser);
api.use("/ical/settings", requireUser);
api.use("/changes", requireUser, loadPlan("open", "changes"), requireSyncDevice);
api.use("/notes/*", requireUser);
api.use("/pair/*", requireUser);
api.use("/auth/device", requireUser);
api.use("/auth/identities", requireUser);
api.use("/auth/identities/*", requireUser);
api.use("/auth/link/email/*", requireUser);
api.use("/auth/link/apple", requireUser);
api.use("/auth/link/google/*", requireUser);
api.use("/auth/link/oidc/*", requireUser);
// The watch is a companion of a signed-in phone or Mac: it loads the plan
// but takes no sync device slot of its own.
api.use("/tasks", requireUser, loadPlan("open", "tasks"));
api.use("/tasks/*", requireUser, loadPlan("open", "tasks"));
api.use("/shares", apiHostOnly, requireUser);
api.use("/shares/*", apiHostOnly, requireUser);
api.use("/access", apiHostOnly, requireUser);
api.use("/access/*", apiHostOnly, requireUser);
api.use("/agent/events/*", apiHostOnly, requireAgentOrUser);
api.use("/agent/webhooks", apiHostOnly, requireUser);
api.use("/agent/webhooks/*", apiHostOnly, requireUser);
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
    // `refs=1`: the client syncs the `taskRef` entity (TaskStore.pull).
    refs: z.enum(["0", "1"]).default("0"),
    // `doSessions=1`: the client syncs the `doSession` entity (TaskStore.pull).
    doSessions: z.enum(["0", "1"]).default("0"),
  }).safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  return c.json(await storeFor(c.env, c.get("userId")).pull(
    q.data.since,
    q.data.limit,
    q.data.settings === "1",
    q.data.checklists === "1",
    q.data.tags === "1",
    q.data.refs === "1",
    q.data.doSessions === "1",
  ));
});

async function liveSocket(c: Ctx) {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") return c.json({ error: "expected_websocket" }, 426);
  // Without live sync the app polls `/sync/pull` (spec §3).
  const plan = c.get("plan");
  if (plan && !plan.limits.liveSync) {
    const breach: LimitBreach = { limit: "liveSync", upsell: null };
    if (decide(c.env, c.get("userId"), "sync_live", plan, breach) === "block") return limitRefusal(c, "live_sync_not_in_plan", breach);
  }
  return storeFor(c.env, c.get("userId")).fetch(withSession(c.req.raw, c.get("session"), SESSION_HEADER));
}

api.post("/sync/ws-ticket", async (c) => {
  const ticket = await issueWsTicket(c.env, {
    userId: c.get("userId"),
    sid: c.get("sid"),
    client: c.get("client"),
  });
  return c.json(ticket, 200, { "Cache-Control": "no-store" });
});

api.get("/sync/ws", liveSocket);

// ---- change history (who changed what, with before/after values) ----

api.get("/changes", async (c) => {
  const q = z.object({
    entity: z.enum(["task", "area", "project", "attachment", "checklistItem", "taskRef", "doSession", "tag", "convo", "setting", "turn"]).optional(),
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

// ---- project & area notes history (docs/PROJECT_NOTES_SPEC.md §6, #123) ----

api.route("/notes", notesHistoryRest);

// ---- attachments (bytes proxied through the Worker; §10 limits) ----

// An agent's file. Its own token is the only credential, so this sits outside
// requireUser (src/shadow/attachments.ts).
api.put("/agent/upload", apiHostOnly, agentUpload);

api.put("/attachments/:id", async (c) => {
  const id = zId.safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "invalid_id" }, 400);
  const length = Number(c.req.header("Content-Length"));
  if (!Number.isInteger(length) || length < 0) return c.json({ error: "length_required" }, 411);
  if (length > MAX_ATTACHMENT_BYTES) return c.json({ error: "too_large", max: MAX_ATTACHMENT_BYTES }, 413);
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);
  const refused = await attachmentRefusal(c.env, userId, c.get("plan"), length, async () => store.attachmentBytes());
  if (refused) return limitRefusal(c, refused.error, refused.breach);
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
/// The first token lives 7 days, and each renewal gives a full one.
/// The new session is a sibling, revocable on its own through /auth/signout.
api.post("/auth/device", async (c) => {
  const userId = c.get("userId");
  logEvent("api_device_session", { by: c.get("actor") });
  return c.json(await issueSession(c.env, userId, HANDOFF_TTL_S));
});

// ---- Sign-in methods management (ADR 0047 decision 6, #171, #643) ----
// Only app sessions reach these routes; agents cannot list, add, or remove
// sign-in methods.

api.get("/auth/identities", async (c) => {
  return c.json(await listUserIdentities(c.env, c.get("userId")), 200, { "Cache-Control": "no-store" });
});

api.delete("/auth/identities/:id", async (c) => {
  let id: string;
  try {
    id = decodeURIComponent(c.req.param("id") ?? "");
  } catch {
    return c.json({ error: "invalid_request" }, 400, { "Cache-Control": "no-store" });
  }
  if (!id || id.length > 300) return c.json({ error: "invalid_request" }, 400, { "Cache-Control": "no-store" });
  const res = await unlinkIdentityFromAccount(c.env, c.get("userId"), id);
  if (!res.ok) return c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
  return c.json({ ok: true, identities: res.identities, canRemove: res.canRemove }, 200, { "Cache-Control": "no-store" });
});

api.post("/auth/link/email/start", async (c) => {
  const body = await parse(c, zEmailStartBody);
  if (body instanceof Response) return body;
  const res = await startEmailSignIn(c.env, body, c.req.header("CF-Connecting-IP"));
  if (res.ok) return c.json({ status: "sent", expiresInSeconds: res.expiresInSeconds, codeLength: 6 }, 202, { "Cache-Control": "no-store" });
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  if (res.retryAfterSeconds) headers["Retry-After"] = String(res.retryAfterSeconds);
  return c.json({ error: res.error, ...(res.retryAfterSeconds ? { retryAfterSeconds: res.retryAfterSeconds } : {}) }, res.status, headers);
});

api.post("/auth/link/email/verify", async (c) => {
  const body = await parse(c, zLinkEmailVerifyBody);
  if (body instanceof Response) return body;
  const res = await linkEmailToAccount(c.env, c.get("userId"), body, c.req.header("CF-Connecting-IP"));
  if (!res.ok) {
    return c.json({ error: res.error, ...(res.attemptsLeft !== undefined ? { attemptsLeft: res.attemptsLeft } : {}) }, res.status, { "Cache-Control": "no-store" });
  }
  return c.json({ ok: true, created: res.created, identities: res.identities, canRemove: res.canRemove }, 200, { "Cache-Control": "no-store" });
});

api.post("/auth/link/apple", async (c) => {
  const body = await parse(c, zAppleBody);
  if (body instanceof Response) return body;
  try {
    const apple = await verifyAppleIdentityToken(body.identityToken, body.nonce, acceptedAppleAudiences(c.env));
    const res = await linkProviderToAccount(c.env, c.get("userId"), "apple", apple.sub);
    if (!res.ok) return c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
    return c.json({ ok: true, created: res.created, identities: res.identities, canRemove: res.canRemove }, 200, { "Cache-Control": "no-store" });
  } catch (e) {
    if (e instanceof AppleIdentityError) {
      return c.json({ error: "invalid_identity_token" }, 401, { "Cache-Control": "no-store" });
    }
    throw e;
  }
});

api.post("/auth/link/google/native", async (c) => {
  if (!isGoogleNativeEnabled(c.env)) return c.json({ error: "provider_off" }, 503, { "Cache-Control": "no-store" });
  const body = await parse(c, zGoogleNativeBody);
  if (body instanceof Response) return body;
  try {
    const google = await verifyGoogleNativeToken(c.env, body);
    const res = await linkProviderToAccount(c.env, c.get("userId"), "google", google.subject);
    if (!res.ok) return c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
    return c.json({ ok: true, created: res.created, identities: res.identities, canRemove: res.canRemove }, 200, { "Cache-Control": "no-store" });
  } catch (e) {
    if (e instanceof OidcTokenError) {
      return c.json({ error: "invalid_identity_token" }, 401, { "Cache-Control": "no-store" });
    }
    throw e;
  }
});

api.post("/auth/link/oidc/start", async (c) => {
  const body = await parse(c, zOidcLinkStartBody);
  if (body instanceof Response) return body;
  const res = await startOidcLinkUrl(c.env, c.get("userId"), body);
  if (!res.ok) return c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
  return c.json({ url: res.url }, 200, { "Cache-Control": "no-store" });
});

// ---- APNs device push tokens (F1b #213, docs/TASK_FACTORY_SPEC.md §8) ----

const zPushToken = z.string().regex(/^[0-9a-fA-F]{32,256}$/);
const zPushTokenRegisterBody = z.object({
  token: zPushToken,
  platform: z.enum(["ios", "watchos"]).default("ios"),
  sandbox: z.boolean().default(false),
  deviceId: z.string().trim().min(1).max(128).optional(),
}).strict();
const zPushTokenDeleteBody = z.object({
  token: zPushToken,
}).strict();

api.post("/devices/push-token", async (c) => {
  const body = await parse(c, zPushTokenRegisterBody);
  if (body instanceof Response) return body;
  const saved = await storeFor(c.env, c.get("userId")).upsertPushToken({
    token: body.token.toLowerCase(),
    deviceId: body.deviceId ?? c.get("sid") ?? null,
    platform: body.platform,
    sandbox: body.sandbox,
  });
  logEvent("push_token_registered", { platform: saved.platform, sandbox: saved.sandbox });
  return c.json({ ok: true, platform: saved.platform, sandbox: saved.sandbox }, 200, { "Cache-Control": "no-store" });
});

api.delete("/devices/push-token", async (c) => {
  const body = await parse(c, zPushTokenDeleteBody);
  if (body instanceof Response) return body;
  const removed = await storeFor(c.env, c.get("userId")).deletePushToken(body.token.toLowerCase());
  logEvent("push_token_deleted", { removed });
  return c.body(null, 204);
});

// ---- task views and verbs for thin clients (src/api/tasksRest.ts) ----

// The same socket for a companion device (docs/COMPANION_DEVICES_SPEC.md §4):
// it has no task store, so it takes no sync device slot. It carries a revision
// number only.
api.get("/tasks/live", liveSocket);
api.route("/tasks", tasksRest);

// ---- shared projects (src/api/shares.ts) ----

api.route("/shares", shares);

api.post("/pair/approve", async (c) => {
  const body = await parse(c, zPairApproveBody);
  if (body instanceof Response) return body;
  const res = await approvePairing(c.env, c.get("userId"), body);
  return res.ok
    ? c.json({ ok: true, client: res.client, kind: res.kind }, 200, { "Cache-Control": "no-store" })
    : c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
});

api.post("/pair/deny", async (c) => {
  const body = await parse(c, zPairDenyBody);
  if (body instanceof Response) return body;
  const res = await denyPairing(c.env, c.get("userId"), body);
  return res.ok
    ? c.json({ ok: true, client: res.client, kind: res.kind }, 200, { "Cache-Control": "no-store" })
    : c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
});

// ---- Devices & Access (Settings > Account > Devices & Access) ----
// Every place the account is signed in: app sessions (one per install) and
// MCP connections (Claude, ChatGPT and other connector clients).

const zSid = z.string().uuid();
const zFamilyId = z.string().regex(/^[A-Za-z0-9_-]{8,64}$/);

api.get("/access", async (c) => {
  const userId = c.get("userId");
  let cap: number | null = null;
  let agentLimit: number | null = null;
  try {
    const limits = (await planFor(c.env, userId)).limits;
    cap = limits.devices;
    agentLimit = limits.connectedAgents;
  } catch {
    // The list still shows; "syncing" then reads true for every device.
  }
  const summary = await storeFor(c.env, userId).accessSummary(c.get("sid"), cap, Date.now(), agentLimit);
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

/// Creates an agent key (#86) for an agent that cannot sign in. Only an app
/// session reaches this route, so an agent cannot mint keys. The key is in
/// this reply only. The key's row in the Agents list is `id`: rename and
/// revoke use the connection routes above and below.
const zCreateKeyBody = z.object({
  name: zAgentName,
  access: z.enum(["read", "write"]).default("write"),
}).strict();

api.post("/access/keys", async (c) => {
  const body = zCreateKeyBody.safeParse(await c.req.json().catch(() => null));
  if (!body.success) return c.json({ error: "invalid_request" }, 400);
  const userId = c.get("userId");
  const scope = body.data.access === "write" ? `${MCP_READ_SCOPE} ${MCP_WRITE_SCOPE}` : MCP_READ_SCOPE;
  const created = await createAgentKey(c.env, userId, body.data.name, scope);
  logEvent("access_key_created", { userId, by: c.get("actor"), access: body.data.access });
  return c.json(created, 201, { "Cache-Control": "no-store" });
});

/// Renames an agent. `name: null` goes back to the client's registered name.
const zRenameConnectionBody = z.object({ name: zAgentName.nullable() }).strict();

api.patch("/access/connections/:id", async (c) => {
  const id = zFamilyId.safeParse(c.req.param("id"));
  const body = zRenameConnectionBody.safeParse(await c.req.json().catch(() => null));
  if (!id.success || !body.success) return c.json({ error: "invalid_request" }, 400);
  const userId = c.get("userId");
  const had = await storeFor(c.env, userId).renameConnection(id.data, body.data.name);
  if (!had) return c.json({ error: "not_found" }, 404);
  logEvent("access_connection_renamed", { userId, by: c.get("actor") });
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
  const now = Date.now();
  const devices = await store.deviceSummary(state.limits.devices, now);
  const syncingDevices = devices.filter((d) => d.syncing).length;
  const hasFreeSlot = syncingDevices < (state.limits.devices ?? Infinity);
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
      // A device that holds a slot, or any device when a slot is free
      // (including after 14 days of holder inactivity), syncs on its next call.
      syncing: sid ? ((devices.find((d) => d.sid === sid)?.syncing ?? false) || hasFreeSlot) : true,
      syncingDevices,
      knownDevices: devices.length,
    },
  });
});

/// Moves the sync slot to this device ("sync this device instead", spec
/// §3.2). On a capped plan the device used least recently stops syncing and
/// keeps its local data. Free on every plan, limited to one manual move per
/// 24 hours on a capped plan (spec §6.4 finding 2).
api.post("/entitlement/device", async (c) => {
  const sid = c.get("sid");
  if (!sid) return c.json({ error: "refresh_token_first" }, 409);
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);
  let plan: PlanState | null = null;
  try {
    plan = await planFor(c.env, userId);
  } catch (e) {
    // Sync of one device is free; a failed plan read lets the move through.
    planCheckFailed(c.env, userId, "device_slot_move", e, "open");
  }
  const enforce = isEnforcing(c.env);
  const res = await store.claimDeviceSlot(sid, c.get("client"), plan?.limits.devices ?? null, enforce);
  if (!res.ok || res.wouldBlock) {
    const breach: LimitBreach = { limit: "devices", upsell: "second_device" };
    if (plan && decide(c.env, userId, "device_slot_move", plan, breach) === "block") {
      return limitRefusal(c, "device_move_rate_limited", breach);
    }
  }
  logEvent("device_slot_claimed", { userId, moved: res.ok ? res.moved : false });
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

const zUserId = z.string().regex(USER_ID_RE);
const zGrantName = z.string().regex(/^[a-z0-9][a-z0-9._-]{0,39}$/);

api.post("/admin/grants", async (c) => {
  if (!c.env.ADMIN_TOKEN) return c.notFound();
  if (!(await adminAllowed(c))) return c.json({ error: "forbidden" }, 403);
  const body = await parse(c, z.object({
    userId: zUserId,
    name: zGrantName,
    note: z.string().max(200).optional(),
    plan: z.enum(["plus", "pro"]).default("plus"),
    expiresAt: z.string().datetime().optional(),
  }).strict());
  if (body instanceof Response) return body;
  const now = Date.now();
  const store = storeFor(c.env, body.userId);
  const expiresAt = body.expiresAt ? Date.parse(body.expiresAt) : null;
  await store.putEntitlement(grantRow(`grant:${body.name}`, body.plan, expiresAt, body.note ?? null, now), "admin");
  logEvent("entitlement_grant", { userId: body.userId, name: body.name, plan: body.plan });
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

// ---- admin: the directory reviewer demo account (ADR 0055) ----
// Same gate as the grant routes, and 404 unless reviewer mode is on. Returns
// a short-lived connector token for the demo account only; the seed script
// (backend/scripts/reviewer-seed.mjs) fills the account with it and revokes it.

api.post("/admin/reviewer/prepare", async (c) => {
  if (!c.env.ADMIN_TOKEN) return c.notFound();
  if (!(await adminAllowed(c))) return c.json({ error: "forbidden" }, 403);
  const tokens = await prepareReviewerAccount(c.env);
  if (!tokens) return c.json({ error: "reviewer_mode_off" }, 404);
  return c.json(tokens, 200, { "Cache-Control": "no-store" });
});

const zReviewerApproveDeviceBody = z.object({
  code: z.string().min(1).max(32),
}).strict();

/// Approves a pending device sign-in code (e.g. web.septena.app) for the demo
/// account only, so mz can open the demo account in a browser while recording
/// directory walkthroughs. Admin-only and off (404) unless reviewer mode is on.
api.post("/admin/reviewer/approve-device", async (c) => {
  if (!c.env.ADMIN_TOKEN) return c.notFound();
  if (!(await adminAllowed(c))) return c.json({ error: "forbidden" }, 403);
  const mode = await ensureReviewerAccount(c.env);
  if (!mode) return c.json({ error: "reviewer_mode_off" }, 404);
  const body = await parse(c, zReviewerApproveDeviceBody);
  if (body instanceof Response) return body;
  const res = await approvePairing(c.env, mode.userId, { code: body.code, kind: "device" });
  if (res.ok) logEvent("reviewer_device_approved", { ok: true, client: res.client });
  return res.ok
    ? c.json({ ok: true, client: res.client, kind: res.kind }, 200, { "Cache-Control": "no-store" })
    : c.json({ error: res.error }, res.status, { "Cache-Control": "no-store" });
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

// ---- agent wake transport (docs/TASK_FACTORY_SPEC.md §4, §8, issue #5) ----
// Multi-user wake plumbing backed by the user's TaskStore DO:
//   - GET  /v1/agent/events/stream  — SSE (`text/event-stream`) or WebSocket
//     upgrade with `since` / `Last-Event-ID` replay + live push + heartbeats.
//   - GET  /v1/agent/webhooks       — list registered outbound webhooks.
//   - POST /v1/agent/webhooks       — register a signed outbound HTTPS webhook.
//   - DELETE /v1/agent/webhooks/:id — remove a webhook.

api.get("/agent/events/stream", async (c) => {
  const rawCursor = c.req.query("since") ?? c.req.header("Last-Event-ID");
  if (rawCursor !== undefined && rawCursor !== "") {
    if (!/^\d+$/.test(rawCursor) || !Number.isSafeInteger(Number(rawCursor))) {
      return c.json({ error: "invalid_request" }, 400);
    }
  }
  return storeFor(c.env, c.get("userId")).fetch(withSession(c.req.raw, c.get("session"), SESSION_HEADER));
});

const zCreateWebhookBody = z.object({
  url: z.string().min(1).max(2048),
  secret: z.string().min(16).max(256).optional(),
  enabled: z.boolean().optional(),
}).strict();

api.get("/agent/webhooks", async (c) => {
  const webhooks = await storeFor(c.env, c.get("userId")).listAgentWebhooks();
  return c.json({ webhooks }, 200, { "Cache-Control": "no-store" });
});

api.post("/agent/webhooks", async (c) => {
  const body = await parse(c, zCreateWebhookBody);
  if (body instanceof Response) return body;
  const validated = validateWebhookUrl(body.url);
  if (!validated.ok) {
    return c.json({ error: "invalid_webhook_url", reason: validated.reason }, 400);
  }
  const secret = body.secret ?? `whsec_${randomId(32)}`;
  const res = await storeFor(c.env, c.get("userId")).createAgentWebhook(
    validated.url,
    secret,
    body.enabled ?? true,
  );
  if (!res.ok) {
    return c.json({ error: "webhook_limit_reached", max: MAX_AGENT_WEBHOOKS }, 409);
  }
  logEvent("agent_webhook_created", { webhookId: res.webhook.id });
  return c.json(res.webhook, 201, { "Cache-Control": "no-store" });
});

api.delete("/agent/webhooks/:id", async (c) => {
  const id = zId.safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "invalid_request" }, 400);
  const removed = await storeFor(c.env, c.get("userId")).deleteAgentWebhook(id.data);
  if (!removed) return c.json({ error: "not_found" }, 404);
  logEvent("agent_webhook_deleted", { webhookId: id.data });
  return c.body(null, 204);
});

// ---- account deletion (§10) ----

async function emptyAttachments(env: Env, userId: string): Promise<void> {
  const prefix = `u/${userId}/`;
  let cursor: string | undefined;
  do {
    const page = await env.ATTACHMENTS.list({ prefix, cursor });
    if (page.objects.length) await env.ATTACHMENTS.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

api.delete("/account", async (c) => {
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);
  // Shared projects first: each one lets this account go while it exists.
  for (const share of await store.listShares()) await projectStoreFor(c.env, share.id).accountDeleted(userId);
  const [ical, entitlements] = await Promise.all([store.getIcalFeed(), store.entitlements()]);
  if (ical) await c.env.TOKENS.delete(icalKvKey(ical.tokenHash));
  // Preserve `trial-used:<userId>` in KV across account deletion so re-signing
  // up with the same Apple id never starts a second trial (spec §6.4 finding 4).
  if (entitlements.some((r) => r.id === TRIAL_ROW_ID)) await markTrialUsed(c.env, userId);
  // The store goes last: it holds the session, so a failure above it can be
  // retried with the same token. Every step repeats safely.
  const accounts = accountStoreFor(c.env);
  if (accounts) await accounts.deleteIdentitiesForUser(userId);
  await emptyAttachments(c.env, userId);
  await store.deleteAccount();
  // An upload from another device may have landed in between.
  try {
    await emptyAttachments(c.env, userId);
  } catch (e) {
    logEvent("account_attachment_sweep_failed", { userId, error: String(e) });
  }
  logEvent("api_account_deleted", {});
  // The store held every session, so no token of this account works now.
  return c.body(null, 204);
});
