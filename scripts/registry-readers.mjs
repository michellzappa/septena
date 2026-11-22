// Reader check for generated registry code (ADR 0020, P3).
//
// `node scripts/gen-registries.mjs --check` calls `checkReaders`. A generated
// member with no reader is dead code that drifts: the registry says one thing
// and no shell shows it. A member counts as read when hand-written code (app
// sources, tests) or another part of the same generated file names it.
//
// Swift: every `static let/var/func` of a generated `enum` and every stored
// `let` of a generated `struct`. TypeScript: every top-level `export`.
// Kotlin is not checked yet (the Android client reads it; see #190).
//
// Exceptions live in `registry/readers-allowlist.json`, each with a reason and
// the issue that removes it. An allowlisted member that gains a reader fails
// the check too, so the allowlist only shrinks.

import fs from "node:fs";
import path from "node:path";

const SKIP_DIRS = new Set(["node_modules", ".git", "Generated", "generated", "build", ".build", "DerivedData"]);

function walk(dir, exts) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (!SKIP_DIRS.has(e.name)) out.push(...walk(p, exts));
    } else if (exts.some((x) => e.name.endsWith(x))) {
      out.push(p);
    }
  }
  return out;
}

const readAll = (files) => files.map((f) => fs.readFileSync(f, "utf8")).join("\n");
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Generated Swift members as `Type.member`, with their declaration line index. */
function swiftMembers(lines) {
  const out = [];
  let type = null;
  let kind = null;
  lines.forEach((line, i) => {
    const t = line.match(/^(enum|struct|extension) (\w+)/);
    if (t) {
      type = t[2];
      kind = t[1];
      return;
    }
    if (line.startsWith("}")) {
      type = null;
      return;
    }
    if (!type || kind === "extension") return;
    const m = kind === "struct"
      ? line.match(/^  let (\w+)/)
      : line.match(/^  static (?:let|var|func) (\w+)/);
    if (m) out.push({ id: `${type}.${m[1]}`, name: m[1], kind, line: i });
  });
  return out;
}

function swiftIsRead(member, handSrc, genLines, extensionSrc) {
  // A struct field is read as `.name`; an enum member as `.name` too (callers
  // write `RegistryX.name`), or bare inside a hand-written `extension RegistryX`
  // or the generated file itself.
  const dotted = new RegExp(`\\.${esc(member.name)}\\b`);
  if (dotted.test(handSrc)) return true;
  const bareHand = new RegExp(`\\b${esc(member.name)}\\b`);
  if ((extensionSrc[member.id.split(".")[0]] ?? []).some((src) => bareHand.test(src))) return true;
  const bare = new RegExp(`\\b${esc(member.name)}\\b`);
  return genLines.some((l, i) => i !== member.line && !/^\s*\/\//.test(l) && bare.test(l.replace(/"(?:[^"\\]|\\.)*"/g, '""')) && !isDeclOfSameName(l, member.name));
}

function isDeclOfSameName(line, name) {
  return new RegExp(`^\\s*(?:static )?(?:let|var|func) ${esc(name)}\\b`).test(line);
}

function tsExports(lines) {
  const out = [];
  lines.forEach((line, i) => {
    const m = line.match(/^export (?:const|function|type|interface|enum) (\w+)/);
    if (m) out.push({ id: m[1], name: m[1], line: i });
  });
  return out;
}

function tsIsRead(member, handSrc, genLines) {
  const re = new RegExp(`\\b${esc(member.name)}\\b`);
  if (re.test(handSrc)) return true;
  return genLines.some((l, i) => i !== member.line && re.test(l.replace(/"(?:[^"\\]|\\.)*"/g, '""')));
}

export function checkReaders(repo) {
  const allow = JSON.parse(fs.readFileSync(path.join(repo, "registry/readers-allowlist.json"), "utf8"));
  const problems = [];

  const swiftGen = fs.readFileSync(path.join(repo, "SeptenaCore/Generated/RegistryConstants.swift"), "utf8").split("\n");
  const swiftFiles = ["Septena", "Septask", "SeptenaCore", "SeptenaCoreTests", "ShareExtension"]
    .flatMap((d) => walk(path.join(repo, d), [".swift"]));
  const swiftHand = readAll(swiftFiles);
  // Hand-written `extension RegistryX { … }` bodies, by type name.
  const extensionSrc = {};
  for (const f of swiftFiles) {
    const text = fs.readFileSync(f, "utf8");
    for (const m of text.matchAll(/^extension (Registry\w+)[^{]*\{([\s\S]*?)^\}/gm)) {
      (extensionSrc[m[1]] ??= []).push(m[2]);
    }
  }
  const tsGen = fs.readFileSync(path.join(repo, "backend/src/generated/registries.ts"), "utf8").split("\n");
  const tsHand = readAll(["backend/src", "backend/test", "backend/scripts"]
    .flatMap((d) => walk(path.join(repo, d), [".ts", ".mjs", ".js"])));

  const lanes = [
    ["swift", swiftMembers(swiftGen), (m) => swiftIsRead(m, swiftHand, swiftGen, extensionSrc)],
    ["ts", tsExports(tsGen), (m) => tsIsRead(m, tsHand, tsGen)],
  ];
  const unread = { swift: [], ts: [] };
  for (const [lane, members, isRead] of lanes) {
    const allowed = allow[lane] ?? {};
    const seen = new Set();
    for (const m of members) {
      const key = m.id in allowed ? m.id : null;
      seen.add(m.id);
      const read = isRead(m);
      if (!read) unread[lane].push(m.id);
      if (!read && !key) problems.push(`${lane}: ${m.id} has no reader (read it, stop generating it, or allowlist it in registry/readers-allowlist.json with a reason and issue)`);
      if (read && key) problems.push(`${lane}: ${m.id} has a reader now; remove it from registry/readers-allowlist.json`);
    }
    for (const id of Object.keys(allowed)) {
      if (!seen.has(id)) problems.push(`${lane}: registry/readers-allowlist.json lists ${id}, which is no longer generated; remove it`);
      const e = allowed[id];
      if (!e?.reason || !e?.issue) problems.push(`${lane}: registry/readers-allowlist.json entry ${id} needs "reason" and "issue"`);
    }
  }
  return { problems, unread };
}

// `node scripts/registry-readers.mjs` prints the unread members (for triage).
if (import.meta.url === `file://${process.argv[1]}`) {
  const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
  const { problems, unread } = checkReaders(repo);
  console.log(JSON.stringify(unread, null, 2));
  if (problems.length) {
    console.error(problems.join("\n"));
    process.exit(1);
  }
}
