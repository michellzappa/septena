#!/usr/bin/env node
// Generates the packaged context/skill files from the single source of truth
// (tools/agent-packages/loop-rules.md), or verifies they match with --check.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const sourcePath = resolve(root, "loop-rules.md");
const rules = readFileSync(sourcePath, "utf8").trimEnd() + "\n";

const GENERATED_BANNER =
  "<!-- Generated from tools/agent-packages/loop-rules.md — edit that file and run `node tools/agent-packages/sync.mjs`. -->\n\n";

const CLAUDE_SKILL_FRONTMATTER = `---
name: septena
description: Work and manage tasks in Septena over MCP following the Septena agent loop rules (claim, read, append turns, ask with options, hand back artifacts/handoffs, release).
---

`;

const targets = [
  {
    path: resolve(root, "gemini-extension/GEMINI.md"),
    content: GENERATED_BANNER + rules,
  },
  {
    path: resolve(root, "claude-plugin/skills/septena/SKILL.md"),
    content: CLAUDE_SKILL_FRONTMATTER + GENERATED_BANNER + rules,
  },
];

const checkOnly = process.argv.includes("--check");
let drifted = false;

for (const target of targets) {
  if (checkOnly) {
    let existing = null;
    try {
      existing = readFileSync(target.path, "utf8");
    } catch {
      existing = null;
    }
    if (existing !== target.content) {
      console.error(`DRIFT: ${target.path} does not match loop-rules.md`);
      drifted = true;
    }
  } else {
    mkdirSync(dirname(target.path), { recursive: true });
    writeFileSync(target.path, target.content, "utf8");
    console.log(`wrote ${target.path}`);
  }
}

if (checkOnly) {
  if (drifted) {
    console.error("Run `node tools/agent-packages/sync.mjs` to update generated package files.");
    process.exit(1);
  }
  console.log("ok: all agent package rule files match loop-rules.md");
}
