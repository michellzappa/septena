import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { escapeHtml, logEvent } from "../util.js";
import { planFor, upsellLine } from "../entitlement/entitlement.js";
import { zId } from "../store/columns.js";
import { projectStoreFor } from "../store/ProjectStore.js";
import { MEMBER_ID_RE, SHARE_ID_RE, newShareId } from "../store/shares.js";
import { PAGE_CSS } from "../shadow/oauth.js";
import { storeFor } from "./session.js";
import { accountStoreFor } from "../store/AccountStore.js";
import { publicAvatar } from "../store/avatar.js";
import { avatarPhotoResponse } from "./avatar.js";

// Shared projects (docs/PROJECT_SHARING_SPEC.md §5). Mounted at /v1/shares
// behind requireUser, so only an app session reaches it, never an agent.
// Membership is checked by the ProjectStore on every call.

type Vars = { userId: string };
type Ctx = Context<{ Bindings: Env; Variables: Vars }>;

export const shares = new Hono<{ Bindings: Env; Variables: Vars }>();

const zName = z.string().trim().min(1).max(80);
// The share id routes the token; the secret after the dot is the credential.
const TOKEN_RE = /^(sp_[A-Za-z0-9_-]{32})\.[A-Za-z0-9_-]{32}$/;
const zToken = z.string().regex(TOKEN_RE);
export const zShareId = z.string().regex(SHARE_ID_RE);

export const zShareCreateBody = z.object({ projectId: zId, name: zName }).strict();
export const zSharePreviewBody = z.object({ token: zToken }).strict();
export const zShareJoinBody = z.object({ token: zToken, name: zName }).strict();

async function body<T extends z.ZodTypeAny>(c: Ctx, schema: T): Promise<z.infer<T> | null> {
  const parsed = schema.safeParse(await c.req.json().catch(() => null));
  return parsed.success ? parsed.data : null;
}

const bad = (c: Ctx) => c.json({ error: "invalid_request" }, 400);
const notFound = (c: Ctx) => c.json({ error: "not_found" }, 404);

function shareId(c: Ctx): string | null {
  const id = zShareId.safeParse(c.req.param("id"));
  return id.success ? id.data : null;
}

/// Creating a share and inviting need Plus; joining never does (ADR 0036).
/// This gate is always on: sharing is new, so nobody loses anything.
async function plusRefusal(c: Ctx): Promise<Response | null> {
  const userId = c.get("userId");
  const { limits, plan } = await planFor(c.env, userId);
  if (limits.createShares) return null;
  logEvent("entitlement_blocked", { surface: "share_create", userId, plan, limit: "createShares" });
  return c.json({ error: "shares_not_in_plan", limit: "createShares", upsell: "share_create", message: upsellLine("share_create") }, 402);
}

shares.get("/", async (c) => c.json({ shares: await storeFor(c.env, c.get("userId")).listShares() }));

shares.post("/", async (c) => {
  const input = await body(c, zShareCreateBody);
  if (!input) return bad(c);
  const refusal = await plusRefusal(c);
  if (refusal) return refusal;
  const userId = c.get("userId");
  const store = storeFor(c.env, userId);
  const state = await store.canShare(input.projectId);
  if (state === "not_found") return notFound(c);
  if (state === "already_shared") return c.json({ error: "already_shared" }, 409);
  const id = newShareId();
  const info = await projectStoreFor(c.env, id).create(id, userId, input.name);
  const started = await store.startShare(userId, input.projectId, info);
  if (started !== "ok") {
    await projectStoreFor(c.env, id).close(userId);
    return started === "not_found" ? notFound(c) : c.json({ error: started }, 409);
  }
  logEvent("share_created", { userId, shareId: id });
  c.executionCtx.waitUntil(showAvatar(c, id));
  return c.json({ share: info }, 201);
});

shares.post("/preview", async (c) => {
  const input = await body(c, zSharePreviewBody);
  if (!input) return bad(c);
  const found = await projectStoreFor(c.env, shareOf(input.token)).preview(input.token);
  return found ? c.json(found) : notFound(c);
});

shares.post("/join", async (c) => {
  const input = await body(c, zShareJoinBody);
  if (!input) return bad(c);
  const result = await projectStoreFor(c.env, shareOf(input.token)).join(input.token, c.get("userId"), input.name);
  if (!result.ok) return result.reason === "full" ? c.json({ error: "share_full" }, 409) : notFound(c);
  logEvent("share_joined", { userId: c.get("userId"), shareId: result.shareId });
  c.executionCtx.waitUntil(showAvatar(c, result.shareId));
  return c.json({ shareId: result.shareId, title: result.title });
});

shares.get("/:id", async (c) => {
  const id = shareId(c);
  const found = id && await projectStoreFor(c.env, id).details(c.get("userId"));
  return found ? c.json({ share: found.info, invites: found.invites }) : notFound(c);
});

shares.post("/:id/invites", async (c) => {
  const id = shareId(c);
  if (!id) return notFound(c);
  const refusal = await plusRefusal(c);
  if (refusal) return refusal;
  const made = await projectStoreFor(c.env, id).invite(c.get("userId"));
  if (!made.ok) return made.reason === "full" ? c.json({ error: "share_full" }, 409) : notFound(c);
  return c.json({ invite: made.invite, url: `${c.env.API_PUBLIC_URL}/join/${made.token}` }, 201, { "Cache-Control": "no-store" });
});

shares.delete("/:id/invites/:invite", async (c) => {
  const id = shareId(c);
  const gone = id && await projectStoreFor(c.env, id).revokeInvite(c.get("userId"), c.req.param("invite"));
  return gone ? c.body(null, 204) : notFound(c);
});

/// A member's photo, for the other members of the project only (#857).
shares.get("/:id/members/:member/avatar", async (c) => {
  const id = shareId(c);
  const member = c.req.param("member");
  if (!id || !MEMBER_ID_RE.test(member)) return notFound(c);
  const owner = await projectStoreFor(c.env, id).memberUserId(c.get("userId"), member);
  return owner ? avatarPhotoResponse(c.env, owner) : notFound(c);
});

shares.delete("/:id/members/:member", async (c) => {
  const id = shareId(c);
  const member = c.req.param("member");
  if (!id || !MEMBER_ID_RE.test(member)) return notFound(c);
  const ended = await projectStoreFor(c.env, id).endMembership(c.get("userId"), member);
  return ended ? c.body(null, 204) : notFound(c);
});

shares.delete("/:id", async (c) => {
  const id = shareId(c);
  const closed = id && await projectStoreFor(c.env, id).close(c.get("userId"));
  if (closed) logEvent("share_closed", { userId: c.get("userId"), shareId: id });
  return closed ? c.body(null, 204) : notFound(c);
});

const shareOf = (token: string) => TOKEN_RE.exec(token)![1];

/// Shows the account's avatar in a project it just shared or joined (#857).
async function showAvatar(c: Ctx, shareId: string): Promise<void> {
  const accounts = accountStoreFor(c.env);
  if (!accounts) return;
  const userId = c.get("userId");
  try {
    await projectStoreFor(c.env, shareId).setMemberAvatar(userId, publicAvatar(await accounts.getAvatar(userId)));
  } catch (e) {
    logEvent("avatar_spread_failed", { userId, shareId, error: String(e) });
  }
}

/// Where an invite link opens. It shows who invites and to what; it never
/// accepts anything. An unknown, used, expired or revoked link gets one page.
export async function joinLanding(c: Context<{ Bindings: Env }>) {
  const token = zToken.safeParse(c.req.param("token"));
  const found = token.success ? await projectStoreFor(c.env, shareOf(token.data)).preview(token.data) : null;
  const main = found
    ? `<h1>${escapeHtml(found.from)} invited you to “${escapeHtml(found.title)}”</h1>
  <p>Join to see its tasks in Septena and work on them together. A free account is enough.</p>
  <p><a class="button" href="septask://join/${token.data}">Open in Septena</a></p>
  <p class="small">No Septena yet? <a href="https://septena.app">Get the app</a>, then open this link again. You can also copy the link and choose Join a Shared Project in Septena.</p>`
    : `<h1>This invite no longer works</h1>
  <p>It was used, it expired, or the owner took it back. Ask for a new link.</p>`;
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Septena invite</title>
<style>${PAGE_CSS}
  .button { display: block; text-align: center; padding: 12px; border-radius: 10px; background: #1a1a1a; color: #fff; text-decoration: none; font-weight: 600; }
  @media (prefers-color-scheme: dark) { .button { background: #f5f5f5; color: #0a0a0a; } }
</style>
</head>
<body><main class="card">
  ${main}
</main></body>
</html>`;
  return new Response(html, {
    status: found ? 200 : 404,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
    },
  });
}
