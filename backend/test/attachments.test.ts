import { beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";
installWorkerTestHooks();

const { Hono } = await import("hono");
const { addAttachment, agentUpload, attachmentsOut, zAttachmentArgs, MAX_AGENT_FILE_BYTES } = await import("../src/shadow/attachments.ts");
const { verifyAccessToken, signAccessToken } = await import("../src/api/session.ts");

const ACTOR = "mcp:Claude Code";
const USER = "u_test";

let store: Awaited<ReturnType<typeof createTestTaskStore>>["store"];
let files: Map<string, Uint8Array>;
let env: never;
let app: InstanceType<typeof Hono>;

beforeEach(async () => {
  ({ store } = await createTestTaskStore());
  files = new Map();
  env = {
    ENTITLEMENT_ENFORCE: "false",
    SESSION_SIGNING_KEY: Buffer.alloc(32, 7).toString("base64"),
    API_PUBLIC_URL: "https://api.test",
    TASK_STORE: { idFromName: (n: string) => n, get: () => store },
    ATTACHMENTS: {
      put: async (k: string, v: Uint8Array) => { files.set(k, v); },
      delete: async (k: string) => { files.delete(k); },
    },
  } as never;
  app = new Hono();
  app.put("/v1/agent/upload", agentUpload as never);
  store.push([{ clientOpId: "op_create_task", op: "upsert", entity: "task", id: "t1", fields: { title: "T", status: "open" } }] as never, "app:test");
});

const add = (a: Record<string, unknown>) => {
  const args = zAttachmentArgs.tasks_attachment_add.parse({ task_id: "t1", filename: "a.md", content_type: "text/markdown", ...a });
  return addAttachment(env, store as never, USER, ACTOR, args) as Promise<Record<string, any>>;
};
const put = (token: string, body: string) =>
  app.request("/v1/agent/upload", { method: "PUT", body, headers: { Authorization: `Bearer ${token}`, "Content-Length": String(body.length) } }, env);

describe("tasks_attachment_add", () => {
  it("stores text and base64 from the call", async () => {
    const r = await add({ text: "héllo", content_type: "text/markdown; charset=utf-8" });
    assert.equal(r.attached, true);
    assert.equal(new TextDecoder().decode(files.get(`u/${USER}/att/${r.id}`)), "héllo");
    await add({ filename: "b.png", content_type: "image/png", base64: "AQID" });
    assert.deepEqual(attachmentsOut(store.readAttachments("t1")).map((x) => [x.filename, x.contentType, x.byteCount, x.uploaded]),
      [["a.md", "text/markdown", 6, true], ["b.png", "image/png", 3, true]]);
  });

  it("refuses bad input and unknown tasks", async () => {
    for (const filename of ["../x", "a/b", "a\\b", "..", "a‮gpj.exe"]) await assert.rejects(async () => add({ filename, text: "x" }));
    await assert.rejects(async () => add({ content_type: "nope", text: "x" }));
    await assert.rejects(async () => add({ text: "x", base64: "AQID" }));
    await assert.rejects(add({ base64: "%%%" }), /not valid base64/);
    await assert.rejects(add({ text: "" }), /empty/);
    await assert.rejects(add({ task_id: "nope", text: "x" }), /Task not found/);
    assert.equal(files.size, 0);
  });

  it("keeps nothing on a stopped task", async () => {
    store.push([{ clientOpId: "op_stop_task", op: "upsert", entity: "convo", id: "t1", fields: { stoppedAt: new Date().toISOString() } }] as never, "app:test");
    await assert.rejects(add({ text: "x" }), /stopped/);
    assert.equal(files.size, 0);
    assert.equal(store.readAttachments("t1").length, 0);
  });

  it("drops the row when the bytes cannot be stored", async () => {
    (env as any).ATTACHMENTS.put = async () => { throw new Error("r2 down"); };
    await assert.rejects(add({ text: "x" }), /r2 down/);
    assert.equal(store.readAttachments("t1").length, 0);
  });

  it("refuses a free account once limits are enforced", async () => {
    (env as any).ENTITLEMENT_ENFORCE = "true";
    await assert.rejects(add({ text: "x" }));
    await assert.rejects(add({}));
    assert.equal(files.size, 0);
  });

  it("takes one upload per token", async () => {
    const r = await add({});
    assert.equal(r.attached, false);
    assert.equal(store.readAttachments("t1").length, 0);
    const { token } = r.upload;
    assert.ok(!r.upload.url.includes(token));
    const ok = await put(token, "bytes");
    assert.equal(ok.status, 200);
    assert.equal(store.readAttachments("t1").length, 1);
    assert.equal((await put(token, "again")).status, 409);
    const { id } = (await ok.json()) as { id: string };
    store.push([{ clientOpId: "op_delete_att", op: "delete", entity: "attachment", id }] as never, "app:test");
    assert.equal((await put(token, "again")).status, 409);
  });

  it("accepts no other token kind, and its token opens nothing else", async () => {
    const { upload } = await add({});
    assert.equal(await verifyAccessToken(env, upload.token), null);
    assert.equal((await put(await signAccessToken(env, USER, "sid"), "x")).status, 401);
    assert.equal((await put(`${upload.token}x`, "x")).status, 401);
  });

  it("refuses a file over 10 MB", async () => {
    const { upload } = await add({});
    const res = await app.request("/v1/agent/upload", {
      method: "PUT", body: "x", headers: { Authorization: `Bearer ${upload.token}`, "Content-Length": String(MAX_AGENT_FILE_BYTES + 1) },
    }, env);
    assert.equal(res.status, 413);
  });
});
