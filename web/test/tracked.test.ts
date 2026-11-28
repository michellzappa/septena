import assert from "node:assert/strict";
import { test } from "node:test";

import { trackedLink } from "../src/lib/tracked.ts";
import type { TaskRefRow } from "../src/lib/types.ts";

const ref = (r: Partial<TaskRefRow>): TaskRefRow => ({ id: "r", taskId: "t", key: "url:https://example.com", ...r });

test("a tracked row links its newest issue reference", () => {
  const link = trackedLink([
    ref({ id: "a", key: "url:https://example.com/doc", snapshot: { url: "https://example.com/doc" } }),
    ref({ id: "b", key: "issue:septena/septena#10", snapshot: { url: "https://github.com/septena/septena/issues/10" }, createdAt: "2026-11-01T00:00:00Z" }),
    ref({ id: "c", key: "issue:septena/septena#858", snapshot: { url: "https://github.com/septena/septena/issues/858" }, createdAt: "2026-11-28T00:00:00Z" }),
  ]);
  assert.deepEqual(link, { url: "https://github.com/septena/septena/issues/858", label: "septena/septena#858" });
});

test("without an issue, a tracked row links the first reference with a URL", () => {
  assert.equal(trackedLink([ref({ key: "url:https://example.com/doc" })])?.url, "https://example.com/doc");
  assert.equal(trackedLink([ref({ key: "email:abc", snapshot: null })]), null);
  assert.equal(trackedLink([]), null);
});
