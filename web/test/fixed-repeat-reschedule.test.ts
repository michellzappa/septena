import assert from "node:assert/strict";
import test from "node:test";
import { applyDateAction, ensureCoreReady, nextScheduledDate } from "../src/lib/core/index.ts";
import { needsFixedRepeatPrompt, planFixedSeriesRebase } from "../src/lib/fixedRepeat.ts";
import type { TaskRow } from "../src/lib/types.ts";

function fixedTask(overrides: Partial<TaskRow> = {}): TaskRow {
  return {
    id: "t1",
    title: "Weekly review",
    status: "open",
    created: "2026-11-01",
    scheduled: "2026-11-30",
    today: false,
    recurrenceUnit: "week",
    recurrenceInterval: 1,
    recurrenceAfterCompletion: false,
    recurrenceSeriesID: "series-1",
    recurrenceAnchorDate: "2026-11-30",
    ...overrides,
  };
}

test("needsFixedRepeatPrompt gates only fixed repeating tasks moving to a different day", () => {
  const fixed = fixedTask();
  assert.equal(needsFixedRepeatPrompt(fixed, "2026-12-02"), true);
  assert.equal(needsFixedRepeatPrompt(fixed, "2026-11-30"), false);
  assert.equal(needsFixedRepeatPrompt(fixed, null), false);

  assert.equal(needsFixedRepeatPrompt(fixedTask({ recurrenceAfterCompletion: true }), "2026-12-02"), false);
  assert.equal(needsFixedRepeatPrompt(fixedTask({ recurrenceUnit: null }), "2026-12-02"), false);
});

test("WASM applyDateAction and planFixedSeriesRebase honor makeException vs updateRule", async () => {
  await ensureCoreReady();
  const t1 = fixedTask({ id: "t1", scheduled: "2026-11-30", recurrenceAnchorDate: "2026-11-30" });
  const t2 = fixedTask({ id: "t2", scheduled: "2026-12-07", recurrenceAnchorDate: "2026-12-07" });
  const t3 = fixedTask({ id: "t3", scheduled: "2026-12-14", recurrenceAnchorDate: "2026-12-14" });
  const now = "2026-11-26T09:00:00Z";
  const today = "2026-11-26";

  const exPatch = applyDateAction(t1, { type: "scheduleFor", day: "2026-12-02", mode: "makeException" }, today, now);
  assert.equal(exPatch.scheduled, "2026-12-02");
  assert.equal(exPatch.recurrenceAnchorDate, undefined);

  const rulePatch = applyDateAction(t1, { type: "scheduleFor", day: "2026-12-02", mode: "updateRule" }, today, now);
  assert.equal(rulePatch.scheduled, "2026-12-02");
  assert.equal(rulePatch.recurrenceAnchorDate, "2026-12-02");

  const rebased = planFixedSeriesRebase(t1, [t1, t2, t3], "2026-12-02", nextScheduledDate);
  assert.deepEqual(
    rebased.map((u) => [u.task.id, u.nextDay]),
    [
      ["t2", "2026-12-09"],
      ["t3", "2026-12-16"],
    ],
  );
});
