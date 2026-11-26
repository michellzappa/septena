import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Project notes tools on the connector: docs/PROJECT_NOTES_SPEC.md §5 (#121).

const HUMAN = "app:mac-test";
const CLIENT = "client0123456789";

async function setup() {
  const { store } = await createTestTaskStore();
  const notes = await import("../src/shadow/notes.ts");
  const agent = await import("../src/shadow/agent.ts");
  // The DO's methods are synchronous here; the tools await them either way.
  const rpc = store as unknown as Parameters<typeof notes.runNotesTool>[0]["store"];
  const ctx = { store: rpc, clientId: CLIENT, timeZone: "Europe/Amsterdam" };
  const run = (name: Parameters<typeof notes.runNotesTool>[1], args: Record<string, unknown>) =>
    notes.runNotesTool(ctx, name, args) as Promise<Record<string, any>>;
  const runAgent = (name: Parameters<typeof agent.runAgentTool>[2], args: Record<string, unknown>) =>
    agent.runAgentTool(rpc, CLIENT, name, args) as Promise<Record<string, any>>;
  let n = 0;
  const human = (entity: string, id: string, fields: Record<string, unknown>) =>
    store.push([{ clientOpId: `h_${++n}_${Date.now()}`, op: "upsert", entity: entity as never, id, fields }], HUMAN);
  return { store, notes, run, runAgent, human };
}

describe("notes tools", () => {
  it("appendLogEntry adds `## Log` once, then entries at the end", async () => {
    const { notes } = await setup();
    const one = notes.appendLogEntry("Goal: ship", "2026-11-21", "claude", "Picked option B");
    assert.equal(one, "Goal: ship\n\n## Log\n\n### 2026-11-21 · claude\n\nPicked option B\n");
    const two = notes.appendLogEntry(one, "2026-11-22", "runner", "Done");
    assert.equal(two, `${one.trimEnd()}\n\n### 2026-11-22 · runner\n\nDone\n`);
    assert.equal(notes.appendLogEntry(null, "2026-11-21", "claude", "x"), "## Log\n\n### 2026-11-21 · claude\n\nx\n");
  });

  it("creates an area and a project with notes, then reads the project", async () => {
    const { run, human } = await setup();
    const area = await run("tasks_area_create", { title: "Work", notes: "Client work" });
    assert.equal(area.noteRev, 1);
    const project = await run("tasks_project_create", { title: "Launch", area: area.id, notes: "Goal: launch", githubRepo: "acme/site" });
    human("task", "t1", { title: "Write copy", status: "open", project: project.id });
    const got = await run("tasks_project_get", { id: project.id });
    assert.equal(got.notes, "Goal: launch");
    assert.equal(got.noteRev, 1);
    assert.equal(got.status, "active");
    assert.equal(got.githubRepo, "acme/site");
    assert.deepEqual(got.area, { id: area.id, title: "Work", notes: "Client work", noteRev: 1 });
    assert.deepEqual(got.openTasks.map((t: { id: string }) => t.id), ["t1"]);
    assert.ok(got.recentChanges.length >= 1);
  });

  it("refuses a project in an unknown area", async () => {
    const { run } = await setup();
    await assert.rejects(run("tasks_project_create", { title: "X", area: "nope" }));
  });

  it("logs to notes, refuses a stale rev with the current notes, and keeps history", async () => {
    const { run, human } = await setup();
    human("project", "p1", { title: "P", status: "active", notes: "Goal" });
    const ok = await run("tasks_notes_log", { container: "project", id: "p1", baseNoteRev: 1, text: "Chose B", agent: "claude-chat" });
    assert.equal(ok.written, true);
    assert.equal(ok.noteRev, 2);
    const stale = await run("tasks_notes_log", { container: "project", id: "p1", baseNoteRev: 1, text: "Again" });
    assert.equal(stale.written, false);
    assert.equal(stale.reason, "stale");
    assert.equal(stale.current.noteRev, 2);
    assert.match(stale.current.notes, /### \d{4}-\d{2}-\d{2} · claude-chat\n\nChose B/);
    const hist = await run("tasks_notes_history", { container: "project", id: "p1", include_body: true });
    assert.deepEqual(hist.history.map((h: { rev: number }) => h.rev), [2, 1]);
    assert.match(hist.history[0].who, /^agent claude-chat@/);
    assert.equal(hist.history[1].who, "user");
    assert.equal(hist.history[1].body, "Goal");
  });

  it("refuses a brief rewrite, allows a proposal", async () => {
    const { run, store, human } = await setup();
    human("area", "a1", { title: "Home", context: "House stuff" });
    const w = await run("tasks_notes_write", { container: "area", id: "a1", baseNoteRev: 1, body: "Better", why: "tidy" });
    assert.equal(w.written, false);
    assert.equal(w.reason, "brief_is_users");
    const p = await run("tasks_notes_propose", { container: "area", id: "a1", brief: "Better", why: "tidy" });
    assert.equal(p.proposed, true);
    const row = store.readContainer("area", "a1");
    assert.equal((row?.notesProposal as { body: string }).body, "Better");
    assert.equal(store.readNote("area", "a1")?.notes, "House stuff");
  });

  it("writes an empty brief", async () => {
    const { run, human } = await setup();
    human("project", "p2", { title: "P", status: "active" });
    const w = await run("tasks_notes_write", { container: "project", id: "p2", baseNoteRev: 0, body: "Goal: x", why: "setup" });
    assert.equal(w.written, true);
    assert.equal(w.noteRev, 1);
  });

  it("returns project and area notes with a claim and on tasks_get", async () => {
    const { runAgent, human } = await setup();
    human("area", "a2", { title: "Work", context: "Area notes" });
    human("project", "p3", { title: "P", status: "active", area: "a2", notes: "Project notes" });
    human("task", "t2", { title: "Do", status: "open", project: "p3" });
    human("convo", "t2", { assignee: "claude" });
    const c = await runAgent("tasks_claim", { id: "t2", agent: "claude-chat" });
    assert.equal(c.claimed, true);
    assert.deepEqual(c.project, { id: "p3", title: "P", notes: "Project notes", noteRev: 1 });
    assert.deepEqual(c.area, { id: "a2", title: "Work", notes: "Area notes", noteRev: 1 });

    human("task", "t3", { title: "Loose", status: "open", area: "a2" });
    human("convo", "t3", { assignee: "claude" });
    const c2 = await runAgent("tasks_claim", { id: "t3", agent: "claude-chat" });
    assert.equal(c2.project, null);
    assert.equal(c2.area.id, "a2");
  });

  it("updates a project and an area, and files tasks under a heading", async () => {
    const { store, run } = await setup();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const write = (name: Parameters<typeof runWriteTool>[1], args: Record<string, unknown>) =>
      runWriteTool({ store: store as never, timeZone: "UTC", actor: "mcp:claude" }, name, args) as Promise<Record<string, any>>;
    const area = await run("tasks_area_create", { title: "Work" });
    const other = await run("tasks_area_create", { title: "Home" });
    const project = await run("tasks_project_create", { title: "Launch", area: area.id });

    await run("tasks_area_update", { id: area.id, title: "Client work", emoji: "💼" });
    assert.equal(store.readContainer("area", area.id)?.emoji, "💼");
    await run("tasks_project_update", { id: project.id, title: "Launch v2", area: other.id, status: "done" });
    let row = store.readContainer("project", project.id)!;
    assert.equal(row.title, "Launch v2");
    assert.equal(row.area, other.id);
    assert.equal(row.status, "done");
    assert.ok(row.completedAt);
    await run("tasks_project_update", { id: project.id, status: "active", area: null });
    row = store.readContainer("project", project.id)!;
    assert.equal(row.completedAt ?? null, null);
    assert.equal(row.area ?? null, null);
    await assert.rejects(run("tasks_project_update", { id: project.id }), /Nothing to update/);
    await assert.rejects(run("tasks_area_update", { id: "nope", title: "X" }), /Area not found/);

    const heading = await run("tasks_heading_create", { project: project.id, title: "Copy" });
    const made = await write("tasks_create", { title: "Write hero", heading: heading.id, origin: "user_request" });
    let task = store.readTask(made.id)!.task;
    assert.equal(task.project, project.id);
    assert.equal(task.heading, heading.id);
    const loose = await write("tasks_create", { title: "Loose", area: area.id, origin: "user_request" });
    await write("tasks_update", { id: loose.id, heading: heading.id });
    task = store.readTask(loose.id)!.task;
    assert.equal(task.project, project.id);
    assert.equal(task.area ?? null, null);
    assert.equal(task.heading, heading.id);
    await write("tasks_update", { id: loose.id, heading: null });
    assert.equal(store.readTask(loose.id)!.task.heading ?? null, null);
    await assert.rejects(write("tasks_update", { id: loose.id, heading: made.id }), /Heading not found/);
    await assert.rejects(write("tasks_update", { id: loose.id, heading: heading.id, area: area.id }), /not both/);

    const got = await run("tasks_project_get", { id: project.id });
    assert.deepEqual(got.headings, [{ id: heading.id, title: "Copy" }]);
    assert.equal(got.openTasks.find((t: { id: string }) => t.id === made.id).heading, heading.id);
  });
});
