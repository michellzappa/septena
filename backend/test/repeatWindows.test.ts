import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";
installWorkerTestHooks();

const { occurrenceId } = await import("../src/core/index.ts");

describe("Missed recurrence windows", () => {
  it("keeps one chore, refreshes one habit, and keeps every owed task", async () => {
    const { store } = await createTestTaskStore();
    const first = "2026-11-06";
    const mode = { laundry: "keepOneOpen", stretch: "startFresh", timesheet: "keepEach" };
    for (const [id, missed] of Object.entries(mode)) {
      store.push([{
        clientOpId: `create_test_${id}`, op: "upsert", entity: "task", id,
        fields: {
          title: id, status: "open", scheduled: first, recurrenceUnit: "week",
          recurrenceInterval: 1, recurrenceAfterCompletion: false, recurrenceSeriesID: id,
          recurrenceAnchorDate: first, recurrenceMissed: missed, recurrenceMissedFrom: first,
          startTime: "09:00", timeZone: "Europe/Amsterdam",
        },
      }], "app:test");
    }

    store.reconcileRepeats(Date.parse("2026-11-27T07:59:00Z"));
    const currentHabit = occurrenceId("stretch", "2026-11-20");
    const nextHabit = occurrenceId("stretch", "2026-11-27");
    assert.equal(store.readTask(currentHabit)?.task.status, "open");
    assert.equal(store.readTask(nextHabit), null);

    const onTime = Date.parse("2026-11-27T08:00:00Z");
    store.reconcileRepeats(onTime);
    store.reconcileRepeats(onTime);
    assert.equal(store.readTask("stretch")?.task.status, "repeatExpired");
    assert.equal(store.readTask(currentHabit)?.task.status, "repeatExpired");
    assert.equal(store.readTask(nextHabit)?.task.status, "open");
    const open = store.readTasks("open", 100).rows;
    assert.equal(open.filter((row) => row.recurrenceSeriesID === "laundry").length, 1);
    assert.equal(open.filter((row) => row.recurrenceSeriesID === "timesheet").length, 4);
    assert.equal(open.filter((row) => row.recurrenceSeriesID === "stretch").length, 1);
    assert.equal(store.readTasks("done", 100).total, 0);

    store.push([{
      clientOpId: "late_manual_completion", op: "upsert", entity: "task", id: currentHabit,
      fields: { status: "done", completedAt: "2026-11-20T09:01:00" },
    }], "app:test");
    store.push([{
      clientOpId: "late_device_expiry", op: "upsert", entity: "task", id: currentHabit,
      fields: { status: "repeatExpired" },
    }], "app:test");
    assert.equal(store.readTask(currentHabit)?.task.status, "done");
  });
});
