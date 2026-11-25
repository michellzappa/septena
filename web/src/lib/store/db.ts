import type { AreaRow, OutboxOp, ProjectRow, StoreSnapshot, TaskRow } from "../types";

// IndexedDB local store for the web client (docs/WEB_CLIENT_SPEC.md §6).
// Holds pulled rows, the sync cursor, and the persistent coalesced outbox.
// Also exports a pure outbox coalescing helper so tests verify offline queue logic in Node.

const DB_NAME = "septena-web-v1";
const DB_VERSION = 1;

const STORES = {
  tasks: "tasks",
  areas: "areas",
  projects: "projects",
  settings: "settings",
  outbox: "outbox",
  meta: "meta",
} as const;

export function coalesceOutboxOp(existing: OutboxOp[], incoming: OutboxOp): OutboxOp[] {
  const next = [...existing];
  if (incoming.op === "delete") {
    // Drop any earlier queued ops for the same row, then append the delete.
    const filtered = next.filter((o) => !(o.entity === incoming.entity && o.id === incoming.id));
    filtered.push(incoming);
    return filtered;
  }

  // Upsert: merge into the latest pending upsert for the same entity+id (preserving its clientOpId).
  const idx = next.findIndex(
    (o) => o.op === "upsert" && o.entity === incoming.entity && o.id === incoming.id,
  );
  if (idx !== -1) {
    const prev = next[idx];
    if (prev.op === "upsert") {
      next[idx] = {
        ...prev,
        fields: { ...prev.fields, ...incoming.fields },
        queuedAt: incoming.queuedAt,
      };
      return next;
    }
  }
  next.push(incoming);
  return next;
}

export function pendingFieldsFor(outbox: OutboxOp[], entity: string, id: string): {
  pendingFields: string[];
  pendingDelete: boolean;
} {
  const fields = new Set<string>();
  let pendingDelete = false;
  for (const op of outbox) {
    if (op.entity !== entity || op.id !== id) continue;
    if (op.op === "delete") {
      pendingDelete = true;
    } else {
      for (const k of Object.keys(op.fields)) fields.add(k);
    }
  }
  return { pendingFields: Array.from(fields), pendingDelete };
}

function reqPromise<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("IndexedDB request failed"));
  });
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("IndexedDB transaction failed"));
    tx.onabort = () => reject(tx.error ?? new Error("IndexedDB transaction aborted"));
  });
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORES.tasks)) db.createObjectStore(STORES.tasks, { keyPath: "id" });
      if (!db.objectStoreNames.contains(STORES.areas)) db.createObjectStore(STORES.areas, { keyPath: "id" });
      if (!db.objectStoreNames.contains(STORES.projects)) db.createObjectStore(STORES.projects, { keyPath: "id" });
      if (!db.objectStoreNames.contains(STORES.settings)) db.createObjectStore(STORES.settings, { keyPath: "id" });
      if (!db.objectStoreNames.contains(STORES.outbox)) db.createObjectStore(STORES.outbox, { keyPath: "clientOpId" });
      if (!db.objectStoreNames.contains(STORES.meta)) db.createObjectStore(STORES.meta, { keyPath: "key" });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("Failed to open IndexedDB"));
  });
}

export class LocalStore {
  private dbPromise: Promise<IDBDatabase> | null = null;

  private db(): Promise<IDBDatabase> {
    if (!this.dbPromise) this.dbPromise = openDb();
    return this.dbPromise;
  }

  async loadSnapshot(): Promise<StoreSnapshot> {
    const db = await this.db();
    const tx = db.transaction(
      [STORES.tasks, STORES.areas, STORES.projects, STORES.settings, STORES.outbox, STORES.meta],
      "readonly",
    );
    const [tasks, areas, projects, settingsRows, outbox, metaRows] = await Promise.all([
      reqPromise<TaskRow[]>(tx.objectStore(STORES.tasks).getAll()),
      reqPromise<AreaRow[]>(tx.objectStore(STORES.areas).getAll()),
      reqPromise<ProjectRow[]>(tx.objectStore(STORES.projects).getAll()),
      reqPromise<Array<{ id: string; value: unknown }>>(tx.objectStore(STORES.settings).getAll()),
      reqPromise<OutboxOp[]>(tx.objectStore(STORES.outbox).getAll()),
      reqPromise<Array<{ key: string; value: unknown }>>(tx.objectStore(STORES.meta).getAll()),
    ]);
    await txDone(tx);

    const meta = new Map(metaRows.map((m) => [m.key, m.value]));
    const settings: Record<string, unknown> = {};
    for (const s of settingsRows) settings[s.id] = s.value;

    outbox.sort((a, b) => a.queuedAt - b.queuedAt);

    return {
      tasks,
      areas,
      projects,
      settings,
      outbox,
      cursor: typeof meta.get("cursor") === "number" ? (meta.get("cursor") as number) : 0,
      userId: typeof meta.get("userId") === "string" ? (meta.get("userId") as string) : null,
      lastSyncedAt: typeof meta.get("lastSyncedAt") === "number" ? (meta.get("lastSyncedAt") as number) : null,
    };
  }

  async setUserId(userId: string): Promise<void> {
    const db = await this.db();
    const tx = db.transaction([STORES.meta], "readwrite");
    tx.objectStore(STORES.meta).put({ key: "userId", value: userId });
    await txDone(tx);
  }

  async resetRowsKeepOutbox(): Promise<void> {
    const db = await this.db();
    const tx = db.transaction([STORES.tasks, STORES.areas, STORES.projects, STORES.settings, STORES.meta], "readwrite");
    tx.objectStore(STORES.tasks).clear();
    tx.objectStore(STORES.areas).clear();
    tx.objectStore(STORES.projects).clear();
    tx.objectStore(STORES.settings).clear();
    tx.objectStore(STORES.meta).put({ key: "cursor", value: 0 });
    await txDone(tx);
  }

  async putLocalAndQueue(
    entity: "task" | "area" | "project" | "setting",
    row: Record<string, unknown> | null,
    op: OutboxOp,
  ): Promise<void> {
    const db = await this.db();
    const storeName =
      entity === "task"
        ? STORES.tasks
        : entity === "area"
          ? STORES.areas
          : entity === "project"
            ? STORES.projects
            : STORES.settings;

    const tx = db.transaction([storeName, STORES.outbox], "readwrite");
    const entityStore = tx.objectStore(storeName);
    const outboxStore = tx.objectStore(STORES.outbox);

    if (row) {
      entityStore.put(row);
    } else if (op.op === "delete") {
      entityStore.delete(op.id);
    }

    const existing = await reqPromise<OutboxOp[]>(outboxStore.getAll());
    const coalesced = coalesceOutboxOp(existing, op);
    outboxStore.clear();
    for (const item of coalesced) outboxStore.put(item);

    await txDone(tx);
  }

  async removeOutboxOps(clientOpIds: string[]): Promise<void> {
    if (!clientOpIds.length) return;
    const db = await this.db();
    const tx = db.transaction([STORES.outbox], "readwrite");
    const store = tx.objectStore(STORES.outbox);
    for (const id of clientOpIds) store.delete(id);
    await txDone(tx);
  }

  async applyPulledBatch(
    mutations: Array<{
      entity: "task" | "area" | "project" | "setting";
      action: "put" | "delete";
      id: string;
      row?: Record<string, unknown>;
    }>,
    nextSince: number,
    syncedAt: number,
  ): Promise<void> {
    const db = await this.db();
    const tx = db.transaction(
      [STORES.tasks, STORES.areas, STORES.projects, STORES.settings, STORES.meta],
      "readwrite",
    );

    for (const m of mutations) {
      const target =
        m.entity === "task"
          ? tx.objectStore(STORES.tasks)
          : m.entity === "area"
            ? tx.objectStore(STORES.areas)
            : m.entity === "project"
              ? tx.objectStore(STORES.projects)
              : tx.objectStore(STORES.settings);
      if (m.action === "delete") {
        target.delete(m.id);
      } else if (m.row) {
        target.put(m.row);
      }
    }

    const meta = tx.objectStore(STORES.meta);
    meta.put({ key: "cursor", value: nextSince });
    meta.put({ key: "lastSyncedAt", value: syncedAt });
    await txDone(tx);
  }

  async clearAll(): Promise<void> {
    if (this.dbPromise) {
      const db = await this.dbPromise;
      db.close();
      this.dbPromise = null;
    }
    await new Promise<void>((resolve, reject) => {
      const req = indexedDB.deleteDatabase(DB_NAME);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(req.error ?? new Error("Failed to delete IndexedDB"));
      req.onblocked = () => resolve();
    });
  }
}
