import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { escapeHtml, logEvent, randomId, sha256Base64Url } from "../util.js";
import { BETA_CHECKLIST, DESIGN_TOKENS } from "../generated/registries.js";
import { accountStoreFor } from "../store/AccountStore.js";
import { BETA_ANSWERS, type BetaAnswer, type BetaTester, type BetaUsage } from "../store/betaInvites.js";
import { zPushBody, type Op } from "../store/ops.js";
import { parseRef, taskRefId } from "../core/index.js";
import { newTaskId } from "../tools/writeTasks.js";
import { PAGE_CSS } from "../shadow/oauth.js";
import { grantRow } from "../entitlement/entitlement.js";
import { plusLinkGrantId } from "../store/plusLinks.js";
import { betaGrantEnd, createPlusLink } from "./plusLinks.js";
import { storeFor } from "./session.js";

// The beta by invite code (ADR 0064, docs/BETA_ONBOARDING_SPEC.md).
//
// POST /v1/beta/join from septena.app/beta: check the code, add the email to
// the TestFlight group (Apple sends its own invite), write the tester, make
// the tester's Pro plan link, send the welcome mail. The thank-you follows
// the email: `grantBetaAtSignIn` claims that link for the account that signs
// in with the address, and the link in the mail covers every other case.

type Ctx = Context<{ Bindings: Env }>;

const SITE = "https://septena.app";
const FROM = { email: "notify@septena.app", name: "Michell from Septena" };
const BRAND = DESIGN_TOKENS.fruitAccents.find((a) => a.id === "persimmon") ?? { light: "#E05212", dark: "#FF7738" };
const ORIGINS = new Set([SITE, "https://www.septena.app"]);
const DEV_ORIGIN = /^http:\/\/localhost:\d{2,5}$/;
const CHECKIN_AFTER_MS = 4 * 86_400_000;
const TRIES_PER_WINDOW = 5;
const TRY_WINDOW_MS = 10 * 60 * 1000;

export const zBetaJoinBody = z.object({
  email: z.string().trim().toLowerCase().max(254).email(),
  code: z.string().trim().min(1).max(64),
  company: z.string().max(200).optional(),
}).strict();

// ---- App Store Connect ----

const b64url = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlText = (text: string) => b64url(new TextEncoder().encode(text));

function pemBytes(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0)).buffer as ArrayBuffer;
}

export function ascConfigured(env: Env): boolean {
  return Boolean(env.ASC_KEY_P8 && env.ASC_KEY_ID && env.ASC_ISSUER_ID && env.ASC_BETA_GROUP_ID && env.ASC_APP_ID);
}

async function ascToken(env: Env): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(env.ASC_KEY_P8!), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" }));
  const body = b64urlText(JSON.stringify({ iss: env.ASC_ISSUER_ID, iat: now, exp: now + 10 * 60, aud: "appstoreconnect-v1" }));
  // WebCrypto ECDSA signs as raw r||s, which is what JWS ES256 wants.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(sig)}`;
}

async function asc(env: Env, method: string, path: string, body?: unknown): Promise<{ ok: boolean; status: number; json: any }> {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${await ascToken(env)}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  const text = await res.text();
  let json: any = {};
  try { json = text ? JSON.parse(text) : {}; } catch { /* keep {} */ }
  return { ok: res.ok, status: res.status, json };
}

/// Adds the email to the TestFlight group; Apple mails the invite. An email
/// that Apple already knows is added to the group and invited again.
/// Answers the tester id, or null when Apple refused.
export async function inviteToTestFlight(env: Env, email: string): Promise<string | null> {
  const group = env.ASC_BETA_GROUP_ID!;
  const made = await asc(env, "POST", "/v1/betaTesters", {
    data: {
      type: "betaTesters",
      attributes: { email },
      relationships: { betaGroups: { data: [{ type: "betaGroups", id: group }] } },
    },
  });
  if (made.ok) return String(made.json?.data?.id ?? "") || null;
  if (made.status !== 409) {
    logEvent("beta_asc_refused", { status: made.status, code: made.json?.errors?.[0]?.code });
    return null;
  }
  const found = await asc(env, "GET", `/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&limit=1`);
  const id = found.ok ? String(found.json?.data?.[0]?.id ?? "") : "";
  if (!id) return null;
  await asc(env, "POST", `/v1/betaGroups/${group}/relationships/betaTesters`, { data: [{ type: "betaTesters", id }] });
  await resendInvite(env, id);
  return id;
}

async function resendInvite(env: Env, testerId: string): Promise<boolean> {
  const r = await asc(env, "POST", "/v1/betaTesterInvitations", {
    data: {
      type: "betaTesterInvitations",
      relationships: {
        app: { data: { type: "apps", id: env.ASC_APP_ID } },
        betaTester: { data: { type: "betaTesters", id: testerId } },
      },
    },
  });
  if (!r.ok) logEvent("beta_asc_resend_refused", { status: r.status });
  return r.ok;
}

// ---- POST /v1/beta/join ----

function cors(c: Ctx): Record<string, string> {
  const origin = c.req.header("Origin") ?? "";
  if (!ORIGINS.has(origin) && !DEV_ORIGIN.test(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

export const betaJoinPreflight = (c: Ctx) => new Response(null, { status: 204, headers: cors(c) });

async function tooManyTries(env: Env, ip: string): Promise<boolean> {
  const bucket = Math.floor(Date.now() / TRY_WINDOW_MS);
  const key = `beta-join:${await sha256Base64Url(ip)}:${bucket}`;
  const n = Number.parseInt((await env.STATE.get(key)) ?? "0", 10) || 0;
  if (n >= TRIES_PER_WINDOW) return true;
  await env.STATE.put(key, String(n + 1), { expirationTtl: Math.ceil(TRY_WINDOW_MS / 1000) + 60 });
  return false;
}

export async function betaJoin(c: Ctx): Promise<Response> {
  const headers = cors(c);
  const answer = (status: number, body: Record<string, unknown>) =>
    c.json(body, status as 200, { ...headers, "Cache-Control": "no-store" });
  const accounts = accountStoreFor(c.env);
  if (!accounts || !ascConfigured(c.env)) return answer(503, { error: "unavailable" });

  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  if (await tooManyTries(c.env, ip)) return answer(429, { error: "rate_limited" });

  const raw = await c.req.json().catch(() => null);
  const parsed = zBetaJoinBody.safeParse(raw);
  if (!parsed.success) {
    const emailBad = parsed.error.issues.some((i) => i.path[0] === "email");
    return answer(400, { error: emailBad ? "bad_email" : "bad_code" });
  }
  const { email, code, company } = parsed.data;
  // Honeypot: people never see it. Answer like a wrong code.
  if (company) return answer(400, { error: "bad_code" });

  const start = await accounts.betaStartJoin(email, code);
  if (!start.ok) {
    logEvent("beta_join_refused", {});
    return answer(400, { error: "bad_code" });
  }
  if (start.state === "already_joined") {
    if (start.tester.ascTesterId) await resendInvite(c.env, start.tester.ascTesterId);
    return answer(200, { state: "already_joined" });
  }

  const testerId = await inviteToTestFlight(c.env, email);
  const tester = await accounts.betaFinishJoin(email, start.codeId, testerId ? "invited" : "failed", testerId);
  if (!testerId) return answer(502, { error: "apple_unavailable" });
  logEvent("beta_joined", { codeId: start.codeId });

  c.executionCtx.waitUntil(afterJoin(c.env, tester, start.codeLabel).catch((e) => logEvent("beta_after_join_failed", { error: String(e) })));
  return answer(200, { state: "joined" });
}

/// The plan link, the grant for an email account that already exists, and
/// the welcome mail. Runs after the answer: the person waits for none of it.
export async function afterJoin(env: Env, tester: BetaTester, codeLabel: string): Promise<void> {
  const accounts = accountStoreFor(env);
  if (!accounts) return;
  let linkUrl: string | null = null;
  if (!tester.planLinkId) {
    const made = await createPlusLink(env, { label: `beta: ${codeLabel}`.slice(0, 60), plan: "pro", months: null, maxUses: 1 });
    if (made) {
      const token = made.url.slice(made.url.lastIndexOf("/") + 1);
      await accounts.betaSetPlanLink(tester.email, made.link.id, await sha256Base64Url(token));
      linkUrl = made.url;
    }
  }
  // An account made with an email code keeps the address, so it gets the
  // grant now. Every other account gets it at its next sign-in or by link.
  const owner = await accounts.resolveIdentity("email", tester.email);
  if (owner) await grantBetaAtSignIn(env, owner.userId, tester.email, true);
  if (linkUrl && !tester.welcomeSentAt) {
    await sendMail(env, tester.email, welcomeMail(tester.email, linkUrl));
    await accounts.betaNoteWelcome(tester.email);
  }
}

import { grantBetaAtSignIn } from "./betaGrant.js";
export { grantBetaAtSignIn };

// ---- launch and the check-in ----

/// Sets the launch date once, writes the end date on every beta grant and
/// mails every tester. Answers false when the date was set before.
export async function setBetaLaunch(env: Env, at: number): Promise<boolean> {
  const accounts = accountStoreFor(env);
  if (!accounts) return false;
  const holders = await accounts.betaSetLaunch(at);
  if (!holders) return false;
  const expiresAt = betaGrantEnd(at);
  for (const h of holders) {
    await storeFor(env, h.userId).putEntitlement(grantRow(plusLinkGrantId(h.linkId), "pro", expiresAt, "beta"), "admin");
  }
  for (const t of await accounts.betaInvited()) await sendMail(env, t.email, launchMail(expiresAt, t.grantedUserId === null));
  logEvent("beta_launch_set", { accounts: holders.length });
  return true;
}

/// How old a tester's measurement may get before the sweep reads it again.
const USAGE_REFRESH_MS = 6 * 60 * 60 * 1000;

/// Hourly: the day-4 check-in and the day-7 question, once per tester; the
/// seed for granted testers who have none yet; and a fresh measurement for
/// the testers whose reading is oldest.
export async function sweepBeta(env: Env, now = Date.now()): Promise<void> {
  const accounts = accountStoreFor(env);
  if (!accounts) return;
  for (const t of await accounts.betaUnseeded()) await seedBetaProject(env, t.grantedUserId!);
  for (const t of await accounts.betaStaleUsage(now - USAGE_REFRESH_MS)) {
    await refreshBetaUsage(env, t, now).catch((e) => logEvent("beta_usage_failed", { error: String(e) }));
  }
  if (!env.EMAIL) return;
  const due = await accounts.betaTakeCheckinsDue(now - CHECKIN_AFTER_MS, now);
  for (const t of due) {
    // The plan link URL is not stored (only its hash), so the reminder
    // points at the welcome mail, which holds it.
    await sendMail(env, t.email, checkinMail(t.grantedUserId === null));
  }
  await sendQuestions(env, now);
}

// ---- the mails ----

interface Mail { subject: string; text: string; html: string }

async function sendMail(env: Env, to: string, mail: Mail): Promise<void> {
  if (!env.EMAIL) return;
  try {
    await env.EMAIL.send({ from: FROM, to, subject: mail.subject, text: mail.text, html: mail.html });
  } catch (e) {
    logEvent("beta_mail_failed", { subject: mail.subject, error: String(e) });
  }
}

const FEEDBACK = `${SITE}/support?from=beta&page=%2Fbeta#contact`;
const MAC = `${SITE}/mac/download`;
const AGENTS = `${SITE}/agents`;

const date = (ms: number) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }).format(ms);

/// One block of a mail: plain text and its HTML. `[label](url)` becomes a
/// link; `**x**` becomes bold.
type Block = { p: string } | { ol: string[] } | { button: string; href: string };

function render(subject: string, blocks: Block[]): Mail {
  const inline = (s: string) => escapeHtml(s)
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_m, label, href) => `<a href="${href}" style="color:${BRAND.light}">${label}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  const plain = (s: string) => s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1 ($2)").replace(/\*\*([^*]+)\*\*/g, "$1");
  const text = blocks.map((b) =>
    "p" in b ? plain(b.p) : "ol" in b ? b.ol.map((x, i) => `${i + 1}. ${plain(x)}`).join("\n") : `${b.button}: ${b.href}`,
  ).join("\n\n");
  const body = blocks.map((b) =>
    "p" in b ? `<p style="margin:0 0 16px">${inline(b.p)}</p>`
      : "ol" in b ? `<ol style="margin:0 0 16px;padding-left:20px">${b.ol.map((x) => `<li style="margin:0 0 8px">${inline(x)}</li>`).join("")}</ol>`
        : `<p style="margin:4px 0 20px"><a href="${b.href}" style="display:inline-block;background:${BRAND.light};color:#fff;text-decoration:none;font-weight:600;padding:11px 20px;border-radius:999px">${escapeHtml(b.button)}</a></p>`,
  ).join("");
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>${escapeHtml(subject)}</title></head>
<body style="margin:0;padding:0;background:#fbfaf8"><div style="max-width:520px;margin:0 auto;padding:32px 20px;font:16px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;color:#1d1b19">
<p style="margin:0 0 24px"><img src="${SITE}/icon.svg" width="28" height="28" alt="Septena"></p>
${body}</div></body></html>`;
  return { subject, text, html };
}

export function welcomeMail(email: string, linkUrl: string): Mail {
  return render("You’re in the Septena beta", [
    { p: "Thanks for testing Septena." },
    { p: `Apple sends its own mail from TestFlight. Open it on your phone or tablet to install. On a Mac, [download the app here](${MAC}).` },
    { p: "These are the parts I most want your notes on. Once you sign in with this address, the same list is a project called Septena beta in your list, and you tick what you tried." },
    { ol: BETA_CHECKLIST.items.map((i) => `**${absoluteLinks(i.title)}.** ${i.try}`) },
    { p: `For the agent items, [the agents page](${AGENTS}) shows how to connect yours.` },
    { p: "The beta notes which of these parts you used and when, never what you wrote." },
    { p: "When something breaks, confuses you or works well, tell me. Say what you tried and what you expected. If an agent was involved, add the prompt." },
    { button: "Send a note", href: FEEDBACK },
    { p: `Your year of Pro starts the day Septena launches. It goes to any account you make with **${email}**. If you sign in with another address, or with Hide My Email, [open this link once to claim it](${linkUrl}).` },
    { p: "Michell" },
  ]);
}

export function checkinMail(unclaimed: boolean): Mail {
  return render("How is Septena so far?", [
    { p: "You joined the beta four days ago. What has got in your way? One line is enough." },
    { button: "Send a note", href: FEEDBACK },
    ...(unclaimed ? [{ p: "Your Pro year isn’t on an account yet. Sign in to Septena, then open the claim link in my first mail, “You’re in the Septena beta”." }] : []),
    { p: "Michell" },
  ]);
}

export function launchMail(expiresAt: number, unclaimed: boolean): Mail {
  return render("Your year of Pro has started", [
    { p: `Septena is out today, and your year of Pro runs until ${date(expiresAt)}. Thank you for testing it with me.` },
    ...(unclaimed ? [{ p: "It isn’t on an account yet. Sign in to Septena, then open the claim link in my first mail, “You’re in the Septena beta”." }] : []),
    { p: "Michell" },
  ]);
}

// ---- the checklist in the app (registry/beta.json, spec §7) ----

const LINK = /\[([^\]]+)\]\(([^)]+)\)/g;
/// A title links its key words to their septena.app page in Markdown. The
/// apps draw text, so they get the words alone.
export const plainTitle = (title: string) => title.replace(LINK, "$1");
const absoluteLinks = (title: string) => title.replace(LINK, (_m, label, href) => `[${label}](${SITE}${href})`);
const titleLinks = (title: string) => [...title.matchAll(LINK)].map(([, label, href]) => ({ label, url: `${SITE}${href}` }));

export const BETA_PLATFORMS = ["ios", "ipados", "macos", "web", "android", "windows", "linux"] as const;
export const BETA_ITEM_IDS = BETA_CHECKLIST.items.map((i) => i.id);

/// `platform` is still asked for so older builds keep their URL; the
/// answer no longer depends on it.
export const zBetaQuery = z.object({ platform: z.enum(BETA_PLATFORMS) }).strict();

/// The welcome card on Today was closed for good.
export const zBetaProgressBody = z.object({ dismissCard: z.literal(true) }).strict();

/// The server writes the seed as itself, never as the user or an agent.
export const BETA_SEED_ACTOR = "system:beta";

/// The ops that write the beta project: one project with the registry notes
/// and one open task per item, with one `about` reference per link in its
/// title. Checked against the push schema like any app push.
export function betaSeedOps(now = new Date()): { ops: Op[]; projectId: string; taskIds: Record<string, string> } {
  const at = now.toISOString();
  const day = at.slice(0, 10);
  const base = `beta-${randomId(12).replace(/[^A-Za-z0-9_-]/g, "x")}`;
  let n = 0;
  const opId = () => `${base}-${n++}`;
  const projectId = newTaskId();
  const ops: Op[] = [{
    clientOpId: opId(), op: "upsert", entity: "project", id: projectId,
    fields: { title: BETA_CHECKLIST.project.title, status: "active", notes: BETA_CHECKLIST.project.notes, created: day },
  }];
  const taskIds: Record<string, string> = {};
  BETA_CHECKLIST.items.forEach((item, i) => {
    let id = newTaskId();
    while (id === projectId || Object.values(taskIds).includes(id)) id = newTaskId();
    taskIds[item.id] = id;
    ops.push({
      clientOpId: opId(), op: "upsert", entity: "task", id,
      fields: {
        title: plainTitle(item.title), status: "open", project: projectId, notes: item.try,
        created: day, createdAt: at, touchedAt: at, source: "app", position: i + 1,
      },
    });
    titleLinks(item.title).forEach((link, j) => {
      const key = parseRef(link.url).key;
      ops.push({
        clientOpId: opId(), op: "upsert", entity: "taskRef", id: taskRefId(id, key, 0),
        fields: { taskId: id, key, role: "about", snapshot: { title: link.label, url: link.url }, position: j + 1, createdAt: at },
      });
    });
  });
  zPushBody.parse({ ops });
  return { ops, projectId, taskIds };
}

/// Seeds the beta project into a tester's account, once. Never throws: a
/// sign-in or a claim must not fail on this. A deleted project does not come
/// back (`seededAt` stays).
export async function seedBetaProject(env: Env, userId: string): Promise<void> {
  const accounts = accountStoreFor(env);
  if (!accounts) return;
  let email: string | null = null;
  try {
    const tester = await accounts.betaTakeSeed(userId);
    if (!tester) return;
    email = tester.email;
    const { ops, projectId, taskIds } = betaSeedOps();
    const { result } = await storeFor(env, userId).push(ops, BETA_SEED_ACTOR, "beta checklist");
    if (result.results[0]?.status !== "applied") throw new Error(`project ${result.results[0]?.status}`);
    await accounts.betaFinishSeed(tester.email, projectId, taskIds);
    logEvent("beta_seeded", { userId, refused: result.results.filter((r) => r.status !== "applied").length });
  } catch (e) {
    logEvent("beta_seed_failed", { userId, error: String(e) });
    if (email) await accounts.betaDropSeed(email).catch(() => undefined);
  }
}

/// Reads what the tester did from their account and stores it on the tester
/// row (the admin page counts from there). Null when the account is not a
/// tester's.
export async function refreshBetaUsage(env: Env, tester: BetaTester, now = Date.now()): Promise<BetaUsage | null> {
  const accounts = accountStoreFor(env);
  if (!accounts || !tester.grantedUserId) return null;
  const usage = await storeFor(env, tester.grantedUserId).betaUsage({
    seededTaskIds: tester.seedTaskIds ? JSON.parse(tester.seedTaskIds) as Record<string, string> : {},
    seededProjectId: tester.seedProjectId,
    joinedAt: tester.joinedAt,
    now,
  });
  return accounts.betaSaveUsage(tester.email, usage, now);
}

/// GET /v1/beta: `{ member: false }` for every account that is not a
/// tester's, so the app shows nothing. A tester gets the card copy and the
/// seeded project. The call also seeds (a tester granted before seeding
/// shipped) and refreshes the measurement.
export async function betaState(env: Env, userId: string, ctx?: { waitUntil(p: Promise<unknown>): void }) {
  const accounts = accountStoreFor(env);
  let tester = await accounts?.betaForUser(userId);
  if (!accounts || !tester) return { member: false as const };
  if (tester.seededAt === null) {
    await seedBetaProject(env, userId);
    tester = (await accounts.betaForUser(userId)) ?? tester;
  }
  const refresh = refreshBetaUsage(env, tester).catch((e) => logEvent("beta_usage_failed", { error: String(e) }));
  if (ctx) ctx.waitUntil(refresh); else await refresh;
  const { cardTitle, cardBody, cardOpen, cardDismiss } = BETA_CHECKLIST.copy;
  return {
    member: true as const,
    projectId: tester.seedProjectId,
    cardDismissedAt: tester.cardDismissedAt,
    copy: { cardTitle, cardBody, cardOpen, cardDismiss },
  };
}

/// POST /v1/beta/progress. False when the account is not a tester's.
export async function betaProgress(env: Env, userId: string, _body: z.infer<typeof zBetaProgressBody>): Promise<boolean> {
  return (await accountStoreFor(env)?.betaDismissCard(userId)) ?? false;
}

// ---- the day-7 question (Sean Ellis) ----

const ANSWER_TOKEN_RE = /^ba_[A-Za-z0-9_-]{32}$/;
const ANSWER_LABEL: Record<BetaAnswer, string> = {
  very: "Very disappointed",
  somewhat: "Somewhat disappointed",
  not: "Not disappointed",
};
export const BETA_QUESTION_AFTER_MS = 7 * 86_400_000;

export function questionMail(answerUrl: (a: BetaAnswer) => string): Mail {
  return render("One question about Septena", [
    { p: "You have had Septena for a week now. I have one question, and one tap answers it." },
    { p: "**How would you feel if you could no longer use Septena?**" },
    ...BETA_ANSWERS.map((a) => ({ button: ANSWER_LABEL[a], href: answerUrl(a) })),
    { p: "You can change your answer later with the same buttons." },
    { p: "Michell" },
  ]);
}

/// Mails the question to the testers who joined a week ago, once each.
async function sendQuestions(env: Env, now: number): Promise<void> {
  const accounts = accountStoreFor(env);
  if (!accounts) return;
  for (const t of await accounts.betaQuestionsDue(now - BETA_QUESTION_AFTER_MS)) {
    const token = `ba_${randomId(24)}`;
    if (!(await accounts.betaTakeQuestion(t.email, await sha256Base64Url(token), now))) continue;
    await sendMail(env, t.email, questionMail((a) => `${env.API_PUBLIC_URL}/beta/answer/${token}?a=${a}`));
  }
}

function answerPage(title: string, main: string, status = 200): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title>
<style>${PAGE_CSS}
  button { width: 100%; padding: 12px; border: 0; border-radius: 10px; background: ${BRAND.light}; color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
  form { margin: 0 0 14px; }
</style></head><body><main class="card">${main}</main></body></html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    },
  });
}

const goneAnswer = () => answerPage("Septena", "<h1>This link no longer works</h1><p>It may be from an older mail.</p>", 404);

async function answerToken(c: Ctx): Promise<string | null> {
  const token = c.req.param("token") ?? "";
  if (!ANSWER_TOKEN_RE.test(token)) return null;
  return (await accountStoreFor(c.env)?.betaHasAnswerToken(await sha256Base64Url(token))) ? token : null;
}

const zAnswer = z.enum(BETA_ANSWERS);

/// GET /beta/answer/:token?a=…: shows the answer and a button. Nothing is
/// stored, so a mail scanner that opens the link answers nothing.
export async function betaAnswerPage(c: Ctx): Promise<Response> {
  const token = await answerToken(c);
  const a = zAnswer.safeParse(c.req.query("a"));
  if (!token || !a.success) return goneAnswer();
  return answerPage("Septena", `<h1>How would you feel if you could no longer use Septena?</h1>
  <p>Your answer: <strong>${escapeHtml(ANSWER_LABEL[a.data])}</strong>.</p>
  <form method="post" action="/beta/answer/${token}"><input type="hidden" name="a" value="${a.data}"><button type="submit">Send my answer</button></form>`);
}

/// POST /beta/answer/:token: stores the answer; a later one replaces it.
export async function betaAnswerSave(c: Ctx): Promise<Response> {
  const token = await answerToken(c);
  const a = zAnswer.safeParse((await c.req.parseBody()).a);
  if (!token || !a.success) return goneAnswer();
  await accountStoreFor(c.env)!.betaAnswer(await sha256Base64Url(token), a.data);
  logEvent("beta_answered", { answer: a.data });
  return answerPage("Septena", `<h1>Thank you</h1>
  <p>I have your answer. If something made you pick it, I would like to hear it.</p>
  <p><a href="${FEEDBACK}">Send a note</a></p>`);
}
