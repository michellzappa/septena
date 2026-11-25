import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {
  CoreError,
  applyDateAction,
  checkPullPage,
  ensureCoreReady,
  getCoreVersion,
  planPullRow,
  taskViewMembership,
} from "../src/lib/core/index.ts";
import { coalesceOutboxOp, pendingFieldsFor } from "../src/lib/store/db.ts";
import type { OutboxOp, TaskRow } from "../src/lib/types.ts";

describe("web shared WASM core (C2 / WB1)", () => {
  it("loads the pinned WASM core and satisfies sync-engine and task-views conformance vectors", async () => {
    await ensureCoreReady();
    assert.match(getCoreVersion(), /^\d+\.\d+\.\d+/);

    const syncFixturePath = path.resolve(process.cwd(), "../registry/conformance/sync-engine.json");
    const syncFixture = JSON.parse(fs.readFileSync(syncFixturePath, "utf8")) as {
      pullPage: Array<{
        name: string;
        input: { cursor: number; page: { resetRequired: boolean; nextSince: number; hasMore: boolean }; resetsSoFar: number };
        expected: unknown;
      }>;
      pullRow: Array<{
        name: string;
        input: { entity: string; row: Record<string, unknown>; current: Record<string, unknown> | null; pendingFields: string[]; pendingDelete: boolean };
        expected: { error?: string } & Record<string, unknown>;
      }>;
    };

    for (const tc of syncFixture.pullPage) {
      const actual = checkPullPage(tc.input.cursor, tc.input.page, tc.input.resetsSoFar);
      assert.deepEqual(actual, tc.expected, `pullPage failed: ${tc.name}`);
    }

    for (const tc of syncFixture.pullRow) {
      if (typeof tc.expected.error === "string") {
        assert.throws(
          () => planPullRow(tc.input),
          (err: unknown) => err instanceof CoreError && err.reason === tc.expected.error,
          `pullRow expected error failed: ${tc.name}`,
        );
      } else {
        const actual = planPullRow(tc.input);
        assert.deepEqual(actual, tc.expected, `pullRow failed: ${tc.name}`);
      }
    }

    const viewsFixturePath = path.resolve(process.cwd(), "../registry/conformance/task-views.json");
    const viewsFixture = JSON.parse(fs.readFileSync(viewsFixturePath, "utf8")) as {
      today: string;
      nowIso: string;
      cases: Array<{ name: string; task: TaskRow; expected: unknown }>;
    };

    for (const tc of viewsFixture.cases) {
      const actual = taskViewMembership(tc.task, viewsFixture.today, viewsFixture.nowIso);
      assert.deepEqual(actual, tc.expected, `taskViewMembership failed: ${tc.name}`);
    }
  });

  it("computes list membership and date actions through the WASM core", async () => {
    await ensureCoreReady();
    const task: TaskRow = {
      id: "t_1",
      title: "Ship web spike",
      status: "open",
      today: false,
      scheduled: null,
      area: "work",
      project: null,
    };

    const m1 = taskViewMembership(task, "2026-11-25", "2026-11-25T14:00:00Z");
    assert.equal(m1.isOnToday, false);
    assert.equal(m1.matchesView.today, false);
    assert.equal(m1.matchesView.anytime, true);

    const patch = applyDateAction(task, { type: "toggleToday" }, "2026-11-25", "2026-11-25T14:00:00Z");
    assert.equal(patch.today, true);

    const m2 = taskViewMembership({ ...task, ...patch }, "2026-11-25", "2026-11-25T14:00:00Z");
    assert.equal(m2.isOnToday, true);
    assert.equal(m2.matchesView.today, true);
  });
});

describe("web offline outbox coalescing", () => {
  it("coalesces multiple offline edits to one task and preserves pending fields during pull merge", async () => {
    await ensureCoreReady();
    let outbox: OutboxOp[] = [];

    outbox = coalesceOutboxOp(outbox, {
      clientOpId: "op_11111111",
      op: "upsert",
      entity: "task",
      id: "w_offline_1",
      fields: { title: "Draft spec", status: "open", today: true },
      queuedAt: 1000,
    });
    outbox = coalesceOutboxOp(outbox, {
      clientOpId: "op_22222222",
      op: "upsert",
      entity: "task",
      id: "w_offline_1",
      fields: { title: "Draft web spec", notes: "Added offline" },
      queuedAt: 2000,
    });

    assert.equal(outbox.length, 1);
    assert.equal(outbox[0].clientOpId, "op_11111111");
    assert.equal(outbox[0].op, "upsert");
    if (outbox[0].op === "upsert") {
      assert.deepEqual(outbox[0].fields, {
        title: "Draft web spec",
        status: "open",
        today: true,
        notes: "Added offline",
      });
    }

    const { pendingFields, pendingDelete } = pendingFieldsFor(outbox, "task", "w_offline_1");
    assert.equal(pendingDelete, false);
    assert.ok(pendingFields.includes("title"));

    const merged = planPullRow({
      entity: "task",
      row: { id: "w_offline_1", rev: 5, title: "Old server title", deadline: "2026-12-01" },
      current: { title: "Draft web spec", status: "open", today: true, notes: "Added offline" },
      pendingFields,
      pendingDelete,
    });
    assert.equal(merged.plan, "merge");
    if (merged.plan === "merge") {
      assert.equal(merged.fields.title, "Draft web spec");
      assert.equal(merged.fields.deadline, "2026-12-01");
    }

    outbox = coalesceOutboxOp(outbox, {
      clientOpId: "op_33333333",
      op: "delete",
      entity: "task",
      id: "w_offline_1",
      queuedAt: 3000,
    });
    assert.equal(outbox.length, 1);
    assert.equal(outbox[0].op, "delete");
  });
});
