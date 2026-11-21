import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const { nextScheduledDate, occurrenceID } = await import("../src/recurrence.ts");
const {
  awaitsReasoning,
  daysOnToday,
  inInbox,
  inTriageBand,
  isInboxMember,
  isOnToday,
  isUnfiled,
  matchesView,
} = await import("../src/tools/taskShared.ts");
import type { TaskConvo, TaskOut } from "../src/tools/taskShared.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REGISTRY_DIR = path.resolve(__dirname, "../../registry");

function readJSON(rel: string) {
  return JSON.parse(fs.readFileSync(path.join(REGISTRY_DIR, rel), "utf8"));
}

describe("Registry entities.json parity with backend/src/store/columns.ts", () => {
  it("matches every entity table, column list, requiredOnInsert, and updatable list", async (t) => {
    let ENTITIES: Record<string, { table: string; columns: Record<string, { kind: string }>; requiredOnInsert: string[]; updatable?: string[] }>;
    try {
      ({ ENTITIES } = await import("../src/store/columns.ts") as unknown as { ENTITIES: typeof ENTITIES });
    } catch (err) {
      if ((err as { code?: string })?.code === "ERR_MODULE_NOT_FOUND") {
        t.skip("backend/node_modules not installed (zod unavailable)");
        return;
      }
      throw err;
    }

    const reg = readJSON("entities.json");
    const regEntityNames = Object.keys(reg.entities).sort();
    const codeEntityNames = Object.keys(ENTITIES).sort();
    assert.deepEqual(codeEntityNames, regEntityNames);

    for (const name of regEntityNames) {
      const rSpec = reg.entities[name];
      const cSpec = ENTITIES[name];
      assert.equal(cSpec.table, rSpec.table, `${name}: table mismatch`);
      assert.deepEqual(
        Object.keys(cSpec.columns).sort(),
        Object.keys(rSpec.columns).sort(),
        `${name}: column list mismatch`,
      );
      assert.deepEqual(
        [...cSpec.requiredOnInsert].sort(),
        [...rSpec.requiredOnInsert].sort(),
        `${name}: requiredOnInsert mismatch`,
      );
      assert.deepEqual(cSpec.updatable, rSpec.updatable, `${name}: updatable mismatch`);
      for (const [col, rCol] of Object.entries(rSpec.columns) as Array<[string, { kind: string }]>) {
        assert.equal(cSpec.columns[col].kind, rCol.kind, `${name}.${col}: kind mismatch`);
      }
    }
  });
});

describe("Conformance: recurrence.json", () => {
  const fixture = readJSON("conformance/recurrence.json");

  for (const c of fixture.nextScheduledDate) {
    it(`nextScheduledDate: ${c.name}`, () => {
      const actual = nextScheduledDate({
        completedOn: c.input.completedOn,
        scheduled: c.input.scheduled,
        logicalScheduled: c.input.logicalScheduled,
        rule: {
          unit: c.input.unit,
          interval: c.input.interval,
          afterCompletion: c.input.afterCompletion,
          weekdays: c.input.weekdays ?? null,
          monthDay: c.input.monthDay ?? null,
          ordinalWeekday: c.input.ordinalWeekday ?? null,
        },
      });
      assert.equal(actual, c.expected);
    });
  }

  for (const c of fixture.occurrenceID) {
    it(`occurrenceID: ${c.sourceTaskID} | ${c.scheduled}`, () => {
      assert.equal(occurrenceID(c.sourceTaskID, c.scheduled), c.expected);
    });
  }
});

describe("Conformance: task-views.json", () => {
  const fixture = readJSON("conformance/task-views.json");
  const today: string = fixture.today;
  const nowMs = Date.parse(fixture.nowIso);

  for (const c of fixture.cases) {
    it(c.name, () => {
      const t: TaskOut = {
        ...c.task,
        createdAt: c.task.createdAt ? Date.parse(c.task.createdAt) : undefined,
        acknowledgedAt: c.task.acknowledgedAt ? Date.parse(c.task.acknowledgedAt) : undefined,
      };
      assert.equal(isUnfiled(t), c.expected.isUnfiled, "isUnfiled");
      assert.equal(isInboxMember(t), c.expected.isInboxMember, "isInboxMember");
      assert.equal(inTriageBand(t, nowMs), c.expected.inTriageBand, "inTriageBand");
      assert.equal(isOnToday(t, today), c.expected.isOnToday, "isOnToday");
      assert.equal(inInbox(t, today, nowMs), c.expected.inInbox, "inInbox");
      assert.equal(daysOnToday(t, today, nowMs), c.expected.daysOnToday, "daysOnToday");
      for (const [view, want] of Object.entries(c.expected.matchesView)) {
        assert.equal(matchesView(t, view as "today" | "inbox" | "upcoming" | "anytime", today, nowMs), want, `matchesView(${view})`);
      }
    });
  }
});

describe("Conformance: convo-derived.json (backend awaitsReasoning)", () => {
  const fixture = readJSON("conformance/convo-derived.json");

  for (const c of fixture.cases) {
    // `stoppedAt` is enforced at the TaskStore layer on the backend; skip here
    // and cover it in Swift `RegistryConformanceTests` + `TaskStore` tests.
    if (c.convo.stoppedAt) continue;
    it(c.name, () => {
      const convo: TaskConvo = {
        confirmedIntent: c.convo.confirmedIntent,
        acceptance: c.convo.acceptance,
        assignee: c.convo.assignee,
        endState: c.convo.endState,
        endStateNote: c.convo.endStateNote,
        thread: c.convo.thread ?? [],
        subtasks: [],
      };
      assert.equal(awaitsReasoning(convo), c.expected.pendingReasoning, "awaitsReasoning");
    });
  }
});
