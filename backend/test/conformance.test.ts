import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const { nextScheduledDate, occurrenceID } = await import("../src/recurrence.ts");
const {
  shiftReminderForRecurrence,
  shiftReminderOnReschedule,
  shouldArmReminder,
} = await import("../src/reminders.ts");
const {
  awaitsReasoning,
  daysOnToday,
  inInbox,
  inTriageBand,
  isInboxMember,
  isOnToday,
  isUnfiled,
  matchesView,
  normalizeView,
} = await import("../src/tools/taskShared.ts");
const {
  ACTIONS_CATALOG,
  CAPABILITIES,
  DESIGN_TOKENS,
  DESTINATIONS,
  ICONS,
  SETTINGS_REGISTRY,
  SURFACES_CATALOG,
  SYNCED_SETTING_KEYS,
  VIEW_ALIASES,
} = await import("../src/generated/registries.ts");
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

  it("matches backend SETTING_VALUES keys 1:1 with SYNCED_SETTING_KEYS from settings.json", async (t) => {
    let SETTING_VALUES: Record<string, unknown>;
    try {
      ({ SETTING_VALUES } = await import("../src/store/columns.ts") as unknown as { SETTING_VALUES: typeof SETTING_VALUES });
    } catch (err) {
      if ((err as { code?: string })?.code === "ERR_MODULE_NOT_FOUND") {
        t.skip("backend/node_modules not installed (zod unavailable)");
        return;
      }
      throw err;
    }

    assert.deepEqual(
      Object.keys(SETTING_VALUES).sort(),
      [...SYNCED_SETTING_KEYS].sort(),
      "backend SETTING_VALUES keys drifted from registry/settings.json SYNCED_SETTING_KEYS",
    );
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

describe("Conformance: reminders.json", () => {
  const fixture = readJSON("conformance/reminders.json");

  for (const c of fixture.shiftReminderForRecurrence) {
    it(`shiftReminderForRecurrence: ${c.name}`, () => {
      assert.equal(shiftReminderForRecurrence(c.input), c.expected);
    });
  }

  for (const c of fixture.shiftReminderOnReschedule) {
    it(`shiftReminderOnReschedule: ${c.name}`, () => {
      assert.equal(shiftReminderOnReschedule(c.input), c.expected);
    });
  }

  for (const c of fixture.shouldArmReminder) {
    it(`shouldArmReminder: ${c.name}`, () => {
      assert.equal(shouldArmReminder(c.input), c.expected);
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

describe("Registry cross-cutting contracts (R1–R4)", () => {
  it("normalizeView honors every alias in destinations.json", () => {
    for (const [alias, canonical] of Object.entries(VIEW_ALIASES)) {
      assert.equal(normalizeView(alias), canonical, `alias ${alias} -> ${canonical}`);
    }
    assert.equal(normalizeView(undefined), "today");
  });

  it("synced settings, destinations, actions, icons, tokens, surfaces, and capabilities are non-empty and consistent", () => {
    assert.ok(SYNCED_SETTING_KEYS.includes("welcomeName"));
    assert.ok(SYNCED_SETTING_KEYS.includes("agentsPaused"));
    assert.equal(SETTINGS_REGISTRY.version, 2);
    assert.equal(SETTINGS_REGISTRY.desktopTabs.length, 6);
    assert.ok(SETTINGS_REGISTRY.pages.some((p: { id: string; depth: number }) => p.id === "advanced" && p.depth === 2));
    assert.ok(DESTINATIONS.length >= 8);
    assert.ok(Object.keys(ICONS).length >= 40);
    assert.equal(DESIGN_TOKENS.accentPalette.length, 16);
    assert.equal(DESIGN_TOKENS.textScale.steps.length, 5);
    assert.equal(SURFACES_CATALOG.notices.maxConcurrentExplainers, 1);
    assert.equal(SURFACES_CATALOG.prompts.safetyContract.cancelIsDefaultButton, true);
    assert.equal(CAPABILITIES["lists.today"].macos, "ships");
    assert.ok(ACTIONS_CATALOG.contextMenus["sidebar.project"].some((i: { kind: string; id?: string }) => i.kind === "action" && i.id === "project.markDone"));
    // docs/TASK_ROW_MENU_SPEC.md: one flat menu, Move is the only submenu.
    const taskRow = ACTIONS_CATALOG.contextMenus["task.row"] as { kind: string; id?: string }[];
    assert.deepEqual(taskRow.filter((i) => i.kind === "submenu").map((i) => i.id), ["move"]);
    assert.ok(taskRow.some((i) => i.kind === "action" && i.id === "task.open"));
  });
});
