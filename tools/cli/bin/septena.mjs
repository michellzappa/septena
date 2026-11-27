#!/usr/bin/env node
// septena: a thin terminal client for Septena tasks (#653).
//
// It is an MCP client: every command is one `tools/call` on
// https://api.septena.app/mcp with an agent key (#86). So every write follows
// the same server rules as any agent (Stop, Pause, claims, the duplicate
// rule), and the CLI holds no task logic of its own. When the REST API (#90)
// ships, `call` moves to it and the commands stay.
//
// No dependencies beyond Node 20.

import { execFileSync, spawnSync } from "node:child_process";
import { createInterface } from "node:readline";
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const VERSION = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
const API = (process.env.SEPTENA_API ?? "https://api.septena.app").replace(/\/+$/, "");
const KEYCHAIN_SERVICE = "app.septena.cli";
const KEYCHAIN_ACCOUNT = "agent-key";
const VIEWS = ["today", "inbox", "review", "upcoming", "anytime", "completed", "faded"];

const HELP = `septena ${VERSION}: your Septena tasks from the terminal

  septena login                 store an agent key (create one in Septena:
                                Settings > AI & Agents > Agents > New Agent Key)
  septena logout                remove the stored key
  septena add TITLE [options]   add a task (TITLE "-" reads one task per stdin line)
      --today                   put it on Today
      --when YYYY-MM-DD         schedule it
      --deadline YYYY-MM-DD     set a deadline
      --project NAME            file it in a project
      --notes TEXT              notes ("-" reads stdin)
      --no-ref                  do not attach the git repo and branch
  septena today | inbox         list a view
  septena ls [VIEW]             list a view: ${VIEWS.join(", ")}
  septena search WORDS          find tasks
  septena done ID               complete a task
  septena --json ...            print the server's JSON (reads)

  SEPTENA_KEY overrides the stored key (for CI). Inside a git worktree,
  add puts the repository and branch on the task as a reference.`;

// ---- key storage: the OS keychain, never a plain dotfile ----

function keychain() {
  if (process.platform === "darwin") {
    return {
      get: () => run("security", ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"]),
      set: (key) => {
        run("security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT]);
        // -w last without a value would prompt; pass it as an argument. The
        // key is visible to `ps` for the moment the command runs.
        return run("security", ["add-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w", key]) !== null;
      },
      remove: () => run("security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT]) !== null,
    };
  }
  if (process.platform === "linux") {
    const attrs = ["service", KEYCHAIN_SERVICE, "account", KEYCHAIN_ACCOUNT];
    return {
      get: () => run("secret-tool", ["lookup", ...attrs]),
      set: (key) => spawnSync("secret-tool", ["store", "--label=Septena agent key", ...attrs], { input: key }).status === 0,
      remove: () => run("secret-tool", ["clear", ...attrs]) !== null,
    };
  }
  return null;
}

function run(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

function storedKey() {
  if (process.env.SEPTENA_KEY) return process.env.SEPTENA_KEY.trim();
  return keychain()?.get() || null;
}

// ---- the call ----

async function call(name, args = {}) {
  const key = storedKey();
  if (!key) fail("No agent key. Run `septena login`, or set SEPTENA_KEY.");
  let res;
  try {
    res = await fetch(`${API}/mcp`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        "User-Agent": `septena-cli/${VERSION}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    });
  } catch (e) {
    fail(`Septena did not answer: ${e.message}`);
  }
  if (res.status === 401) fail("Septena refused the key. It was disconnected, or it is wrong. Run `septena login` with a new key.");
  const text = await res.text();
  const body = parseRpc(text);
  if (!res.ok && !body) fail(`Septena answered HTTP ${res.status}.`);
  if (body?.error) fail(body.error.message ?? "Septena refused the call.");
  const result = body?.result;
  const out = result?.content?.find((c) => c.type === "text")?.text ?? "";
  if (result?.isError) fail(out || "Septena refused the call.");
  try {
    return JSON.parse(out);
  } catch {
    return out;
  }
}

/// A JSON reply, or the last `data:` event of an event stream.
function parseRpc(text) {
  try {
    return JSON.parse(text);
  } catch {
    const data = text.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).pop();
    try {
      return data ? JSON.parse(data) : null;
    } catch {
      return null;
    }
  }
}

function fail(message) {
  process.stderr.write(`septena: ${message}\n`);
  process.exit(1);
}

// ---- arguments ----

function parse(argv) {
  const opts = { json: false, ref: true, positional: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) fail(`${a} needs a value.`);
      return argv[++i];
    };
    switch (a) {
      case "--json": opts.json = true; break;
      case "--today": opts.today = true; break;
      case "--when": opts.when = date(value(), a); break;
      case "--deadline": opts.deadline = date(value(), a); break;
      case "--project": opts.project = value(); break;
      case "--notes": opts.notes = value(); break;
      case "--no-ref": opts.ref = false; break;
      case "-h": case "--help": opts.help = true; break;
      case "-v": case "--version": opts.version = true; break;
      default:
        if (a.startsWith("--")) fail(`Unknown option ${a}. Run \`septena --help\`.`);
        opts.positional.push(a);
    }
  }
  return opts;
}

function date(v, flag) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) fail(`${flag} takes a date as YYYY-MM-DD.`);
  return v;
}

async function readStdin() {
  if (process.stdin.isTTY) return "";
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

// ---- git reference (ADR 0031): the CLI attaches it, Septena connects to nothing (ADR 0038) ----

function gitRef() {
  const remote = run("git", ["config", "--get", "remote.origin.url"]);
  if (!remote) return null;
  const branch = run("git", ["rev-parse", "--abbrev-ref", "HEAD"]);
  const web = remoteToWeb(remote);
  if (!web) return null;
  const repo = new URL(web).pathname.replace(/^\/+/, "");
  const url = branch && branch !== "HEAD" ? `${web}/tree/${branch.split("/").map(encodeURIComponent).join("/")}` : web;
  return {
    key: url,
    role: "about",
    snapshot: { title: branch && branch !== "HEAD" ? `${repo} (${branch})` : repo, subtitle: repo, url },
  };
}

/// git@host:owner/repo.git and https://host/owner/repo.git → https://host/owner/repo.
/// Credentials in an https remote are dropped.
function remoteToWeb(remote) {
  const scp = remote.match(/^[\w.-]+@([\w.-]+):(.+?)(?:\.git)?\/?$/);
  if (scp) return `https://${scp[1]}/${scp[2]}`;
  try {
    const u = new URL(remote.replace(/^ssh:\/\/[^@]+@/, "https://").replace(/^git:\/\//, "https://"));
    if (!/^https?:$/.test(u.protocol)) return null;
    return `https://${u.host}${u.pathname.replace(/\.git\/?$/, "").replace(/\/+$/, "")}`;
  } catch {
    return null;
  }
}

// ---- output ----

function printTasks(result, json) {
  if (json) return console.log(JSON.stringify(result, null, 2));
  const tasks = result?.tasks ?? [];
  if (tasks.length === 0) return console.log("Nothing here.");
  for (const t of tasks) {
    const dates = [t.scheduled && `when ${t.scheduled}`, t.deadline && `due ${t.deadline}`].filter(Boolean).join(", ");
    console.log(`${t.id}  ${t.title}${dates ? `  (${dates})` : ""}`);
  }
  if (result.truncated) console.log(`… ${result.total - tasks.length} more`);
}

// ---- commands ----

async function login() {
  const kc = keychain();
  if (!kc) fail("This system has no keychain the CLI can use. Set SEPTENA_KEY instead.");
  process.stdout.write("Paste the agent key (Septena > Settings > AI & Agents > Agents > New Agent Key): ");
  const rl = createInterface({ input: process.stdin, terminal: false });
  const key = (await new Promise((resolve) => rl.once("line", resolve)))?.trim() ?? "";
  rl.close();
  if (!key.startsWith("sk1.")) fail("That is not an agent key. A key starts with sk1.");
  if (!kc.set(key)) fail("The keychain refused the key.");
  process.env.SEPTENA_KEY = key;
  await call("tasks_list", { view: "today", limit: 1 });
  console.log("Signed in. The key is in your keychain.");
}

async function projectId(name) {
  const { projects = [] } = await call("tasks_list_projects", { status: "active", limit: 500 });
  const lower = name.toLowerCase();
  const match = projects.find((p) => p.title?.toLowerCase() === lower)
    ?? projects.filter((p) => p.title?.toLowerCase().includes(lower)).at(0);
  if (!match) fail(`No active project matches "${name}".`);
  return match.id;
}

async function add(opts) {
  let titles = opts.positional.slice(1);
  if (titles.length === 1 && titles[0] === "-") {
    titles = (await readStdin()).split("\n").map((l) => l.trim()).filter(Boolean);
  } else {
    titles = [titles.join(" ").trim()].filter(Boolean);
  }
  if (titles.length === 0) fail("add needs a title.");
  const notes = opts.notes === "-" ? (await readStdin()).trim() : opts.notes;
  const project = opts.project ? await projectId(opts.project) : undefined;
  const ref = opts.ref ? gitRef() : null;
  for (const title of titles) {
    const args = {
      title,
      origin: "user_request",
      ...(opts.today ? { today: true } : {}),
      ...(opts.when ? { scheduled: opts.when } : {}),
      ...(opts.deadline ? { deadline: opts.deadline } : {}),
      ...(project ? { project } : {}),
      ...(notes ? { notes } : {}),
      ...(ref ? { refs: [ref] } : {}),
    };
    const res = await call("tasks_create", args);
    if (opts.json) console.log(JSON.stringify(res));
    else console.log(`${res.id ?? ""}  ${title}${res.placement && res.placement !== "committed" ? `  (${res.placement})` : ""}`);
  }
}

async function main() {
  const opts = parse(process.argv.slice(2));
  const [cmd, ...rest] = opts.positional;
  if (opts.version) return console.log(VERSION);
  if (opts.help || !cmd) return console.log(HELP);
  switch (cmd) {
    case "login": return login();
    case "logout": {
      if (!keychain()?.remove()) fail("No stored key.");
      return console.log("Removed the key from your keychain. To stop the key itself, disconnect it in Septena.");
    }
    case "add": return add(opts);
    case "today": case "inbox":
      return printTasks(await call("tasks_list", { view: cmd, limit: 100 }), opts.json);
    case "ls": {
      const view = rest[0] ?? "today";
      if (!VIEWS.includes(view)) fail(`Unknown view ${view}. Views: ${VIEWS.join(", ")}.`);
      return printTasks(await call("tasks_list", { view, limit: 100 }), opts.json);
    }
    case "search": {
      if (!rest.length) fail("search needs words.");
      return printTasks(await call("tasks_search", { query: rest.join(" "), limit: 50 }), opts.json);
    }
    case "done": {
      if (rest.length !== 1) fail("done takes one task id.");
      const res = await call("tasks_complete", { id: rest[0] });
      return opts.json ? console.log(JSON.stringify(res)) : console.log(res.alreadyComplete ? `Already done: ${rest[0]}` : `Done: ${rest[0]}`);
    }
    default:
      fail(`Unknown command ${cmd}. Run \`septena --help\`.`);
  }
}

export { remoteToWeb, parseRpc };

// Run as a command, not when a test imports this file. npm installs the
// command as a link, so compare real paths.
const invoked = process.argv[1] ? realpathSync(process.argv[1]) : "";
if (invoked === realpathSync(fileURLToPath(import.meta.url))) await main();
