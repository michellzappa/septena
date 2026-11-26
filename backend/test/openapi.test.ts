import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// AS4 and AS5 (ADR 0050 §2, §5): the OpenAPI document lists every /v1 route,
// and the conformance runner works on the published vectors. That the
// generated files are current is checked by `pnpm run gen:contract --check`
// in backend CI.

const { api } = await import("../src/api/routes.ts");
const { ROUTES, INTERNAL_ROUTES, buildOpenApi } = await import("../src/api/openapi.ts");

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const RUNNER = path.join(REPO, "docs/agent-spec/conformance/run.mjs");
const VECTORS = path.join(REPO, "registry/conformance");

describe("openapi.json", () => {
  it("documents every /v1 route or names it as internal, and nothing else", () => {
    const registered = new Set(
      (api.routes as Array<{ method: string; path: string }>)
        .filter((r) => r.method !== "ALL")
        .map((r) => `${r.method} ${r.path}`),
    );
    const listed = [...ROUTES, ...INTERNAL_ROUTES].map((r) => `${r.method} ${r.path}`);
    assert.equal(new Set(listed).size, listed.length, "a route is listed twice");
    const missing = [...registered].filter((r) => !listed.includes(r));
    const extra = listed.filter((r) => !registered.has(r));
    assert.deepEqual(missing, [], "routes with no entry in src/api/openapi.ts");
    assert.deepEqual(extra, [], "entries in src/api/openapi.ts with no route");
  });

  it("declares every path parameter and gives each operation a unique id", () => {
    const doc = buildOpenApi() as { openapi: string; paths: Record<string, Record<string, { operationId: string; parameters: Array<{ name?: string; in?: string }> }>> };
    assert.equal(doc.openapi, "3.1.0");
    const ids = new Set<string>();
    for (const [p, ops] of Object.entries(doc.paths)) {
      assert.ok(p.startsWith("/v1/"), p);
      const names = [...p.matchAll(/\{(\w+)\}/g)].map((m) => m[1]);
      for (const op of Object.values(ops)) {
        assert.ok(!ids.has(op.operationId), op.operationId);
        ids.add(op.operationId);
        const declared = op.parameters.filter((x) => x.in === "path").map((x) => x.name);
        assert.deepEqual(declared, names, `${p} ${op.operationId}`);
      }
    }
  });

  it("describes a validator's fields, limits and defaults", () => {
    const doc = buildOpenApi() as { paths: Record<string, Record<string, { requestBody?: { content: Record<string, { schema: Record<string, unknown> }> } }>> };
    const body = doc.paths["/v1/tasks"].post.requestBody!.content["application/json"].schema as {
      properties: Record<string, Record<string, unknown>>; required: string[]; additionalProperties: boolean;
    };
    assert.deepEqual(body.required, ["title"]);
    assert.equal(body.additionalProperties, false);
    assert.equal(body.properties.title.maxLength, 500);
    assert.equal(body.properties.when.default, "inbox");
    assert.ok(body.properties.idempotency_key, "writes list the idempotency key");
  });
});

describe("conformance runner (docs/agent-spec/conformance/run.mjs)", () => {
  function run(implSource: string) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "septena-conformance-"));
    const impl = path.join(dir, "impl.mjs");
    fs.writeFileSync(impl, implSource);
    const res = spawnSync(process.execPath, [RUNNER, impl, "--dir", VECTORS], { encoding: "utf8" });
    fs.rmSync(dir, { recursive: true, force: true });
    return res;
  }

  it("passes an implementation that returns each case's expected result", () => {
    const files = fs.readdirSync(VECTORS).filter((f) => f.endsWith(".json"));
    const lines = files.map((f) => {
      const name = f.replace(/\.json$/, "").replace(/-([a-z0-9])/g, (_, ch: string) => ch.toUpperCase());
      const suites = Object.entries(JSON.parse(fs.readFileSync(path.join(VECTORS, f), "utf8")))
        .filter(([, v]) => Array.isArray(v)).map(([k]) => `${JSON.stringify(k)}: echo`);
      return `export const ${name} = { ${suites.join(", ")} };`;
    });
    const res = run(`const echo = (c) => c.expected;\n${lines.join("\n")}\n`);
    assert.equal(res.status, 0, res.stdout + res.stderr);
    assert.match(res.stdout, / 0 failed, 0 skipped/);
  });

  it("fails on a wrong result and skips suites the module does not export", () => {
    const res = run(`export const refs = { taskRefId: () => "wrong" };\n`);
    assert.equal(res.status, 1, res.stdout);
    assert.match(res.stdout, /FAIL {2}refs\.json taskRefId #0/);
    assert.match(res.stdout, /skip {2}recurrence\.json nextScheduledDate/);
  });
});
