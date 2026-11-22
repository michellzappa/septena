import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Onboarding prompt (`onboard_septena`), `GET /onboard.md`, MCP prompts
// protocol plumbing, and area emoji persistence (#124, #103).

describe("onboard prompt & MCP prompts plumbing", () => {
  it("exposes onboard_septena with stripped frontmatter and optional focus", async () => {
    const { ONBOARD_MARKDOWN, ONBOARD_PROMPT_NAME, PROMPTS, getPrompt } =
      await import("../src/shadow/prompts.ts");

    assert.equal(PROMPTS.length, 1);
    assert.equal(PROMPTS[0].name, ONBOARD_PROMPT_NAME);
    assert.ok(ONBOARD_MARKDOWN.startsWith("---\n"), "onboard.md should carry skill frontmatter");

    const bare = getPrompt(ONBOARD_PROMPT_NAME);
    assert.ok(bare);
    assert.equal(bare.messages.length, 1);
    assert.equal(bare.messages[0].role, "user");
    const text = bare.messages[0].content.text;
    assert.ok(!text.startsWith("---"), "prompt message should strip YAML frontmatter");
    assert.match(text, /tasks_area_create/);
    assert.match(text, /tasks_project_create/);
    assert.match(text, /tasks_create/);
    assert.match(text, /emoji/i);

    const focused = getPrompt(ONBOARD_PROMPT_NAME, { focus: "Focus on Q4 launch and home errands." });
    assert.ok(focused);
    assert.match(focused.messages[0].content.text, /Focus on Q4 launch and home errands\./);

    assert.equal(getPrompt("nope"), null);
  });

  it("advertises prompts capability in initialize and server/discover when enabled", async () => {
    const { answerProtocolMethod } = await import("../src/rpc.ts");

    const initRes = answerProtocolMethod(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
      "legacy",
      { instructions: "hi", initializeInstructions: "hi", hasPrompts: true },
    );
    assert.ok(initRes);
    const initBody = await initRes.json() as { result: { capabilities: Record<string, unknown> } };
    assert.deepEqual(initBody.result.capabilities, { tools: {}, prompts: {} });

    const discRes = answerProtocolMethod(
      { jsonrpc: "2.0", id: 2, method: "server/discover" },
      "modern",
      { instructions: "hi", hasPrompts: true },
    );
    assert.ok(discRes);
    const discBody = await discRes.json() as { result: { capabilities: Record<string, unknown> } };
    assert.deepEqual(discBody.result.capabilities, { tools: {}, prompts: {} });
  });

  it("validates Mcp-Name header on modern prompts/get requests", async () => {
    const { MODERN_VERSION, validateModernHeaders } = await import("../src/protocol.ts");

    const missingName = validateModernHeaders(
      (h) => ({ "MCP-Protocol-Version": MODERN_VERSION, "Mcp-Method": "prompts/get" }[h]),
      "prompts/get",
      { name: "onboard_septena" },
    );
    assert.match(missingName ?? "", /missing Mcp-Name/);

    const mismatch = validateModernHeaders(
      (h) => ({
        "MCP-Protocol-Version": MODERN_VERSION,
        "Mcp-Method": "prompts/get",
        "Mcp-Name": "other",
      }[h]),
      "prompts/get",
      { name: "onboard_septena" },
    );
    assert.match(mismatch ?? "", /does not match/);

    const ok = validateModernHeaders(
      (h) => ({
        "MCP-Protocol-Version": MODERN_VERSION,
        "Mcp-Method": "prompts/get",
        "Mcp-Name": "onboard_septena",
      }[h]),
      "prompts/get",
      { name: "onboard_septena" },
    );
    assert.equal(ok, null);
  });

  it("creates an area with emoji and context notes and persists both", async () => {
    const { store } = await createTestTaskStore();
    const notes = await import("../src/shadow/notes.ts");
    const rpc = store as unknown as Parameters<typeof notes.runNotesTool>[0]["store"];
    const created = await notes.runNotesTool(
      { store: rpc, clientId: "client0123456789", timeZone: "Europe/Amsterdam" },
      "tasks_area_create",
      { title: "Home", emoji: "🏠", notes: "House errands and family logistics", why: "onboarding" },
    ) as Record<string, unknown>;

    assert.equal(created.title, "Home");
    assert.equal(created.emoji, "🏠");
    assert.equal(created.noteRev, 1);

    const areas = store.readAreas(50);
    const row = areas.find((a) => a.id === created.id);
    assert.ok(row);
    assert.equal(row.emoji, "🏠");
    assert.equal(row.context, "House errands and family logistics");
  });
});
