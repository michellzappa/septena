import { ApiError, SeptenaApiClient } from "../api/client";
import { applyDateAction, checkPullPage, ensureCoreReady, localTodayYMD, planPullRow } from "../core";
import { LocalStore, pendingFieldsFor } from "../store/db";
import type { NotSyncedItem, OutboxOp, StoreSnapshot, TaskRow } from "../types";

// Sync engine & mutator boundary (docs/WEB_CLIENT_SPEC.md §6, SEPTASK_BACKEND.md §6).
// - Mutators are the single write path: optimistic local IndexedDB write + queued outbox op.
// - Push drains the outbox, then pull fetches the delta and merges through the shared WASM core.
// - Works offline: writes queue in IndexedDB and drain automatically on reconnect.

export interface SyncState {
  snapshot: StoreSnapshot;
  online: boolean;
  syncing: boolean;
  liveConnected: boolean;
  lastError: string | null;
  notSynced: NotSyncedItem[];
}

function randomBase64Url(bytes: number): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  let bin = "";
  for (const b of buf) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function newTaskId(): string {
  // Compact URL-safe id matching registry/entities.json `id` pattern.
  return `w_${randomBase64Url(12)}`;
}

function newClientOpId(): string {
  return `op_${randomBase64Url(16)}`;
}

const EMPTY_SNAPSHOT: StoreSnapshot = {
  tasks: [],
  areas: [],
  projects: [],
  settings: {},
  outbox: [],
  cursor: 0,
  userId: null,
  lastSyncedAt: null,
};

export class WebSyncEngine {
  readonly api: SeptenaApiClient;
  readonly store: LocalStore;

  private state: SyncState;
  private listeners = new Set<(s: SyncState) => void>();
  private ws: WebSocket | null = null;
  private wsReconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private wsRetryMs = 2000;
  private channel: BroadcastChannel | null = null;
  private syncScheduled = false;
  private running = false;
  private stopped = false;

  constructor(api: SeptenaApiClient, store = new LocalStore()) {
    this.api = api;
    this.store = store;
    this.state = {
      snapshot: EMPTY_SNAPSHOT,
      online: typeof navigator === "undefined" ? true : navigator.onLine,
      syncing: false,
      liveConnected: false,
      lastError: null,
      notSynced: [],
    };
  }

  getState(): SyncState {
    return this.state;
  }

  subscribe(fn: (s: SyncState) => void): () => void {
    this.listeners.add(fn);
    fn(this.state);
    return () => this.listeners.delete(fn);
  }

  private emit(patch: Partial<SyncState>): void {
    this.state = { ...this.state, ...patch };
    for (const fn of this.listeners) fn(this.state);
  }

  async loadFromDisk(): Promise<StoreSnapshot> {
    await ensureCoreReady();
    const snapshot = await this.store.loadSnapshot();
    this.emit({ snapshot });
    return snapshot;
  }

  async start(userId: string): Promise<void> {
    this.stopped = false;
    await ensureCoreReady();
    const existing = await this.store.loadSnapshot();
    if (existing.userId && existing.userId !== userId) {
      await this.store.clearAll();
    }
    await this.store.setUserId(userId);
    const snapshot = await this.store.loadSnapshot();
    this.emit({ snapshot, lastError: null });

    if (typeof window !== "undefined") {
      window.addEventListener("online", this.onOnline);
      window.addEventListener("offline", this.onOffline);
      if ("BroadcastChannel" in window && !this.channel) {
        this.channel = new BroadcastChannel("septena-web");
        this.channel.onmessage = () => {
          void this.reloadFromDisk();
        };
      }
    }

    await this.syncNow();
    this.connectLiveSocket();
  }

  stop(): void {
    this.stopped = true;
    if (typeof window !== "undefined") {
      window.removeEventListener("online", this.onOnline);
      window.removeEventListener("offline", this.onOffline);
    }
    this.closeLiveSocket();
    if (this.channel) {
      this.channel.close();
      this.channel = null;
    }
  }

  async signOutAndWipe(): Promise<void> {
    this.stop();
    await this.api.signOut();
    await this.store.clearAll();
    if (typeof navigator !== "undefined" && navigator.serviceWorker?.controller) {
      navigator.serviceWorker.controller.postMessage({ type: "CLEAR_SHELL_CACHE" });
    }
    this.emit({
      snapshot: EMPTY_SNAPSHOT,
      syncing: false,
      liveConnected: false,
      lastError: null,
      notSynced: [],
    });
  }

  private onOnline = () => {
    this.emit({ online: true, lastError: null });
    void this.syncNow();
    this.connectLiveSocket();
  };

  private onOffline = () => {
    this.emit({ online: false, liveConnected: false });
    this.closeLiveSocket();
  };

  private async reloadFromDisk(): Promise<void> {
    const snapshot = await this.store.loadSnapshot();
    this.emit({ snapshot });
  }

  private broadcastChange(): void {
    try {
      this.channel?.postMessage({ type: "updated", at: Date.now() });
    } catch {
      // Ignore BroadcastChannel errors on closed channels.
    }
  }

  // ---- Mutators (the single write boundary) ----

  async createTask(input: {
    title: string;
    notes?: string;
    today?: boolean;
    scheduled?: string | null;
    deadline?: string | null;
    area?: string | null;
    project?: string | null;
  }): Promise<TaskRow> {
    await ensureCoreReady();
    const title = input.title.trim();
    if (!title) throw new Error("Task title is required");

    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const id = newTaskId();
    const fields: Record<string, unknown> = {
      title,
      status: "open",
      created: todayYMD,
      createdAt: now,
      touchedAt: now,
      source: "app",
      sourceClient: "web",
      today: Boolean(input.today),
      todaySetOn: input.today ? todayYMD : null,
      scheduled: input.scheduled ?? null,
      deadline: input.deadline ?? null,
      area: input.area ?? null,
      project: input.project ?? null,
      notes: input.notes?.trim() ? input.notes.trim() : null,
    };

    const row: TaskRow = {
      id,
      title,
      status: "open",
      ...fields,
    };
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "upsert",
      entity: "task",
      id,
      fields,
      queuedAt: Date.now(),
    };

    await this.store.putLocalAndQueue("task", row, op);
    await this.reloadFromDisk();
    this.broadcastChange();
    this.scheduleSync();
    return row;
  }

  async toggleTaskDone(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const nextStatus = task.status === "done" ? "open" : "done";
    const fields: Record<string, unknown> = {
      status: nextStatus,
      completedAt: nextStatus === "done" ? now : null,
      touchedAt: now,
    };
    await this.patchTask(task, fields);
  }

  async toggleTaskToday(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const datePatch = applyDateAction(task, { type: "toggleToday" }, todayYMD, now);
    if (Object.keys(datePatch).length === 0) return;
    await this.patchTask(task, { ...datePatch, touchedAt: now });
  }

  async setTaskScheduled(task: TaskRow, day: string | null): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const datePatch = day
      ? applyDateAction(task, { type: "scheduleFor", day }, todayYMD, now)
      : applyDateAction(task, { type: "clearWhen" }, todayYMD, now);
    if (Object.keys(datePatch).length === 0) return;
    await this.patchTask(task, { ...datePatch, touchedAt: now });
  }

  async setTaskDeadline(task: TaskRow, day: string | null): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const datePatch = applyDateAction(task, { type: "setDeadline", day }, todayYMD, now);
    if (Object.keys(datePatch).length === 0) return;
    await this.patchTask(task, { ...datePatch, touchedAt: now });
  }

  async updateTaskFields(task: TaskRow, fields: Record<string, unknown>): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, { ...fields, touchedAt: now });
  }

  async deleteTask(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "delete",
      entity: "task",
      id: task.id,
      queuedAt: Date.now(),
    };
    await this.store.putLocalAndQueue("task", null, op);
    await this.reloadFromDisk();
    this.broadcastChange();
    this.scheduleSync();
  }

  private async patchTask(task: TaskRow, fields: Record<string, unknown>): Promise<void> {
    const updated: TaskRow = { ...task, ...fields };
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "upsert",
      entity: "task",
      id: task.id,
      fields,
      queuedAt: Date.now(),
    };
    await this.store.putLocalAndQueue("task", updated, op);
    await this.reloadFromDisk();
    this.broadcastChange();
    this.scheduleSync();
  }

  // ---- Sync loop (push then pull, coordinated with Web Locks) ----

  scheduleSync(): void {
    if (this.stopped || !this.state.online) return;
    if (this.running) {
      this.syncScheduled = true;
      return;
    }
    void this.syncNow();
  }

  async syncNow(): Promise<void> {
    if (this.stopped) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) {
      this.emit({ online: false });
      return;
    }
    if (this.running) {
      this.syncScheduled = true;
      return;
    }

    const runLocked = async () => {
      this.running = true;
      this.emit({ syncing: true, lastError: null });
      try {
        await this.drainOutbox();
        await this.pullAllPages();
        this.broadcastChange();
      } catch (err) {
        if (err instanceof ApiError && err.status === 401) {
          this.emit({ lastError: "Session expired — please sign in again." });
        } else if (err instanceof TypeError || (typeof navigator !== "undefined" && !navigator.onLine)) {
          this.emit({ online: false, lastError: null });
        } else {
          this.emit({ lastError: err instanceof Error ? err.message : "Sync failed" });
        }
      } finally {
        this.running = false;
        const snapshot = await this.store.loadSnapshot();
        this.emit({ syncing: false, snapshot });
        if (this.syncScheduled && !this.stopped) {
          this.syncScheduled = false;
          void this.syncNow();
        }
      }
    };

    if (typeof navigator !== "undefined" && navigator.locks?.request) {
      await navigator.locks.request("septena-web-sync", runLocked);
    } else {
      await runLocked();
    }
  }

  private async drainOutbox(): Promise<void> {
    const snap = await this.store.loadSnapshot();
    if (!snap.outbox.length) return;

    const batch = snap.outbox.slice(0, 100);
    const res = await this.api.push(batch);
    const doneIds: string[] = [];
    const newlyRejected: NotSyncedItem[] = [];

    for (const r of res.results) {
      if (r.status === "applied" || r.status === "noop" || r.status === "dropped") {
        doneIds.push(r.clientOpId);
      } else if (r.status === "rejected") {
        doneIds.push(r.clientOpId);
        const orig = batch.find((o) => o.clientOpId === r.clientOpId);
        newlyRejected.push({
          clientOpId: r.clientOpId,
          entity: orig?.entity ?? "task",
          id: orig?.id ?? "",
          reason: r.reason,
          at: Date.now(),
        });
      }
    }

    await this.store.removeOutboxOps(doneIds);
    if (newlyRejected.length) {
      this.emit({ notSynced: [...this.state.notSynced, ...newlyRejected].slice(-20) });
    }
    if (snap.outbox.length > batch.length) {
      await this.drainOutbox();
    }
  }

  private async pullAllPages(): Promise<void> {
    let resets = 0;
    let snap = await this.store.loadSnapshot();
    let cursor = snap.cursor;

    while (!this.stopped) {
      const page = await this.api.pull(cursor);
      const check = checkPullPage(cursor, page, resets);
      if (check.decision === "reset") {
        resets += 1;
        await this.store.resetRowsKeepOutbox();
        snap = await this.store.loadSnapshot();
        cursor = 0;
        continue;
      }
      if (check.decision === "fail") {
        throw new Error(check.reason ?? "Pull page check failed");
      }

      const taskMap = new Map<string, Record<string, unknown>>(snap.tasks.map((t) => [t.id, t]));
      const areaMap = new Map<string, Record<string, unknown>>(snap.areas.map((a) => [a.id, a]));
      const projectMap = new Map<string, Record<string, unknown>>(snap.projects.map((p) => [p.id, p]));
      const mutations: Array<{
        entity: "task" | "area" | "project" | "setting";
        action: "put" | "delete";
        id: string;
        row?: Record<string, unknown>;
      }> = [];

      for (const change of page.changes) {
        const entity = change.entity;
        if (entity !== "task" && entity !== "area" && entity !== "project" && entity !== "setting") {
          continue;
        }
        const id = typeof change.row.id === "string" ? change.row.id : null;
        if (!id) continue;

        const current =
          entity === "task"
            ? (taskMap.get(id) ?? null)
            : entity === "area"
              ? (areaMap.get(id) ?? null)
              : entity === "project"
                ? (projectMap.get(id) ?? null)
                : id in snap.settings
                  ? { id, value: snap.settings[id] }
                  : null;

        const { pendingFields, pendingDelete } = pendingFieldsFor(snap.outbox, entity, id);
        const plan = planPullRow({
          entity,
          row: change.row,
          current,
          pendingFields,
          pendingDelete,
        });

        if (plan.plan === "skip" || plan.plan === "turn" || plan.plan === "shadowOnly") {
          continue;
        }
        if (plan.plan === "tombstone") {
          if (entity === "task" && plan.keepLocalRow && current) {
            const deletedRow = {
              ...current,
              id,
              rev: plan.revision,
              updatedAt: plan.updatedAt,
              deletedAt: plan.deletedAt,
            };
            mutations.push({ entity, action: "put", id, row: deletedRow });
            taskMap.set(id, deletedRow);
          } else {
            mutations.push({ entity, action: "delete", id });
            if (entity === "task") taskMap.delete(id);
            else if (entity === "area") areaMap.delete(id);
            else if (entity === "project") projectMap.delete(id);
          }
          continue;
        }
        if (plan.plan === "merge") {
          const row = {
            ...plan.fields,
            id,
            rev: plan.revision,
            ...(plan.updatedAt ? { updatedAt: plan.updatedAt } : {}),
          };
          mutations.push({ entity, action: "put", id, row });
          if (entity === "task") taskMap.set(id, row);
          else if (entity === "area") areaMap.set(id, row);
          else if (entity === "project") projectMap.set(id, row);
        }
      }

      await this.store.applyPulledBatch(mutations, page.nextSince, Date.now());
      snap = await this.store.loadSnapshot();
      cursor = page.nextSince;

      if (check.decision === "apply") break;
    }
  }

  // ---- Live WebSocket nudge via single-use /v1/sync/ws-ticket ----

  private connectLiveSocket(): void {
    if (this.stopped || typeof window === "undefined" || !navigator.onLine) return;
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }
    this.clearReconnectTimer();

    void (async () => {
      try {
        const { ticket } = await this.api.wsTicket();
        if (this.stopped) return;
        const socket = new WebSocket(this.api.wsUrl(ticket));
        this.ws = socket;

        socket.onopen = () => {
          this.wsRetryMs = 2000;
          this.emit({ liveConnected: true });
        };

        socket.onmessage = (event) => {
          try {
            const msg = JSON.parse(String(event.data)) as { rev?: number };
            if (typeof msg.rev === "number" && msg.rev > this.state.snapshot.cursor) {
              this.scheduleSync();
            }
          } catch {
            // Ignore non-JSON frames.
          }
        };

        socket.onclose = () => {
          if (this.ws === socket) this.ws = null;
          this.emit({ liveConnected: false });
          this.scheduleWsReconnect();
        };

        socket.onerror = () => {
          socket.close();
        };
      } catch {
        this.emit({ liveConnected: false });
        this.scheduleWsReconnect();
      }
    })();
  }

  private scheduleWsReconnect(): void {
    if (this.stopped || typeof window === "undefined" || !navigator.onLine) return;
    this.clearReconnectTimer();
    const wait = this.wsRetryMs;
    this.wsRetryMs = Math.min(this.wsRetryMs * 2, 30_000);
    this.wsReconnectTimer = setTimeout(() => {
      this.connectLiveSocket();
    }, wait);
  }

  private clearReconnectTimer(): void {
    if (this.wsReconnectTimer) {
      clearTimeout(this.wsReconnectTimer);
      this.wsReconnectTimer = null;
    }
  }

  private closeLiveSocket(): void {
    this.clearReconnectTimer();
    if (this.ws) {
      this.ws.onclose = null;
      this.ws.close();
      this.ws = null;
    }
  }
}
