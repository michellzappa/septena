import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { createTestSupportStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Contact Support (ADR 0054, docs/SUPPORT_SPEC.md §5).

const { support, sweepSupport, MAX_PER_MINUTE, replyMail } = await import("../src/support/routes.ts");
const { intakeBody, sign, verify } = await import("../src/support/starlings.ts");
const { Hono } = await import("hono");

const KEY_HEX = "0123456789abcdef".repeat(4);
const KEY = Uint8Array.from(KEY_HEX.match(/../g)!, (p) => parseInt(p, 16));
const supportKey = (n: number) => String.fromCharCode(65 + n).repeat(43);

async function harness(opts: { starlings?: (req: Request) => Promise<Response> } = {}) {
  const { store } = await createTestSupportStore();
  const kv = new Map<string, string>();
  const mails: { to: string; subject: string; text: string }[] = [];
  const sent: { headers: Headers; body: string }[] = [];
  const env = {
    APP_INTAKE_KEY: KEY_HEX,
    STARLINGS_INTAKE_URL: "https://starlings.test/api/support/app-intake",
    STATE: {
      async get(k: string) { return kv.get(k) ?? null; },
      async put(k: string, v: string) { kv.set(k, v); },
    },
    SUPPORT_STORE: { idFromName: (n: string) => n, get: () => store },
    EMAIL: { async send(m: { to: string; subject: string; text: string }) { mails.push(m); } },
  };
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    sent.push({ headers: req.headers, body: await req.clone().text() });
    return opts.starlings ? opts.starlings(req) : new Response(JSON.stringify({ ok: true, thread_id: "gst_x" }), { status: 200 });
  }) as typeof fetch;
  const app = new Hono();
  app.route("/v1/support", support);
  const waits: Promise<unknown>[] = [];
  const ctx = { waitUntil: (p: Promise<unknown>) => waits.push(p), passThroughOnException() {}, props: {} };
  const call = async (path: string, init: RequestInit = {}) => {
    const res = await app.fetch(new Request(`https://api.septena.app${path}`, init), env as never, ctx as never);
    await Promise.all(waits.splice(0));
    return res;
  };
  return { env, store, call, mails, sent, restore: () => { globalThis.fetch = realFetch; } };
}

function post(body: unknown, key = supportKey(0)) {
  return {
    method: "POST",
    headers: { "content-type": "application/json", "X-Septena-Support-Key": key, "CF-Connecting-IP": "203.0.113.9" },
    body: JSON.stringify(body),
  };
}

async function signedReply(body: unknown, opts: { key?: Uint8Array<ArrayBuffer>; direction?: "reply" | "intake"; at?: number } = {}) {
  const raw = JSON.stringify(body);
  const ts = String(opts.at ?? Date.now());
  return {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-starlings-timestamp": ts,
      "x-starlings-signature": await sign(opts.key ?? KEY, opts.direction ?? "reply", ts, raw),
    },
    body: raw,
  };
}

describe("support signatures", () => {
  it("match Starlings: hex HMAC-SHA256 of direction.timestamp.body, keyed with the decoded 32 bytes", async () => {
    const expected = createHmac("sha256", Buffer.from(KEY_HEX, "hex")).update("intake.1700000000000.{\"a\":1}").digest("hex");
    assert.equal(await sign(KEY, "intake", "1700000000000", "{\"a\":1}"), expected);
    const now = Date.now();
    const sig = await sign(KEY, "reply", String(now), "x");
    assert.equal(await verify(KEY, "reply", { timestamp: String(now), signature: sig, rawBody: "x", now }), true);
    assert.equal(await verify(KEY, "intake", { timestamp: String(now), signature: sig, rawBody: "x", now }), false);
    assert.equal(await verify(KEY, "reply", { timestamp: String(now - 6 * 60_000), signature: sig, rawBody: "x", now }), false);
  });

  it("send a report with platform, version and build when diagnostics are on, a message otherwise", () => {
    const base = { id: "m1", reporterRef: "install:abc", text: "Help", email: "a@example.com", name: null };
    assert.deepEqual(intakeBody({ ...base, diagnostics: null }), {
      message_id: "m1", kind: "message", reporter: { ref: "install:abc", email: "a@example.com" }, text: "Help",
    });
    const report = intakeBody({ ...base, diagnostics: JSON.stringify({ platform: "macos", appVersion: "0.9.4", build: 2310, osVersion: "26.1", signedIn: false }) });
    assert.equal(report.kind, "report");
    assert.deepEqual(report.report, { platform: "macos", app_version: "0.9.4", build: 2310 });
    assert.equal(report.text, "Help\n\nOS 26.1 · signed out");
  });
});

describe("POST /v1/support/messages", () => {
  it("stores a signed-out message, forwards it signed, and a repeat adds nothing", async () => {
    const h = await harness();
    try {
      const id = crypto.randomUUID();
      const res = await h.call("/v1/support/messages", post({ message_id: id, text: "Sync stopped", email: "Sam@Example.com" }));
      assert.equal(res.status, 202);
      assert.equal(h.sent.length, 1);
      const sent = JSON.parse(h.sent[0]!.body);
      assert.equal(sent.message_id, id);
      assert.match(sent.reporter.ref, /^install:/);
      assert.equal(sent.reporter.email, "sam@example.com");
      const ts = h.sent[0]!.headers.get("x-starlings-timestamp")!;
      assert.equal(h.sent[0]!.headers.get("x-starlings-signature"), await sign(KEY, "intake", ts, h.sent[0]!.body));
      assert.equal((await h.store.conversation(sent.reporter.ref)).messages[0]!.state, "sent");

      assert.equal((await h.call("/v1/support/messages", post({ message_id: id, text: "Sync stopped", email: "sam@example.com" }))).status, 202);
      assert.equal(h.sent.length, 1);
    } finally { h.restore(); }
  });

  it("needs an email when signed out, a valid key, and a sender", async () => {
    const h = await harness();
    try {
      assert.equal((await h.call("/v1/support/messages", post({ message_id: crypto.randomUUID(), text: "Hi" }))).status, 400);
      assert.equal((await h.call("/v1/support/messages", post({ message_id: crypto.randomUUID(), text: "Hi", email: "a@b.co" }, "short"))).status, 400);
      const none = await h.call("/v1/support/messages", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
      assert.equal(none.status, 401);
      assert.equal(h.sent.length, 0);
    } finally { h.restore(); }
  });

  it("refuses another sender's message id instead of returning their message", async () => {
    const h = await harness();
    try {
      const id = crypto.randomUUID();
      await h.call("/v1/support/messages", post({ message_id: id, text: "Mine", email: "a@b.co" }, supportKey(0)));
      const other = await h.call("/v1/support/messages", post({ message_id: id, text: "Theirs", email: "c@d.co" }, supportKey(1)));
      assert.equal(other.status, 409);
    } finally { h.restore(); }
  });

  it("rate limits a sender per minute", async () => {
    const h = await harness();
    try {
      for (let i = 0; i < MAX_PER_MINUTE; i++) {
        assert.equal((await h.call("/v1/support/messages", post({ message_id: crypto.randomUUID(), text: `m${i}`, email: "a@b.co" }))).status, 202);
      }
      assert.equal((await h.call("/v1/support/messages", post({ message_id: crypto.randomUUID(), text: "again", email: "a@b.co" }))).status, 429);
    } finally { h.restore(); }
  });

  it("keeps a message pending when Starlings is down, and the sweep sends it later", async () => {
    let up = false;
    const h = await harness({ starlings: async () => new Response("", { status: up ? 200 : 503 }) });
    try {
      await h.call("/v1/support/messages", post({ message_id: crypto.randomUUID(), text: "Queued", email: "a@b.co" }));
      assert.equal((await h.store.pending(10)).length, 1);
      up = true;
      assert.deepEqual(await sweepSupport(h.env as never), { sent: 1, purged: 0 });
      assert.equal((await h.store.pending(10)).length, 0);
    } finally { h.restore(); }
  });
});

describe("POST /v1/support/replies", () => {
  it("stores a signed reply once, mails the sender, and shows it unread until read", async () => {
    const h = await harness();
    try {
      await h.call("/v1/support/messages", post({ message_id: crypto.randomUUID(), text: "Help", email: "a@b.co" }));
      const ref = JSON.parse(h.sent[0]!.body).reporter.ref as string;
      const reply = { message_id: "msg_1", reporter_ref: ref, text: "Try signing in again.", author: { name: "mz" } };
      assert.equal((await h.call("/v1/support/replies", await signedReply(reply))).status, 204);
      assert.equal((await h.call("/v1/support/replies", await signedReply(reply))).status, 204);
      assert.equal(h.mails.length, 1);
      assert.equal(h.mails[0]!.to, "a@b.co");
      assert.equal(h.mails[0]!.text, replyMail("Try signing in again.").text);

      const list = await h.call("/v1/support/messages", { headers: { "X-Septena-Support-Key": supportKey(0) } });
      const body = await list.json() as { messages: { direction: string }[]; unread: number };
      assert.deepEqual(body.messages.map((m) => m.direction), ["in", "out"]);
      assert.equal(body.unread, 1);
      assert.equal((await h.call("/v1/support/read", { method: "POST", headers: { "X-Septena-Support-Key": supportKey(0) } })).status, 204);
      assert.equal((await h.store.conversation(ref)).unread, 0);
    } finally { h.restore(); }
  });

  it("refuses a wrong key, the intake direction and an old timestamp", async () => {
    const h = await harness();
    try {
      const reply = { message_id: "msg_2", reporter_ref: "install:x", text: "Hi", author: { name: "mz" } };
      const wrong = Uint8Array.from(KEY, (b) => b ^ 1);
      assert.equal((await h.call("/v1/support/replies", await signedReply(reply, { key: wrong }))).status, 401);
      assert.equal((await h.call("/v1/support/replies", await signedReply(reply, { direction: "intake" }))).status, 401);
      assert.equal((await h.call("/v1/support/replies", await signedReply(reply, { at: Date.now() - 6 * 60_000 }))).status, 401);
      assert.equal((await h.store.conversation("install:x")).messages.length, 0);
    } finally { h.restore(); }
  });
});

describe("SupportStore", () => {
  it("moves a signed-out conversation to the account, and a later reply to the old ref lands there", async () => {
    const { store } = await createTestSupportStore();
    store.addInbound({ id: "a", reporterRef: "install:k", text: "Hi", email: "a@b.co", name: null, diagnostics: null, now: 1 });
    assert.equal(store.moveConversation("install:k", "user:u1"), 1);
    store.addReply({ id: "r", reporterRef: "install:k", text: "Hello", authorName: "mz", now: 2 });
    assert.deepEqual(store.conversation("user:u1").messages.map((m) => m.id), ["a", "r"]);
    assert.equal(store.conversation("install:k").messages.length, 0);
  });

  it("purges rows past retention", async () => {
    const { store } = await createTestSupportStore();
    store.addInbound({ id: "old", reporterRef: "install:k", text: "Hi", email: null, name: null, diagnostics: null, now: 1 });
    assert.equal(store.purgeBefore(2), 1);
  });
});
