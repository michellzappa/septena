// The MCP tools that api.septena.app/mcp registers, read from the backend
// source without running it. scripts/gen-registries.mjs uses the list to check
// the `agent` field of registry/capabilities.json and the tools that
// skills/*/SKILL.md name.
//
// The tool definitions live in the arrays listed in TOOL_FILES (backend/src/
// shadow/mcp.ts joins them into tools/list). backend/test/agentErrors.test.ts
// checks that this list equals the live tools/list, so a tool defined in a new
// file fails that test until the file is added here.
import fs from "node:fs";
import path from "node:path";

export const TOOL_FILES = [
  "backend/src/tools/taskTools.ts",
  "backend/src/shadow/attachments.ts",
  "backend/src/shadow/agent.ts",
  "backend/src/shadow/notes.ts",
];

/** Sorted, unique tool names (`tasks_*`) defined in TOOL_FILES. */
export function mcpToolNames(repo) {
  const names = new Set();
  for (const rel of TOOL_FILES) {
    const src = fs.readFileSync(path.join(repo, rel), "utf8");
    for (const m of src.matchAll(/^\s+name:\s*"(tasks_[a-z_]+)"/gm)) names.add(m[1]);
  }
  return [...names].sort();
}
