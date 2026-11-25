import { registerHooks } from "node:module";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve } from "node:path";

// Test-only loader hooks so Node can import the real Durable Object and its
// relative `.js` ESM specifiers directly from TypeScript source without a build
// step or extra devDependencies.
let hooksInstalled = false;

export function installWorkerTestHooks(): void {
  if (hooksInstalled) return;
  hooksInstalled = true;

  if (!("WebSocketRequestResponsePair" in globalThis)) {
    (globalThis as Record<string, unknown>).WebSocketRequestResponsePair = class {
      request: string;
      response: string;
      constructor(request: string, response: string) {
        this.request = request;
        this.response = response;
      }
    };
  }

  registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === "cloudflare:workers") {
        return { url: "virtual:cloudflare-workers", shortCircuit: true };
      }
      if (specifier === "qrcode-generator") {
        try {
          return nextResolve(specifier, context);
        } catch {
          return { url: "virtual:qrcode-generator", shortCircuit: true };
        }
      }
      if ((specifier.startsWith("./") || specifier.startsWith("../")) && specifier.endsWith(".js") && context.parentURL) {
        const dir = dirname(fileURLToPath(context.parentURL));
        const tsCandidate = resolve(dir, specifier.slice(0, -3) + ".ts");
        if (existsSync(tsCandidate)) {
          return { url: pathToFileURL(tsCandidate).href, shortCircuit: true };
        }
      }
      return nextResolve(specifier, context);
    },
    load(url, context, nextLoad) {
      if (url === "virtual:qrcode-generator") {
        return {
          format: "module",
          shortCircuit: true,
          source: `export default function qrcode() { return { addData() {}, make() {}, getModuleCount() { return 0; }, isDark() { return false; } }; }`,
        };
      }
      if (url === "virtual:cloudflare-workers") {
        return {
          format: "module",
          shortCircuit: true,
          source: `
            export class DurableObject {
              constructor(ctx, env) {
                this.ctx = ctx;
                this.env = env;
              }
            }
            export class WebSocketRequestResponsePair {
              constructor(request, response) {
                this.request = request;
                this.response = response;
              }
            }
          `,
        };
      }
      if (url.startsWith("file:") && url.endsWith(".md")) {
        const text = readFileSync(fileURLToPath(url), "utf8");
        return {
          format: "module",
          shortCircuit: true,
          source: `export default ${JSON.stringify(text)};`,
        };
      }
      if (url.startsWith("file:") && url.endsWith(".json")) {
        const text = readFileSync(fileURLToPath(url), "utf8");
        return {
          format: "module",
          shortCircuit: true,
          source: `export default ${text};`,
        };
      }
      return nextLoad(url, context);
    },
  });
}

/// Minimal `SqlStorage` implementation backed by Node's built-in `node:sqlite`.
/// Implements the subset `TaskStore` uses (`exec` → `toArray`, `one`, iterator,
/// `rowsWritten`, plus multi-statement DDL).
function makeSqlStorage(db: DatabaseSync) {
  return {
    exec<T = Record<string, unknown>>(query: string, ...bindings: unknown[]) {
      const trimmed = query.trim();
      // Multi-statement DDL (migrateTables) has no bindings.
      if (bindings.length === 0 && trimmed.includes(";") && trimmed.indexOf(";") < trimmed.length - 1) {
        db.exec(trimmed);
        const empty: T[] = [];
        return {
          toArray: () => empty,
          one: () => { throw new Error("no rows"); },
          rowsWritten: 0,
          [Symbol.iterator]: () => empty[Symbol.iterator](),
        };
      }
      const stmt = db.prepare(trimmed);
      const args = bindings as SQLInputValue[];
      const isSelect = /^(SELECT|PRAGMA|WITH)\b/i.test(trimmed);
      if (isSelect) {
        const rows = stmt.all(...args) as T[];
        return {
          toArray: () => rows,
          one: () => {
            if (rows.length !== 1) throw new Error(`expected 1 row, got ${rows.length}`);
            return rows[0];
          },
          rowsWritten: 0,
          [Symbol.iterator]: () => rows[Symbol.iterator](),
        };
      }
      const info = stmt.run(...args);
      const empty: T[] = [];
      return {
        toArray: () => empty,
        one: () => { throw new Error("no rows"); },
        rowsWritten: Number(info.changes),
        [Symbol.iterator]: () => empty[Symbol.iterator](),
      };
    },
  };
}

/// Creates a real `TaskStore` instance backed by an in-memory SQLite database.
/// Pass `existing` to open a second store on the same database, the way a
/// Durable Object restarts on its stored data (runs migrations again).
export async function createTestTaskStore(existing?: DatabaseSync, envOverrides: Record<string, unknown> = {}) {
  installWorkerTestHooks();
  const { TaskStore } = await import("../src/store/TaskStore.ts");
  const db = existing ?? new DatabaseSync(":memory:");
  let alarm: number | null = null;
  let inTx = false;
  const pendingWaitUntil: Promise<unknown>[] = [];
  const sockets: Array<{ ws: WebSocket; tags: string[] }> = [];

  const ctx = {
    storage: {
      sql: makeSqlStorage(db),
      transactionSync<T>(fn: () => T): T {
        if (inTx) return fn();
        inTx = true;
        db.exec("BEGIN");
        try {
          const out = fn();
          db.exec("COMMIT");
          return out;
        } catch (err) {
          db.exec("ROLLBACK");
          throw err;
        } finally {
          inTx = false;
        }
      },
      async getAlarm() { return alarm; },
      async setAlarm(ts: number) { alarm = ts; },
      async deleteAlarm() { alarm = null; },
      async deleteAll() {
        const tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").all() as { name: string }[];
        for (const { name } of tables) db.exec(`DROP TABLE "${name}"`);
      },
    },
    blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T> {
      return fn();
    },
    waitUntil(p: Promise<unknown>) {
      pendingWaitUntil.push(Promise.resolve(p));
    },
    setWebSocketAutoResponse() {},
    acceptWebSocket(ws: WebSocket, tags?: string[]) {
      sockets.push({ ws, tags: tags ?? [] });
    },
    getWebSockets(tag?: string) {
      if (!tag) return sockets.map((s) => s.ws);
      return sockets.filter((s) => s.tags.includes(tag)).map((s) => s.ws);
    },
  };

  async function flushWaitUntil(): Promise<void> {
    while (pendingWaitUntil.length > 0) {
      const batch = pendingWaitUntil.splice(0, pendingWaitUntil.length);
      await Promise.allSettled(batch);
    }
  }

  // Expose an RPC-like async proxy matching `StoreRpc` as well as direct calls.
  const store = new TaskStore(ctx as never, envOverrides as never);
  return { store, db, flushWaitUntil, sockets };
}

/// Gives `sid` a live app session, so an access token a test signs for it is
/// accepted (every request asks the store, ADR 0040).
export function ensureSession(store: Awaited<ReturnType<typeof createTestTaskStore>>["store"], sid: string): void {
  if (!store.authorizeSession(sid, null)) store.createSession(`h-${sid}`, Date.now() + 86_400_000, sid);
}

/// Creates a real `AccountStore` instance backed by an in-memory SQLite
/// database. Pass `existing` to simulate a Durable Object restart on stored data.
export async function createTestAccountStore(existing?: DatabaseSync) {
  installWorkerTestHooks();
  const { AccountStore } = await import("../src/store/AccountStore.ts");
  const db = existing ?? new DatabaseSync(":memory:");
  let inTx = false;

  const ctx = {
    storage: {
      sql: makeSqlStorage(db),
      transactionSync<T>(fn: () => T): T {
        if (inTx) return fn();
        inTx = true;
        db.exec("BEGIN");
        try {
          const out = fn();
          db.exec("COMMIT");
          return out;
        } catch (err) {
          db.exec("ROLLBACK");
          throw err;
        } finally {
          inTx = false;
        }
      },
    },
    blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T> {
      return fn();
    },
  };

  const store = new AccountStore(ctx as never, {} as never);
  return { store, db };
}

/// Creates a real `PairingStore` instance backed by an in-memory KV map so
/// tests exercise the actual Durable Object methods and alarm/expiry cleanup.
export async function createTestPairingStore() {
  installWorkerTestHooks();
  const { PairingStore } = await import("../src/shadow/PairingStore.ts");
  const data = new Map<string, unknown>();
  let alarm: number | null = null;

  const ctx = {
    storage: {
      async get<T>(key: string): Promise<T | undefined> {
        return data.get(key) as T | undefined;
      },
      async put(key: string, value: unknown): Promise<void> {
        data.set(key, value);
      },
      async deleteAll(): Promise<void> {
        data.clear();
      },
      async getAlarm(): Promise<number | null> {
        return alarm;
      },
      async setAlarm(ts: number): Promise<void> {
        alarm = ts;
      },
      async deleteAlarm(): Promise<void> {
        alarm = null;
      },
    },
  };

  const store = new PairingStore(ctx as never, {} as never);
  return {
    store,
    data,
    getAlarm: () => alarm,
  };
}

/// Creates a real `ProjectStore` (a shared project) on an in-memory database.
export async function createTestProjectStore(env: Record<string, unknown>) {
  installWorkerTestHooks();
  const { ProjectStore } = await import("../src/store/ProjectStore.ts");
  const db = new DatabaseSync(":memory:");
  const pending: Promise<unknown>[] = [];
  let inTx = false;
  let alarm: number | null = null;
  const ctx = {
    storage: {
      sql: makeSqlStorage(db),
      transactionSync<T>(fn: () => T): T {
        if (inTx) return fn();
        inTx = true;
        db.exec("BEGIN");
        try {
          const out = fn();
          db.exec("COMMIT");
          return out;
        } catch (err) {
          db.exec("ROLLBACK");
          throw err;
        } finally {
          inTx = false;
        }
      },
      async getAlarm() { return alarm; },
      async setAlarm(ts: number) { alarm = ts; },
    },
    waitUntil(p: Promise<unknown>) { pending.push(Promise.resolve(p)); },
  };
  const store = new ProjectStore(ctx as never, env as never);
  async function flushWaitUntil(): Promise<void> {
    while (pending.length > 0) await Promise.allSettled(pending.splice(0, pending.length));
  }
  return { store, flushWaitUntil, alarmAt: () => alarm };
}
