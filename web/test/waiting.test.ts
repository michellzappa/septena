import assert from "node:assert/strict";
import test from "node:test";
import { BADGE_GROUP_IDS, reviewGroupOf } from "../src/lib/destinations.ts";
import type { TaskRow } from "../src/lib/types.ts";
import {
  assigneeLabel,
  clearWaitingFields,
  compareWaiting,
  isAssignedToOther,
  isWaitingTask,
  setWaitingFields,
  sharedWaitingTarget,
  waitingDays,
  waitingLabel,
} from "../src/lib/waiting.ts";
import type { ProjectShareInfo } from "../src/lib/types.ts";

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

const share: ProjectShareInfo = {
  id: "sh-1",
  role: "owner",
  me: "m-alice",
  members: [
    { id: "m-alice", name: "Alice", role: "owner" },
    { id: "m-bob", name: "Bob", role: "editor" },
    { id: "m-cara", name: "Cara", role: "editor" },
  ],
};

test("shared assignment triggers Waiting only for the assigner", () => {
  const delegatedByAlice = task({
    id: "d1",
    assignedTo: "m-bob",
    assignedBy: "m-alice",
    assignedAt: "2026-11-20",
  });
  const delegatedByCara = task({
    id: "d2",
    assignedTo: "m-bob",
    assignedBy: "m-cara",
    assignedAt: "2026-11-20",
  });
  const ownTask = task({
    id: "d3",
    assignedTo: "m-alice",
    assignedBy: "m-alice",
    assignedAt: "2026-11-20",
  });

  assert.equal(isAssignedToOther(delegatedByAlice, share), true);
  assert.equal(isAssignedToOther(delegatedByCara, share), true);
  assert.equal(isAssignedToOther(ownTask, share), false);

  assert.deepEqual(sharedWaitingTarget(delegatedByAlice, share), { name: "Bob", since: "2026-11-20" });
  assert.equal(sharedWaitingTarget(delegatedByCara, share), null);
  assert.equal(sharedWaitingTarget(ownTask, share), null);

  assert.equal(isWaitingTask(delegatedByAlice, share), true);
  assert.equal(reviewGroupOf(delegatedByAlice, null, share), "waiting");
  assert.equal(reviewGroupOf(delegatedByCara, null, share), null);
  assert.equal(waitingLabel(delegatedByAlice, "2026-11-25", "en", share), "Waiting on Bob · 5 days");
});

test("assigneeLabel shows You inside a shared project and hides own outside", () => {
  const mine = task({ assignedTo: "m-alice" });
  const bobs = task({ assignedTo: "m-bob" });
  assert.equal(assigneeLabel(mine, share, true, "en"), "You");
  assert.equal(assigneeLabel(mine, share, false, "en"), null);
  assert.equal(assigneeLabel(bobs, share, false, "en"), "Bob");
  assert.equal(assigneeLabel(bobs, share, true, "en"), "Bob");
});

test("compareWaiting orders manual and shared waits together by start day", () => {
  const sharedOlder = task({ id: "s", assignedTo: "m-bob", assignedBy: "m-alice", assignedAt: "2026-11-10" });
  const manualNewer = task({ id: "m", waitingOn: "Anna", waitingSince: "2026-11-20" });
  assert.deepEqual(
    [manualNewer, sharedOlder].sort((a, b) => compareWaiting(a, b, share, share)).map((t) => t.id),
    ["s", "m"],
  );
});
