import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const HUMAN_ACTOR = "app:mac-test";
const AGENT_ACTOR = "mcp:claude";

let seq = 0;
const opId = (prefix = "tagop") => `${prefix}_${++seq}_${Date.now()}`;

function makeRpcStore(store: Awaited<ReturnType<typeof createTestTaskStore>>["store"]) {
  return {
    readTask: async (id: string) => store.readTask(id),
    readTasks: async (status: "open" | "done", limit: number) => store.readTasks(status, limit),
    readAreas: async (limit: number) => store.readAreas(limit),
    readProjects: async (status: "active" | "done" | "cancelled" | "all", limit: number) => store.readProjects(status, limit),
    readChecklistItems: async (taskId: string) => store.readChecklistItems(taskId),
    readChecklistItem: async (id: string) => store.readChecklistItem(id),
    readChecklistCounts: async () => store.readChecklistCounts(),
    readTaskLinks: async () => store.readTaskLinks(),
    readTaskRefs: async (id: string) => store.readTaskRefs(id),
    readTags: async () => store.readTags(),
    readTagByName: async (name: string) => store.readTagByName(name),
    readOrderTop: async () => store.readOrderTop(),
    readDoing: async () => store.readDoing(),
    readSetting: async (key: string) => store.readSetting(key),
    push: async (ops: Parameters<typeof store.push>[0], actor: string) => store.push(ops, actor),
  };
}

describe("Tags (flat tags & in-list filtering core, TG0 #158)", () => {
  it("creates, reuses case-insensitively, updates, clears, and copies tags on recurring tasks", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const ctx = { store: makeRpcStore(store) as never, timeZone: "UTC" };

    // 1. Create a task with tags (duplicates in differing case collapse into one).
    const first = (await runWriteTool(ctx, "tasks_create", {
      title: "Buy groceries",
      today: true,
      tags: ["Errands", "5min", "errands"],
      origin: "user_request",
    })) as { id: string; tags: string[] };
    assert.deepEqual(first.tags, ["Errands", "5min"]);
    assert.equal(store.readTags().length, 2);

    // 2. Second task referencing "ERRANDS" reuses existing tag ID without duplicating.
    const second = (await runWriteTool(ctx, "tasks_create", {
      title: "Post package",
      scheduled: "2026-11-22",
      recurrence: { unit: "week", interval: 1, after_completion: false },
      tags: ["ERRANDS"],
      origin: "user_request",
    })) as { id: string; tags: string[] };
    assert.deepEqual(second.tags, ["Errands"]);
    assert.equal(store.readTags().length, 2);

    const errandTag = store.readTagByName("errands");
    assert.ok(errandTag);
    const secondRow = store.readTask(second.id);
    assert.deepEqual(secondRow?.task.tags, [errandTag.id]);

    // 3. Completing a recurring task carries tags onto the next occurrence.
    const completed = (await runWriteTool(ctx, "tasks_complete", { id: second.id })) as {
      nextOccurrence?: { id: string; scheduled: string };
    };
    assert.ok(completed.nextOccurrence);
    const nextRow = store.readTask(completed.nextOccurrence.id);
    assert.deepEqual(nextRow?.task.tags, [errandTag.id]);

    // 4. Updating tags replaces them; passing [] clears them.
    await runWriteTool(ctx, "tasks_update", { id: first.id, tags: ["Waiting"] });
    assert.equal(store.readTags().length, 3);
    const waitingTag = store.readTagByName("waiting");
    assert.ok(waitingTag);
    assert.deepEqual(store.readTask(first.id)?.task.tags, [waitingTag.id]);

    await runWriteTool(ctx, "tasks_update", { id: first.id, tags: [] });
    assert.equal(store.readTask(first.id)?.task.tags, null);
  });

  it("enforces case-insensitive uniqueness on sync push, 20-tag limit, and tags=1 pull flag", async () => {
    const { store } = await createTestTaskStore();
    const { MAX_TAGS_PER_TASK } = await import("../src/store/columns.ts");

    // Create tag "Work"
    const r1 = store.push([
      { clientOpId: opId(), op: "upsert", entity: "tag", id: "tag-work", fields: { name: "Work", color: "blue", position: 0 } },
    ], HUMAN_ACTOR);
    assert.equal(r1.result.results[0].status, "applied");

    // Conflicting case-insensitive name with a different ID is rejected.
    const rDup = store.push([
      { clientOpId: opId(), op: "upsert", entity: "tag", id: "tag-work-2", fields: { name: "  work " } },
    ], HUMAN_ACTOR);
    assert.equal(rDup.result.results[0].status, "rejected");
    assert.equal(rDup.result.results[0].reason, "duplicate_tag_name");

    // Re-updating the same ID is allowed (e.g. changing capitalization or color).
    const rSame = store.push([
      { clientOpId: opId(), op: "upsert", entity: "tag", id: "tag-work", fields: { name: "WORK", color: "amber" } },
    ], HUMAN_ACTOR);
    assert.equal(rSame.result.results[0].status, "applied");
    assert.equal(store.readTagByName("work")?.name, "WORK");

    // Pull without tags=1 hides tag rows (older client compatibility).
    const pullOld = store.pull(0, 500, false, false, false);
    assert.equal(pullOld.changes.filter((c) => c.entity === "tag").length, 0);

    // Pull with tags=1 includes tag rows.
    const pullNew = store.pull(0, 500, false, false, true);
    assert.equal(pullNew.changes.filter((c) => c.entity === "tag").length, 1);

    // Task tags array rejects > MAX_TAGS_PER_TASK (20) via push validation.
    const tooMany = Array.from({ length: MAX_TAGS_PER_TASK + 1 }, (_, i) => `tag-${i}`);
    const rLimit = store.push([
      { clientOpId: opId(), op: "upsert", entity: "task", id: "t-limit", fields: { title: "Too many", status: "open", tags: tooMany } },
    ], HUMAN_ACTOR);
    assert.equal(rLimit.result.results[0].status, "rejected");

    // Soft-deleting a tag works cleanly without touching tasks.
    const rDel = store.push([
      { clientOpId: opId(), op: "delete", entity: "tag", id: "tag-work" },
    ], HUMAN_ACTOR);
    assert.equal(rDel.result.results[0].status, "applied");
    assert.equal(store.readTags().length, 0);
  });

  it("refuses agent tag update on a stopped task without leaking orphan tags", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const ctx = { store: makeRpcStore(store) as never, timeZone: "UTC" };

    store.push([
      { clientOpId: opId(), op: "upsert", entity: "task", id: "t-stop", fields: { title: "Locked", status: "open" } },
      { clientOpId: opId(), op: "upsert", entity: "convo", id: "t-stop", fields: { stoppedAt: "2026-11-21T10:00:00Z" } },
    ], HUMAN_ACTOR);

    await assert.rejects(
      () => runWriteTool(ctx, "tasks_update", { id: "t-stop", tags: ["ShouldNotExist"] }),
      /stopped/,
    );
    assert.equal(store.readTags().length, 0);
    assert.equal(store.readTask("t-stop")?.task.tags, null);
  });
});
