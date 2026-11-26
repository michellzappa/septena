import assert from "node:assert/strict";
import test from "node:test";
import { BADGE_GROUP_IDS, reviewGroupOf } from "../src/lib/destinations.ts";
import type { TaskRow } from "../src/lib/types.ts";
import { clearWaitingFields, compareWaiting, setWaitingFields, waitingDays, waitingLabel } from "../src/lib/waiting.ts";

const task = (fields: Partial<TaskRow> = {}): TaskRow => ({ id: "t", title: "Task", status: "open", ...fields });
const anna = { waitingOn: "Anna", waitingSince: "2026-11-20" };

test("Waiting comes after the conversation group and before the agent stage", () => {
  assert.equal(reviewGroupOf(task(anna), null), "waiting");
  assert.equal(reviewGroupOf(task(anna), { reviewGroup: "questions", agentStage: null }), "questions");
  assert.equal(reviewGroupOf(task(anna), { reviewGroup: "finished", agentStage: "review" }), "finished");
  assert.equal(reviewGroupOf(task(anna), { reviewGroup: null, agentStage: "working" }), "waiting");
  assert.equal(reviewGroupOf(task({ ...anna, fadedAt: "2026-11-21T10:00:00Z" }), null), "waiting");
  assert.equal(reviewGroupOf(task({ waitingOn: "   " }), null), null);
  assert.equal(reviewGroupOf(task({ ...anna, status: "done" }), null), null);
  assert.ok(!BADGE_GROUP_IDS.has("waiting"));
});

test("Waiting sorts the oldest wait first", () => {
  const rows = [
    task({ id: "b", waitingOn: "B", waitingSince: "2026-11-22" }),
    task({ id: "none", waitingOn: "C", waitingSince: null }),
    task({ id: "a", waitingOn: "A", waitingSince: "2026-11-01" }),
  ];
  assert.deepEqual([...rows].sort(compareWaiting).map((t) => t.id), ["a", "b", "none"]);
});

test("the row label names the person and the days", () => {
  assert.equal(waitingDays(anna, "2026-11-25"), 5);
  assert.equal(waitingLabel(anna, "2026-11-25", "en"), "Waiting on Anna · 5 days");
  assert.equal(waitingLabel(anna, "2026-11-21", "en"), "Waiting on Anna · 1 day");
  assert.equal(waitingLabel(anna, "2026-11-20", "en"), "Waiting on Anna");
  assert.equal(waitingLabel(task(), "2026-11-20", "en"), null);
});

test("a new wait starts today; a renamed wait keeps its day", () => {
  assert.deepEqual(setWaitingFields(task(), "  Anna ", "2026-11-26"), { waitingOn: "Anna", waitingSince: "2026-11-26", fadedAt: null });
  assert.deepEqual(setWaitingFields(task(anna), "Ben", "2026-11-26"), { waitingOn: "Ben", waitingSince: "2026-11-20", fadedAt: null });
  assert.deepEqual(setWaitingFields(task(anna), "  ", "2026-11-26"), clearWaitingFields());
  assert.equal((setWaitingFields(task(), "x".repeat(100), "2026-11-26").waitingOn as string).length, 80);
});
