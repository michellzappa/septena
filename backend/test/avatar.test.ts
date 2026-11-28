import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestProjectStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// The editable avatar (#857): validation, the photo routes, R2 cleanup and
// who may read a member's photo.

const { api } = await import("../src/api/routes.ts");
const { signAccessToken } = await import("../src/api/session.ts");
const { AVATAR_COLOR_IDS, MAX_AVATAR_PHOTO_BYTES, defaultAvatarColor, isOneEmoji, isInitials, zAvatarPatchBody } = await import("../src/store/avatar.ts");

const ANN = `u_${"a".repeat(24)}`;
const BEN = `u_${"b".repeat(24)}`;
const CAT = `u_${"c".repeat(24)}`;
const SHARE = `sp_${"s".repeat(32)}`;
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9]);

async function harness() {
  const pending: Promise<unknown>[] = [];
  const ctx = { waitUntil(p: Promise<unknown>) { pending.push(p); }, passThroughOnException() {} } as unknown as ExecutionContext;
  const r2 = new Map<string, { body: Uint8Array; type?: string }>();
  const tasks = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>>();
  const projects = new Map<string, Awaited<ReturnType<typeof createTestProjectStore>>>();
  const { store: accounts } = await createTestAccountStore();
  const env: Record<string, unknown> = {
    API_PUBLIC_URL: "https://api.septena.app",
    ENTITLEMENT_ENFORCE: "false",
    SESSION_SIGNING_KEY: Buffer.alloc(32, 5).toString("base64"),
    ATTACHMENTS: {
      async put(key: string, body: Uint8Array, opts?: { httpMetadata?: { contentType?: string } }) { r2.set(key, { body, type: opts?.httpMetadata?.contentType }); },
      async get(key: string) {
        const o = r2.get(key);
        return o ? { body: o.body, size: o.body.byteLength, httpMetadata: { contentType: o.type } } : null;
      },
      async delete(keys: string | string[]) { for (const k of Array.isArray(keys) ? keys : [keys]) r2.delete(k); },
      async list() { return { objects: [], truncated: false }; },
    },
    TASK_STORE: { idFromName: (n: string) => n, get: (n: string) => tasks.get(n)!.store },
    PROJECT_STORE: { idFromName: (n: string) => n, get: (n: string) => projects.get(n)!.store },
    ACCOUNT_STORE: { idFromName: (n: string) => n, get: () => accounts },
  };
  for (const u of [ANN, BEN, CAT]) tasks.set(u, await createTestTaskStore(undefined, env));
  const settle = async () => {
    for (let i = 0; i < 8; i++) {
      await Promise.all(pending.splice(0));
      for (const t of tasks.values()) await t.flushWaitUntil();
      for (const p of projects.values()) await p.flushWaitUntil();
    }
  };
  const auth = async (u: string) => {
    ensureSession(tasks.get(u)!.store, `sid-${u}`);
    return `Bearer ${await signAccessToken(env as never, u, `sid-${u}`)}`;
  };
  const call = async (u: string, method: string, path: string, body?: BodyInit, type?: string) => {
    const headers: Record<string, string> = { Authorization: await auth(u) };
    if (type) headers["Content-Type"] = type;
    const res = await api.fetch(new Request(`https://api.septena.app${path}`, { method, body, headers }), env, ctx);
    await settle();
    return res;
  };
  return { env, r2, tasks, projects, accounts, call, settle };
}

describe("avatar validation", () => {
  it("takes one emoji grapheme and nothing else", () => {
    for (const e of ["🙂", "👍🏽", "👩‍💻", "🇧🇷", "1️⃣", "❤️"]) assert.ok(isOneEmoji(e), e);
    for (const e of ["", "a", "🙂🙂", "🙂a", "AB", "<script>"]) assert.ok(!isOneEmoji(e), e);
  });

  it("takes one to three letters as initials", () => {
    for (const s of ["M", "MZ", "abc", "ÉÖ", "李", "J2"]) assert.ok(isInitials(s), s);
    for (const s of ["", "ABCD", "M Z", "M.", "🙂"]) assert.ok(!isInitials(s), s);
  });

  it("takes only palette colors and refuses a photo by JSON", () => {
    assert.ok(zAvatarPatchBody.safeParse({ kind: "initials", color: AVATAR_COLOR_IDS[0] }).success);
    assert.ok(!zAvatarPatchBody.safeParse({ kind: "initials", color: "#ff0000" }).success);
    assert.ok(!zAvatarPatchBody.safeParse({ kind: "photo" }).success);
    assert.ok(!zAvatarPatchBody.safeParse({ kind: "emoji" }).success);
    assert.ok(!zAvatarPatchBody.safeParse({ kind: "emoji", emoji: "🙂", extra: 1 }).success);
  });

  it("derives a stable palette color from the user id", () => {
    assert.equal(defaultAvatarColor(ANN), defaultAvatarColor(ANN));
    assert.ok(AVATAR_COLOR_IDS.includes(defaultAvatarColor(ANN)));
    const spread = new Set(Array.from({ length: 50 }, (_, i) => defaultAvatarColor(`u_${String(i).padStart(24, "x")}`)));
    assert.ok(spread.size > 3);
  });
});

describe("avatar routes", () => {
  it("starts as initials on the derived color", async () => {
    const h = await harness();
    const res = await h.call(ANN, "GET", "/account");
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { userId: ANN, avatar: { kind: "initials", color: defaultAvatarColor(ANN), updatedAt: 0 } });
  });

  it("saves initials and an emoji, and refuses bad input", async () => {
    const h = await harness();
    const color = AVATAR_COLOR_IDS[2];
    let res = await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "initials", initials: "MZ", color }), "application/json");
    assert.equal(res.status, 200);
    assert.deepEqual(((await res.json()) as any).avatar, { kind: "initials", color, initials: "MZ", updatedAt: ((await (await h.call(ANN, "GET", "/account")).json()) as any).avatar.updatedAt });
    res = await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "emoji", emoji: "🦊" }), "application/json");
    const a = ((await res.json()) as any).avatar;
    assert.equal(a.kind, "emoji");
    assert.equal(a.emoji, "🦊");
    assert.equal(a.color, color);
    assert.equal(a.initials, "MZ");
    for (const bad of [{ kind: "emoji", emoji: "🦊🦊" }, { kind: "initials", color: "neon" }, { kind: "initials", initials: "ABCD" }]) {
      assert.equal((await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify(bad), "application/json")).status, 400);
    }
  });

  it("keeps a newer avatar over an offline edit that arrives late", async () => {
    const h = await harness();
    await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "emoji", emoji: "🦊", updatedAt: Date.now() }), "application/json");
    const res = await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "emoji", emoji: "🐢", updatedAt: Date.now() - 60_000 }), "application/json");
    const body = (await res.json()) as any;
    assert.equal(body.applied, false);
    assert.equal(body.avatar.emoji, "🦊");
  });

  it("stores a photo under the account, replaces it and deletes the old object", async () => {
    const h = await harness();
    let res = await h.call(ANN, "PUT", "/account/avatar", JPEG, "image/jpeg");
    assert.equal(res.status, 200);
    const first = ((await res.json()) as any).avatar;
    assert.equal(first.kind, "photo");
    assert.ok(first.photoId);
    assert.equal(first.photoKey, undefined);
    assert.deepEqual([...h.r2.keys()], [`u/${ANN}/avatar/${first.photoId}`]);

    res = await h.call(ANN, "GET", "/account/avatar/photo");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Content-Type"), "image/jpeg");
    assert.deepEqual(new Uint8Array(await res.arrayBuffer()), JPEG);

    const second = ((await (await h.call(ANN, "PUT", "/account/avatar", PNG, "image/png")).json()) as any).avatar;
    assert.notEqual(second.photoId, first.photoId);
    assert.deepEqual([...h.r2.keys()], [`u/${ANN}/avatar/${second.photoId}`]);

    // An emoji lets the photo go too.
    await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "emoji", emoji: "🦊" }), "application/json");
    assert.equal(h.r2.size, 0);
    assert.equal((await h.call(ANN, "GET", "/account/avatar/photo")).status, 404);
  });

  it("DELETE goes back to initials and deletes the photo", async () => {
    const h = await harness();
    const color = AVATAR_COLOR_IDS[4];
    await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "initials", color }), "application/json");
    await h.call(ANN, "PUT", "/account/avatar", JPEG, "image/jpeg");
    assert.equal(h.r2.size, 1);
    const res = await h.call(ANN, "DELETE", "/account/avatar");
    const a = ((await res.json()) as any).avatar;
    assert.equal(a.kind, "initials");
    assert.equal(a.color, color);
    assert.equal(h.r2.size, 0);
  });

  it("refuses a photo over 5 MB, an empty body and other file types", async () => {
    const h = await harness();
    const big = new Uint8Array(MAX_AVATAR_PHOTO_BYTES + 1);
    big.set(JPEG);
    assert.equal((await h.call(ANN, "PUT", "/account/avatar", big, "image/jpeg")).status, 413);
    assert.equal((await h.call(ANN, "PUT", "/account/avatar", new Uint8Array(), "image/jpeg")).status, 400);
    assert.equal((await h.call(ANN, "PUT", "/account/avatar", new TextEncoder().encode("GIF89a....."), "image/gif")).status, 415);
    assert.equal(h.r2.size, 0);
    const ok = new Uint8Array(MAX_AVATAR_PHOTO_BYTES);
    ok.set(JPEG);
    assert.equal((await h.call(ANN, "PUT", "/account/avatar", ok, "image/jpeg")).status, 200);
  });

  it("needs a signed-in account", async () => {
    const h = await harness();
    const res = await api.fetch(new Request("https://api.septena.app/account/avatar", { method: "PUT", body: JPEG }), h.env, { waitUntil() {}, passThroughOnException() {} } as never);
    assert.equal(res.status, 401);
  });
});

describe("avatars in shared projects", () => {
  async function sharedWithBen() {
    const h = await harness();
    h.tasks.get(ANN)!.store.push([{ clientOpId: "op-ann-000001", op: "upsert", entity: "project", id: "home", fields: { title: "Home", status: "active" } }] as never, "app:test");
    h.projects.set(SHARE, await createTestProjectStore(h.env));
    const p = h.projects.get(SHARE)!.store;
    const info = p.create(SHARE, ANN, "Ann");
    assert.equal(h.tasks.get(ANN)!.store.startShare(ANN, "home", info), "ok");
    const made = await p.invite(ANN);
    assert.ok(made.ok);
    const joined = await p.join(made.token, BEN, "Ben");
    assert.ok(joined.ok);
    await h.settle();
    const annMember = info.me;
    return { h, p, annMember, benMember: joined.memberId };
  }

  const shareInfo = (h: Awaited<ReturnType<typeof harness>>, u: string) => {
    const project = h.tasks.get(u)!.db.prepare("SELECT share FROM projects WHERE share IS NOT NULL").get() as { share: string };
    return JSON.parse(project.share) as { members: { id: string; name: string; avatar?: { kind: string; emoji?: string; photoId?: string } }[] };
  };

  it("a new avatar reaches every member through the project", async () => {
    const { h, annMember } = await sharedWithBen();
    await h.call(ANN, "PATCH", "/account/avatar", JSON.stringify({ kind: "emoji", emoji: "🦊" }), "application/json");
    const ann = shareInfo(h, BEN).members.find((m) => m.id === annMember)!;
    assert.equal(ann.avatar?.kind, "emoji");
    assert.equal(ann.avatar?.emoji, "🦊");
  });

  it("only members read a member's photo", async () => {
    const { h, annMember } = await sharedWithBen();
    await h.call(ANN, "PUT", "/account/avatar", JPEG, "image/jpeg");
    const photoId = shareInfo(h, BEN).members.find((m) => m.id === annMember)!.avatar!.photoId;
    assert.ok(photoId);
    const path = `/shares/${SHARE}/members/${annMember}/avatar`;
    const ben = await h.call(BEN, "GET", path);
    assert.equal(ben.status, 200);
    assert.deepEqual(new Uint8Array(await ben.arrayBuffer()), JPEG);
    assert.equal((await h.call(CAT, "GET", path)).status, 404);
    assert.equal((await h.call(BEN, "GET", `/shares/${SHARE}/members/m_${"x".repeat(16)}/avatar`)).status, 404);
  });

  it("a member who leaves cannot read the photo any more", async () => {
    const { h, p, annMember, benMember } = await sharedWithBen();
    await h.call(ANN, "PUT", "/account/avatar", JPEG, "image/jpeg");
    assert.ok(await p.endMembership(BEN, benMember));
    await h.settle();
    assert.equal((await h.call(BEN, "GET", `/shares/${SHARE}/members/${annMember}/avatar`)).status, 404);
  });
});
