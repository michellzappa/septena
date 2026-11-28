import test from "node:test";
import assert from "node:assert/strict";
import { createTestProjectStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();
const { zPushBody } = await import("../src/store/ops.ts");
import type { Op } from "../src/store/ops.ts";

// Shared projects across real stores (docs/PROJECT_SHARING_SPEC.md): two or
// more TaskStores and the ProjectStore between them.

type Tasks = Awaited<ReturnType<typeof createTestTaskStore>>;
type Projects = Awaited<ReturnType<typeof createTestProjectStore>>;

async function world(users: string[]) {
  const tasks = new Map<string, Tasks>();
  const projects = new Map<string, Projects>();
  let reachable = true;
  /// Chance that one call between two stores fails, before or after it ran.
  let lossy: (() => number) | null = null;
  const flaky = <T extends object>(target: T): T => lossy
    ? new Proxy(target, {
      get(t, name) {
        const v = (t as Record<string | symbol, unknown>)[name];
        if (typeof v !== "function") return v;
        return async (...args: unknown[]) => {
          const roll = lossy?.() ?? 1;
          if (roll < 0.15) throw new Error("lost request");
          // Structured clone, as RPC does: no shared objects between stores.
          const out = await (v as (...a: unknown[]) => unknown).apply(t, structuredClone(args));
          if (roll < 0.3) throw new Error("lost answer");
          return structuredClone(out);
        };
      },
    })
    : target;
  const env: Record<string, unknown> = {
    API_PUBLIC_URL: "https://api.septena.app",
    ATTACHMENTS: { async delete() {} },
    TASK_STORE: {
      idFromName: (n: string) => n,
      get: (n: string) => {
        if (!reachable) throw new Error("unreachable");
        return flaky(tasks.get(n)!.store);
      },
    },
    PROJECT_STORE: {
      idFromName: (n: string) => n,
      get: (n: string) => {
        if (!reachable) throw new Error("unreachable");
        return flaky(projects.get(n)!.store);
      },
    },
  };
  for (const u of users) tasks.set(u, await createTestTaskStore(undefined, env));
  let n = 0;
  return {
    async settle() {
      for (let i = 0; i < 12; i++) {
        for (const t of tasks.values()) await t.flushWaitUntil();
        for (const p of projects.values()) await p.flushWaitUntil();
      }
    },
    setReachable(v: boolean) { reachable = v; },
    setLossy(random: (() => number) | null) { lossy = random; },
    /// The object stops: what ran in the background is gone, the data stays.
    async restart(u: string) { tasks.set(u, await createTestTaskStore(tasks.get(u)!.db, env)); },
    alarmAt: (u: string) => tasks.get(u)!.alarmAt(),
    projectAlarmAt: (id: string) => projects.get(id)!.alarmAt(),
    projectRow(id: string, entity: string, row: string) {
      const r = projects.get(id)!.db.prepare("SELECT fields, deleted FROM rows WHERE entity = ? AND id = ?").get(entity, row) as { fields: string; deleted: number };
      return { deleted: r.deleted === 1, fields: JSON.parse(r.fields) as Record<string, unknown> };
    },
    projectRows(id: string) {
      return projects.get(id)!.db.prepare("SELECT entity, id, fields FROM rows WHERE deleted = 0").all() as { entity: string; id: string; fields: string }[];
    },
    sharedId(u: string, entity: string, local: string) {
      return (tasks.get(u)!.db.prepare("SELECT sharedId FROM share_ids WHERE entity = ? AND localId = ?").get(entity, local) as { sharedId: string } | undefined)?.sharedId;
    },
    store: (u: string) => tasks.get(u)!.store,
    project: (id: string) => projects.get(id)!.store,
    async newProject(id: string) { projects.set(id, await createTestProjectStore(env)); return projects.get(id)!.store; },
    push(u: string, ...ops: Record<string, unknown>[]) {
      return tasks.get(u)!.store.push(ops.map((op) => ({ clientOpId: `op-${u}-${String(++n).padStart(6, "0")}`, ...op })) as Op[], "app:test").result.results;
    },
    row(u: string, table: string, where: string, ...args: string[]) {
      return tasks.get(u)!.db.prepare(`SELECT * FROM ${table} WHERE ${where}`).get(...args) as Record<string, unknown> | undefined;
    },
    rows(u: string, table: string) {
      return tasks.get(u)!.db.prepare(`SELECT * FROM ${table} WHERE deletedAt IS NULL`).all() as Record<string, unknown>[];
    },
  };
}

const up = (entity: string, id: string, fields: Record<string, unknown>) => ({ op: "upsert", entity, id, fields });
const del = (entity: string, id: string) => ({ op: "delete", entity, id });
const SHARE = `sp_${"a".repeat(32)}`;

async function shared() {
  const w = await world(["ann", "ben", "cat"]);
  w.push("ann",
    up("project", "home", { title: "Home", status: "active", notes: "brief", area: "life" }),
    up("task", "hd", { title: "Kitchen", status: "open", kind: "heading", project: "home" }),
    up("task", "t1", { title: "Paint", status: "open", project: "home", heading: "hd", scheduled: "2026-12-01", starred: true, deadline: "2026-12-24" }),
    up("checklistItem", "c1", { taskId: "t1", title: "Buy paint" }),
    up("task", "other", { title: "Private", status: "open" }),
  );
  // The same short ids exist in the other account.
  w.push("ben", up("project", "home", { title: "Ben home", status: "active" }), up("task", "t1", { title: "Ben task", status: "open" }));
  const p = await w.newProject(SHARE);
  const info = p.create(SHARE, "ann", "Ann");
  assert.equal(w.store("ann").startShare("ann", "home", info), "ok");
  await w.settle();
  const join = async (user: string, name: string) => {
    const made = await p.invite("ann");
    assert.ok(made.ok);
    const res = await p.join(made.token, user, name);
    assert.ok(res.ok);
    await w.settle();
    return { token: made.token, memberId: res.memberId };
  };
  return { w, p, join };
}

const replica = (w: Awaited<ReturnType<typeof world>>, u: string, title: string) => w.rows(u, "tasks").find((t) => t.title === title);

test("a member gets the shared fields, not the personal ones, and no id collides", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const t = replica(w, "ben", "Paint")!;
  assert.equal(t.deadline, "2026-12-24");
  assert.equal(t.scheduled, null);
  assert.equal(t.starred, 0);
  assert.notEqual(t.id, "t1");
  assert.equal(w.row("ben", "tasks", "id = ?", "t1")!.title, "Ben task");
  const heading = replica(w, "ben", "Kitchen")!;
  assert.equal(t.heading, heading.id);
  const project = w.row("ben", "projects", "id = ?", t.project as string)!;
  assert.equal(project.title, "Home");
  assert.equal(project.notes, "brief");
  assert.equal(project.area, null);
  assert.equal(w.rows("ben", "checklist_items")[0].taskId, t.id);
  assert.equal(replica(w, "ben", "Private"), undefined);
  const info = JSON.parse(project.share as string);
  assert.equal(info.role, "editor");
  assert.deepEqual(info.members.map((m: { name: string }) => m.name), ["Ann", "Ben"]);
  assert.equal(JSON.parse(w.row("ann", "projects", "id = ?", "home")!.share as string).members.length, 2);
});

test("edits travel both ways and personal fields stay put", async () => {
  const { w, join } = await shared();
  const { memberId } = await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.push("ben", up("task", id, { title: "Paint it", today: true, todaySetOn: "2026-11-25", assignedTo: memberId }));
  w.push("ann", up("task", "t1", { notes: "white", scheduled: "2026-12-05" }));
  await w.settle();
  const a = w.row("ann", "tasks", "id = ?", "t1")!;
  const b = w.row("ben", "tasks", "id = ?", id)!;
  assert.equal(a.title, "Paint it");
  assert.equal(a.assignedTo, memberId);
  assert.equal(a.today, 0);
  assert.equal(a.scheduled, "2026-12-05");
  assert.equal(b.notes, "white");
  assert.equal(b.scheduled, null);
  assert.equal(b.today, 1);
});

test("both write one field at once: the stores agree", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  await join("cat", "Cat");
  const ben = replica(w, "ben", "Paint")!.id as string;
  const cat = replica(w, "cat", "Paint")!.id as string;
  w.push("ann", up("task", "t1", { title: "A" }));
  w.push("ben", up("task", ben, { title: "B" }));
  w.push("cat", up("task", cat, { title: "C" }));
  await w.settle();
  const titles = [w.row("ann", "tasks", "id = ?", "t1")!.title, w.row("ben", "tasks", "id = ?", ben)!.title, w.row("cat", "tasks", "id = ?", cat)!.title];
  assert.equal(new Set(titles).size, 1);
});

test("a task and a checklist item a member adds reach everyone; completing and deleting too", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const project = replica(w, "ben", "Paint")!.project as string;
  w.push("ben", up("task", "new1", { title: "Sand", status: "open", project }), up("checklistItem", "ci", { taskId: "new1", title: "Grit" }));
  await w.settle();
  const a = replica(w, "ann", "Sand")!;
  assert.equal(a.project, "home");
  assert.ok(a.acknowledgedAt);
  const item = w.rows("ann", "checklist_items").find((c) => c.title === "Grit")!;
  assert.equal(item.taskId, a.id);
  w.push("ann", up("task", a.id as string, { status: "done", completedAt: "2026-11-25T10:00:00" }), up("checklistItem", item.id as string, { checked: true }));
  await w.settle();
  assert.equal(w.row("ben", "tasks", "id = ?", "new1")!.status, "done");
  assert.equal(w.row("ben", "checklist_items", "id = ?", "ci")!.checked, 1);
  w.push("ben", del("task", "new1"));
  await w.settle();
  assert.ok(w.row("ann", "tasks", "id = ?", a.id as string)!.deletedAt);
});

test("an agent's proposal is not shared until it is accepted", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  w.push("ann", up("task", "prop", { title: "Proposal", status: "open", project: "home", source: "mcp" }));
  await w.settle();
  assert.equal(replica(w, "ben", "Proposal"), undefined);
  w.push("ann", up("task", "prop", { acknowledgedAt: "2026-11-25T10:00:00Z" }));
  await w.settle();
  assert.ok(replica(w, "ben", "Proposal"));
});

test("a member cannot delete the project or move its tasks out; the owner can move one", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const t = replica(w, "ben", "Paint")!;
  const move = w.push("ben", up("task", t.id as string, { project: null }));
  assert.equal(move[0].reason, "shared_move_out");
  // What a client that does not know sharing sends to delete a project.
  const gone = w.push("ben", del("task", t.id as string), del("project", t.project as string));
  assert.deepEqual(gone.map((r) => r.reason), ["shared_project", "shared_project"]);
  await w.settle();
  assert.equal(w.row("ann", "tasks", "id = ?", "t1")!.deletedAt, null);
  w.push("ann", up("task", "t1", { project: null }));
  await w.settle();
  assert.equal(replica(w, "ben", "Paint"), undefined);
  assert.equal(w.row("ann", "tasks", "id = ?", "t1")!.deletedAt, null);
  assert.ok(w.rows("ann", "checklist_items").length);
});

test("invites: one use, revocable, not for a removed member to reuse", async () => {
  const { w, p, join } = await shared();
  const { token, memberId } = await join("ben", "Ben");
  assert.deepEqual(await p.join(token, "cat", "Cat"), { ok: false, reason: "invalid" });
  assert.equal(await p.preview(token), null);
  assert.equal((await p.invite("ben")).ok, false);
  const open = await p.invite("ann");
  assert.ok(open.ok);
  assert.deepEqual(await p.preview(open.token), { title: "Home", from: "Ann", members: 2 });
  assert.equal(p.revokeInvite("ben", open.invite.id), false);
  assert.equal(p.revokeInvite("ann", open.invite.id), true);
  assert.deepEqual(await p.join(open.token, "cat", "Cat"), { ok: false, reason: "invalid" });
  assert.equal(await p.endMembership("ann", memberId), true);
  await w.settle();
  assert.equal(replica(w, "ben", "Paint"), undefined);
  assert.equal(w.row("ben", "tasks", "id = ?", "t1")!.title, "Ben task");
  assert.deepEqual(await p.push("ben", []), { ok: false, reason: "not_member", keepCopy: false });
  assert.deepEqual(await p.join(token, "ben", "Ben"), { ok: false, reason: "invalid" });
  await join("ben", "Ben");
  assert.ok(replica(w, "ben", "Paint"));
});

test("a member leaves; the owner stops sharing and keeps the project", async () => {
  const { w, p, join } = await shared();
  const ben = await join("ben", "Ben");
  const cat = await join("cat", "Cat");
  assert.equal(await p.endMembership("ben", cat.memberId), false);
  assert.equal(await p.endMembership("ben", ben.memberId), true);
  await w.settle();
  assert.equal(replica(w, "ben", "Paint"), undefined);
  assert.ok(replica(w, "cat", "Paint"));
  assert.equal(await p.close("cat"), false);
  assert.equal(await p.close("ann"), true);
  await w.settle();
  assert.equal(replica(w, "cat", "Paint"), undefined);
  assert.equal(w.row("ann", "projects", "id = ?", "home")!.share, null);
  assert.equal(w.row("ann", "tasks", "id = ?", "t1")!.deletedAt, null);
  assert.equal(w.push("ann", up("task", "t1", { project: null }))[0].status, "applied");
});

test("the owner's account goes: members keep a private copy", async () => {
  const { w, p, join } = await shared();
  await join("ben", "Ben");
  await p.accountDeleted("ann");
  await w.settle();
  const t = replica(w, "ben", "Paint")!;
  assert.equal(w.row("ben", "projects", "id = ?", t.project as string)!.share, null);
  assert.equal(w.store("ben").listShares().length, 0);
});

test("a write made while the project store is unreachable arrives later", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.setReachable(false);
  w.push("ben", up("task", id, { title: "Offline edit" }));
  await w.settle();
  w.setReachable(true);
  w.push("ann", up("task", "t1", { title: "Ann edit" }));
  await w.settle();
  assert.equal(w.row("ben", "tasks", "id = ?", id)!.title, "Offline edit");
  await w.store("ben").alarm();
  await w.settle();
  assert.equal(w.row("ann", "tasks", "id = ?", "t1")!.title, "Offline edit");
});

test("a repeat: one shared first day, and one next occurrence when both complete it", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const fields = { status: "open", project: "home", recurrenceUnit: "week", recurrenceInterval: 1, recurrenceSeriesID: "ser1", scheduled: "2026-11-26" };
  w.push("ann", up("task", "bins", { title: "Bins", ...fields }));
  await w.settle();
  const ben = replica(w, "ben", "Bins")!;
  assert.equal(ben.scheduled, "2026-11-26");
  const next = { title: "Bins", ...fields, scheduled: "2026-12-03" };
  w.push("ann", up("task", "recur-aaaa", next));
  w.push("ben", up("task", "recur-bbbb", { ...next, project: ben.project }));
  await w.settle();
  for (const u of ["ann", "ben"]) assert.equal(w.rows(u, "tasks").filter((t) => t.scheduled === "2026-12-03").length, 1);
});

test("a Do is private, and ends when another member closes or deletes the task", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.push("ben", up("doSession", "do-1", { taskId: id, startedAt: new Date().toISOString() }));
  await w.settle();
  assert.equal(w.store("ben").readDoing()!.taskId, id);
  assert.equal(w.rows("ann", "do_sessions").length, 0);
  w.push("ann", up("task", "t1", { status: "done", completedAt: "2026-11-25T10:00:00" }));
  await w.settle();
  assert.equal(w.store("ben").readDoing(), null);
  assert.equal(w.store("ben").readDoSession("do-1")!.exit, "done");
  w.push("ann", up("task", "t1", { status: "open" }));
  await w.settle();
  w.push("ben", up("doSession", "do-2", { taskId: id, startedAt: new Date().toISOString() }));
  w.push("ann", del("task", "t1"));
  await w.settle();
  assert.equal(w.store("ben").readDoing(), null);
  assert.equal(w.store("ben").readDoSession("do-2"), null);
});

// ---- never lose data (spec §5a) ----

test("two members edit the same notes at once: both keep their words", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.push("ann", up("task", "t1", { notes: "white paint\nbrush" }));
  await w.settle();
  w.push("ann", up("task", "t1", { notes: "white paint\nbrush\ntape" }));
  w.push("ben", up("task", id, { notes: "blue paint\nbrush" }));
  await w.settle();
  for (const [u, local] of [["ann", "t1"], ["ben", id]]) assert.equal(w.row(u, "tasks", "id = ?", local)!.notes, "blue paint\nbrush\ntape");
  w.push("ann", up("project", "home", { notes: "brief\nann" }));
  w.push("ben", up("project", w.row("ben", "tasks", "id = ?", id)!.project as string, { notes: "brief\nben" }));
  await w.settle();
  const notes = w.row("ann", "projects", "id = ?", "home")!.notes as string;
  assert.deepEqual(notes.split("\n").sort(), ["ann", "ben", "brief"]);
  assert.equal(w.row("ben", "projects", "title = ? AND deletedAt IS NULL", "Home")!.notes, notes);
});

// #617: project notes typed in the app, sent through /v1/sync/push as the
// app sends them (the Worker's schema first, then the store).
test("project notes the app pushes save for the owner and for a member, and both read them", async () => {
  // A first random byte of 0xff: every base64url id starts with "_".
  const real = crypto.getRandomValues.bind(crypto);
  crypto.getRandomValues = (<T extends ArrayBufferView | null>(a: T): T => {
    real(a as ArrayBufferView);
    if (a && a.byteLength) new Uint8Array(a.buffer, a.byteOffset, a.byteLength)[0] = 0xff;
    return a;
  }) as typeof crypto.getRandomValues;
  try {
    const { w, join } = await shared();
    await join("ben", "Ben");
    const benProject = w.row("ben", "projects", "title = ? AND deletedAt IS NULL", "Home")!.id as string;
    let n = 0;
    const appPush = (u: string, id: string, notes: string, base: string | null) => {
      const body = { ops: [{ clientOpId: `app-${u}-${String(++n).padStart(6, "0")}`, op: "upsert", entity: "project", id, fields: { notes }, base: { notes: base } }] };
      const parsed = zPushBody.safeParse(body);
      assert.ok(parsed.success, `the Worker refuses ${u}'s push: ${parsed.success ? "" : JSON.stringify(parsed.error.issues)}`);
      return w.store(u).push(parsed.data.ops as Op[], "app:test").result.results[0];
    };
    assert.equal(appPush("ann", "home", "brief\nowner line", "brief").status, "applied");
    await w.settle();
    for (const [u, id] of [["ann", "home"], ["ben", benProject]]) assert.equal(w.row(u, "projects", "id = ?", id)!.notes, "brief\nowner line", u);
    assert.equal(appPush("ben", benProject, "brief\nowner line\nmember line", "brief\nowner line").status, "applied");
    await w.settle();
    for (const [u, id] of [["ann", "home"], ["ben", benProject]]) {
      assert.equal(w.row(u, "projects", "id = ?", id)!.notes, "brief\nowner line\nmember line", u);
    }
  } finally {
    crypto.getRandomValues = real;
  }
});

test("a device that was offline sends the notes it started from: nothing is overwritten", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.push("ann", up("task", "t1", { notes: "a\nb" }));
  await w.settle();
  w.push("ben", up("task", id, { notes: "a\nb\nben" }));
  await w.settle();
  w.push("ann", { ...up("task", "t1", { notes: "A\nb" }), base: { notes: "a\nb" } });
  await w.settle();
  for (const [u, local] of [["ann", "t1"], ["ben", id]]) assert.equal(w.row(u, "tasks", "id = ?", local)!.notes, "A\nb\nben");
  // A plain overwrite still works, and the log keeps all of what it replaced.
  const long = "x".repeat(9_000);
  w.push("ann", up("task", "t1", { notes: long }));
  await w.settle();
  w.push("ben", up("task", id, { notes: "short" }));
  await w.settle();
  const log = w.store("ann").history("task", "t1", null, 1)[0];
  assert.equal(log.diff!.notes[0], long);
});

test("a task another member deletes stays with a member who has files or a conversation on it", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.push("ben",
    up("attachment", "file1", { taskId: id, filename: "wall.jpg", contentType: "image/jpeg", byteCount: 10, createdAt: "2026-11-25T10:00:00Z", sha256: "a".repeat(64) }));
  assert.equal(w.rows("ben", "attachments").length, 1);
  w.push("ann", del("task", "t1"));
  await w.settle();
  const t = w.row("ben", "tasks", "id = ?", id)!;
  assert.equal(t.deletedAt, null);
  assert.equal(t.project, null);
  assert.equal(w.rows("ben", "attachments").length, 1);
  assert.equal(w.rows("ben", "checklist_items").length, 1);
  // It is private now: a later edit goes nowhere.
  w.push("ben", up("task", id, { title: "Mine" }));
  await w.settle();
  assert.equal(replica(w, "ann", "Mine"), undefined);
  assert.equal(w.row("ann", "tasks", "id = ?", "t1")!.title, "Paint");
});

test("a task one member deletes while another writes it: the writer keeps a private copy", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.setReachable(false);
  w.push("ben", up("task", id, { notes: "an hour of typing" }));
  await w.settle();
  w.setReachable(true);
  w.push("ann", del("task", "t1"));
  await w.settle();
  await w.store("ben").alarm();
  await w.settle();
  const t = w.row("ben", "tasks", "id = ?", id)!;
  assert.equal(t.deletedAt, null);
  assert.equal(t.notes, "an hour of typing");
});

test("leaving keeps what exists nowhere else: unsent tasks and own files", async () => {
  const { w, p, join } = await shared();
  const { memberId } = await join("ben", "Ben");
  const project = replica(w, "ben", "Paint")!.project as string;
  w.setReachable(false);
  w.push("ben", up("task", "late", { title: "Written offline", status: "open", project }));
  await w.settle();
  w.setReachable(true);
  assert.equal(await p.endMembership("ann", memberId), true);
  await w.settle();
  assert.equal(replica(w, "ben", "Paint"), undefined);
  const t = replica(w, "ben", "Written offline")!;
  assert.equal(t.project, project);
  const kept = w.row("ben", "projects", "id = ?", project)!;
  assert.equal(kept.deletedAt, null);
  assert.equal(kept.share, null);
});

test("the owner's account goes while a member's write is on its way: the copy stays", async () => {
  const { w, p, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  w.setReachable(false);
  await p.accountDeleted("ann");
  w.push("ben", up("task", id, { status: "done", completedAt: "2026-11-25T10:00:00" }));
  await w.settle();
  w.setReachable(true);
  // The write finds out before the notice arrives.
  await w.store("ben").alarm();
  await w.settle();
  assert.equal(w.row("ben", "tasks", "id = ?", id)!.deletedAt, null);
  assert.equal(w.store("ben").listShares().length, 0);
  // A project store that knows nothing about the member never deletes.
  assert.deepEqual(await p.push("stranger", []), { ok: false, reason: "not_member", keepCopy: true });
});

test("an object that stops in the middle sends the rest when its alarm fires", async () => {
  const { w, join } = await shared();
  await join("ben", "Ben");
  const id = replica(w, "ben", "Paint")!.id as string;
  const daily = w.alarmAt("ben")!;
  assert.ok(daily > Date.now() + 3_600_000);
  w.setReachable(false);
  w.push("ben", up("task", id, { title: "Stopped" }));
  await new Promise((done) => setImmediate(done));
  assert.ok(w.alarmAt("ben")! < Date.now() + 60_000);
  await w.restart("ben");
  w.setReachable(true);
  await w.store("ben").alarm();
  await w.settle();
  assert.equal(w.row("ann", "tasks", "id = ?", "t1")!.title, "Stopped");
  assert.ok(w.alarmAt("ben")! > Date.now() + 3_600_000);
  assert.equal(w.projectAlarmAt(SHARE), null);
});

test("a project that ended for everyone is removed from its store a day later", async (t) => {
  const { w, p, join } = await shared();
  await join("ben", "Ben");
  await p.close("ann");
  await w.settle();
  assert.ok(w.projectAlarmAt(SHARE)! > Date.now() + 3_600_000);
  t.mock.method(Date, "now", () => new Date().getTime() + 25 * 3_600_000);
  await p.alarm();
  assert.throws(() => w.projectRows(SHARE));
  assert.deepEqual(await p.push("ben", []), { ok: false, reason: "not_member", keepCopy: true });
});

function random(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test("random edits by three members over a bad network: every store ends equal and no word is lost", async () => {
  for (let seed = 1; seed <= 25; seed++) {
    const { w, p, join } = await shared();
    await join("ben", "Ben");
    await join("cat", "Cat");
    const users = ["ann", "ben", "cat"];
    const rnd = random(seed);
    const pick = <T>(list: T[]) => list[Math.floor(rnd() * list.length)];
    const words: { shared: string; word: string }[] = [];
    const deleted = new Set<string>();
    w.setLossy(rnd);
    for (let step = 0; step < 120; step++) {
      const u = pick(users);
      const open = w.rows(u, "tasks").filter((t) => t.kind !== "heading" && t.project && w.sharedId(u, "task", t.id as string));
      const t = pick(open);
      const roll = rnd();
      if (roll < 0.15 || !t) {
        const project = u === "ann" ? "home" : w.row(u, "projects", "title != 'Ben home' AND deletedAt IS NULL")!.id;
        w.push(u, up("task", `n-${seed}-${step}`, { title: `T${step}`, status: "open", project }));
      } else if (roll < 0.55) {
        const word = `w${seed}x${step}`;
        words.push({ shared: w.sharedId(u, "task", t.id as string)!, word });
        const lines = t.notes ? (t.notes as string).split("\n") : [];
        lines.splice(Math.floor(rnd() * (lines.length + 1)), 0, word);
        w.push(u, { ...up("task", t.id as string, { notes: lines.join("\n") }), base: { notes: (t.notes as string | null) ?? null } });
      } else if (roll < 0.7) w.push(u, up("task", t.id as string, { title: `${t.title}${u[0]}`.slice(-20) }));
      else if (roll < 0.8) w.push(u, up("task", t.id as string, { status: pick(["open", "done"]), position: step }));
      else if (roll < 0.9) w.push(u, up("checklistItem", `c-${seed}-${step}`, { taskId: t.id, title: `item ${step}` }));
      else if (roll < 0.93) {
        deleted.add(w.sharedId(u, "task", t.id as string)!);
        w.push(u, del("task", t.id as string));
      } else if (roll < 0.96) await w.settle();
      else await w.restart(u);
    }
    w.setLossy(null);
    for (let i = 0; i < 6; i++) {
      for (const u of users) await w.store(u).alarm();
      await p.alarm();
      await w.settle();
    }
    const truth = w.projectRows(SHARE);
    for (const u of users) {
      const mine = w.rows(u, "tasks").filter((t) => w.sharedId(u, "task", t.id as string));
      assert.equal(mine.length, truth.filter((r) => r.entity === "task").length, `seed ${seed} ${u} tasks`);
      for (const t of mine) {
        const fields = JSON.parse(truth.find((r) => r.entity === "task" && r.id === w.sharedId(u, "task", t.id as string))!.fields);
        for (const f of ["title", "status", "notes", "position"]) assert.equal(t[f] ?? null, fields[f] ?? null, `seed ${seed} ${u} ${f}`);
      }
      const items = w.rows(u, "checklist_items").filter((c) => w.sharedId(u, "checklistItem", c.id as string));
      const live = truth.filter((r) => r.entity === "checklistItem" && mine.some((t) => w.sharedId(u, "task", t.id as string) === JSON.parse(r.fields).taskId));
      assert.equal(items.length, live.length, `seed ${seed} ${u} items`);
    }
    for (const { shared: id, word } of words) {
      const row = truth.find((r) => r.entity === "task" && r.id === id);
      const everywhere = users.some((u) => w.rows(u, "tasks").some((t) => ((t.notes as string | null) ?? "").includes(word)));
      if (row) assert.ok((JSON.parse(row.fields).notes as string).includes(word), `seed ${seed} lost ${word}`);
      else assert.ok(everywhere || deleted.has(id), `seed ${seed} lost ${word} with its task`);
    }
  }
});

test("assignedBy and assignedAt are server-stamped, power shared waiting, and hide others' tasks from Anytime", async () => {
  const { w, join } = await shared();
  const ben = await join("ben", "Ben");
  const cat = await join("cat", "Cat");
  const annMemberId = w.store("ann").listShares()[0].memberId;

  // Create an undated shared task so it would normally sit in Anytime.
  w.push("ann", up("task", "t2", { title: "Fix sink", status: "open", project: "home" }));
  await w.settle();

  // Ann assigns it to Ben.
  w.push("ann", up("task", "t2", { assignedTo: ben.memberId }));
  await w.settle();

  const annRow = replica(w, "ann", "Fix sink")!;
  const benRow = replica(w, "ben", "Fix sink")!;
  const catRow = replica(w, "cat", "Fix sink")!;
  assert.equal(annRow.assignedTo, ben.memberId);
  assert.equal(annRow.assignedBy, annMemberId);
  assert.match(String(annRow.assignedAt), /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(benRow.assignedBy, annMemberId);
  assert.equal(benRow.assignedAt, annRow.assignedAt);
  assert.equal(catRow.assignedBy, annMemberId);

  // Editing title does not clobber assignedBy / assignedAt.
  w.push("ben", up("task", benRow.id as string, { title: "Fix kitchen sink" }));
  await w.settle();
  assert.equal(replica(w, "ann", "Fix kitchen sink")!.assignedBy, annMemberId);

  // Agent cannot close a shared task Ann is waiting on, but Ben's agent is not blocked by Ann's wait.
  const agentRefused = w.store("ann").push(
    [{ clientOpId: "op-agent-close-01", op: "upsert", entity: "task", id: "t2", fields: { status: "done" } }],
    "mcp:claude",
  ).result.results[0];
  assert.equal(agentRefused.status, "rejected");
  assert.equal(agentRefused.reason, "in_review");

  // MCP listTasks: Ann sees it in waiting, NOT in anytime; Ben sees it in anytime, NOT in waiting; Cat sees it in neither.
  const { listTasks } = await import("../src/shadow/mcp.ts");
  const annAnytime = await listTasks(w.store("ann") as never, "UTC", "anytime", 100);
  const annWaiting = await listTasks(w.store("ann") as never, "UTC", "waiting", 100);
  const benAnytime = await listTasks(w.store("ben") as never, "UTC", "anytime", 100);
  const benWaiting = await listTasks(w.store("ben") as never, "UTC", "waiting", 100);
  const catAnytime = await listTasks(w.store("cat") as never, "UTC", "anytime", 100);
  const catWaiting = await listTasks(w.store("cat") as never, "UTC", "waiting", 100);
  assert.ok(!annAnytime.tasks.some((t) => t.title === "Fix kitchen sink"));
  assert.equal(annWaiting.tasks.find((t) => t.title === "Fix kitchen sink")?.waitingOn, "Ben");
  assert.ok(benAnytime.tasks.some((t) => t.title === "Fix kitchen sink"));
  assert.ok(!benWaiting.tasks.some((t) => t.title === "Fix kitchen sink"));
  assert.ok(!catAnytime.tasks.some((t) => t.title === "Fix kitchen sink"));
  assert.ok(!catWaiting.tasks.some((t) => t.title === "Fix kitchen sink"));

  // Reassigning updates assignedBy; unassigning clears assignedBy and assignedAt.
  w.push("cat", up("task", catRow.id as string, { assignedTo: cat.memberId }));
  await w.settle();
  assert.equal(replica(w, "ann", "Fix kitchen sink")!.assignedBy, cat.memberId);

  w.push("cat", up("task", catRow.id as string, { assignedTo: null }));
  await w.settle();
  const cleared = replica(w, "ann", "Fix kitchen sink")!;
  assert.equal(cleared.assignedTo, null);
  assert.equal(cleared.assignedBy, null);
  assert.equal(cleared.assignedAt, null);
});
