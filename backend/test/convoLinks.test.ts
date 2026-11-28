import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// `issue`, `refCount` and `endState` on MCP task rows (#310, #386). `issue` is
// the task's newest `issue` reference.

const url = (n: number, kind = "issues") => `https://github.com/michellzappa/septena/${kind}/${n}`;

describe("issueLink", () => {
  it("builds the link from the key and keeps the spelling of the name", async () => {
    const { issueLink } = await import("../src/tools/taskShared.ts");
    assert.deepEqual(issueLink("issue:acme/app#7", null), {
      url: "https://github.com/acme/app/issues/7", repo: "acme/app", number: 7, kind: "issue",
    });
    assert.deepEqual(issueLink("issue:acme/app#8", { rawId: "Acme/App#8", url: "https://github.com/Acme/App/pull/8" }), {
      url: "https://github.com/Acme/App/pull/8", repo: "Acme/App", number: 8, kind: "pr",
    });
  });

  it("never takes the address from a snapshot that names something else", async () => {
    const { issueLink } = await import("../src/tools/taskShared.ts");
    const link = issueLink("issue:acme/app#8", { rawId: "Evil/Repo#8", url: "https://example.com/pull/1" });
    assert.equal(link.url, "https://github.com/acme/app/pull/8");
  });
});

describe("task rows carry the linked issue and end state", () => {
  it("tasks_list and tasks_search show issue and a non-open endState", async () => {
    const { store } = await createTestTaskStore();
    const rpc = {
      readTask: async (id: string) => store.readTask(id),
      readTasks: async (status: "open" | "done", limit: number) => store.readTasks(status, limit),
      readAreas: async (limit: number) => store.readAreas(limit),
      readProjects: async (status: "active" | "done" | "cancelled" | "all", limit: number) => store.readProjects(status, limit),
      readChecklistCounts: async () => store.readChecklistCounts(),
      readTaskLinks: async () => store.readTaskLinks(),
      readTaskRefs: async (id: string) => store.readTaskRefs(id),
      readTags: async () => store.readTags(),
      readSetting: async (key: string) => store.readSetting(key),
      readOrderTop: async () => store.readOrderTop(),
      readDoing: async () => store.readDoing(),
      push: async (ops: Parameters<typeof store.push>[0], actor: string) => store.push(ops, actor),
    };
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const { listTasks, searchTasks } = await import("../src/shadow/mcp.ts");
    const ctx = { store: rpc as never, timeZone: "UTC" };
    const linked = (await runWriteTool(ctx, "tasks_create", { title: "Linked idea", origin: "user_request" })) as { id: string };
    const plain = (await runWriteTool(ctx, "tasks_create", { title: "Plain idea", origin: "user_request" })) as { id: string };
    await runWriteTool(ctx, "tasks_set_artifact", {
      id: linked.id, artifact: { kind: "github-issue", title: "GitHub #310", refs: [url(310)] },
    });
    await runWriteTool(ctx, "tasks_set_endstate", { id: linked.id, endState: "decomposed", note: `Tracked in ${url(310)}` });

    // A decomposed task is tracked (ADR 0066): it leaves Anytime, and search still finds it.
    const anytime = await listTasks(rpc as never, "UTC", "anytime", 100);
    assert.equal(anytime.tasks.some((t) => t.id === linked.id), false);
    assert.equal(anytime.tasks.some((t) => t.id === plain.id), true);
    const list = await listTasks(rpc as never, "UTC", "all", 100);
    const row = list.tasks.find((t) => t.id === linked.id)!;
    assert.equal(row.issue?.number, 310);
    assert.equal(row.refCount, 1);
    assert.equal(row.endState, "decomposed");
    const other = list.tasks.find((t) => t.id === plain.id)!;
    assert.equal(other.issue, undefined);
    assert.equal(other.refCount, undefined);
    assert.equal(other.endState, undefined);

    const found = await searchTasks(rpc as never, "UTC", { query: "linked idea" });
    assert.equal(found.tasks[0].issue?.url, url(310));
  });
});
