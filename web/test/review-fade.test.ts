import assert from "node:assert/strict";
import test from "node:test";
import { BADGE_GROUP_IDS, destinationGroups, reviewGroupOf, SIDEBAR_DESTINATIONS } from "../src/lib/destinations.ts";
import { fadeInput, fadeSettings, isProposal, isSweepDue, sweepAnchorDay } from "../src/lib/fade.ts";
import type { TaskRow } from "../src/lib/types.ts";

const task = (fields: Partial<TaskRow> = {}): TaskRow => ({ id: "t", title: "Task", status: "open", ...fields });

test("Faded and Agent are groups of Review, not sidebar lists", () => {
  assert.deepEqual(
    destinationGroups("review").map((g) => g.id),
    ["questions", "finished", "waiting", "working", "queued", "stopped", "faded"],
  );
  assert.deepEqual([...BADGE_GROUP_IDS], ["questions", "finished"]);
  const ids = SIDEBAR_DESTINATIONS.map((d) => d.id as string);
  assert.ok(ids.includes("review"));
  for (const nested of ["faded", "agent", "inbox", "recentlyDeleted"]) assert.ok(!ids.includes(nested), nested);
});

test("a task is in one Review group", () => {
  assert.equal(reviewGroupOf(task(), { reviewGroup: "questions", agentStage: null }), "questions");
  assert.equal(reviewGroupOf(task(), { reviewGroup: "finished", agentStage: null }), "finished");
  assert.equal(reviewGroupOf(task({ fadedAt: "2026-11-20T10:00:00Z" }), null), "faded");
  // The first group that fits wins (docs/REVIEW_SPEC.md §1): a question beats Faded.
  assert.equal(reviewGroupOf(task({ fadedAt: "2026-11-20T10:00:00Z" }), { reviewGroup: "questions", agentStage: null }), "questions");
  assert.equal(reviewGroupOf(task(), null), null);
  for (const out of [{ status: "done" }, { deletedAt: "2026-11-20T10:00:00Z" }, { kind: "heading" }] as Partial<TaskRow>[]) {
    assert.equal(reviewGroupOf(task({ ...out, fadedAt: "2026-11-20T10:00:00Z" }), { reviewGroup: "finished", agentStage: null }), null);
  }
});

test("Review shows agent work in progress by its stage", () => {
  for (const stage of ["working", "queued", "stopped"] as const) {
    assert.equal(reviewGroupOf(task(), { reviewGroup: null, agentStage: stage }), stage);
  }
  for (const stage of ["done", "yourTurn", "review", null] as const) {
    assert.equal(reviewGroupOf(task(), { reviewGroup: null, agentStage: stage }), null);
  }
  assert.equal(reviewGroupOf(task(), { reviewGroup: "questions", agentStage: "yourTurn" }), "questions");
  assert.equal(reviewGroupOf(task({ fadedAt: "2026-11-20T10:00:00Z" }), { reviewGroup: null, agentStage: "queued" }), "queued");
});

test("the fade input marks an unaccepted proposal", () => {
  const clock = { now: "2026-12-09T10:00:00Z", today: "2026-12-09", utcOffsetSeconds: 0 };
  assert.equal(fadeInput(task({ source: "mcp" }), null, null, clock).isProposal, true);
  assert.equal(isProposal(task({ source: "mcp", acknowledgedAt: "2026-12-02T10:00:00Z" })), false);
  assert.equal(isProposal(task({ source: "app" })), false);
});

test("fade settings: absent or null means on", () => {
  assert.deepEqual(fadeSettings({}), { enabled: true, sweptAt: null, dismissedOn: null });
  assert.equal(fadeSettings({ tasksShowAging: null }).enabled, true);
  assert.equal(fadeSettings({ tasksShowAging: false }).enabled, false);
});

test("the weekly prompt shows on the sweep day only, until swept or dismissed", () => {
  const sunday = new Date(2026, 10, 29, 9);
  const monday = new Date(2026, 10, 30, 9);
  const faded = [new Date(2026, 10, 27, 9).toISOString()];
  const none = { sweptAt: null, dismissedOn: null };
  assert.equal(sweepAnchorDay(sunday), "2026-11-29");
  assert.equal(sweepAnchorDay(monday), "2026-11-29");
  assert.equal(isSweepDue(sunday, none, faded), true);
  assert.equal(isSweepDue(monday, none, faded), false);
  assert.equal(isSweepDue(sunday, none, []), false);
  assert.equal(isSweepDue(sunday, { ...none, dismissedOn: "2026-11-29" }, faded), false);
  assert.equal(isSweepDue(sunday, { ...none, dismissedOn: "2026-11-22" }, faded), true);
  assert.equal(isSweepDue(sunday, { ...none, sweptAt: new Date(2026, 10, 29, 8).toISOString() }, faded), false);
  assert.equal(isSweepDue(sunday, { ...none, sweptAt: new Date(2026, 10, 28, 9).toISOString() }, faded), false);
  assert.equal(isSweepDue(sunday, { ...none, sweptAt: new Date(2026, 10, 22, 9).toISOString() }, faded), true);
});
