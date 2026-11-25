import test from "node:test";
import assert from "node:assert/strict";
import { createTestProjectStore, createTestTaskStore } from "./taskStoreHarness.ts";
import type { Op } from "../src/store/ops.ts";

// Shared projects across real stores (docs/PROJECT_SHARING_SPEC.md): two or
// more TaskStores and the ProjectStore between them.

type Tasks = Awaited<ReturnType<typeof createTestTaskStore>>;
type Projects = Awaited<ReturnType<typeof createTestProjectStore>>;

async function world(users: string[]) {
  const tasks = new Map<string, Tasks>();
  const projects = new Map<string, Projects>();
  let reachable = true;
  const env: Record<string, unknown> = {
    API_PUBLIC_URL: "https://api.septena.app",
    ATTACHMENTS: { async delete() {} },
    TASK_STORE: {
      idFromName: (n: string) => n,
      get: (n: string) => {
        if (!reachable) throw new Error("unreachable");
        return tasks.get(n)!.store;
      },
    },
    PROJECT_STORE: {
      idFromName: (n: string) => n,
      get: (n: string) => {
        if (!reachable) throw new Error("unreachable");
        return projects.get(n)!.store;
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
  assert.deepEqual(await p.push("ben", []), { ok: false, reason: "not_member" });
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
