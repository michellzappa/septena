// The OpenAPI 3.1 document for /v1 (ADR 0050 §5, docs/AGENT_SURFACE_SPEC.md
// AS4). `scripts/gen-contract.ts` writes it to `src/generated/openapi.json`,
// which the Worker serves at /openapi.json. Never edit the JSON by hand.
//
// Every request schema below is the route's own Zod validator, imported from
// the route file and converted by `zodToJsonSchema`. The route list is checked
// against the Hono router in test/openapi.test.ts: a /v1 route that is neither
// documented here nor listed in INTERNAL_ROUTES fails the backend tests.
//
// The Worker does not import this file. Only the generator and the tests do.

import { z, type ZodTypeAny } from "zod";
import { zId } from "../store/columns.js";
import { zPushBody } from "../store/ops.js";
import { REFUSALS, ERROR_FORMAT_HEADER } from "../errors.js";
import { IDEMPOTENCY_KEY_FIELD, zIdempotencyKey } from "../idempotency.js";
import {
  zDevicePollBody,
  zDeviceStartBody,
  zPairApproveBody,
  zPairDenyBody,
  zPairInspectBody,
} from "../shadow/oauth.js";
import { zAgentSignupPollBody, zAgentSignupStartBody } from "../shadow/agentSignup.js";
import { zEmailStartBody, zEmailVerifyBody } from "./emailSignIn.js";
import { zLinkCompleteBody, zLinkEmailVerifyBody } from "./authLink.js";
import { zGoogleNativeBody, zOidcLinkStartBody, zOidcRedeemBody } from "./oidc.js";
import { SUPPORT_KEY_HEADER, zSupportMessageBody } from "../support/routes.js";
import {
  zAgentEventsQuery,
  zAppleBody,
  zChangesQuery,
  zCreateKeyBody,
  zCreateWebhookBody,
  zEntitlementAppleBody,
  zFamilyId,
  zIcalUpdateBody,
  zPushTokenDeleteBody,
  zPushTokenRegisterBody,
  zRefreshBody,
  zRenameConnectionBody,
  zSid,
  zSyncPullQuery,
} from "./routes.js";
import {
  zAcceptBody,
  zAnswerBody,
  zByRefBody,
  zCreateTaskBody,
  zDeferBody,
  zDoEndBody,
  zDoStartBody,
  zDoVerb,
  zSendBackBody,
  zTasksQuery,
  zVerb,
} from "./tasksRest.js";
import { zShareCreateBody, zShareId, zShareJoinBody, zSharePreviewBody } from "./shares.js";
import { zAvatarPatchBody } from "./avatar.js";
import { zHistoryQuery } from "./notesHistoryRest.js";
import { isOptional, zodToJsonSchema, type JsonSchema } from "./zodJsonSchema.js";
import { zBetaProgressBody, zBetaQuery } from "./beta.js";

type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

/// Who may call a route.
/// - `none`: no credential.
/// - `app`: an app session (`Authorization: Bearer sa1.…`).
/// - `appOrAgent`: an app session or an MCP access token with `tasks:read`.
/// - `uploadToken`: the one-use token from the `tasks_attachment_add` tool.
/// - `feedToken`: the secret in the path is the credential.
/// - `appOrSupportKey`: an app session, or the install's support key header.
type Auth = "none" | "app" | "appOrAgent" | "uploadToken" | "feedToken" | "appOrSupportKey";

interface RouteDoc {
  method: Method;
  /// The Hono path under /v1, with `:param` segments.
  path: string;
  tag: Tag;
  summary: string;
  auth: Auth;
  params?: Record<string, ZodTypeAny>;
  query?: z.AnyZodObject;
  body?: ZodTypeAny;
  /// A raw byte upload instead of a JSON body.
  binaryBody?: boolean;
  /// Takes an idempotency key (ADR 0050 §4).
  idempotent?: boolean;
  /// The success statuses and what they mean.
  ok: Record<number, string>;
  /// A WebSocket upgrade or an event stream, not a JSON answer.
  stream?: "websocket" | "sse" | "calendar" | "bytes";
}

const TAGS = {
  tasks: "Task views and verbs for thin clients. Writes run the same functions as the MCP tools.",
  agent: "Agent sign-up, wake events, webhooks and file uploads.",
  auth: "Sign-in and sessions.",
  sync: "The sync protocol of the apps (ADR 0002).",
  account: "Devices, connections, agent keys, the plan and the account.",
  support: "Contact Support: messages to the Septena team and their replies.",
  shares: "Shared projects.",
  calendar: "The calendar feed.",
} as const;
type Tag = keyof typeof TAGS;

const zTaskId = { id: zId };

/// The /v1 routes on the public contract.
export const ROUTES: RouteDoc[] = [
  // ---- tasks ----
  { method: "GET", path: "/tasks", tag: "tasks", auth: "app", summary: "List the tasks of one view, ready to draw.", query: zTasksQuery, ok: { 200: "The view: tasks, totals and the task in progress." } },
  { method: "GET", path: "/tasks/lists", tag: "tasks", auth: "app", summary: "The views, areas and projects with their counts.", ok: { 200: "The lists." } },
  { method: "POST", path: "/tasks", tag: "tasks", auth: "app", summary: "Create a task. A task with the same `from` reference returns the existing one.", body: zCreateTaskBody, idempotent: true, ok: { 201: "Created.", 200: "A task with this reference exists (placement `existing`)." } },
  { method: "POST", path: "/tasks/by-ref", tag: "tasks", auth: "app", summary: "The tasks that point at a reference key, a URL or a message link.", body: zByRefBody, ok: { 200: "The matching tasks." } },
  { method: "POST", path: "/tasks/:id/do", tag: "tasks", auth: "app", summary: "Start a Do on a task. The client makes the session id, so a retry starts nothing new.", params: zTaskId, body: zDoStartBody, idempotent: true, ok: { 201: "Started.", 200: "This session has started already." } },
  { method: "POST", path: "/tasks/do/:sessionId/:verb", tag: "tasks", auth: "app", summary: "Stop or confirm one Do.", params: { sessionId: zId, verb: zDoVerb }, body: zDoEndBody, idempotent: true, ok: { 200: "Done, or already ended." } },
  { method: "POST", path: "/tasks/:id/answer", tag: "tasks", auth: "app", summary: "Answer the open question of an agent, as the person.", params: zTaskId, body: zAnswerBody, idempotent: true, ok: { 200: "The answer turn." } },
  { method: "POST", path: "/tasks/:id/accept", tag: "tasks", auth: "app", summary: "Accept a hand-off in Review. The task is done.", params: zTaskId, body: zAcceptBody, idempotent: true, ok: { 200: "Accepted, or already done." } },
  { method: "POST", path: "/tasks/:id/send_back", tag: "tasks", auth: "app", summary: "Send a hand-off in Review back to the agent with a note.", params: zTaskId, body: zSendBackBody, idempotent: true, ok: { 200: "Sent back." } },
  { method: "POST", path: "/tasks/:id/:verb", tag: "tasks", auth: "app", summary: "Complete, schedule, defer or cancel a task. Only `defer` takes a body (`until`, `session`).", params: { id: zId, verb: zVerb }, body: zDeferBody.optional(), idempotent: true, ok: { 200: "The write result." } },
  { method: "GET", path: "/tasks/live", tag: "tasks", auth: "app", summary: "A WebSocket that carries the account's revision number.", stream: "websocket", ok: { 101: "Switching to WebSocket." } },

  // ---- agent ----
  { method: "POST", path: "/agent/signup/start", tag: "agent", auth: "none", summary: "Start an account sign-up or connection for an agent. The person confirms from an email (ADR 0056).", body: zAgentSignupStartBody, ok: { 202: "The confirmation email is sent. Poll with the request id and secret." } },
  { method: "POST", path: "/agent/signup/poll", tag: "agent", auth: "none", summary: "Poll an agent sign-up. After the person confirms, it returns the agent's tokens.", body: zAgentSignupPollBody, ok: { 200: "Confirmed: the tokens.", 202: "Still pending." } },
  { method: "GET", path: "/agent/events/stream", tag: "agent", auth: "appOrAgent", summary: "Server-sent agent wake events. Resume with `since` or `Last-Event-ID`.", query: zAgentEventsQuery, stream: "sse", ok: { 200: "An event stream." } },
  { method: "GET", path: "/agent/webhooks", tag: "agent", auth: "app", summary: "The account's agent wake webhooks.", ok: { 200: "The webhooks." } },
  { method: "POST", path: "/agent/webhooks", tag: "agent", auth: "app", summary: "Add an agent wake webhook.", body: zCreateWebhookBody, ok: { 201: "The webhook, with its signing secret." } },
  { method: "DELETE", path: "/agent/webhooks/:id", tag: "agent", auth: "app", summary: "Remove an agent wake webhook.", params: { id: zId }, ok: { 204: "Removed." } },
  { method: "PUT", path: "/agent/upload", tag: "agent", auth: "uploadToken", summary: "Upload the bytes of a file an agent attaches. The token comes from the tasks_attachment_add tool.", binaryBody: true, stream: "bytes", ok: { 200: "The attachment." } },

  // ---- auth ----
  { method: "GET", path: "/auth/methods", tag: "auth", auth: "none", summary: "The sign-in methods this server has on.", ok: { 200: "The methods." } },
  { method: "POST", path: "/auth/apple", tag: "auth", auth: "none", summary: "Sign in with an Apple identity token.", body: zAppleBody, ok: { 200: "A session." } },
  { method: "POST", path: "/auth/email/start", tag: "auth", auth: "none", summary: "Send a one-time sign-in code to an email address.", body: zEmailStartBody, ok: { 202: "The code is sent." } },
  { method: "POST", path: "/auth/email/verify", tag: "auth", auth: "none", summary: "Sign in with the emailed code.", body: zEmailVerifyBody, ok: { 200: "A session." } },
  { method: "POST", path: "/auth/device/start", tag: "auth", auth: "none", summary: "Start a device sign-in that a signed-in app approves.", body: zDeviceStartBody, ok: { 200: "The code to show and the poll secret." } },
  { method: "POST", path: "/auth/device/poll", tag: "auth", auth: "none", summary: "Poll a device sign-in.", body: zDevicePollBody, ok: { 200: "Approved: a session.", 202: "Still pending." } },
  { method: "POST", path: "/auth/device", tag: "auth", auth: "app", summary: "Make a separate session for a companion device.", ok: { 200: "A session." } },
  { method: "POST", path: "/auth/google/native", tag: "auth", auth: "none", summary: "Sign in with a Google identity token from the device's own account picker.", body: zGoogleNativeBody, ok: { 200: "A session." } },
  { method: "POST", path: "/auth/oidc/redeem", tag: "auth", auth: "none", summary: "Swap the one-use code from a web sign-in redirect for a session.", body: zOidcRedeemBody, ok: { 200: "A session." } },
  { method: "POST", path: "/auth/link/complete", tag: "auth", auth: "none", summary: "Finish adding a sign-in method to an existing account with the emailed code.", body: zLinkCompleteBody, ok: { 200: "A session." } },
  { method: "GET", path: "/beta", tag: "account", auth: "app", summary: "The beta checklist for this platform. `member: false` for an account that is not a beta tester's.", query: zBetaQuery, ok: { 200: "The checklist, or member false." } },
  { method: "POST", path: "/beta/progress", tag: "account", auth: "app", summary: "Tick or untick a checklist item, say you used Septena this week, or close the welcome card.", body: zBetaProgressBody, ok: { 204: "Saved.", 404: "The account is not a beta tester's." } },
  { method: "GET", path: "/auth/identities", tag: "auth", auth: "app", summary: "The sign-in methods on the account.", ok: { 200: "The methods." } },
  { method: "DELETE", path: "/auth/identities/:id", tag: "auth", auth: "app", summary: "Remove a sign-in method.", params: { id: z.string() }, ok: { 204: "Removed." } },
  { method: "POST", path: "/auth/link/email/start", tag: "auth", auth: "app", summary: "Send a code to add an email sign-in.", body: zEmailStartBody, ok: { 202: "The code is sent." } },
  { method: "POST", path: "/auth/link/email/verify", tag: "auth", auth: "app", summary: "Add an email sign-in with the emailed code.", body: zLinkEmailVerifyBody, ok: { 200: "Added." } },
  { method: "POST", path: "/auth/link/apple", tag: "auth", auth: "app", summary: "Add Sign in with Apple to the account.", body: zAppleBody, ok: { 200: "Added." } },
  { method: "POST", path: "/auth/link/google/native", tag: "auth", auth: "app", summary: "Add a Google sign-in from the device's own account picker.", body: zGoogleNativeBody, ok: { 200: "Added." } },
  { method: "POST", path: "/auth/link/oidc/start", tag: "auth", auth: "app", summary: "Start adding a web sign-in provider. The answer names the address to open.", body: zOidcLinkStartBody, ok: { 200: "The address to open." } },
  { method: "POST", path: "/auth/refresh", tag: "auth", auth: "none", summary: "Swap a refresh token (body or web cookie) for a new session.", body: zRefreshBody.optional(), ok: { 200: "A session." } },
  { method: "POST", path: "/auth/signout", tag: "auth", auth: "none", summary: "Revoke a refresh token (body or web cookie).", body: zRefreshBody.optional(), ok: { 204: "Signed out." } },
  { method: "POST", path: "/pair/inspect", tag: "auth", auth: "app", summary: "Read what a sign-in code is for (a device or an agent connector) before approving it.", body: zPairInspectBody, ok: { 200: "The kind and the client." } },
  { method: "POST", path: "/pair/approve", tag: "auth", auth: "app", summary: "Approve a sign-in code.", body: zPairApproveBody, ok: { 200: "Approved." } },
  { method: "POST", path: "/pair/deny", tag: "auth", auth: "app", summary: "Turn down a sign-in code.", body: zPairDenyBody, ok: { 200: "Turned down." } },

  // ---- sync ----
  { method: "POST", path: "/sync/push", tag: "sync", auth: "app", summary: "Push a batch of operations. Each op carries a client op id, so a retry applies nothing twice.", body: zPushBody, ok: { 200: "A result per op." } },
  { method: "GET", path: "/sync/pull", tag: "sync", auth: "app", summary: "Pull the changes after a revision.", query: zSyncPullQuery, ok: { 200: "A page of changes." } },
  { method: "POST", path: "/sync/ws-ticket", tag: "sync", auth: "app", summary: "A one-use ticket for a browser WebSocket.", ok: { 200: "The ticket." } },
  { method: "GET", path: "/sync/ws", tag: "sync", auth: "app", summary: "The live sync WebSocket. A browser sends `?ticket=` from /sync/ws-ticket.", stream: "websocket", ok: { 101: "Switching to WebSocket." } },
  { method: "GET", path: "/changes", tag: "sync", auth: "app", summary: "The change history: who changed what, with the values before and after.", query: zChangesQuery, ok: { 200: "The changes." } },
  { method: "GET", path: "/notes/history", tag: "sync", auth: "app", summary: "The revisions of a project's or an area's notes.", query: zHistoryQuery, ok: { 200: "The revisions." } },
  { method: "PUT", path: "/attachments/:id", tag: "sync", auth: "app", summary: "Upload the bytes of an attachment whose metadata was pushed.", params: { id: zId }, binaryBody: true, ok: { 200: "Stored." } },
  { method: "GET", path: "/attachments/:id", tag: "sync", auth: "app", summary: "Download the bytes of an attachment.", params: { id: zId }, stream: "bytes", ok: { 200: "The file." } },

  // ---- account ----
  { method: "GET", path: "/access", tag: "account", auth: "app", summary: "The devices, agent connections and keys that can reach the account.", ok: { 200: "The access summary." } },
  { method: "DELETE", path: "/access/devices/:sid", tag: "account", auth: "app", summary: "Sign out another device.", params: { sid: zSid }, ok: { 204: "Signed out." } },
  { method: "DELETE", path: "/access/connections/:id", tag: "account", auth: "app", summary: "Disconnect an agent.", params: { id: zFamilyId }, ok: { 204: "Disconnected." } },
  { method: "PATCH", path: "/access/connections/:id", tag: "account", auth: "app", summary: "Rename an agent connection.", params: { id: zFamilyId }, body: zRenameConnectionBody, ok: { 204: "Renamed." } },
  { method: "POST", path: "/access/keys", tag: "account", auth: "app", summary: "Make an agent key with read or write access.", body: zCreateKeyBody, ok: { 201: "The key. It is shown once." } },
  { method: "POST", path: "/devices/push-token", tag: "account", auth: "app", summary: "Register a push token for this device.", body: zPushTokenRegisterBody, ok: { 200: "Registered." } },
  { method: "DELETE", path: "/devices/push-token", tag: "account", auth: "app", summary: "Remove a push token.", body: zPushTokenDeleteBody, ok: { 204: "Removed." } },
  { method: "GET", path: "/entitlement", tag: "account", auth: "app", summary: "The account's plan, limits, usage and device slot.", ok: { 200: "The entitlement." } },
  { method: "POST", path: "/entitlement/device", tag: "account", auth: "app", summary: "Move the sync slot to this device.", ok: { 200: "This device syncs." } },
  { method: "POST", path: "/entitlement/apple", tag: "account", auth: "app", summary: "Record a signed App Store transaction.", body: zEntitlementAppleBody, ok: { 200: "The entitlement it gives." } },
  { method: "GET", path: "/account", tag: "account", auth: "app", summary: "The account id and its avatar.", ok: { 200: "The account." } },
  { method: "PATCH", path: "/account/avatar", tag: "account", auth: "app", summary: "Set the avatar to initials or one emoji, with a color from the palette. A change older than the stored one changes nothing (`applied: false`).", body: zAvatarPatchBody, ok: { 200: "The avatar." } },
  { method: "PUT", path: "/account/avatar", tag: "account", auth: "app", summary: "Set a photo as the avatar: a square JPEG, PNG or HEIC up to 256 KB. The photo before it is deleted.", binaryBody: true, ok: { 200: "The avatar." } },
  { method: "DELETE", path: "/account/avatar", tag: "account", auth: "app", summary: "Go back to initials. The photo is deleted.", ok: { 200: "The avatar." } },
  { method: "GET", path: "/account/avatar/photo", tag: "account", auth: "app", summary: "The account's own avatar photo.", stream: "bytes", ok: { 200: "The photo." } },
  { method: "DELETE", path: "/account", tag: "account", auth: "app", summary: "Delete the account and everything in it.", ok: { 204: "Deleted." } },

  // ---- support ----
  { method: "POST", path: "/support/messages", tag: "support", auth: "appOrSupportKey", summary: "Send a message to Support. The client makes `message_id`, so a retry sends nothing twice.", body: zSupportMessageBody, ok: { 202: "Received." } },
  { method: "GET", path: "/support/messages", tag: "support", auth: "appOrSupportKey", summary: "The conversation with Support.", ok: { 200: "The messages and replies." } },
  { method: "POST", path: "/support/read", tag: "support", auth: "appOrSupportKey", summary: "Mark the replies as read.", ok: { 204: "Marked." } },

  // ---- shares ----
  { method: "GET", path: "/shares", tag: "shares", auth: "app", summary: "The shared projects the account owns or joined.", ok: { 200: "The shares." } },
  { method: "POST", path: "/shares", tag: "shares", auth: "app", summary: "Share a project.", body: zShareCreateBody, ok: { 201: "The share." } },
  { method: "POST", path: "/shares/preview", tag: "shares", auth: "app", summary: "Read an invite before joining.", body: zSharePreviewBody, ok: { 200: "The project behind the invite." } },
  { method: "POST", path: "/shares/join", tag: "shares", auth: "app", summary: "Join a shared project with an invite.", body: zShareJoinBody, ok: { 200: "Joined." } },
  { method: "GET", path: "/shares/:id", tag: "shares", auth: "app", summary: "One share, with its invites.", params: { id: zShareId }, ok: { 200: "The share." } },
  { method: "POST", path: "/shares/:id/invites", tag: "shares", auth: "app", summary: "Make an invite link.", params: { id: zShareId }, ok: { 201: "The invite and its link." } },
  { method: "DELETE", path: "/shares/:id/invites/:invite", tag: "shares", auth: "app", summary: "Revoke an invite.", params: { id: zShareId, invite: z.string() }, ok: { 204: "Revoked." } },
  { method: "GET", path: "/shares/:id/members/:member/avatar", tag: "shares", auth: "app", summary: "The avatar photo of a member of the project. Only members read it.", params: { id: zShareId, member: z.string() }, stream: "bytes", ok: { 200: "The photo." } },
  { method: "DELETE", path: "/shares/:id/members/:member", tag: "shares", auth: "app", summary: "Remove a member, or leave.", params: { id: zShareId, member: z.string() }, ok: { 204: "Removed." } },
  { method: "DELETE", path: "/shares/:id", tag: "shares", auth: "app", summary: "Stop sharing a project.", params: { id: zShareId }, ok: { 204: "Closed." } },

  // ---- calendar ----
  { method: "GET", path: "/ical/settings", tag: "calendar", auth: "app", summary: "The calendar feed settings and its address.", ok: { 200: "The feed." } },
  { method: "POST", path: "/ical/settings", tag: "calendar", auth: "app", summary: "Turn the feed on or off, set its scope, or make a new address.", body: zIcalUpdateBody, ok: { 200: "The feed." } },
  { method: "DELETE", path: "/ical/settings", tag: "calendar", auth: "app", summary: "Turn the feed off.", ok: { 204: "Off." } },
  { method: "GET", path: "/ical/:tokenFile", tag: "calendar", auth: "feedToken", summary: "The calendar feed (`<token>.ics`).", params: { tokenFile: z.string().regex(/^[A-Za-z0-9_-]{32,64}\.ics$/) }, stream: "calendar", ok: { 200: "An iCalendar file.", 304: "Not changed." } },
];

/// /v1 routes that are not part of the contract, and why.
export const INTERNAL_ROUTES: Array<{ method: Method | "OPTIONS"; path: string; why: string }> = [
  { method: "POST", path: "/webhooks/apple", why: "Called by the App Store only." },
  { method: "POST", path: "/beta/join", why: "Called by septena.app/beta only (ADR 0064)." },
  { method: "OPTIONS", path: "/beta/join", why: "The CORS preflight for septena.app/beta." },
  { method: "POST", path: "/support/replies", why: "Called by the support workspace only (signed)." },
  { method: "GET", path: "/auth/oidc/:provider/start", why: "A browser redirect in the web sign-in flow, not an API call." },
  { method: "GET", path: "/auth/oidc/:provider/callback", why: "The provider's redirect back, not an API call." },
  { method: "POST", path: "/auth/oidc/:provider/callback", why: "The provider's form post back, not an API call." },
  { method: "POST", path: "/admin/grants", why: "Operator only (X-Admin-Token)." },
  { method: "DELETE", path: "/admin/grants/:userId/:name", why: "Operator only." },
  { method: "POST", path: "/admin/reviewer/prepare", why: "Operator only." },
  { method: "POST", path: "/admin/reviewer/approve-device", why: "Operator only." },
  { method: "GET", path: "/admin/copy/:userId/snapshot", why: "Operator only (account move)." },
  { method: "GET", path: "/admin/copy/:userId/export", why: "Operator only (account move)." },
  { method: "POST", path: "/admin/copy/:userId/import/begin", why: "Operator only (account move)." },
  { method: "POST", path: "/admin/copy/:userId/import", why: "Operator only (account move)." },
  { method: "POST", path: "/admin/copy/:userId/import/end", why: "Operator only (account move)." },
];

const SECURITY: Record<Auth, Array<Record<string, string[]>>> = {
  none: [],
  app: [{ appSession: [] }],
  appOrAgent: [{ appSession: [] }, { agentToken: [] }],
  uploadToken: [{ uploadToken: [] }],
  feedToken: [],
  appOrSupportKey: [{ appSession: [] }, { supportKey: [] }],
};

function openApiPath(path: string): string {
  return `/v1${path.replace(/:([A-Za-z]+)/g, "{$1}")}`;
}

function operationId(method: Method, path: string): string {
  const words = path.split("/").filter(Boolean).map((part) => part.startsWith(":") ? `by_${part.slice(1)}` : part);
  return [method.toLowerCase(), ...words].join("_").replace(/[^A-Za-z0-9_]/g, "_");
}

/// A path or query parameter. A query field with a default may be left out.
function parameter(name: string, where: "path" | "query", schema: ZodTypeAny): JsonSchema {
  const out: JsonSchema = { name, in: where, required: where === "path" || !isOptional(schema), schema: zodToJsonSchema(schema) };
  return out;
}

/// A body with the optional `idempotency_key` field merged in.
function withIdempotencyField(body: JsonSchema): JsonSchema {
  if (body.type !== "object") return body;
  const properties = { ...(body.properties as Record<string, JsonSchema>), [IDEMPOTENCY_KEY_FIELD]: zodToJsonSchema(zIdempotencyKey) };
  return { ...body, properties };
}

function errorResponse(description: string): JsonSchema {
  return { description, content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } };
}

function operation(r: RouteDoc): JsonSchema {
  const parameters: JsonSchema[] = [];
  const pathNames = [...r.path.matchAll(/:([A-Za-z]+)/g)].map((m) => m[1]);
  for (const name of pathNames) parameters.push(parameter(name, "path", r.params?.[name] ?? z.string()));
  if (r.query) {
    for (const [name, schema] of Object.entries(r.query.shape as Record<string, ZodTypeAny>)) {
      parameters.push(parameter(name, "query", schema));
    }
  }
  if (r.idempotent) parameters.push({ $ref: "#/components/parameters/IdempotencyKey" });
  parameters.push({ $ref: "#/components/parameters/ErrorFormat" });

  const op: JsonSchema = {
    operationId: operationId(r.method, r.path),
    tags: [r.tag],
    summary: r.summary,
    security: SECURITY[r.auth],
    parameters,
  };
  if (r.auth === "feedToken") op.description = "The token in the path is the credential. Treat the address as a secret.";
  if (r.body) {
    const schema = zodToJsonSchema(r.body);
    op.requestBody = {
      required: !isOptional(r.body),
      content: { "application/json": { schema: r.idempotent ? withIdempotencyField(schema) : schema } },
    };
  } else if (r.binaryBody) {
    op.requestBody = { required: true, content: { "application/octet-stream": { schema: { type: "string", contentMediaType: "application/octet-stream" } } } };
  }
  const responses: Record<string, JsonSchema> = {};
  for (const [status, description] of Object.entries(r.ok)) {
    if (status === "101" || status === "204" || status === "304") responses[status] = { description };
    else if (r.stream === "sse") responses[status] = { description, content: { "text/event-stream": { schema: { type: "string" } } } };
    else if (r.stream === "calendar") responses[status] = { description, content: { "text/calendar": { schema: { type: "string" } } } };
    else if (r.stream === "bytes" && r.method === "GET") responses[status] = { description, content: { "application/octet-stream": { schema: { type: "string", contentMediaType: "application/octet-stream" } } } };
    else responses[status] = { description, content: { "application/json": { schema: { type: "object" } } } };
  }
  if (r.body || r.query || pathNames.length) responses["400"] = errorResponse("The request is not valid.");
  if (r.auth !== "none" && r.auth !== "feedToken") responses["401"] = errorResponse("The credential is missing, expired or revoked.");
  if (r.idempotent) responses["409"] = errorResponse("A call with this idempotency key is still running (`idempotency_in_progress`).");
  if (r.tag === "tasks" && r.method === "POST") responses["422"] = errorResponse("The write was refused. `reason` (or the envelope's `code`) names the refusal.");
  responses.default = errorResponse("An error.");
  op.responses = responses;
  return op;
}

/// The whole document. Deterministic: the same routes give the same bytes.
export function buildOpenApi(): JsonSchema {
  const paths: Record<string, Record<string, JsonSchema>> = {};
  for (const r of ROUTES) {
    const p = openApiPath(r.path);
    paths[p] ??= {};
    paths[p][r.method.toLowerCase()] = operation(r);
  }
  const codes = Object.keys(REFUSALS);
  return {
    openapi: "3.1.0",
    jsonSchemaDialect: "https://json-schema.org/draft/2020-12/schema",
    info: {
      title: "Septena API",
      version: "v0",
      summary: "The /v1 HTTP API of the Septena task backend.",
      description: [
        "Generated from the route validators by backend/scripts/gen-contract.ts. Do not edit by hand.",
        "",
        "Version v0 is unstable until Septena 1.0: fields and routes can change. The agent spec at https://septena.app/spec.md defines the records, the IDs, the claim lifecycle and every refusal code.",
        "",
        "Agents should use the MCP server at https://api.septena.app/mcp. This API serves the apps and thin clients. Response bodies are described in words only: the server does not validate them against a schema.",
        "",
        `Errors: a refused call answers \`{ "error": "<code>", ... }\`. Send \`${ERROR_FORMAT_HEADER}: envelope\` to get \`{ "error": { "code", "message", "hint", "retryable" } }\` instead, with the old fields next to it.`,
      ].join("\n"),
      license: { name: "MIT", identifier: "MIT" },
    },
    servers: [{ url: "https://api.septena.app" }],
    externalDocs: { description: "The Septena agent spec", url: "https://septena.app/spec.md" },
    tags: Object.entries(TAGS).map(([name, description]) => ({ name, description })),
    paths,
    components: {
      securitySchemes: {
        appSession: { type: "http", scheme: "bearer", description: "An app session access token (`sa1.…`) from a sign-in route or /v1/auth/refresh." },
        agentToken: { type: "http", scheme: "bearer", description: "An MCP access token (`sm2.…`) from OAuth, an agent key or an agent sign-up." },
        uploadToken: { type: "http", scheme: "bearer", description: "The one-use upload token from the tasks_attachment_add tool." },
        supportKey: { type: "apiKey", in: "header", name: SUPPORT_KEY_HEADER, description: "A random key the app makes once per install, for Support before sign-in." },
      },
      parameters: {
        IdempotencyKey: {
          name: "Idempotency-Key",
          in: "header",
          required: false,
          description: `A key you make for this write. A repeat with the same key and body in 24 hours returns the first answer with \`Idempotent-Replayed: true\` and writes nothing. The body field \`${IDEMPOTENCY_KEY_FIELD}\` does the same.`,
          schema: zodToJsonSchema(zIdempotencyKey),
        },
        ErrorFormat: {
          name: ERROR_FORMAT_HEADER,
          in: "header",
          required: false,
          description: "`envelope`: a refused call carries the error envelope in `error`.",
          schema: { type: "string", enum: ["envelope"] },
        },
      },
      schemas: {
        Error: {
          type: "object",
          required: ["error"],
          properties: {
            error: { anyOf: [{ type: "string", description: "The code (default format)." }, { $ref: "#/components/schemas/ErrorEnvelope" }] },
            reason: { type: "string", description: "On a refused task write: the refusal's code." },
            message: { type: "string" },
          },
        },
        ErrorEnvelope: {
          type: "object",
          required: ["code", "message", "hint", "retryable"],
          properties: {
            code: { type: "string", description: "A refusal code. The spec lists each with its hint and retryable.", examples: codes },
            message: { type: "string" },
            hint: { type: "string", description: "What to do next." },
            retryable: { type: "boolean", description: "Whether the same request can succeed later with no action by the user." },
          },
        },
      },
    },
  };
}
