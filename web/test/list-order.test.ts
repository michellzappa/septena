import assert from "node:assert/strict";
import test from "node:test";
import { groupTasksByList, moveIdToTarget, nextStructurePosition, orderByPosition } from "../src/lib/listOrder.ts";
import type { AreaRow, ProjectRow } from "../src/lib/types.ts";

test("orderByPosition puts positioned items ascending and sinks position 0/unset to bottom", () => {
  const areas: AreaRow[] = [
    { id: "a_zero", title: "Alpha Unset", position: 0 },
    { id: "a_two", title: "Work", position: 2 },
    { id: "a_none", title: "Beta Unset" },
    { id: "a_one", title: "Personal", position: 1 },
  ];
  assert.deepEqual(
    orderByPosition(areas).map((a) => a.id),
    ["a_one", "a_two", "a_zero", "a_none"],
  );
});

test("groupTasksByList walks areas -> area projects -> standalone projects in sidebar order", () => {
  const areas = orderByPosition<AreaRow>([
    { id: "a_work", title: "Work", emoji: "💼", position: 2 },
    { id: "a_home", title: "Home", emoji: "🏡", position: 1 },
  ]);
  const projects = orderByPosition<ProjectRow>([
    { id: "p_solo", title: "Standalone", area: null, status: "active", position: 1 },
    { id: "p_work_b", title: "Launch", area: "a_work", status: "active", position: 2 },
    { id: "p_work_a", title: "Q4 Plan", area: "a_work", status: "active", position: 1 },
    { id: "p_home", title: "Garden", area: "a_home", status: "active", position: 1 },
  ]);

  // Tasks arrive in arbitrary order (e.g. todayPosition order) — group order must STILL follow sidebar!
  const items = [
    { id: "t1", task: { project: "p_solo", area: null } },
    { id: "t2", task: { project: "p_work_b", area: "a_work" } },
    { id: "t3", task: { project: null, area: "a_work" } },
    { id: "t4", task: { project: "p_home", area: "a_home" } },
    { id: "t5", task: { project: null, area: null } },
    { id: "t6", task: { project: "p_work_a", area: "a_work" } },
    { id: "t7", task: { project: null, area: "a_home" } },
  ];

  const grouped = groupTasksByList(items, areas, projects);
  assert.deepEqual(grouped.ungrouped.map((x) => x.id), ["t5"]);
  assert.deepEqual(
    grouped.groups.map((g) => g.key),
    ["a:a_home", "p:p_home", "a:a_work", "p:p_work_a", "p:p_work_b", "p:p_solo"],
  );
  assert.deepEqual(grouped.groups[0].items.map((x) => x.id), ["t7"]);
  assert.deepEqual(grouped.groups[3].items.map((x) => x.id), ["t6"]);
});

test("nextStructurePosition uses 0 for unpositioned/mixed groups and max + 1 for positioned groups", () => {
  assert.equal(nextStructurePosition([]), 0);
  assert.equal(nextStructurePosition([{ position: 0 }, { position: null }]), 0);
  assert.equal(nextStructurePosition([{ position: 1 }, { position: 0 }]), 0);
  assert.equal(nextStructurePosition([{ position: 1 }, { position: 3 }, { position: 2 }]), 4);
});

test("moveIdToTarget moves a row into the target's slot in both directions", () => {
  const ids = ["h1", "h2", "h3", "h4"];
  assert.deepEqual(moveIdToTarget(ids, "h1", "h3"), ["h2", "h3", "h1", "h4"]);
  assert.deepEqual(moveIdToTarget(ids, "h4", "h2"), ["h1", "h4", "h2", "h3"]);
});

test("moveIdToTarget refuses a drop on itself or on an id outside the list", () => {
  assert.equal(moveIdToTarget(["a", "b"], "a", "a"), null);
  assert.equal(moveIdToTarget(["a", "b"], "x", "b"), null);
  assert.equal(moveIdToTarget(["a", "b"], "a", "x"), null);
});
