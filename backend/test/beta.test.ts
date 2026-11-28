import { describe, it, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// The beta by invite code (ADR 0064, docs/BETA_ONBOARDING_SPEC.md).

const { betaJoin, grantBetaAtSignIn, setBetaLaunch, sweepBeta, afterJoin, betaState, betaProgress, betaAnswerPage, betaAnswerSave, zBetaProgressBody } = await import("../src/api/beta.ts");
const { BETA_CHECKLIST } = await import("../src/generated/registries.ts");
const { testerStats } = await import("../src/store/AccountStore.ts");
const { renderAdmin, betaFunnel } = await import("../src/admin/page.ts");
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
    assert.match(h.mails[0].html, /<a href="https:\/\/septena\.app\/workflows\/do"[^>]*>Do<\/a>/, "the checklist links its key words");
    assert.doesNotMatch(h.mails[0].text + h.mails[0].html, /[—–]/, "no dashes in the mail");
    assert.match(h.mails[0].text, /notes which of these parts you used and when, never what you wrote/);

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
  async function tester() {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    await h.join({ email: "ana@example.com", code: "FIRSTWAVE" });
    await grantBetaAtSignIn(h.env, userId(1), "ana@example.com", true);
    return { ...h, store: await h.taskStore(userId(1)) };
  }

  it("seeds the Septena beta project once, when the grant lands", async () => {
    const h = await tester();
    const t = h.accounts.betaTester("ana@example.com")!;
    assert.ok(t.seededAt && t.seedProjectId);
    const map = JSON.parse(t.seedTaskIds!) as Record<string, string>;
    assert.deepEqual(Object.keys(map), BETA_CHECKLIST.items.map((i) => i.id));
    const project = h.store.readContainer("project", t.seedProjectId!)!;
    assert.equal(project.title, "Septena beta");
    assert.equal(project.area ?? null, null);
    assert.equal(project.notes, BETA_CHECKLIST.project.notes);
    const doTask = h.store.readTask(map.do)!.task;
    assert.equal(doTask.title, "Do one task");
    assert.equal(doTask.project, t.seedProjectId);
    assert.equal(doTask.status, "open");
    assert.equal(doTask.source, "app");
    assert.equal(doTask.addedVia ?? null, null);
    assert.equal(doTask.notes, BETA_CHECKLIST.items.find((i) => i.id === "do")!.try);
    const refs = h.store.readTaskRefs(map["review-stop"]);
    assert.deepEqual(refs.map((r) => (r.snapshot as { title: string }).title), ["Review", "stop"]);
    assert.deepEqual(refs.map((r) => [r.key, r.role]), [
      ["url:https://septena.app/workflows/agent-delegation", "about"], ["url:https://septena.app/help/agent-controls", "about"],
    ]);
    assert.equal(h.store.history("project", t.seedProjectId!, null, 5)[0].actor, "system:beta", "the server writes the seed");

    // Deleting the project does not bring it back: not on a new GET, a new
    // sign-in or the sweep.
    h.store.push([{ clientOpId: "del-project-1", op: "delete", entity: "project", id: t.seedProjectId! }], "app:septask-ios");
    await grantBetaAtSignIn(h.env, userId(1), "ana@example.com", true);
    await betaState(h.env, userId(1));
    await sweepBeta(h.env);
    const projects = h.store.readProjects("all", 50);
    assert.equal(projects.filter((p) => p.title === "Septena beta").length, 0);
    assert.equal(h.accounts.betaTester("ana@example.com")!.seedProjectId, t.seedProjectId);
  });

  it("seeds a tester granted before seeding shipped, on their next GET", async () => {
    const h = await harness();
    h.accounts.createBetaCode({ code: "FIRSTWAVE", label: "Friends", maxUses: 5, endsAt: null });
    fakeApple();
    await h.join({ email: "ana@example.com", code: "FIRSTWAVE" });
    // The grant as it landed before this deploy: the tester row, no seed.
    h.accounts.betaLinkClaimed(h.accounts.betaTester("ana@example.com")!.planLinkId!, userId(1));
    assert.equal(h.accounts.betaTester("ana@example.com")!.seededAt, null);
    const s = await betaState(h.env, userId(1));
    assert.ok(s.member && s.projectId);
    assert.equal((await h.taskStore(userId(1))).readProjects("all", 50).filter((p) => p.title === "Septena beta").length, 1);
    await betaState(h.env, userId(1));
    assert.equal((await h.taskStore(userId(1))).readProjects("all", 50).filter((p) => p.title === "Septena beta").length, 1, "once");
  });

  it("answers member false to everyone else, and the card and project to a tester", async () => {
    const h = await tester();
    assert.deepEqual(await betaState(h.env, userId(9)), { member: false });
    assert.equal(await betaProgress(h.env, userId(9), { dismissCard: true }), false);
    const s = await betaState(h.env, userId(1));
    assert.deepEqual(Object.keys(s).sort(), ["cardDismissedAt", "copy", "member", "projectId"]);
    assert.ok(s.member);
    assert.equal(s.projectId, h.accounts.betaTester("ana@example.com")!.seedProjectId);
    assert.equal(s.cardDismissedAt, null);
    assert.deepEqual(Object.keys(s.copy).sort(), ["cardBody", "cardDismiss", "cardOpen", "cardTitle"]);
    assert.match(s.copy.cardBody, /Septena beta project/);
    assert.equal(await betaProgress(h.env, userId(1), { dismissCard: true }), true);
    const after = await betaState(h.env, userId(1));
    assert.ok(after.member && after.cardDismissedAt);
    assert.equal(zBetaProgressBody.safeParse({ item: "do", tried: true }).success, false, "ticks are tasks now");
  });

  it("measures each item from the account's own data, apart from what was ticked", async () => {
    const h = await tester();
    const t = h.accounts.betaTester("ana@example.com")!;
    const map = JSON.parse(t.seedTaskIds!) as Record<string, string>;
    const s = h.store;
    const APP = "app:septask-ios";
    const AGENT = "mcp:Claude";
    let n = 0;
    const op = () => `op-${String(++n).padStart(6, "0")}`;
    const push = (actor: string, ...ops: Record<string, unknown>[]) =>
      s.push(ops.map((o) => ({ clientOpId: op(), ...o })) as never, actor).result.results;
    const usage = () => s.betaUsage({ seededTaskIds: map, seededProjectId: t.seedProjectId, joinedAt: t.joinedAt });

    const none = usage();
    assert.ok(Object.values(none.did).every((v) => v === null), "a fresh account did nothing");
    assert.ok(Object.values(none.ticked).every((v) => v === false));

    // Seeded tasks never count: Do of the seeded task, moving it to Today.
    push(APP, { op: "upsert", entity: "doSession", id: "do-seeded", fields: { taskId: map.do, startedAt: new Date().toISOString() } });
    push(APP, { op: "upsert", entity: "task", id: map.capture, fields: { today: true } });
    assert.equal(usage().did.do, null);

    // Ticked is not did: the seeded task is done, the feature unused.
    push(APP, { op: "upsert", entity: "task", id: map.fade, fields: { status: "done" } });
    const ticked = usage();
    assert.equal(ticked.ticked.fade, true);
    assert.equal(ticked.did.fade, null);

    // inbox-today: an Inbox task the user files later.
    push(APP, { op: "upsert", entity: "task", id: "inbox1", fields: { title: "x", status: "open", addedVia: "typed" } });
    assert.equal(usage().did["inbox-today"], null);
    push(APP, { op: "upsert", entity: "task", id: "inbox1", fields: { today: true } });
    assert.ok(usage().did["inbox-today"]);

    // do
    push(APP, { op: "upsert", entity: "doSession", id: "do-own", fields: { taskId: "inbox1", startedAt: new Date().toISOString() } });
    assert.ok(usage().did.do);

    // second-device: the second device with a session.
    ensureSession(s, "sid-a"); s.deviceAccess("sid-a", "septask-ios", null);
    assert.equal(usage().did["second-device"], null);
    ensureSession(s, "sid-b"); s.deviceAccess("sid-b", "septask-mac", null);
    assert.ok(usage().did["second-device"]);

    // fade: the sweep answered.
    push(APP, { op: "upsert", entity: "setting", id: "fadeSweptAt", fields: { value: new Date().toISOString() } });
    assert.ok(usage().did.fade);

    // connect-agent
    s.recordConnection("fam-1", "client-1", "Claude", "tasks:read tasks:write");
    assert.ok(usage().did["connect-agent"]);

    // review-stop: Pause all agents.
    push(APP, { op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } });
    assert.ok(usage().did["review-stop"]);

    // discuss: a user turn in a thread the app's model runs. A thread with
    // only a connected agent's turns does not count.
    push(APP, { op: "upsert", entity: "task", id: "talk1", fields: { title: "t", status: "open" } });
    push(AGENT, { op: "appendTurn", taskId: "talk1", turn: { role: "provider", step: "confirm", provider: "claude", question: "Which?", ts: new Date().toISOString() } });
    push(APP, { op: "appendTurn", taskId: "talk1", turn: { role: "user", step: "confirm", chosen: "A", ts: new Date().toISOString() } });
    assert.equal(usage().did.discuss, null);
    push(APP, { op: "appendTurn", taskId: "talk1", turn: { role: "provider", step: "confirm", provider: "onDevice", question: "Is this it?", ts: new Date().toISOString() } });
    assert.ok(usage().did.discuss);

    // move-in, siri, capture: how the task was added.
    push(APP, { op: "upsert", entity: "task", id: "imp1", fields: { title: "i", status: "open", addedVia: "import" } });
    push(APP, { op: "upsert", entity: "task", id: "sir1", fields: { title: "s", status: "open", addedVia: "shortcut" } });
    assert.equal(usage().did.capture, null);
    push(APP, { op: "upsert", entity: "task", id: "cap1", fields: { title: "c", status: "open", addedVia: "share" } });
    const all = usage();
    for (const id of ["move-in", "siri", "capture"]) assert.ok(all.did[id], id);
    assert.ok(Object.values(all.did).every((v) => typeof v === "number"), "every item measured");

    // A deleted device or agent still counts once stored.
    const saved = h.accounts.betaSaveUsage("ana@example.com", all);
    s.forgetConnection("fam-1");
    const later = h.accounts.betaSaveUsage("ana@example.com", usage());
    assert.equal(later.did["connect-agent"], saved.did["connect-agent"]);
  });

  it("counts review-stop from an Accept, a completed agent loop, active days and a normal week", async () => {
    const h = await tester();
    const t = h.accounts.betaTester("ana@example.com")!;
    const map = JSON.parse(t.seedTaskIds!) as Record<string, string>;
    const s = h.store;
    const APP = "app:septask-ios";
    const AGENT = "mcp:Claude";
    let n = 0;
    const push = (actor: string, ...ops: Record<string, unknown>[]) =>
      s.push(ops.map((o) => ({ clientOpId: `loop-${String(++n).padStart(6, "0")}`, ...o })) as never, actor).result.results;
    const usage = () => s.betaUsage({ seededTaskIds: map, seededProjectId: t.seedProjectId, joinedAt: t.joinedAt });

    push(APP, { op: "upsert", entity: "task", id: "job1", fields: { title: "j", status: "open" } },
      { op: "upsert", entity: "convo", id: "job1", fields: { assignee: "claude" } });
    push(AGENT, { op: "appendTurn", taskId: "job1", turn: { role: "provider", step: "decide", provider: "claude", question: "Which one?", options: ["A", "B"], ts: new Date().toISOString() } });
    push(APP, { op: "appendTurn", taskId: "job1", turn: { role: "user", step: "decide", chosen: "A", inReplyTo: 1, ts: new Date().toISOString() } });
    const handoff = push(AGENT, { op: "upsert", entity: "convo", id: "job1", fields: { endState: "needs_verify", endStateNote: "Check the draft." } });
    assert.equal(handoff[0].status, "applied");
    assert.equal(usage().loops.total, 0, "not accepted yet");
    push(APP, { op: "upsert", entity: "task", id: "job1", fields: { status: "done" } });
    const u = usage();
    assert.ok(u.did["review-stop"], "Accept in Review");
    assert.deepEqual(u.loops, { total: 1, week: 1 });

    // A loop with no answered question is not a loop.
    push(APP, { op: "upsert", entity: "task", id: "job2", fields: { title: "j2", status: "open" } });
    push(AGENT, { op: "upsert", entity: "convo", id: "job2", fields: { endState: "needs_verify", endStateNote: "Check it." } });
    push(APP, { op: "upsert", entity: "task", id: "job2", fields: { status: "done" } });
    assert.equal(usage().loops.total, 1);

    // A normal week: the user added job1 and job2 (agents and the seed do
    // not count), completed both, and moved one to Today.
    push(AGENT, { op: "upsert", entity: "task", id: "byagent", fields: { title: "a", status: "open", addedVia: "agent" } });
    push(APP, { op: "upsert", entity: "task", id: "job3", fields: { title: "j3", status: "open" } });
    push(APP, { op: "upsert", entity: "task", id: "job3", fields: { today: true } });
    push(APP, { op: "upsert", entity: "task", id: map.do, fields: { status: "done" } });
    const w = usage();
    assert.deepEqual(w.week, { added: 3, done: 2, movedToday: 1 });
    assert.ok(w.firstTaskAt && w.firstDoneAt);
    assert.equal(w.activeDays.w1, 1, "every change today is one active day");
    assert.equal(w.week1ThirdDayAt, null);

    // The product-wide counts ride on the account summary.
    const summary = s.accountSummary()!;
    assert.equal(summary.agentLoops7d, 1);
    assert.equal(summary.userTasksAdded7d, 3);
    assert.equal(summary.userTasksDone7d, 3, "the summary does not know the seed");
    assert.equal(summary.userMovedToday7d, 1);
    // The daily snapshot (recordMetrics) is the overview: the sums land there.
    const { overview } = await import("../src/admin/accounts.ts");
    const o = overview([{ summary, createdAt: Date.now() }, { summary, createdAt: Date.now() }] as never);
    assert.deepEqual([o.agentLoops7d, o.userTasksAdded7d, o.userTasksDone7d, o.userMovedToday7d], [2, 6, 6, 2]);
  });

  it("counts active days per week from the join", async () => {
    const h = await tester();
    const t = h.accounts.betaTester("ana@example.com")!;
    const s = h.store;
    s.push([{ clientOpId: "days-000001", op: "upsert", entity: "task", id: "d1", fields: { title: "d", status: "open" } }], "app:septask-ios");
    // Same rows, read as if the join had been 10 days ago: today is in week 2.
    const u = s.betaUsage({ seededTaskIds: {}, seededProjectId: null, joinedAt: t.joinedAt - 10 * DAY });
    assert.equal(u.activeDays.w1, 0);
    assert.equal(u.activeDays.w2 >= 1, true);
  });

  it("asks the day-7 question once and records the answer only on a POST", async () => {
    const h = await tester();
    await sweepBeta(h.env, Date.now() + 6 * DAY);
    assert.equal(h.mails.filter((m) => m.subject === "One question about Septena").length, 0, "not before day 7");
    await sweepBeta(h.env, Date.now() + 8 * DAY);
    await sweepBeta(h.env, Date.now() + 9 * DAY);
    const asked = h.mails.filter((m) => m.subject === "One question about Septena");
    assert.equal(asked.length, 1);
    assert.equal(h.mails.filter((m) => m.subject === "How is Septena so far?").length, 1, "the day-4 check-in stays");
    assert.doesNotMatch(asked[0].text + asked[0].html, /[—–]/);
    const url = /https:\/\/api\.septena\.app\/beta\/answer\/(ba_[A-Za-z0-9_-]{32})\?a=very/.exec(asked[0].text);
    assert.ok(url, "a link per answer");
    const token = url[1];
    const app = new Hono();
    app.get("/beta/answer/:token", betaAnswerPage as never);
    app.post("/beta/answer/:token", betaAnswerSave as never);
    const call = (path: string, init?: RequestInit) => app.fetch(new Request(`${ORIGIN}${path}`, init), h.env, { waitUntil() {}, passThroughOnException() {} } as never);

    const shown = await call(`/beta/answer/${token}?a=very`);
    assert.equal(shown.status, 200);
    assert.match(await shown.text(), /Very disappointed/);
    assert.equal(h.accounts.betaTester("ana@example.com")!.answer, null, "opening the link answers nothing");
    assert.equal((await call(`/beta/answer/ba_${"x".repeat(32)}?a=very`)).status, 404);
    assert.equal((await call(`/beta/answer/${token}?a=maybe`)).status, 404);

    const post = (a: string) => call(`/beta/answer/${token}`, { method: "POST", body: new URLSearchParams({ a }) });
    assert.equal((await post("very")).status, 200);
    assert.equal(h.accounts.betaTester("ana@example.com")!.answer, "very");
    await post("somewhat");
    assert.equal(h.accounts.betaTester("ana@example.com")!.answer, "somewhat", "a later answer replaces it");
  });

  it("shows counts, the funnel and one tester on the admin page, with no email list", async () => {
    const h = await tester();
    await betaState(h.env, userId(1));
    const listed = h.accounts.listBetaCodes();
    assert.equal(listed.testers.length, 1);
    assert.ok(!JSON.stringify(listed.testers).includes("@"), "the card's rows carry no email");
    assert.deepEqual(betaFunnel(listed.testers), [1, 1, 0, 0, 0, 0]);
    const view = {
      admin: "mz@example.com", accounts: [], links: [], uses: [], signups: null, query: "", emailSignups: [], emailUserId: null,
      history: [], traffic: { state: "off" }, releases: [], now: Date.now(),
      beta: { ...listed, lookup: { email: "ana@example.com", tester: testerStats(h.accounts.betaTester("ana@example.com")!) } },
    };
    const html = renderAdmin("plans", view as never);
    assert.match(html, /Activation/);
    assert.match(html, /Did it/);
    assert.match(html, /bar: 40%/);
    assert.match(html, /action="\/admin\/beta\/tester"/);
    assert.equal((html.match(/ana@example\.com/g) ?? []).length, 1, "only the looked-up address, once");
    const noLookup = renderAdmin("plans", { ...view, beta: { ...listed } } as never);
    assert.ok(!noLookup.includes("ana@example.com"));
  });
});

describe("addedVia", () => {
  it("takes the registry values from an app push and nothing else", async () => {
    const { zPushBody } = await import("../src/store/ops.ts");
    const op = (addedVia: unknown) => ({ ops: [{ clientOpId: "addv-0001", op: "upsert", entity: "task", id: "t1", fields: { title: "x", status: "open", addedVia } }] });
    for (const v of ["typed", "quick-entry", "quick-add", "share", "shortcut", "import", "agent", "api", null]) assert.ok(zPushBody.safeParse(op(v)).success, String(v));
    assert.equal(zPushBody.safeParse(op("siri")).success, false);
  });

  it("is agent on a task an MCP connector creates", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const out = await runWriteTool({ store: store as never, timeZone: "UTC", agentName: "Claude" }, "tasks_create", { title: "From the agent" }) as { id?: string; task?: { id: string } };
    const id = out.id ?? out.task!.id;
    assert.equal(store.readTask(id)!.task.addedVia, "agent");
  });
});

void afterJoin;
