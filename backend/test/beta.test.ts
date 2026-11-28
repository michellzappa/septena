import { describe, it, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// The beta by invite code (ADR 0064, docs/BETA_ONBOARDING_SPEC.md).

const { betaJoin, grantBetaAtSignIn, setBetaLaunch, sweepBeta, afterJoin, betaState, betaProgress, betaItemsFor } = await import("../src/api/beta.ts");
const { claimPlusLink, betaGrantEnd } = await import("../src/api/plusLinks.ts");
const { normalizeBetaCode } = await import("../src/store/betaInvites.ts");
const { Hono } = await import("hono");

const ORIGIN = "https://api.septena.app";
const DAY = 86_400_000;
const userId = (n: number) => `u_${String(n).repeat(43)}`;

async function pem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
}

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

/// App Store Connect, as far as the join needs it.
function fakeApple(opts: { refuse?: boolean } = {}) {
  const calls: { method: string; path: string; body: any }[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    assert.equal(url.host, "api.appstoreconnect.apple.com");
    assert.match(String((init?.headers as Record<string, string>).Authorization), /^Bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    calls.push({ method: init?.method ?? "GET", path: url.pathname, body });
    if (opts.refuse) return new Response(JSON.stringify({ errors: [{ code: "FORBIDDEN" }] }), { status: 403 });
    if (url.pathname === "/v1/betaTesters" && init?.method === "POST") return new Response(JSON.stringify({ data: { id: "tester-1" } }), { status: 201 });
    return new Response("{}", { status: 201 });
  }) as typeof fetch;
  return calls;
}

async function harness() {
  const { store: accounts } = await createTestAccountStore();
  const tasks = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const map = new Map<string, string>();
  const kv = { async get(k: string) { return map.get(k) ?? null; }, async put(k: string, v: string) { map.set(k, v); }, async delete(k: string) { map.delete(k); } };
  const ns = (make: (id: string) => Promise<object>) => ({
    idFromName: (name: string) => name,
    get: (id: string) => new Proxy({}, {
      get: (_t, prop: string) => async (...args: unknown[]) =>
        ((await make(id)) as Record<string, (...a: unknown[]) => unknown>)[prop](...args),
    }),
  });
  const taskStore = async (id: string) => {
    if (!tasks.has(id)) tasks.set(id, (await createTestTaskStore()).store);
    return tasks.get(id)!;
  };
  const mails: { to: string; subject: string; text: string; html: string }[] = [];
  const env = {
    API_PUBLIC_URL: ORIGIN, STATE: kv, TOKENS: kv, CLIENTS: kv,
    TASK_STORE: ns(taskStore), ACCOUNT_STORE: ns(async () => accounts),
    EMAIL: { async send(m: { to: string; subject: string; text: string; html: string }) { mails.push(m); } },
    ASC_KEY_P8: await pem(), ASC_KEY_ID: "KEY1", ASC_ISSUER_ID: "issuer", ASC_APP_ID: "app-1", ASC_BETA_GROUP_ID: "group-1",
  } as never;
  const pending: Promise<unknown>[] = [];
  const ctx = { waitUntil(p: Promise<unknown>) { pending.push(p); }, passThroughOnException() {} } as never;
  const app = new Hono();
  app.post("/v1/beta/join", betaJoin as never);
  let ip = 0;
  const join = async (body: unknown, origin = "https://septena.app") => {
    const res = await app.fetch(new Request(`${ORIGIN}/v1/beta/join`, {
      method: "POST", headers: { "Content-Type": "application/json", Origin: origin, "CF-Connecting-IP": `10.0.0.${++ip}` }, body: JSON.stringify(body),
    }), env, ctx);
    await Promise.all(pending.splice(0));
    return { status: res.status, json: await res.json() as Record<string, string>, cors: res.headers.get("Access-Control-Allow-Origin") };
  };
  return { env, accounts, taskStore, mails, join };
}

describe("Beta codes", () => {
  it("normalizes codes", () => {
    assert.equal(normalizeBetaCode(" first-wave "), "FIRSTWAVE");
  });

  it("uses a code only when the invite went through, and stops at the limit", async () => {
    const { store: a } = await createTestAccountStore();
    const code = a.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 1, endsAt: null })!;
    assert.equal(a.createBetaCode({ code: "FIRSTWAVE", label: "again", maxUses: 1, endsAt: null }), null, "a code text is unique");
    assert.deepEqual(a.betaStartJoin("a@x.io", "nope1234"), { ok: false });
    const s = a.betaStartJoin("a@x.io", "firstwave");
    assert.ok(s.ok && s.state === "new");
    a.betaFinishJoin("a@x.io", code.id, "failed", null);
    assert.equal(a.listBetaCodes().codes[0].useCount, 0, "a failed invite takes no use");
    a.betaFinishJoin("a@x.io", code.id, "invited", "t1");
    assert.equal(a.listBetaCodes().codes[0].useCount, 1);
    const again = a.betaStartJoin("a@x.io", "anything");
    assert.ok(again.ok && again.state === "already_joined", "a tester comes back as joined with any code");
    assert.deepEqual(a.betaStartJoin("b@x.io", "FIRSTWAVE"), { ok: false }, "used up");
  });

  it("refuses closed and ended codes", async () => {
    const { store: a } = await createTestAccountStore();
    const c1 = a.createBetaCode({ code: "CLOSEDONE", label: "x", maxUses: 9, endsAt: null })!;
    a.closeBetaCode(c1.id);
    a.createBetaCode({ code: "ENDEDCODE", label: "y", maxUses: 9, endsAt: Date.now() - 1 });
    assert.deepEqual(a.betaStartJoin("a@x.io", "CLOSEDONE"), { ok: false });
    assert.deepEqual(a.betaStartJoin("a@x.io", "ENDEDCODE"), { ok: false });
  });
});

describe("POST /v1/beta/join", () => {
  it("invites through TestFlight, makes the Pro link and sends the welcome mail", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    const apple = fakeApple();
    const r = await h.join({ email: "Ana@Example.com", code: "firstwave" });
    assert.equal(r.status, 200);
    assert.equal(r.json.state, "joined");
    assert.equal(r.cors, "https://septena.app");
    assert.equal(apple[0].body.data.attributes.email, "ana@example.com");
    assert.equal(apple[0].body.data.relationships.betaGroups.data[0].id, "group-1");
    const tester = h.accounts.betaTester("ana@example.com")!;
    assert.equal(tester.ascState, "invited");
    assert.ok(tester.planLinkId && tester.planLinkHash);
    assert.equal(h.mails.length, 1);
    assert.equal(h.mails[0].subject, "You’re in the Septena beta");
    assert.match(h.mails[0].text, /\/plus\/pl_/);
    assert.doesNotMatch(h.mails[0].text + h.mails[0].html, /[—–]/, "no dashes in the mail");

    const back = await h.join({ email: "ana@example.com", code: "whatever" });
    assert.equal(back.json.state, "already_joined");
    assert.equal(apple.at(-1)!.path, "/v1/betaTesterInvitations", "a second visit resends the invite");
    assert.equal(h.mails.length, 1, "no second welcome mail");
  });

  it("answers bad_code, bad_email and apple_unavailable", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    assert.deepEqual((await h.join({ email: "a@x.io", code: "WRONGCODE" })).json, { error: "bad_code" });
    assert.deepEqual((await h.join({ email: "not-an-email", code: "FIRSTWAVE" })).json, { error: "bad_email" });
    fakeApple({ refuse: true });
    const r = await h.join({ email: "a@x.io", code: "FIRSTWAVE" });
    assert.equal(r.status, 502);
    assert.equal(h.accounts.listBetaCodes().codes[0].useCount, 0);
    assert.equal(h.mails.length, 0);
  });

  it("limits tries per address", async () => {
    const h = await harness();
    fakeApple();
    const app = new Hono();
    app.post("/v1/beta/join", betaJoin as never);
    let last = 0;
    for (let i = 0; i < 6; i++) {
      const res = await app.fetch(new Request(`${ORIGIN}/v1/beta/join`, {
        method: "POST", headers: { "Content-Type": "application/json", "CF-Connecting-IP": "10.9.9.9" }, body: JSON.stringify({ email: "a@x.io", code: "WRONGCODE" }),
      }), h.env, { waitUntil() {}, passThroughOnException() {} } as never);
      last = res.status;
    }
    assert.equal(last, 429);
  });
});

describe("The Pro year follows the email", () => {
  it("gives Pro at sign-in with the email, and the first account wins", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    await h.join({ email: "ana@example.com", code: "FIRSTWAVE" });
    await grantBetaAtSignIn(h.env, userId(1), "ana@example.com", false);
    assert.deepEqual((await h.taskStore(userId(1))).entitlements(), [], "an unverified email gets nothing");
    await grantBetaAtSignIn(h.env, userId(1), "Ana@example.com", true);
    const rows = (await h.taskStore(userId(1))).entitlements();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].plan, "pro");
    assert.equal(rows[0].expiresAt, null, "no end before launch");
    assert.equal(h.accounts.betaTester("ana@example.com")!.grantedUserId, userId(1));

    const tester = h.accounts.betaTester("ana@example.com")!;
    ensureSession(await h.taskStore(userId(2)), "sid-2");
    assert.equal(await claimPlusLink(h.env, tester.planLinkHash!, userId(2)), null, "the link is used once");
  });

  it("gives Pro at join to an email account that exists", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    const { userId: owner } = await h.accounts.resolveOrCreateIdentity("email", "bo@example.com");
    fakeApple();
    await h.join({ email: "bo@example.com", code: "FIRSTWAVE" });
    assert.equal((await h.taskStore(owner)).entitlements()[0].plan, "pro");
  });

  it("the launch day ends every grant a year later and mails every tester", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    await h.join({ email: "ana@example.com", code: "FIRSTWAVE" });
    await h.join({ email: "cy@example.com", code: "FIRSTWAVE" });
    await grantBetaAtSignIn(h.env, userId(1), "ana@example.com", true);
    const launch = Date.UTC(2027, 2, 1);
    assert.equal(await setBetaLaunch(h.env, launch), true);
    assert.equal(await setBetaLaunch(h.env, launch), false, "once");
    assert.equal((await h.taskStore(userId(1))).entitlements()[0].expiresAt, betaGrantEnd(launch));
    const launchMails = h.mails.filter((m) => m.subject === "Your year of Pro has started");
    assert.equal(launchMails.length, 2);
    assert.match(launchMails.find((m) => m.to === "cy@example.com")!.text, /isn’t on an account yet/);

    // A claim after launch gets the end date too.
    const cy = h.accounts.betaTester("cy@example.com")!;
    await grantBetaAtSignIn(h.env, userId(3), "cy@example.com", true);
    assert.equal((await h.taskStore(userId(3))).entitlements()[0].expiresAt, betaGrantEnd(launch));
    assert.ok(cy);
  });

  it("sends the day-4 check-in once", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    await h.join({ email: "ana@example.com", code: "FIRSTWAVE" });
    await sweepBeta(h.env, Date.now() + 3 * DAY);
    assert.equal(h.mails.filter((m) => m.subject === "How is Septena so far?").length, 0, "not before day 4");
    await sweepBeta(h.env, Date.now() + 5 * DAY);
    await sweepBeta(h.env, Date.now() + 6 * DAY);
    assert.equal(h.mails.filter((m) => m.subject === "How is Septena so far?").length, 1);
  });
});

describe("The checklist in the app", () => {
  it("shows nothing to an account that is not a tester's, and the items to one that is", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    await h.join({ email: "ana@example.com", code: "FIRSTWAVE" });
    assert.deepEqual(await betaState(h.env, userId(1), "ios"), { member: false });
    assert.equal(await betaProgress(h.env, userId(1), { item: "do", tried: true }), false, "a non-tester cannot write");
    await grantBetaAtSignIn(h.env, userId(1), "ana@example.com", true);
    const s = await betaState(h.env, userId(1), "ios");
    assert.ok(s.member);
    assert.equal(s.items.length, 10);
    assert.equal(s.copy.title, "Beta");
    assert.deepEqual(s.tried, {});
    assert.equal(s.cardDismissedAt, null);

    assert.equal(await betaProgress(h.env, userId(1), { item: "do", tried: true }), true);
    await betaProgress(h.env, userId(1), { ack: true });
    await betaProgress(h.env, userId(1), { dismissCard: true });
    const after = await betaState(h.env, userId(1), "ios");
    assert.ok(after.member && after.tried.do && after.ackAt && after.cardDismissedAt);
    await betaProgress(h.env, userId(1), { item: "do", tried: false });
    const untick = await betaState(h.env, userId(1), "ios");
    assert.ok(untick.member && !untick.tried.do);
    assert.equal(h.accounts.listBetaCodes().progress._ack, 1);
  });

  it("lists only what ships on the platform", () => {
    const web = betaItemsFor("web").map((i) => i.id);
    assert.ok(!web.includes("do"), "Do is not built on the web");
    assert.ok(!web.includes("siri"));
    assert.ok(web.includes("connect-agent"));
    assert.ok(betaItemsFor("macos").map((i) => i.id).includes("siri"));
  });
});

void afterJoin;
