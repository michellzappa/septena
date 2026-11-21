#!/usr/bin/env node
// Copies Septena's data from the old Cloudflare account to the new one
// (docs/CLOUDFLARE_ACCOUNT_MOVE.md, ADR 0018). Drives `wrangler` for KV and
// R2 and the backend's /v1/admin/copy routes for the per-user TaskStores.
//
//   node scripts/account-move.mjs users
//   node scripts/account-move.mjs kv
//   node scripts/account-move.mjs stores [--suffix _rehearsal] [--resume]
//   node scripts/account-move.mjs r2 [--suffix _rehearsal]
//
// --suffix writes each user into "<userId><suffix>" on the new account, so a
// rehearsal never fills the store a real user will be imported into.
// ADMIN_TOKEN is read from the macOS keychain (service septena-cf/ADMIN_TOKEN)
// and never printed. Wrangler runs in an empty folder: it takes account_id
// from a wrangler.toml over CLOUDFLARE_ACCOUNT_ID.

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const OLD = { account: "50894cc73fc5188e3efb7eb9819c54e9", api: "https://api.septena.app" };
const NEW = { account: "1d2ed1f57832a528b7f197b5a9d68d39", api: "https://septena-mcp-gateway.septena-mcp-gateway.workers.dev" };

const KV = [
  ["STATE", "2ad8a91b6ba54e579d843f5bdf215bf4", "4066d642849946a5bcdb5523b52a35d5"],
  ["TOKENS", "d89bf617d013488096dd64be9f826d7e", "1b8f0af54763424190a01dcb85109852"],
  ["CLIENTS", "8d9200723c194a03ac3e1482f24f173d", "c6550511896e493aa5abd8685e9dd6a1"],
  ["community ATTEST", "10bb35645a93423591188c0ef8160b95", "1d3f2d0925804c01bb23b2d56e71e4d3"],
  ["community CHALLENGES", "a473762726b74e34aa07226a82aca718", "14504cb083914ff58cb7224649addb09"],
  ["community RL", "80b89a7a4b2a4102b6f4393c50496afc", "4b24aa6a1dbf4b568a69b204286a1248"],
];
const BUCKET = "septena-attachments";

const work = mkdtempSync(join(tmpdir(), "septena-move-"));
const args = process.argv.slice(2);
const cmd = args[0];
const suffix = args.includes("--suffix") ? args[args.indexOf("--suffix") + 1] : "";

function wrangler(account, wargs, opts = {}) {
  return execFileSync("npx", ["wrangler", ...wargs], {
    cwd: work,
    env: { ...process.env, CLOUDFLARE_ACCOUNT_ID: account },
    encoding: opts.binary ? undefined : "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 256 * 1024 * 1024,
  });
}

function json(text) {
  const start = text.search(/[[{]/);
  return JSON.parse(text.slice(start));
}

const adminToken = () =>
  execFileSync("security", ["find-generic-password", "-s", "septena-cf/ADMIN_TOKEN", "-w"], { encoding: "utf8" }).trim();

async function admin(base, path, init = {}) {
  const res = await fetch(base + path, {
    ...init,
    headers: { "X-Admin-Token": adminToken(), "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`${init.method ?? "GET"} ${path} -> ${res.status} ${body.slice(0, 200)}`);
  return JSON.parse(body);
}

function listKeys(account, id) {
  return json(wrangler(account, ["kv", "key", "list", "--namespace-id", id, "--remote"]));
}

// ---- users: every user with a live app session ----
function users() {
  const tokens = KV.find(([n]) => n === "TOKENS")[1];
  const keys = listKeys(OLD.account, tokens).filter((k) => k.name.startsWith("api-refresh:"));
  if (!keys.length) return [];
  const file = join(work, "user-keys.json");
  writeFileSync(file, JSON.stringify(keys.map((k) => k.name)));
  const got = json(wrangler(OLD.account, ["kv", "bulk", "get", file, "--namespace-id", tokens, "--remote"]));
  const ids = new Set();
  for (const v of Object.values(got)) {
    const raw = typeof v === "string" ? v : v?.value;
    if (typeof raw === "string" && /^u_[A-Za-z0-9_-]{20,64}$/.test(raw.trim())) ids.add(raw.trim());
  }
  return [...ids].sort();
}

// ---- kv: copy every key with its expiration ----
function copyKv() {
  const now = Math.floor(Date.now() / 1000);
  for (const [name, oldId, newId] of KV) {
    const keys = listKeys(OLD.account, oldId).filter((k) => !k.expiration || k.expiration > now + 60);
    if (!keys.length) { console.log(`kv ${name}: 0 keys`); continue; }
    const out = [];
    for (let i = 0; i < keys.length; i += 100) {
      const chunk = keys.slice(i, i + 100);
      const file = join(work, `get-${i}.json`);
      writeFileSync(file, JSON.stringify(chunk.map((k) => k.name)));
      const got = json(wrangler(OLD.account, ["kv", "bulk", "get", file, "--namespace-id", oldId, "--remote"]));
      for (const k of chunk) {
        const v = got[k.name];
        const value = typeof v === "string" ? v : v?.value;
        if (typeof value !== "string") throw new Error(`kv ${name}: no text value for a key`);
        const row = { key: k.name, value };
        if (k.expiration) row.expiration = k.expiration;
        if (k.metadata) row.metadata = k.metadata;
        out.push(row);
      }
    }
    const file = join(work, `put-${name.replace(" ", "-")}.json`);
    writeFileSync(file, JSON.stringify(out));
    wrangler(NEW.account, ["kv", "bulk", "put", file, "--namespace-id", newId, "--remote"]);
    const after = listKeys(NEW.account, newId).length;
    console.log(`kv ${name}: ${out.length} copied, new namespace holds ${after}`);
  }
}

// ---- stores: copy each user's TaskStore table by table ----
async function copyStores() {
  const ids = users();
  console.log(`stores: ${ids.length} users`);
  for (const id of ids) {
    const target = id + suffix;
    const before = (await admin(OLD.api, `/v1/admin/copy/${id}/snapshot`)).tables;
    // --resume continues an import that stopped partway: copyImport needs the
    // import flag, which an earlier begin left set, and INSERT OR REPLACE is
    // safe to repeat.
    if (!args.includes("--resume")) await admin(NEW.api, `/v1/admin/copy/${target}/import/begin`, { method: "POST" });
    for (const table of Object.keys(before)) {
      let after = 0;
      for (;;) {
        const page = await admin(OLD.api, `/v1/admin/copy/${id}/export?table=${table}&after=${after}&limit=500`);
        if (page.rows.length) {
          await admin(NEW.api, `/v1/admin/copy/${target}/import`, { method: "POST", body: JSON.stringify({ table, rows: page.rows }) });
        }
        if (page.next === null) break;
        after = page.next;
      }
    }
    const result = (await admin(NEW.api, `/v1/admin/copy/${target}/import/end`, { method: "POST" })).tables;
    const diff = Object.keys(before).filter((t) => before[t] !== result[t]);
    console.log(`store ${id.slice(0, 8)}…${suffix}: ${diff.length ? "MISMATCH " + diff.map((t) => `${t} ${before[t]}→${result[t]}`).join(", ") : "match"} (${Object.entries(before).map(([t, n]) => `${t}=${n}`).join(" ")})`);
  }
}

// ---- r2: copy each user's live attachments ----
async function copyR2() {
  const ids = users();
  for (const id of ids) {
    let after = 0;
    let copied = 0;
    for (;;) {
      const page = await admin(OLD.api, `/v1/admin/copy/${id}/export?table=attachments&after=${after}&limit=500`);
      for (const row of page.rows) {
        if (row.deletedAt || !row.uploadedAt) continue;
        const from = `${BUCKET}/u/${id}/att/${row.id}`;
        const to = `${BUCKET}/u/${id + suffix}/att/${row.id}`;
        const file = join(work, "obj.bin");
        try {
          wrangler(OLD.account, ["r2", "object", "get", from, "--file", file, "--remote"]);
        } catch {
          console.log(`r2 ${id.slice(0, 8)}…: object missing for one attachment row (metadata without bytes)`);
          continue;
        }
        wrangler(NEW.account, ["r2", "object", "put", to, "--file", file, "--remote"]);
        if (readFileSync(file).length !== Number(row.byteCount)) {
          throw new Error(`r2 size mismatch for an attachment of ${id.slice(0, 8)}…`);
        }
        copied++;
      }
      if (page.next === null) break;
      after = page.next;
    }
    console.log(`r2 ${id.slice(0, 8)}…${suffix}: ${copied} objects copied`);
  }
}

if (cmd === "users") console.log(users().map((id) => id.slice(0, 8) + "…").join("\n") || "(none)");
else if (cmd === "kv") copyKv();
else if (cmd === "stores") await copyStores();
else if (cmd === "r2") await copyR2();
else {
  console.error("usage: account-move.mjs users | kv | stores [--suffix S] | r2 [--suffix S]");
  process.exit(2);
}
