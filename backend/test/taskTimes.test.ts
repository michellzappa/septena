import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const HUMAN_ACTOR = "app:mac-test";
let seq = 0;
const opId = (prefix = "timeop") => `${prefix}_${++seq}_${Date.now()}`;

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

describe("Optional task startTime & durationMinutes (IC0 #165)", () => {
  it("creates, updates, clears, and carries startTime/durationMinutes/timeZone on recurring tasks", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const ctx = { store: makeRpcStore(store) as never, timeZone: "UTC" };

    const created = (await runWriteTool(ctx, "tasks_create", {
      title: "Dentist appointment",
      scheduled: "2026-11-25",
      start_time: "14:00",
      duration_minutes: 60,
      time_zone: "Europe/Berlin",
      recurrence: { unit: "month", interval: 6, after_completion: false },
      origin: "user_request",
    })) as { id: string; start_time: string; duration_minutes: number; time_zone: string };

    assert.equal(created.start_time, "14:00");
    assert.equal(created.duration_minutes, 60);
    assert.equal(created.time_zone, "Europe/Berlin");

    const stored = store.readTask(created.id);
    assert.equal(stored?.task.startTime, "14:00");
    assert.equal(stored?.task.durationMinutes, 60);
    assert.equal(stored?.task.timeZone, "Europe/Berlin");

    // Completing recurring task copies startTime/durationMinutes/timeZone onto next occurrence.
    const completed = (await runWriteTool(ctx, "tasks_complete", { id: created.id })) as {
      nextOccurrence?: { id: string; scheduled: string };
    };
    assert.ok(completed.nextOccurrence);
    const next = store.readTask(completed.nextOccurrence.id);
    assert.equal(next?.task.startTime, "14:00");
    assert.equal(next?.task.durationMinutes, 60);
    assert.equal(next?.task.timeZone, "Europe/Berlin");

    // Clearing start_time clears durationMinutes & timeZone too.
    await runWriteTool(ctx, "tasks_update", { id: next!.task.id as string, start_time: null });
    const cleared = store.readTask(next!.task.id as string);
    assert.equal(cleared?.task.startTime, null);
    assert.equal(cleared?.task.durationMinutes, null);
    assert.equal(cleared?.task.timeZone, null);
  });

  it("validates startTime format, durationMinutes bounds, and IANA timeZone on push schema", async () => {
    const { zPushBody } = await import("../src/store/ops.ts");
    const valid = zPushBody.safeParse({
      ops: [{
        clientOpId: opId(),
        op: "upsert",
        entity: "task",
        id: "t-valid",
        fields: { title: "Call", status: "open", startTime: "09:30", durationMinutes: 30, timeZone: "America/New_York" },
      }],
    });
    assert.equal(valid.success, true);

    const badTime = zPushBody.safeParse({
      ops: [{
        clientOpId: opId(),
        op: "upsert",
        entity: "task",
        id: "t-badtime",
        fields: { title: "Call", status: "open", startTime: "25:00" },
      }],
    });
    assert.equal(badTime.success, false);

    const badDuration = zPushBody.safeParse({
      ops: [{
        clientOpId: opId(),
        op: "upsert",
        entity: "task",
        id: "t-baddur",
        fields: { title: "Call", status: "open", startTime: "09:30", durationMinutes: 2 },
      }],
    });
    assert.equal(badDuration.success, false);

    const badTz = zPushBody.safeParse({
      ops: [{
        clientOpId: opId(),
        op: "upsert",
        entity: "task",
        id: "t-badtz",
        fields: { title: "Call", status: "open", startTime: "09:30", timeZone: "Mars/Olympus_Mons" },
      }],
    });
    assert.equal(badTz.success, false);
  });
});
