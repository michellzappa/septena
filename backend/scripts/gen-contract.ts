// Writes the generated files of the agent contract (ADR 0050 §2, §5):
//
//   backend/src/generated/openapi.json  the OpenAPI 3.1 document for /v1,
//                                       from the route validators (src/api/openapi.ts)
//   docs/agent-spec/schema.json         the JSON Schema of the records,
//                                       from registry/entities.json
//   docs/agent-spec/spec.md             docs/agent-spec/spec.src.md with its
//                                       tables filled from the registry and
//                                       the refusal table (src/errors.ts)
//
// Usage (from backend/):
//   pnpm run gen:contract           write the files
//   pnpm run gen:contract --check   fail when a file is out of date
//
// It loads the TypeScript sources with the test loader hooks, so it needs
// Node 24 and `pnpm install`, and nothing else.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installWorkerTestHooks } from "../test/taskStoreHarness.ts";

installWorkerTestHooks();

const { buildOpenApi } = await import("../src/api/openapi.ts");
const { zodToJsonSchema } = await import("../src/api/zodJsonSchema.ts");
const { zTurn } = await import("../src/store/ops.ts");
const { REFUSALS } = await import("../src/errors.ts");

const BACKEND = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO = path.resolve(BACKEND, "..");
const CHECK = process.argv.includes("--check");

type Column = {
  kind: "text" | "int" | "real" | "bool" | "json";
  max?: number;
  min?: number;
  format?: string;
  enum?: string;
  nullable?: boolean;
  default?: unknown;
  serverOwned?: boolean;
  maxJsonLength?: number;
};
type Entity = { table: string; deletable: boolean; requiredOnInsert: string[]; updatable?: string[]; columns: Record<string, Column> };
type Entities = {
  turnFields: string[];
  patterns: Record<string, string>;
  limits: Record<string, number>;
  enums: Record<string, string[]>;
  entities: Record<string, Entity>;
};

const entities = JSON.parse(fs.readFileSync(path.join(REPO, "registry/entities.json"), "utf8")) as Entities;
const rules = JSON.parse(fs.readFileSync(path.join(REPO, "registry/rules.json"), "utf8")) as Record<string, number>;

// ---- JSON Schema of the records ----

const SCHEMA_ID = "https://septena.app/spec/schema.json";

function columnSchema(col: Column): Record<string, unknown> {
  let out: Record<string, unknown>;
  if (col.kind === "text") {
    if (col.enum) out = { $ref: `#/$defs/${col.enum}` };
    else if (col.format) out = col.max ? { allOf: [{ $ref: `#/$defs/${col.format}` }, { maxLength: col.max }] } : { $ref: `#/$defs/${col.format}` };
    else out = col.max ? { type: "string", maxLength: col.max } : { type: "string" };
  } else if (col.kind === "int" || col.kind === "real") {
    out = { type: col.kind === "int" ? "integer" : "number" };
    if (col.min !== undefined) out.minimum = col.min;
    if (col.max !== undefined) out.maximum = col.max;
  } else if (col.kind === "bool") {
    out = { type: "boolean" };
    if (col.default !== undefined) out.default = Boolean(col.default);
  } else {
    out = col.maxJsonLength ? { description: `JSON, at most ${col.maxJsonLength} characters when serialized.` } : {};
  }
  if (col.kind !== "bool" && col.default !== undefined) out.default = col.default;
  if (col.serverOwned) out.readOnly = true;
  if (col.nullable) out = { anyOf: [out, { type: "null" }] };
  return out;
}

function recordSchema(name: string, spec: Entity): Record<string, unknown> {
  const properties: Record<string, unknown> = { id: { $ref: "#/$defs/id" } };
  for (const [field, col] of Object.entries(spec.columns)) properties[field] = columnSchema(col);
  const notes = [`The \`${name}\` record (table \`${spec.table}\`).`];
  notes.push(spec.deletable ? "It can be deleted." : "It is never deleted on its own.");
  if (spec.updatable) notes.push(`Fields that change after create: ${spec.updatable.join(", ")}.`);
  return {
    type: "object",
    description: notes.join(" "),
    required: ["id", ...spec.requiredOnInsert],
    properties,
  };
}

function buildSchema(): Record<string, unknown> {
  const turn = zodToJsonSchema(zTurn);
  const turnFields = Object.keys(turn.properties as object);
  if (turnFields.join() !== entities.turnFields.join()) {
    throw new Error(`zTurn fields (${turnFields}) differ from registry/entities.json turnFields (${entities.turnFields})`);
  }
  const defs: Record<string, unknown> = {};
  for (const [name, pattern] of Object.entries(entities.patterns)) defs[name] = { type: "string", pattern };
  for (const [name, values] of Object.entries(entities.enums)) defs[name] = { type: "string", enum: values };
  for (const [name, spec] of Object.entries(entities.entities)) defs[name] = recordSchema(name, spec);
  defs.turn = { ...turn, description: "One step of a task's conversation. Turns are appended, never changed." };
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: SCHEMA_ID,
    title: "Septena records",
    description: "Agent spec v0, unstable until Septena 1.0 (https://septena.app/spec.md). Generated from registry/entities.json by backend/scripts/gen-contract.ts. Do not edit by hand.",
    "x-septena-spec-version": "v0",
    $defs: defs,
  };
}

// ---- spec.md ----

const cell = (s: string) => s.replaceAll("|", "\\|").replaceAll("\n", " ");

function typeText(col: Column): string {
  if (col.kind === "text") {
    if (col.enum) return `one of \`${col.enum}\``;
    if (col.format) return col.format === "id" ? "id" : col.format;
    return col.max ? `text, ≤ ${col.max}` : "text";
  }
  if (col.kind === "int" || col.kind === "real") {
    const t = col.kind === "int" ? "integer" : "number";
    if (col.min !== undefined && col.max !== undefined) return `${t}, ${col.min} to ${col.max}`;
    return t;
  }
  if (col.kind === "bool") return "boolean";
  return "JSON";
}

function recordsSection(): string {
  const out: string[] = [];
  for (const [name, spec] of Object.entries(entities.entities)) {
    out.push(`### \`${name}\``, "");
    const facts = [`Required on create: ${spec.requiredOnInsert.length ? spec.requiredOnInsert.map((f) => `\`${f}\``).join(", ") : "nothing"}.`];
    facts.push(spec.deletable ? "Can be deleted." : "Not deleted on its own.");
    out.push(facts.join(" "), "");
    out.push("| Field | Type | Notes |", "|---|---|---|", "| `id` | id | Set at create, never changes. |");
    for (const [field, col] of Object.entries(spec.columns)) {
      const notes: string[] = [];
      if (col.serverOwned) notes.push("server-owned");
      if (col.nullable) notes.push("may be null");
      if (col.default !== undefined) notes.push(`default ${JSON.stringify(col.kind === "bool" ? Boolean(col.default) : col.default)}`);
      if (spec.updatable && !spec.updatable.includes(field) && !col.serverOwned) notes.push("set at create");
      out.push(`| \`${field}\` | ${cell(typeText(col))} | ${notes.join(", ")} |`);
    }
    out.push("");
  }
  out.push("### `turn`", "", "One step of a task's conversation, in its `thread`. Turns are appended, never changed.", "");
  out.push("| Field | Type |", "|---|---|");
  const turn = zodToJsonSchema(zTurn) as { properties: Record<string, Record<string, unknown>>; required: string[] };
  for (const field of entities.turnFields) {
    const p = turn.properties[field];
    const inner = (p.anyOf as Array<Record<string, unknown>> | undefined)?.[0] ?? p;
    let t = String(inner.type ?? "any");
    if (inner.enum) t = (inner.enum as string[]).map((v) => `\`${v}\``).join(", ");
    else if (inner.format === "date-time") t = "stamp with zone";
    else if (inner.type === "string" && inner.maxLength) t = `text, ≤ ${inner.maxLength}`;
    else if (inner.type === "array") t = `list of text, ≤ ${inner.maxItems} items`;
    else if (inner.type === "number" && inner.maximum !== undefined) t = `number, ${inner.minimum} to ${inner.maximum}`;
    out.push(`| \`${field}\` | ${cell(t)}${turn.required.includes(field) ? ", required" : ""} |`);
  }
  return out.join("\n").trimEnd();
}

function enumsSection(): string {
  const out = ["| Name | Values |", "|---|---|"];
  for (const [name, values] of Object.entries(entities.enums)) out.push(`| \`${name}\` | ${values.map((v) => `\`${v}\``).join(", ")} |`);
  return out.join("\n");
}

function refusalsSection(): string {
  const out = ["| Code | Retryable | Hint |", "|---|---|---|"];
  for (const [code, info] of Object.entries(REFUSALS as Record<string, { retryable: boolean; hint: string }>)) {
    out.push(`| \`${code}\` | ${info.retryable ? "yes" : "no"} | ${cell(info.hint)} |`);
  }
  return out.join("\n");
}

function conformanceSection(): string {
  const dir = path.join(REPO, "registry/conformance");
  const out = ["| File | Suites (cases) |", "|---|---|"];
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort()) {
    const data = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8")) as Record<string, unknown>;
    const suites = Object.entries(data).filter(([, v]) => Array.isArray(v)).map(([k, v]) => `\`${k}\` (${(v as unknown[]).length})`);
    out.push(`| [\`${file}\`](https://septena.app/spec/conformance/${file}) | ${suites.join(", ")} |`);
  }
  return out.join("\n");
}

function duration(seconds: number): string {
  if (seconds % 3600 === 0) return `${seconds / 3600} hour${seconds === 3600 ? "" : "s"}`;
  return `${seconds / 60} minutes`;
}

function buildSpec(): string {
  const source = fs.readFileSync(path.join(REPO, "docs/agent-spec/spec.src.md"), "utf8");
  const fills: Record<string, string> = {
    records: recordsSection(),
    enums: enumsSection(),
    refusals: refusalsSection(),
    conformance: conformanceSection(),
    idPattern: entities.patterns.id,
    claimDefault: duration(rules.claimTtlDefaultSeconds),
    claimMax: duration(rules.claimTtlMaxSeconds),
    runBudget: String(rules.agentRunBudget),
  };
  const filled = source.replace(/\{\{(\w+)\}\}/g, (_, key: string) => {
    if (!(key in fills)) throw new Error(`spec.src.md: unknown placeholder {{${key}}}`);
    return fills[key];
  });
  const header = "<!-- Generated by backend/scripts/gen-contract.ts from docs/agent-spec/spec.src.md. Edit the source, then run `pnpm run gen:contract` in backend/. -->\n\n";
  return header + filled;
}

// ---- write or check ----

const outputs: Array<[string, string]> = [
  ["backend/src/generated/openapi.json", JSON.stringify(buildOpenApi(), null, 2) + "\n"],
  ["docs/agent-spec/schema.json", JSON.stringify(buildSchema(), null, 2) + "\n"],
  ["docs/agent-spec/spec.md", buildSpec()],
];

let stale = 0;
for (const [rel, content] of outputs) {
  const full = path.join(REPO, rel);
  const existing = fs.existsSync(full) ? fs.readFileSync(full, "utf8") : null;
  if (existing === content) continue;
  if (CHECK) {
    console.error(`generated file out of date: ${rel} (run: pnpm run gen:contract in backend/)`);
    stale++;
    continue;
  }
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content, "utf8");
  console.log(`wrote ${rel}`);
}
if (stale) process.exit(1);
if (CHECK) console.log("contract: generated files are current");
