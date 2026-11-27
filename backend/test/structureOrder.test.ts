import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const ACTOR = "app:ios-test";

describe("TaskStore structure ordering (position == 0 sinks to bottom)", () => {
  it("orders areas, projects, and tags with positive positions ascending and 0/null at the bottom alphabetically", async () => {
    const { store } = await createTestTaskStore();
    store.push([
      { clientOpId: "op_a1", op: "upsert", entity: "area", id: "a_zero", fields: { title: "Alpha Unset", position: 0 } },
      { clientOpId: "op_a2", op: "upsert", entity: "area", id: "a_two", fields: { title: "Work", position: 2 } },
      { clientOpId: "op_a3", op: "upsert", entity: "area", id: "a_null", fields: { title: "beta unset" } },
      { clientOpId: "op_a4", op: "upsert", entity: "area", id: "a_one", fields: { title: "Personal", position: 1 } },

      { clientOpId: "op_p1", op: "upsert", entity: "project", id: "p_zero", fields: { title: "Admin", status: "active", position: 0 } },
      { clientOpId: "op_p2", op: "upsert", entity: "project", id: "p_two", fields: { title: "Launch", status: "active", position: 2 } },
      { clientOpId: "op_p3", op: "upsert", entity: "project", id: "p_null", fields: { title: "backlog", status: "active" } },
      { clientOpId: "op_p4", op: "upsert", entity: "project", id: "p_one", fields: { title: "Q4 Plan", status: "active", position: 1 } },

      { clientOpId: "op_t1", op: "upsert", entity: "tag", id: "t_zero", fields: { name: "Alpha", position: 0 } },
      { clientOpId: "op_t2", op: "upsert", entity: "tag", id: "t_two", fields: { name: "Urgent", position: 2 } },
      { clientOpId: "op_t3", op: "upsert", entity: "tag", id: "t_null", fields: { name: "beta" } },
      { clientOpId: "op_t4", op: "upsert", entity: "tag", id: "t_one", fields: { name: "Deep", position: 1 } },
    ], ACTOR);

    assert.deepEqual(
      store.readAreas(50).map((r) => r.id),
      ["a_one", "a_two", "a_zero", "a_null"],
    );
    assert.deepEqual(
      store.readProjects("active", 50).map((r) => r.id),
      ["p_one", "p_two", "p_zero", "p_null"],
    );
    assert.deepEqual(
      store.readTags().map((r) => r.id),
      ["t_one", "t_two", "t_zero", "t_null"],
    );
  });
});
