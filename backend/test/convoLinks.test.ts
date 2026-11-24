import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// `issue` and `endState` on MCP task rows (#310). The search order mirrors
// SeptenaCore TaskConvo.linkedIssue (ConvoDerived.swift).

const url = (n: number, kind = "issues") => `https://github.com/michellzappa/septena/${kind}/${n}`;

describe("issueLink (mirrors TaskConvo.linkedIssue)", () => {
  it("parses issues and pull requests", async () => {
    const { parseIssueLink } = await import("../src/tools/taskShared.ts");
    assert.deepEqual(parseIssueLink(`see ${url(310)} now`), {
      url: url(310), repo: "michellzappa/septena", number: 310, kind: "issue",
    });
    assert.equal(parseIssueLink(url(12, "pull"))?.kind, "pr");
    assert.equal(parseIssueLink("github.com/x without a path"), undefined);
    assert.equal(parseIssueLink(null), undefined);
  });

  it("takes artifact refs, body, title, handoff, end-state note, then the turn, in that order", async () => {
    const { issueLink } = await import("../src/tools/taskShared.ts");
    const all = {
      artifact: { refs: ["no link", url(1)], body: url(2), title: url(3) },
      handoffPayload: url(4), endStateNote: url(5), turnText: url(6),
    };
    assert.equal(issueLink(all)?.number, 1);
    assert.equal(issueLink({ ...all, artifact: { ...all.artifact, refs: [] } })?.number, 2);
    assert.equal(issueLink({ ...all, artifact: { title: url(3) } })?.number, 3);
    assert.equal(issueLink({ ...all, artifact: null })?.number, 4);
    assert.equal(issueLink({ endStateNote: url(5), turnText: url(6) })?.number, 5);
    assert.equal(issueLink({ turnText: url(6) })?.number, 6);
    assert.equal(issueLink({}), undefined);
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
      readConvoLinks: async () => store.readConvoLinks(),
      readTags: async () => store.readTags(),
      readSetting: async (key: string) => store.readSetting(key),
      readOrderTop: async () => store.readOrderTop(),
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

    const list = await listTasks(rpc as never, "UTC", "anytime", 100);
    const row = list.tasks.find((t) => t.id === linked.id)!;
    assert.equal(row.issue?.number, 310);
    assert.equal(row.endState, "decomposed");
    const other = list.tasks.find((t) => t.id === plain.id)!;
    assert.equal(other.issue, undefined);
    assert.equal(other.endState, undefined);

    const found = await searchTasks(rpc as never, "UTC", { query: "linked idea" });
    assert.equal(found.tasks[0].issue?.url, url(310));
  });
});
