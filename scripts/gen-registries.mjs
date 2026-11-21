#!/usr/bin/env node
// Validates `registry/*.json` and generates typed Swift + TypeScript constants.
//
// Usage:
//   node scripts/gen-registries.mjs          # validate and write generated files
//   node scripts/gen-registries.mjs --check  # validate and fail if generated files drifted
//
// Zero external dependencies (Node >= 20). See ADR 0015 (`docs/adr/0015-*.md`).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, "..");
const CHECK = process.argv.includes("--check");

const readJSON = (rel) => {
  const full = path.join(REPO, rel);
  try {
    return JSON.parse(fs.readFileSync(full, "utf8"));
  } catch (err) {
    throw new Error(`Failed to parse ${rel}: ${err.message}`);
  }
};

function assert(cond, msg) {
  if (!cond) throw new Error(`registry validation failed: ${msg}`);
}

function validateEntities(entities) {
  assert(entities.version === 1, "entities.json: version must be 1");
  assert(entities.patterns && typeof entities.patterns === "object", "entities.json: missing patterns");
  for (const [k, pattern] of Object.entries(entities.patterns)) {
    assert(typeof pattern === "string" && pattern.length > 0, `entities.json: pattern ${k} must be non-empty string`);
    // Verify valid JS RegExp syntax.
    new RegExp(pattern);
  }
  assert(entities.limits && typeof entities.limits === "object", "entities.json: missing limits");
  for (const [k, v] of Object.entries(entities.limits)) {
    assert(typeof v === "number" && Number.isInteger(v) && v > 0, `entities.json: limit ${k} must be positive int`);
  }
  assert(entities.enums && typeof entities.enums === "object", "entities.json: missing enums");
  for (const [k, vals] of Object.entries(entities.enums)) {
    assert(Array.isArray(vals) && vals.length > 0, `entities.json: enum ${k} must be non-empty array`);
    const seen = new Set();
    for (const v of vals) {
      assert(typeof v === "string" && v.length > 0, `entities.json: enum ${k} contains invalid item`);
      assert(!seen.has(v), `entities.json: enum ${k} contains duplicate "${v}"`);
      seen.add(v);
    }
  }
  const validKinds = new Set(["text", "int", "real", "bool", "json"]);
  assert(entities.entities && typeof entities.entities === "object", "entities.json: missing entities");
  for (const [name, spec] of Object.entries(entities.entities)) {
    assert(typeof spec.table === "string" && spec.table.length > 0, `entity ${name}: missing table`);
    assert(typeof spec.deletable === "boolean", `entity ${name}: deletable must be boolean`);
    assert(Array.isArray(spec.requiredOnInsert), `entity ${name}: requiredOnInsert must be array`);
    assert(spec.columns && typeof spec.columns === "object", `entity ${name}: missing columns`);
    for (const req of spec.requiredOnInsert) {
      assert(req in spec.columns, `entity ${name}: requiredOnInsert "${req}" not in columns`);
    }
    if (spec.updatable !== undefined) {
      assert(Array.isArray(spec.updatable), `entity ${name}: updatable must be array`);
      for (const up of spec.updatable) {
        assert(up in spec.columns, `entity ${name}: updatable "${up}" not in columns`);
      }
    }
    for (const [colName, col] of Object.entries(spec.columns)) {
      assert(validKinds.has(col.kind), `entity ${name}.${colName}: invalid kind "${col.kind}"`);
      if (col.format !== undefined) {
        assert(col.format in entities.patterns, `entity ${name}.${colName}: unknown format "${col.format}"`);
      }
      if (col.enum !== undefined) {
        assert(col.enum in entities.enums, `entity ${name}.${colName}: unknown enum "${col.enum}"`);
      }
    }
  }
}

function validateRules(rules) {
  assert(rules.version === 1, "rules.json: version must be 1");
  const required = [
    "cueDecayDays",
    "fadeWindowDays",
    "fadeGraceDays",
    "fadeMinOpacity",
    "fadeSweepWeekday",
    "recentlyDeletedDays",
    "upcomingCalendarDays",
    "toastDurationSeconds",
    "agentRunBudget",
    "claimTtlDefaultSeconds",
    "claimTtlMaxSeconds",
    "tombstoneTtlDays",
    "clientOpTtlDays",
    "changeLogTtlDays",
  ];
  for (const k of required) {
    assert(typeof rules[k] === "number" && Number.isFinite(rules[k]) && rules[k] > 0, `rules.json: ${k} must be positive number`);
  }
  assert(rules.fadeMinOpacity > 0 && rules.fadeMinOpacity < 1, "rules.json: fadeMinOpacity must be in (0, 1)");
  assert(rules.fadeSweepWeekday >= 1 && rules.fadeSweepWeekday <= 7, "rules.json: fadeSweepWeekday must be 1..7");
  assert(rules.claimTtlMaxSeconds >= rules.claimTtlDefaultSeconds, "rules.json: claimTtlMaxSeconds must be >= claimTtlDefaultSeconds");
}

function validateConformance() {
  const dir = path.join(REPO, "registry/conformance");
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  assert(files.length > 0, "registry/conformance must contain at least one fixture file");
  for (const f of files) {
    const data = readJSON(`registry/conformance/${f}`);
    assert(data.version === 1, `registry/conformance/${f}: version must be 1`);
  }
}

function swiftString(s) {
  return JSON.stringify(s);
}

function generateSwift(entities, rules) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Source: registry/entities.json, registry/rules.json");
  lines.push("// Regenerate: node scripts/gen-registries.mjs");
  lines.push("");
  lines.push("import Foundation");
  lines.push("");
  lines.push("/// Wire schema size and count limits shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityLimits {");
  for (const [k, v] of Object.entries(entities.limits)) {
    const type = v > 2_000_000_000 || k.endsWith("Bytes") ? "Int64" : "Int";
    lines.push(`  static let ${k}: ${type} = ${v}`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Wire schema regex strings shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityPatterns {");
  for (const [k, v] of Object.entries(entities.patterns)) {
    lines.push(`  static let ${k} = ${swiftString(v)}`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Canonical enum wire strings shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityEnums {");
  for (const [k, vals] of Object.entries(entities.enums)) {
    lines.push(`  static let ${k}: [String] = [${vals.map(swiftString).join(", ")}]`);
  }
  const entityNames = Object.keys(entities.entities);
  const deletable = entityNames.filter((n) => entities.entities[n].deletable);
  lines.push(`  static let entityNames: [String] = [${entityNames.map(swiftString).join(", ")}]`);
  lines.push(`  static let deletableEntities: [String] = [${deletable.map(swiftString).join(", ")}]`);
  lines.push("}");
  lines.push("");
  lines.push("/// Domain thresholds and retention constants shared across platforms (`registry/rules.json`).");
  lines.push("enum RegistryRules {");
  for (const [k, v] of Object.entries(rules)) {
    if (k === "version") continue;
    const type = Number.isInteger(v) ? "Int" : "Double";
    lines.push(`  static let ${k}: ${type} = ${v}`);
  }
  lines.push("}");
  lines.push("");
  return lines.join("\n");
}

function generateTS(entities, rules) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Source: registry/entities.json, registry/rules.json");
  lines.push("// Regenerate: node scripts/gen-registries.mjs");
  lines.push("");
  lines.push("export const ENTITY_PATTERNS = {");
  for (const [k, v] of Object.entries(entities.patterns)) {
    lines.push(`  ${k}: ${JSON.stringify(v)},`);
  }
  lines.push("} as const;");
  lines.push("");
  lines.push("export const ENTITY_LIMITS = {");
  for (const [k, v] of Object.entries(entities.limits)) {
    lines.push(`  ${k}: ${v},`);
  }
  lines.push("} as const;");
  lines.push("");
  lines.push("export const ENTITY_ENUMS = {");
  for (const [k, vals] of Object.entries(entities.enums)) {
    lines.push(`  ${k}: ${JSON.stringify(vals)} as const,`);
  }
  lines.push("} as const;");
  lines.push("");
  const deletable = Object.keys(entities.entities).filter((n) => entities.entities[n].deletable);
  lines.push(`export const DELETABLE_ENTITIES = ${JSON.stringify(deletable)} as const;`);
  lines.push("");
  lines.push("export const DOMAIN_RULES = {");
  for (const [k, v] of Object.entries(rules)) {
    if (k === "version") continue;
    lines.push(`  ${k}: ${v},`);
  }
  lines.push("} as const;");
  lines.push("");
  return lines.join("\n");
}

function writeOrCheck(rel, content) {
  const full = path.join(REPO, rel);
  const existing = fs.existsSync(full) ? fs.readFileSync(full, "utf8") : null;
  if (CHECK) {
    if (existing !== content) {
      throw new Error(`generated file out of date: ${rel} (run: node scripts/gen-registries.mjs)`);
    }
    return false;
  }
  if (existing === content) return false;
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content, "utf8");
  return true;
}

const entities = readJSON("registry/entities.json");
const rules = readJSON("registry/rules.json");
validateEntities(entities);
validateRules(rules);
validateConformance();

const outputs = [
  ["SeptenaCore/Generated/RegistryConstants.swift", generateSwift(entities, rules)],
  ["backend/src/generated/registries.ts", generateTS(entities, rules)],
];

let changed = 0;
for (const [rel, content] of outputs) {
  if (writeOrCheck(rel, content)) {
    console.log(`wrote ${rel}`);
    changed++;
  }
}

if (CHECK) {
  console.log("registries: ok (valid and generated files up to date)");
} else if (changed === 0) {
  console.log("registries: already up to date");
}
