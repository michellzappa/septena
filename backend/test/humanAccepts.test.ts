import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const HUMAN_ACTOR = "app:mac-test";
const AGENT_ACTOR = "mcp:claude";
const RUNNER_ACTOR = "mcp:runner:mz-mini@a1b2c3d4";

let seq = 0;
const opId = (prefix = "testop") => `${prefix}_${++seq}_${Date.now()}`;

describe("TaskStore human_accepts rule (#87)", () => {
  it("refuses an agent write setting status=done on a task with a Claude-assigned conversation", async () => {
    const { store } = await createTestTaskStore();

    // Human creates a task and assigns its conversation to Claude.
    store.push([
      {
        clientOpId: opId("create"),
        op: "upsert",
        entity: "task",
        id: "task-claude-1",
        fields: { title: "Ship review gate", status: "open" },
      },
      {
        clientOpId: opId("assign"),
        op: "upsert",
        entity: "convo",
        id: "task-claude-1",
        fields: { assignee: "claude" },
      },
    ], HUMAN_ACTOR);

    // Agent tries to mark the task done directly (both mcp:claude and runner actor).
    for (const actor of [AGENT_ACTOR, RUNNER_ACTOR]) {
      const { result } = store.push([
        {
          clientOpId: opId("agent_done"),
          op: "upsert",
          entity: "task",
          id: "task-claude-1",
          fields: { status: "done", completedAt: "2026-11-20T18:00:00Z" },
        },
      ], actor);

      assert.equal(result.results.length, 1);
      const r = result.results[0];
      assert.equal(r.status, "rejected");
      assert.equal(r.reason, "human_accepts");
      assert.ok(r.rule && r.rule.includes("needs_verify"), `expected rule mentioning needs_verify, got: ${r.rule}`);
    }

    // Task must still be open in the store.
    const row = store.readTask("task-claude-1");
    assert.equal(row?.task.status, "open");
    assert.equal(row?.task.completedAt, null);

    // Agent can still set needs_verify with what to check.
    const verify = store.push([
      {
        clientOpId: opId("verify"),
        op: "upsert",
        entity: "convo",
        id: "task-claude-1",
        fields: { endState: "needs_verify", endStateNote: "Check Review list shows Accept and Send back." },
      },
    ], AGENT_ACTOR);
    assert.equal(verify.result.results[0].status, "applied");
    assert.equal(store.readTask("task-claude-1")?.convo?.endState, "needs_verify");

    // Agent can still update non-done task fields (e.g. notes).
    const noteUpdate = store.push([
      {
        clientOpId: opId("notes"),
        op: "upsert",
        entity: "task",
        id: "task-claude-1",
        fields: { notes: "Opened PR #99" },
      },
    ], AGENT_ACTOR);
    assert.equal(noteUpdate.result.results[0].status, "applied");
  });

  it("returns human_accepts via tasks_complete and does not spawn a recurring occurrence", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");

    store.push([
      {
        clientOpId: opId("create"),
        op: "upsert",
        entity: "task",
        id: "task-claude-rec",
        fields: {
          title: "Weekly digest",
          status: "open",
          scheduled: "2026-11-20",
          recurrenceUnit: "week",
          recurrenceInterval: 1,
          recurrenceAfterCompletion: true,
        },
      },
      {
        clientOpId: opId("assign"),
        op: "upsert",
        entity: "convo",
        id: "task-claude-rec",
        fields: { assignee: "claude" },
      },
    ], HUMAN_ACTOR);

    const out = await runWriteTool(
      { store: store as never, timeZone: "UTC" },
      "tasks_complete",
      { id: "task-claude-rec" },
    ) as Record<string, unknown>;

    assert.equal(out.id, "task-claude-rec");
    assert.equal(out.completed, false);
    assert.equal(out.reason, "human_accepts");
    assert.equal(typeof out.rule, "string");
    assert.ok((out.rule as string).includes("needs_verify"));

    // Task stayed open and no next occurrence was created.
    const open = store.readTasks("open", 100);
    assert.equal(open.total, 1);
    assert.equal(open.rows[0].id, "task-claude-rec");
  });

  it("allows an agent to complete a plain task with no conversation", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");

    store.push([
      {
        clientOpId: opId("create"),
        op: "upsert",
        entity: "task",
        id: "task-plain-1",
        fields: { title: "Buy milk", status: "open" },
      },
    ], HUMAN_ACTOR);

    const { result } = store.push([
      {
        clientOpId: opId("agent_done"),
        op: "upsert",
        entity: "task",
        id: "task-plain-1",
        fields: { status: "done", completedAt: "2026-11-20T18:05:00Z" },
      },
    ], AGENT_ACTOR);

    assert.equal(result.results[0].status, "applied");
    assert.equal(store.readTask("task-plain-1")?.task.status, "done");

    // Also verify via tasks_complete tool on a second plain task.
    store.push([
      {
        clientOpId: opId("create"),
        op: "upsert",
        entity: "task",
        id: "task-plain-2",
        fields: { title: "Water plants", status: "open" },
      },
    ], HUMAN_ACTOR);

    const out = await runWriteTool(
      { store: store as never, timeZone: "UTC" },
      "tasks_complete",
      { id: "task-plain-2" },
    ) as Record<string, unknown>;

    assert.equal(out.status, "done");
    assert.equal(store.readTask("task-plain-2")?.task.status, "done");
  });

  it("allows an agent to complete a task whose conversation is not assigned to Claude", async () => {
    const { store } = await createTestTaskStore();

    for (const [id, assignee] of [["task-me", "me"], ["task-local", "local"], ["task-unassigned", null]] as const) {
      store.push([
        {
          clientOpId: opId("create"),
          op: "upsert",
          entity: "task",
          id,
          fields: { title: `Task ${id}`, status: "open" },
        },
        {
          clientOpId: opId("convo"),
          op: "upsert",
          entity: "convo",
          id,
          fields: { assignee },
        },
      ], HUMAN_ACTOR);

      const { result } = store.push([
        {
          clientOpId: opId("agent_done"),
          op: "upsert",
          entity: "task",
          id,
          fields: { status: "done", completedAt: "2026-11-20T18:10:00Z" },
        },
      ], AGENT_ACTOR);

      assert.equal(result.results[0].status, "applied", `expected ${id} (assignee=${assignee}) to be completable`);
      assert.equal(store.readTask(id)?.task.status, "done");
    }
  });

  it("always allows a human actor to complete a Claude-assigned task", async () => {
    const { store } = await createTestTaskStore();

    store.push([
      {
        clientOpId: opId("create"),
        op: "upsert",
        entity: "task",
        id: "task-human-accept",
        fields: { title: "Review PR", status: "open" },
      },
      {
        clientOpId: opId("assign"),
        op: "upsert",
        entity: "convo",
        id: "task-human-accept",
        fields: {
          assignee: "claude",
          endState: "needs_verify",
          endStateNote: "Verify tests pass",
        },
      },
    ], HUMAN_ACTOR);

    const { result } = store.push([
      {
        clientOpId: opId("human_done"),
        op: "upsert",
        entity: "task",
        id: "task-human-accept",
        fields: { status: "done", completedAt: "2026-11-20T18:15:00Z" },
      },
    ], HUMAN_ACTOR);

    assert.equal(result.results[0].status, "applied");
    assert.equal(store.readTask("task-human-accept")?.task.status, "done");
  });
});
