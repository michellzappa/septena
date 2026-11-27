import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

// Agent comment notification modes and per-agent overrides (#743):
//   - every_comment: pushes questions, review hand-offs, and plain agent notes
//   - needs_input (default): pushes questions and review hand-offs only
//   - daily_digest: queues updates and sends one summary push on the daily alarm
//   - off: pushes nothing

installWorkerTestHooks();

const { clearApnsJwtCache, setApnsFetchForTests } = await import("../src/api/apns.ts");

const HUMAN = "app:ios";
const CLAUDE_ACTOR = "mcp:Claude@client-claude";
const CODEX_ACTOR = "mcp:Codex@client-codex";

let opSeq = 0;
const opId = () => `anop_${++opSeq}`;

async function makeApnsEnv() {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  let b64 = "";
  for (let i = 0; i < pkcs8.length; i++) b64 += String.fromCharCode(pkcs8[i]);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(b64)}\n-----END PRIVATE KEY-----`;
  return {
    APNS_KEY: pem,
    APNS_KEY_ID: "KEY1234567",
    APNS_TEAM_ID: "TEAM123456",
    APNS_BUNDLE_ID: "com.septena.tasks",
  };
}

interface CapturedPush {
  category: string;
  title: string;
  body: string;
  raw: Record<string, unknown>;
}

function capturePushes() {
  clearApnsJwtCache();
  const sent: CapturedPush[] = [];
  setApnsFetchForTests((async (_url: string | URL | Request, init?: RequestInit) => {
    const raw = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
    const aps = (raw.aps ?? {}) as { category?: string; alert?: { title?: string; body?: string } };
    sent.push({
      category: aps.category ?? "",
      title: aps.alert?.title ?? "",
      body: aps.alert?.body ?? "",
      raw,
    });
    return new Response(null, { status: 200 });
  }) as typeof fetch);
  return {
    sent,
    restore() {
      setApnsFetchForTests(null);
      clearApnsJwtCache();
    },
  };
}

type Store = Awaited<ReturnType<typeof createTestTaskStore>>["store"];

function setupTask(store: Store, id: string, title = "Book flights") {
  store.push([
    { clientOpId: opId(), op: "upsert", entity: "task", id, fields: { title, status: "open" } },
    { clientOpId: opId(), op: "upsert", entity: "convo", id, fields: { assignee: "claude" } },
  ], HUMAN);
}

function addToken(store: Store, ch: string) {
  store.upsertPushToken({ token: ch.repeat(64), deviceId: "dev1", platform: "ios", sandbox: false });
}

function nextSeq(store: Store, id: string): number {
  return (store.readTask(id)?.turns.length ?? 0) + 1;
}

function sendNote(store: Store, id: string, note: string, actor = CLAUDE_ACTOR) {
  store.claim(id, actor.slice(4), 60_000, actor, "note");
  return store.push([{
    clientOpId: opId(),
    op: "appendTurn",
    taskId: id,
    turn: { seq: nextSeq(store, id), role: "provider", step: "work", note, ts: new Date().toISOString() },
  }], actor);
}

function sendQuestion(store: Store, id: string, question: string, actor = CLAUDE_ACTOR) {
  store.claim(id, actor.slice(4), 60_000, actor, "ask");
  return store.push([{
    clientOpId: opId(),
    op: "appendTurn",
    taskId: id,
    turn: {
      seq: nextSeq(store, id),
      role: "provider",
      step: "decide",
      question,
      options: ["Yes", "No"],
      ts: new Date().toISOString(),
    },
  }], actor);
}

function sendReviewHandoff(store: Store, id: string, endStateNote: string, actor = CLAUDE_ACTOR) {
  store.claim(id, actor.slice(4), 60_000, actor, "handoff");
  return store.push([{
    clientOpId: opId(),
    op: "upsert",
    entity: "convo",
    id,
    fields: {
      endState: "needs_verify",
      endStateAt: new Date().toISOString(),
      endStateNote,
    },
  }], actor);
}

describe("agent comment notifications (#743)", () => {
  it("default (needs_input): pushes questions and review hand-offs, skips plain notes", async () => {
    const env = await makeApnsEnv();
    const cap = capturePushes();
    try {
      const { store, flushWaitUntil } = await createTestTaskStore(undefined, env);
      addToken(store, "a");
      setupTask(store, "t1");

      sendNote(store, "t1", "Checking options.");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 0, "plain notes do not push in default needs_input mode");

      sendQuestion(store, "t1", "Window or aisle?");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 1);
      assert.equal(cap.sent[0].category, "AGENT_QUESTION");

      setupTask(store, "t2", "Draft email");
      sendReviewHandoff(store, "t2", "Ready to send.");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 2);
      assert.equal(cap.sent[1].category, "AGENT_REVIEW");
    } finally {
      cap.restore();
    }
  });

  it("every_comment: pushes plain notes, questions, and review hand-offs", async () => {
    const env = await makeApnsEnv();
    const cap = capturePushes();
    try {
      const { store, flushWaitUntil } = await createTestTaskStore(undefined, env);
      addToken(store, "b");
      store.push([{
        clientOpId: opId(),
        op: "upsert",
        entity: "setting",
        id: "agentCommentNotifications",
        fields: { value: "every_comment" },
      }], HUMAN);
      setupTask(store, "t1", "Plan offsite");

      sendNote(store, "t1", "Shortlisted 3 hotels.");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 1);
      assert.equal(cap.sent[0].category, "AGENT_COMMENT");
      assert.match(cap.sent[0].body, /Shortlisted 3 hotels/);

      sendQuestion(store, "t1", "Confirm budget?");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 2);
      assert.equal(cap.sent[1].category, "AGENT_QUESTION");
    } finally {
      cap.restore();
    }
  });

  it("off: suppresses questions, notes, and review hand-offs", async () => {
    const env = await makeApnsEnv();
    const cap = capturePushes();
    try {
      const { store, flushWaitUntil } = await createTestTaskStore(undefined, env);
      addToken(store, "c");
      store.push([{
        clientOpId: opId(),
        op: "upsert",
        entity: "setting",
        id: "agentCommentNotifications",
        fields: { value: "off" },
      }], HUMAN);
      setupTask(store, "t1");

      sendNote(store, "t1", "Working");
      sendQuestion(store, "t1", "Approve?");
      setupTask(store, "t2");
      sendReviewHandoff(store, "t2", "Done");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 0);
    } finally {
      cap.restore();
    }
  });

  it("daily_digest: queues comments and sends one summary push on the daily alarm", async () => {
    const env = await makeApnsEnv();
    const cap = capturePushes();
    try {
      const { store, flushWaitUntil } = await createTestTaskStore(undefined, env);
      addToken(store, "d");
      store.push([{
        clientOpId: opId(),
        op: "upsert",
        entity: "setting",
        id: "agentCommentNotifications",
        fields: { value: "daily_digest" },
      }], HUMAN);
      setupTask(store, "t1", "Book flights");
      setupTask(store, "t2", "Prep deck");

      sendNote(store, "t1", "Found direct flights.");
      sendQuestion(store, "t1", "Morning or evening?");
      sendReviewHandoff(store, "t2", "Slides are ready.");
      await flushWaitUntil();
      assert.equal(cap.sent.length, 0, "daily_digest sends nothing immediately");

      await store.alarm();
      assert.equal(cap.sent.length, 1, "daily alarm flushes one digest push");
      assert.equal(cap.sent[0].category, "AGENT_DIGEST");
      assert.equal(cap.sent[0].title, "3 agent updates across 2 tasks");
      assert.match(cap.sent[0].body, /Book flights: Found direct flights\./);

      // A second alarm sends nothing once the queue is drained.
      await store.alarm();
      assert.equal(cap.sent.length, 1);
    } finally {
      cap.restore();
    }
  });

  it("per-agent override wins over the global setting for that agent only", async () => {
    const env = await makeApnsEnv();
    const cap = capturePushes();
    try {
      const { store, flushWaitUntil } = await createTestTaskStore(undefined, env);
      addToken(store, "e");
      store.recordConnection("fam-claude", "client-claude", "Claude", "tasks:write", Date.now(), "Claude");
      store.recordConnection("fam-codex", "client-codex", "Codex", "tasks:write", Date.now(), "Codex");

      // Global is off, but Claude overrides to every_comment and Codex stays off.
      store.push([
        { clientOpId: opId(), op: "upsert", entity: "setting", id: "agentCommentNotifications", fields: { value: "off" } },
        { clientOpId: opId(), op: "upsert", entity: "setting", id: "agentCommentNotificationsByAgent", fields: { value: { Claude: "every_comment" } } },
      ], HUMAN);

      setupTask(store, "t1", "Claude task");
      setupTask(store, "t2", "Codex task");

      sendNote(store, "t1", "Claude update", CLAUDE_ACTOR);
      sendQuestion(store, "t2", "Codex question", CODEX_ACTOR);
      await flushWaitUntil();

      assert.equal(cap.sent.length, 1, "only Claude pushed");
      assert.equal(cap.sent[0].category, "AGENT_COMMENT");
      assert.equal(cap.sent[0].title, "Claude task");
    } finally {
      cap.restore();
    }
  });
});
