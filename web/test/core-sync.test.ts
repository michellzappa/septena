import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {
  CoreError,
  applyDateAction,
  checkPullPage,
  checklistOccurrenceId,
  conversationState,
  deriveConversation,
  ensureCoreReady,
  fadeFill,
  getCoreVersion,
  nextScheduledDate,
  occurrenceId,
  parseRef,
  planPullRow,
  planPushResponse,
  rowOpacity,
  serverRejectionReason,
  shiftReminderForRecurrence,
  shiftReminderOnReschedule,
  shouldArmReminder,
  shouldFade,
  taskViewMembership,
  type CoreConversation,
  type CoreFadeInput,
  type PushOutcome,
} from "../src/lib/core/index.ts";
import { coalesceOutboxOp, pendingFieldsFor } from "../src/lib/store/db.ts";
import type { OutboxOp, TaskRow } from "../src/lib/types.ts";

function readFixture<T>(name: string): T {
  const p = path.resolve(process.cwd(), `../registry/conformance/${name}`);
  return JSON.parse(fs.readFileSync(p, "utf8")) as T;
}

describe("web shared WASM core conformance (ADR 0025 / C2)", () => {
  it("satisfies sync-engine.json (pullPage, pullRow, pushResponse, rejectionReason)", async () => {
    await ensureCoreReady();
    assert.match(getCoreVersion(), /^\d+\.\d+\.\d+/);

    const fixture = readFixture<{
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
      pushResponse: Array<{
        name: string;
        input: { sentIds: string[]; outcome: PushOutcome };
        expected: unknown;
      }>;
      rejectionReason: Array<{
        name: string;
        input: { status: number; body: string };
        expected: string;
      }>;
    }>("sync-engine.json");

    for (const tc of fixture.pullPage) {
      assert.deepEqual(checkPullPage(tc.input.cursor, tc.input.page, tc.input.resetsSoFar), tc.expected, tc.name);
    }
    for (const tc of fixture.pullRow) {
      if (typeof tc.expected.error === "string") {
        assert.throws(
          () => planPullRow(tc.input),
          (err: unknown) => err instanceof CoreError && err.reason === tc.expected.error,
          tc.name,
        );
      } else {
        assert.deepEqual(planPullRow(tc.input), tc.expected, tc.name);
      }
    }
    for (const tc of fixture.pushResponse) {
      assert.deepEqual(planPushResponse(tc.input.sentIds, tc.input.outcome), tc.expected, tc.name);
    }
    for (const tc of fixture.rejectionReason) {
      assert.equal(serverRejectionReason(tc.input.status, tc.input.body), tc.expected, tc.name);
    }
  });

  it("satisfies task-views.json, task-fade.json, recurrence.json, reminders.json, convo-derived.json, refs.json", async () => {
    await ensureCoreReady();

    // task-views.json
    const views = readFixture<{ today: string; nowIso: string; cases: Array<{ name: string; task: TaskRow; expected: unknown }> }>("task-views.json");
    for (const tc of views.cases) {
      assert.deepEqual(taskViewMembership(tc.task, views.today, views.nowIso), tc.expected, tc.name);
    }

    // task-fade.json
    const fade = readFixture<{
      rowOpacity: Array<{ name: string; fill: number | null; expected: number }>;
      shouldFade: Array<{ name: string; input: CoreFadeInput; expected: boolean }>;
    }>("task-fade.json");
    for (const tc of fade.rowOpacity) {
      assert.ok(Math.abs(rowOpacity(tc.fill) - tc.expected) < 1e-6, tc.name);
    }
    for (const tc of fade.shouldFade) {
      assert.equal(shouldFade(tc.input), tc.expected, tc.name);
    }
    const sampleFade = fadeFill(fade.shouldFade[0].input);
    assert.ok(sampleFade === null || (sampleFade >= 0 && sampleFade <= 1));

    // recurrence.json
    const rec = readFixture<{
      nextScheduledDate: Array<{
        name: string;
        input: {
          completedOn: string;
          scheduled?: string | null;
          logicalScheduled?: string | null;
          unit: string;
          interval: number;
          afterCompletion: boolean;
          weekdays?: number[] | null;
          monthDay?: number | null;
          ordinalWeekday?: { ordinal: number; weekday: number } | null;
        };
        expected: string | null;
      }>;
      occurrenceID: Array<{ sourceTaskID: string; scheduled: string; expected: string }>;
      checklistOccurrenceID: Array<{ newTaskID: string; index: number; sourceItemID: string; expected: string }>;
    }>("recurrence.json");
    for (const tc of rec.nextScheduledDate) {
      const { completedOn, scheduled, logicalScheduled, ...rule } = tc.input;
      assert.equal(nextScheduledDate({ completedOn, scheduled, logicalScheduled, rule }), tc.expected, tc.name);
    }
    for (const tc of rec.occurrenceID) {
      assert.equal(occurrenceId(tc.sourceTaskID, tc.scheduled), tc.expected);
    }
    for (const tc of rec.checklistOccurrenceID) {
      assert.equal(
        checklistOccurrenceId(tc.newTaskID, tc.index, tc.sourceItemID),
        tc.expected,
      );
    }

    // reminders.json
    const rem = readFixture<{
      shiftReminderForRecurrence: Array<{ name: string; input: { sourceReminderAt: string | null; sourceScheduled: string | null; nextScheduled: string | null }; expected: string | null }>;
      shiftReminderOnReschedule: Array<{ name: string; input: { reminderAt: string | null; oldScheduled: string | null; newScheduled: string | null }; expected: string | null }>;
      shouldArmReminder: Array<{ name: string; input: { status: string; isDeleted: boolean; isHeading: boolean; isUnratifiedProposal: boolean; reminderAt: string | null; reminderDismissedAt: string | null }; expected: boolean }>;
    }>("reminders.json");
    for (const tc of rem.shiftReminderForRecurrence) {
      assert.equal(shiftReminderForRecurrence(tc.input), tc.expected, tc.name);
    }
    for (const tc of rem.shiftReminderOnReschedule) {
      assert.equal(shiftReminderOnReschedule(tc.input), tc.expected, tc.name);
    }
    for (const tc of rem.shouldArmReminder) {
      assert.equal(shouldArmReminder(tc.input), tc.expected, tc.name);
    }

    // convo-derived.json
    const convo = readFixture<{
      cases: Array<{ name: string; convo: CoreConversation; expected: { stage: string; badge: string | null; pendingReasoning: boolean } }>;
      conversationState: Array<{ name: string; convo: CoreConversation; expected: unknown }>;
    }>("convo-derived.json");
    const convoNow = "2026-11-20T12:00:00Z";
    for (const tc of convo.cases) {
      const proj = deriveConversation(tc.convo, convoNow);
      assert.equal(proj.stage, tc.expected.stage, tc.name);
      assert.equal(proj.badge, tc.expected.badge, tc.name);
      assert.equal(proj.pendingReasoning, tc.expected.pendingReasoning, tc.name);
    }
    for (const tc of convo.conversationState) {
      assert.deepEqual(conversationState(tc.convo, convoNow), tc.expected, tc.name);
    }

    // refs.json (parseRef cases)
    const refs = readFixture<{ parseRef: Array<{ name: string; input: string; expected: { error?: string } & Record<string, unknown> }> }>("refs.json");
    for (const tc of refs.parseRef) {
      if (typeof tc.expected.error === "string") {
        assert.throws(
          () => parseRef(tc.input),
          (err: unknown) => err instanceof CoreError && err.reason === tc.expected.error,
          tc.name,
        );
      } else {
        assert.deepEqual(parseRef(tc.input), tc.expected, tc.name);
      }
    }
  });

  it("computes date actions through the WASM core", async () => {
    await ensureCoreReady();
    const task: TaskRow = {
      id: "t_1",
      title: "Ship web parity",
      status: "open",
      today: false,
      scheduled: null,
      area: "work",
      project: null,
    };
    const patch = applyDateAction(task, { type: "toggleToday" }, "2026-11-25", "2026-11-25T14:00:00Z");
    assert.equal(patch.today, true);
  });
});

describe("web offline outbox coalescing", () => {
  it("coalesces upserts, preserves appendTurn ops, and lets pending local fields win pull merge", async () => {
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
    outbox = coalesceOutboxOp(outbox, {
      clientOpId: "op_turn_111",
      op: "appendTurn",
      taskId: "w_offline_1",
      turn: { role: "user", step: "decide", chosen: "A", inReplyTo: 1, ts: "2026-11-25T15:00:00Z" },
      queuedAt: 2500,
    });

    assert.equal(outbox.length, 2);
    assert.equal(outbox[0].clientOpId, "op_11111111");
    assert.equal(outbox[1].op, "appendTurn");

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

    // Deleting drops earlier upserts for that entity+id, leaving appendTurn untouched.
    outbox = coalesceOutboxOp(outbox, {
      clientOpId: "op_33333333",
      op: "delete",
      entity: "task",
      id: "w_offline_1",
      queuedAt: 3000,
    });
    assert.equal(outbox.length, 2);
    assert.equal(outbox[1].op, "delete");
  });
});
