import assert from "node:assert/strict";
import test from "node:test";
import { newTaskTargetOf } from "../src/lib/destinations.ts";

test("newTaskTargetOf reads registry destinations.json per smart list", () => {
  assert.equal(newTaskTargetOf({ kind: "smart", id: "today" }), "here");
  assert.equal(newTaskTargetOf({ kind: "smart", id: "anytime" }), "here");
  assert.equal(newTaskTargetOf({ kind: "smart", id: "upcoming" }), "tomorrow");
  assert.equal(newTaskTargetOf({ kind: "smart", id: "logbook" }), "today");
  assert.equal(newTaskTargetOf({ kind: "smart", id: "starred" }), "today");
});

test("newTaskTargetOf makes the task in place on an area or project page", () => {
  assert.equal(newTaskTargetOf({ kind: "area", id: "a1" }), "here");
  assert.equal(newTaskTargetOf({ kind: "project", id: "p1" }), "here");
});
