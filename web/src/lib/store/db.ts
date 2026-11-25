import type {
  AreaRow,
  AttachmentRow,
  ChecklistItemRow,
  ConvoRow,
  OutboxOp,
  ProjectRow,
  StoreSnapshot,
  SyncedEntity,
  TagRow,
  TaskRefRow,
  TaskRow,
  TurnRow,
} from "../types";

// IndexedDB local store for the web client (docs/WEB_CLIENT_SPEC.md §6, WB2).
// Holds every synced entity, append-only conversation turns, sync cursor, and
// the persistent coalesced outbox.

const DB_NAME = "septena-web-v1";
const DB_VERSION = 2;

const STORES = {
  tasks: "tasks",
  areas: "areas",
  projects: "projects",
  checklistItems: "checklistItems",
  tags: "tags",
  taskRefs: "taskRefs",
  convos: "convos",
  turns: "turns",
  attachments: "attachments",
  settings: "settings",
  outbox: "outbox",
  meta: "meta",
} as const;

type StoreName = (typeof STORES)[keyof typeof STORES];

export function storeNameForEntity(entity: SyncedEntity | "turn"): StoreName {
  switch (entity) {
    case "task": return STORES.tasks;
    case "area": return STORES.areas;
    case "project": return STORES.projects;
    case "checklistItem": return STORES.checklistItems;
    case "tag": return STORES.tags;
    case "taskRef": return STORES.taskRefs;
    case "convo": return STORES.convos;
    case "turn": return STORES.turns;
    case "attachment": return STORES.attachments;
    case "setting": return STORES.settings;
  }
}

export function turnSyntheticId(taskId: string, seq: number): string {
  return `${taskId}:${seq}`;
}

export function coalesceOutboxOp(existing: OutboxOp[], incoming: OutboxOp): OutboxOp[] {
  const next = [...existing];
  if (incoming.op === "appendTurn") {
    // Conversation turns are append-only and never coalesce.
    next.push(incoming);
    return next;
  }

  if (incoming.op === "delete") {
    const filtered = next.filter(
      (o) => o.op === "appendTurn" || !(o.entity === incoming.entity && o.id === incoming.id),
    );
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
    if (op.op === "appendTurn") continue;
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
      const createIfMissing = (name: string, keyPath: string) => {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name, { keyPath });
      };
      createIfMissing(STORES.tasks, "id");
      createIfMissing(STORES.areas, "id");
      createIfMissing(STORES.projects, "id");
      createIfMissing(STORES.checklistItems, "id");
      createIfMissing(STORES.tags, "id");
      createIfMissing(STORES.taskRefs, "id");
      createIfMissing(STORES.convos, "id");
      createIfMissing(STORES.turns, "id");
      createIfMissing(STORES.attachments, "id");
      createIfMissing(STORES.settings, "id");
      createIfMissing(STORES.outbox, "clientOpId");
      createIfMissing(STORES.meta, "key");
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("Failed to open IndexedDB"));
  });
}

export interface LocalMutation {
  entity: SyncedEntity | "turn";
  action: "put" | "delete";
  id: string;
  row?: Record<string, unknown>;
}

const ALL_DATA_STORES: StoreName[] = [
  STORES.tasks,
  STORES.areas,
  STORES.projects,
  STORES.checklistItems,
  STORES.tags,
  STORES.taskRefs,
  STORES.convos,
  STORES.turns,
  STORES.attachments,
  STORES.settings,
];

export class LocalStore {
  private dbPromise: Promise<IDBDatabase> | null = null;

  private db(): Promise<IDBDatabase> {
    if (!this.dbPromise) this.dbPromise = openDb();
    return this.dbPromise;
  }

  async loadSnapshot(): Promise<StoreSnapshot> {
    const db = await this.db();
    const tx = db.transaction([...ALL_DATA_STORES, STORES.outbox, STORES.meta], "readonly");
    const [
      tasks,
      areas,
      projects,
      checklistItems,
      tags,
      taskRefs,
      convos,
      turns,
      attachments,
      settingsRows,
      outbox,
      metaRows,
    ] = await Promise.all([
      reqPromise<TaskRow[]>(tx.objectStore(STORES.tasks).getAll()),
      reqPromise<AreaRow[]>(tx.objectStore(STORES.areas).getAll()),
      reqPromise<ProjectRow[]>(tx.objectStore(STORES.projects).getAll()),
      reqPromise<ChecklistItemRow[]>(tx.objectStore(STORES.checklistItems).getAll()),
      reqPromise<TagRow[]>(tx.objectStore(STORES.tags).getAll()),
      reqPromise<TaskRefRow[]>(tx.objectStore(STORES.taskRefs).getAll()),
      reqPromise<ConvoRow[]>(tx.objectStore(STORES.convos).getAll()),
      reqPromise<TurnRow[]>(tx.objectStore(STORES.turns).getAll()),
      reqPromise<AttachmentRow[]>(tx.objectStore(STORES.attachments).getAll()),
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
      checklistItems,
      tags,
      taskRefs,
      convos,
      turns,
      attachments,
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
    const tx = db.transaction([...ALL_DATA_STORES, STORES.meta], "readwrite");
    for (const s of ALL_DATA_STORES) tx.objectStore(s).clear();
    tx.objectStore(STORES.meta).put({ key: "cursor", value: 0 });
    await txDone(tx);
  }

  async commitLocalAndQueue(mutations: LocalMutation[], ops: OutboxOp[]): Promise<void> {
    const db = await this.db();
    const touched = new Set<StoreName>([STORES.outbox]);
    for (const m of mutations) touched.add(storeNameForEntity(m.entity));

    const tx = db.transaction(Array.from(touched), "readwrite");
    for (const m of mutations) {
      const store = tx.objectStore(storeNameForEntity(m.entity));
      if (m.action === "delete") {
        store.delete(m.id);
      } else if (m.row) {
        store.put(m.row);
      }
    }

    if (ops.length) {
      const outboxStore = tx.objectStore(STORES.outbox);
      let current = await reqPromise<OutboxOp[]>(outboxStore.getAll());
      current.sort((a, b) => a.queuedAt - b.queuedAt);
      for (const op of ops) {
        current = coalesceOutboxOp(current, op);
      }
      outboxStore.clear();
      for (const item of current) outboxStore.put(item);
    }

    await txDone(tx);
  }

  async putLocalAndQueue(
    entity: SyncedEntity,
    row: Record<string, unknown> | null,
    op: OutboxOp,
  ): Promise<void> {
    const mutation: LocalMutation = row
      ? { entity, action: "put", id: String(row.id), row }
      : { entity, action: "delete", id: op.op === "appendTurn" ? op.taskId : op.id };
    await this.commitLocalAndQueue([mutation], [op]);
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
    mutations: LocalMutation[],
    nextSince: number,
    syncedAt: number,
  ): Promise<void> {
    const db = await this.db();
    const tx = db.transaction([...ALL_DATA_STORES, STORES.meta], "readwrite");

    for (const m of mutations) {
      const target = tx.objectStore(storeNameForEntity(m.entity));
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
