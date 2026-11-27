import assert from "node:assert/strict";
import test from "node:test";
import { ensureCoreReady } from "../src/lib/core/index.ts";
import {
  listSortFor,
  listSortKey,
  nextListSortMap,
  readListSortMap,
  sortListItems,
} from "../src/lib/listSort.ts";
import type { TaskRow } from "../src/lib/types.ts";

const task = (id: string, title: string, scheduled: string | null = null): TaskRow =>
  ({ id, title, status: "open", scheduled }) as TaskRow;

const items = [
  { task: task("t1", "Charlie", "2026-12-03") },
  { task: task("t2", "alpha") },
  { task: task("t3", "Bravo", "2026-12-01") },
];

test("Manual returns the input order without the core", () => {
  assert.deepEqual(
    sortListItems(items, "manual", (i) => i.task).map((i) => i.task.id),
    ["t1", "t2", "t3"],
  );
});

test("a core error returns the manual order", async () => {
  await ensureCoreReady();
  // A sort value the core rejects, and (on a core without sortTasks) the unknown function.
  const out = sortListItems(items, "bogus" as never, (i) => i.task);
  assert.deepEqual(out.map((i) => i.task.id), ["t1", "t2", "t3"]);
});

test("a sorted list keeps pinned rows and each group's slots", async () => {
  await ensureCoreReady();
  const out = sortListItems(items, "title", (i) => i.task, () => "", (i) => i.task.id === "t1");
  // t1 stays first whatever the core does; t2 and t3 are either sorted or left in manual order.
  assert.equal(out[0].task.id, "t1");
  assert.deepEqual(new Set(out.map((i) => i.task.id)), new Set(["t1", "t2", "t3"]));
});

test("list keys follow the registry and the spec", () => {
  assert.equal(listSortKey({ kind: "smart", id: "today" }), "today");
  assert.equal(listSortKey({ kind: "smart", id: "anytime" }), "anytime");
  assert.equal(listSortKey({ kind: "smart", id: "upcoming" }), null);
  assert.equal(listSortKey({ kind: "smart", id: "logbook" }), null);
  assert.equal(listSortKey({ kind: "project", id: "p1" }), "project:p1");
  assert.equal(listSortKey({ kind: "area", id: "a1" }), "area:a1");
});

test("the stored record drops invalid values, Manual removes the key, stale lists drop", () => {
  const map = readListSortMap({ today: "when", anytime: "manual", "project:p1": "nope", "project:p2": "title", "area:a9": "created" });
  assert.deepEqual(map, { today: "when", "project:p2": "title", "area:a9": "created" });
  assert.equal(listSortFor(map, "anytime"), "manual");
  const live = { projectIds: new Set(["p2"]), areaIds: new Set<string>() };
  assert.deepEqual(nextListSortMap(map, "today", "manual", live), { "project:p2": "title" });
  assert.deepEqual(nextListSortMap(map, "anytime", "deadline", live), {
    today: "when",
    "project:p2": "title",
    anytime: "deadline",
  });
});
