import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const backendRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function parseFile(relPath) {
  const fullPath = resolve(backendRoot, relPath);
  const src = readFileSync(fullPath, "utf8");
  return ts.createSourceFile(fullPath, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
}

function propName(nameNode) {
  if (ts.isIdentifier(nameNode) || ts.isStringLiteral(nameNode)) return nameNode.text;
  return null;
}

function literalValue(node) {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (ts.isObjectLiteralExpression(node)) {
    const out = {};
    for (const prop of node.properties) {
      if (!ts.isPropertyAssignment(prop)) continue;
      const key = propName(prop.name);
      if (key) out[key] = literalValue(prop.initializer);
    }
    return out;
  }
  return undefined;
}

function extractToolArray(arrayExpr) {
  assert.ok(ts.isArrayLiteralExpression(arrayExpr), "expected tool array literal");
  return arrayExpr.elements.map((el) => {
    assert.ok(ts.isObjectLiteralExpression(el), "expected tool object literal");
    const obj = {};
    for (const prop of el.properties) {
      if (!ts.isPropertyAssignment(prop)) continue;
      const key = propName(prop.name);
      if (key === "name" || key === "title" || key === "annotations") {
        obj[key] = literalValue(prop.initializer);
      }
    }
    return obj;
  });
}

function findConstInitializer(sourceFile, varName) {
  let found = null;
  function visit(node) {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.name.text === varName && node.initializer) {
      found = node.initializer;
      return;
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  assert.ok(found, `could not find const ${varName}`);
  return found;
}

function objectKeys(sourceFile, varName) {
  const init = findConstInitializer(sourceFile, varName);
  assert.ok(ts.isObjectLiteralExpression(init), `expected object literal for ${varName}`);
  return init.properties
    .filter(ts.isPropertyAssignment)
    .map((p) => propName(p.name))
    .filter(Boolean);
}

const taskToolsFile = parseFile("src/tools/taskTools.ts");
const agentFile = parseFile("src/shadow/agent.ts");
const shadowMcpFile = parseFile("src/shadow/mcp.ts");
const shadowWritesFile = parseFile("src/shadow/writes.ts");
const notesFile = parseFile("src/shadow/notes.ts");

const taskTools = extractToolArray(findConstInitializer(taskToolsFile, "TASK_TOOLS"));
const agentTools = extractToolArray(findConstInitializer(agentFile, "AGENT_TOOLS"));
const notesTools = extractToolArray(findConstInitializer(notesFile, "NOTES_TOOLS"));
const allTools = [...taskTools, ...agentTools, ...notesTools];
const byName = new Map(allTools.map((t) => [t.name, t]));

test("every api.septena.app tool has unique name, title, and explicit MCP ToolAnnotations", () => {
  assert.equal(byName.size, allTools.length, "duplicate tool names detected");
  assert.equal(taskTools.length, 24, `expected 24 task tools, got ${taskTools.length}`);
  assert.equal(agentTools.length, 5, "expected 5 agent tools");
  assert.equal(notesTools.length, 7, "expected 7 project notes tools (docs/PROJECT_NOTES_SPEC.md §5)");

  for (const tool of allTools) {
    assert.equal(typeof tool.name, "string", "tool.name must be string");
    assert.ok(tool.name.length > 0, "tool.name must be non-empty");
    assert.equal(typeof tool.title, "string", `${tool.name}: missing top-level title`);
    assert.ok(tool.title.length > 0, `${tool.name}: empty top-level title`);

    const a = tool.annotations;
    assert.ok(a && typeof a === "object", `${tool.name}: missing annotations`);
    assert.equal(a.title, tool.title, `${tool.name}: annotations.title must match tool.title`);
    for (const hint of ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]) {
      assert.equal(typeof a[hint], "boolean", `${tool.name}: annotations.${hint} must be boolean`);
    }
    assert.equal(a.openWorldHint, false, `${tool.name}: Septena tools operate only on the user's private store`);
    if (a.readOnlyHint) {
      assert.equal(a.destructiveHint, false, `${tool.name}: read-only tool cannot be destructive`);
      assert.equal(a.idempotentHint, true, `${tool.name}: read-only tool must be idempotent`);
    }
  }
});

test("api.septena.app connector tools match issue #85 read-only and destructive rules", () => {
  const shadowReads = objectKeys(shadowMcpFile, "zArgs");
  const shadowWrites = objectKeys(shadowWritesFile, "zWriteArgs");
  const shadowAgent = objectKeys(agentFile, "zAgentArgs");
  const shadowNotes = objectKeys(notesFile, "zNotesArgs");
  const apiConnectorNames = new Set([...shadowReads, ...shadowWrites, ...shadowAgent, ...shadowNotes]);

  const expectedReadOnly = new Set([
    "tasks_list",
    "tasks_get",
    "tasks_thread_get",
    "tasks_list_areas",
    "tasks_list_projects",
    "tasks_list_tags",
    "tasks_search",
    "tasks_find_by_ref",
    "tasks_orientation",
    "tasks_pending_reasoning",
    "tasks_project_get",
    "tasks_notes_history",
    "tasks_agent_events",
    "tasks_activity",
    "tasks_history",
  ]);
  const expectedDestructive = new Set(["tasks_complete", "tasks_update", "tasks_checklist_delete"]);

  assert.equal(apiConnectorNames.size, allTools.length, "tool definitions and handlers must match 1:1");

  for (const name of apiConnectorNames) {
    const tool = byName.get(name);
    assert.ok(tool, `api connector tool ${name} missing from tool definitions`);
    if (expectedReadOnly.has(name)) {
      assert.equal(tool.annotations.readOnlyHint, true, `${name} must be readOnlyHint: true`);
      assert.equal(tool.annotations.destructiveHint, false, `${name} must be destructiveHint: false`);
    } else {
      assert.equal(tool.annotations.readOnlyHint, false, `${name} must be readOnlyHint: false`);
      assert.equal(
        tool.annotations.destructiveHint,
        expectedDestructive.has(name),
        `${name} destructiveHint mismatch`,
      );
    }
  }
});
