import { ApiError, SeptenaApiClient } from "../api/client";
import {
  applyDateAction,
  checkPullPage,
  checklistOccurrenceId,
  ensureCoreReady,
  localTodayYMD,
  localUtcOffsetSeconds,
  localWallClockTimestamp,
  nextOccurrenceDates,
  nextScheduledDate,
  occurrenceId,
  parseRef,
  planPullRow,
  planPushResponse,
  shiftReminderForRecurrence,
  shiftReminderOnReschedule,
  shouldFade,
  taskRefId,
} from "../core";
import { evaluateConversation, groupTurnsByTask } from "../conversation";
import { fadeInput, fadeSettings, isProposal, type FadeClock } from "../fade";
import { clearWaitingFields, setWaitingFields } from "../waiting";
import {
  needsFixedRepeatPrompt,
  planFixedSeriesRebase,
  type RescheduleMode,
} from "../fixedRepeat";
import {
  AccountSwitchRequiredError,
  decideAccountSwitch,
  type AccountSwitchSummary,
} from "./accountSwitch";
import { LocalStore, pendingFieldsFor, turnSyntheticId, type LocalMutation } from "../store/db";
import type { ParsedBackupPreview } from "../export";
import type {
  AreaRow,
  AttachmentRow,
  ChecklistItemRow,
  ConvoRow,
  NotSyncedItem,
  OrdinalWeekday,
  OutboxOp,
  ProjectRow,
  StoreSnapshot,
  SyncedEntity,
  TagRow,
  TaskRefRow,
  TaskRow,
  TurnRow,
  WireTurn,
} from "../types";

// Full WB2 sync engine & mutator boundary (docs/WEB_CLIENT_SPEC.md §6, SEPTASK_BACKEND.md §6).
// - Mutators are the single write path: optimistic local IndexedDB write + queued outbox op.
// - Every task rule (dates, recurrence spawning, reminder shifting, reference normalization)
//   and every sync decision (checkPullPage, planPullRow, planPushResponse) runs through the
//   shared Rust WASM core — zero duplicated logic in TypeScript.

export { needsFixedRepeatPrompt, type RescheduleMode };

export interface SyncState {
  snapshot: StoreSnapshot;
  online: boolean;
  syncing: boolean;
  liveConnected: boolean;
  lastError: string | null;
  notSynced: NotSyncedItem[];
}

/** What a completion replaced, so its undo restores exactly that. */
export interface CompletionReceipt {
  before: Array<{ task: TaskRow; convo: ConvoRow | null }>;
  spawnedTaskIds: string[];
}

function randomBase64Url(bytes: number): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  let bin = "";
  for (const b of buf) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function newId(prefix: string): string {
  return `${prefix}_${randomBase64Url(12)}`;
}

function newClientOpId(): string {
  return `op_${randomBase64Url(16)}`;
}

const EMPTY_SNAPSHOT: StoreSnapshot = {
  tasks: [],
  areas: [],
  projects: [],
  checklistItems: [],
  tags: [],
  taskRefs: [],
  convos: [],
  turns: [],
  attachments: [],
  settings: {},
  outbox: [],
  cursor: 0,
  userId: null,
  lastSyncedAt: null,
};

const SYNCED_ENTITY_SET = new Set<string>([
  "task",
  "area",
  "project",
  "checklistItem",
  "tag",
  "taskRef",
  "convo",
  "attachment",
  "setting",
]);

function isSyncedEntity(e: string): e is SyncedEntity {
  return SYNCED_ENTITY_SET.has(e);
}

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
  /** The account and app day the fade pass last ran for in this tab. */
  private lastFadePass: string | null = null;

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

  /**
   * What a session for `userId` would remove from this device, or null when
   * `start` may go on without asking (same account, no stored account, or
   * nothing local to lose). Call it before `start`; on a summary, ask the user
   * and pass `replaceOtherAccount` only when they chose Replace (#575).
   */
  async accountSwitchSummary(userId: string): Promise<AccountSwitchSummary | null> {
    await ensureCoreReady();
    const existing = await this.store.loadSnapshot();
    this.emit({ snapshot: existing });
    const decision = decideAccountSwitch(existing, userId);
    return decision.kind === "ask" ? decision.summary : null;
  }

  async start(userId: string, options: { replaceOtherAccount?: boolean } = {}): Promise<void> {
    this.stopped = false;
    await ensureCoreReady();
    const existing = await this.store.loadSnapshot();
    const decision = decideAccountSwitch(existing, userId);
    if (decision.kind === "ask" && !options.replaceOtherAccount) {
      // Fails closed: another account's tasks stay until the user confirms.
      this.stopped = true;
      throw new AccountSwitchRequiredError(decision.summary);
    }
    if (decision.kind !== "keep") {
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

  async deleteAccountAndWipe(): Promise<void> {
    this.stop();
    await this.api.deleteAccount();
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

  clearNotSynced(): void {
    this.emit({ notSynced: [] });
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
      // Ignore closed BroadcastChannel.
    }
  }

  private async commit(mutations: LocalMutation[], ops: OutboxOp[]): Promise<void> {
    await this.store.commitLocalAndQueue(mutations, ops);
    await this.reloadFromDisk();
    this.broadcastChange();
    this.scheduleSync();
  }

  // ---- Task mutators ----

  async createTask(input: {
    id?: string;
    title: string;
    notes?: string;
    kind?: "heading" | null;
    heading?: string | null;
    today?: boolean;
    starred?: boolean;
    scheduled?: string | null;
    deadline?: string | null;
    area?: string | null;
    project?: string | null;
    tags?: string[] | null;
    position?: number | null;
  }): Promise<TaskRow> {
    await ensureCoreReady();
    const title = input.title.trim();
    if (!title) throw new Error("Task title is required");

    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const id = input.id ?? newId("w");
    const fields: Record<string, unknown> = {
      title,
      status: "open",
      kind: input.kind ?? null,
      heading: input.heading ?? null,
      created: todayYMD,
      createdAt: now,
      touchedAt: now,
      source: "app",
      sourceClient: "web",
      today: Boolean(input.today),
      todaySetOn: input.today ? todayYMD : null,
      starred: Boolean(input.starred),
      scheduled: input.scheduled ?? null,
      deadline: input.deadline ?? null,
      area: input.area ?? null,
      project: input.project ?? null,
      tags: input.tags ?? null,
      notes: input.notes?.trim() ? input.notes.trim() : null,
      ...(input.position !== undefined ? { position: input.position } : {}),
    };

    const row: TaskRow = { id, title, status: "open", ...fields };
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "upsert",
      entity: "task",
      id,
      fields,
      queuedAt: Date.now(),
    };
    await this.commit([{ entity: "task", action: "put", id, row }], [op]);
    return row;
  }

  private buildNextRecurrenceMutations(
    task: TaskRow,
    completedOn: string,
    now: string,
  ): { mutations: LocalMutation[]; ops: OutboxOp[]; spawnedTaskId: string | null } {
    if (!task.recurrenceUnit || task.recurrencePaused) {
      return { mutations: [], ops: [], spawnedTaskId: null };
    }
    const nextDay = nextScheduledDate({
      completedOn,
      scheduled: task.scheduled ?? null,
      logicalScheduled: task.recurrenceAnchorDate ?? null,
      rule: {
        unit: task.recurrenceUnit,
        interval: Math.max(1, task.recurrenceInterval ?? 1),
        afterCompletion: Boolean(task.recurrenceAfterCompletion),
        weekdays: task.recurrenceWeekdays ?? null,
        monthDay: task.recurrenceMonthDay ?? null,
        ordinalWeekday: task.recurrenceOrdinalWeekday ?? null,
      },
    });
    if (!nextDay) return { mutations: [], ops: [], spawnedTaskId: null };

    const newTaskID = occurrenceId(task.id, nextDay);
    const dateFields = nextOccurrenceDates(task, nextDay, now);
    const shiftedReminder = shiftReminderForRecurrence({
      sourceReminderAt: task.reminderAt ?? null,
      sourceScheduled: task.scheduled ?? null,
      nextScheduled: nextDay,
    });

    const seriesId = task.recurrenceSeriesID ?? task.id;
    const fields: Record<string, unknown> = {
      title: task.title,
      status: "open",
      area: task.area ?? null,
      project: task.project ?? null,
      heading: task.heading ?? null,
      notes: task.notes ?? null,
      starred: Boolean(task.starred),
      tags: task.tags ?? null,
      startTime: task.startTime ?? null,
      durationMinutes: task.durationMinutes ?? null,
      timeZone: task.timeZone ?? null,
      recurrenceUnit: task.recurrenceUnit,
      recurrenceInterval: Math.max(1, task.recurrenceInterval ?? 1),
      recurrenceAfterCompletion: Boolean(task.recurrenceAfterCompletion),
      recurrencePaused: false,
      recurrenceSeriesID: seriesId,
      recurrenceAnchorDate: nextDay,
      recurrenceWeekdays: task.recurrenceWeekdays ?? null,
      recurrenceMonthDay: task.recurrenceMonthDay ?? null,
      recurrenceOrdinalWeekday: task.recurrenceOrdinalWeekday ?? null,
      reminderAt: shiftedReminder,
      reminderMode: shiftedReminder ? (task.reminderMode ?? "floating") : null,
      created: completedOn,
      createdAt: now,
      touchedAt: now,
      source: "app",
      sourceClient: "web",
      ...dateFields,
    };

    const row: TaskRow = { id: newTaskID, title: task.title, status: "open", ...fields };
    const queuedAt = Date.now();
    const mutations: LocalMutation[] = [{ entity: "task", action: "put", id: newTaskID, row }];
    const ops: OutboxOp[] = [
      {
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "task",
        id: newTaskID,
        fields,
        queuedAt,
      },
    ];

    // Carry checklist items (unchecked) via WASM checklistOccurrenceId.
    const items = this.state.snapshot.checklistItems
      .filter((c) => !c.deletedAt && c.taskId === task.id)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
    items.forEach((item, index) => {
      const nextItemId = checklistOccurrenceId(newTaskID, index, item.id);
      const itemFields: Record<string, unknown> = {
        taskId: newTaskID,
        title: item.title,
        checked: false,
        checkedAt: null,
        position: item.position ?? index,
        createdAt: now,
      };
      const nextItemRow: ChecklistItemRow = { id: nextItemId, taskId: newTaskID, title: item.title, ...itemFields };
      mutations.push({ entity: "checklistItem", action: "put", id: nextItemId, row: nextItemRow });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "checklistItem",
        id: nextItemId,
        fields: itemFields,
        queuedAt: queuedAt + index + 1,
      });
    });

    // Carry `about` references onto the next occurrence.
    const aboutRefs = this.state.snapshot.taskRefs.filter(
      (r) => !r.deletedAt && r.taskId === task.id && (r.role ?? "about") === "about",
    );
    aboutRefs.forEach((ref, index) => {
      const nextRefId = taskRefId(newTaskID, ref.key, 0);
      const refFields: Record<string, unknown> = {
        taskId: newTaskID,
        key: ref.key,
        role: "about",
        snapshot: ref.snapshot ?? null,
        position: ref.position ?? index,
        createdAt: now,
      };
      const nextRefRow: TaskRefRow = { id: nextRefId, taskId: newTaskID, key: ref.key, kind: ref.kind, ...refFields };
      mutations.push({ entity: "taskRef", action: "put", id: nextRefId, row: nextRefRow });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "taskRef",
        id: nextRefId,
        fields: refFields,
        queuedAt: queuedAt + items.length + index + 2,
      });
    });

    return { mutations, ops, spawnedTaskId: newTaskID };
  }

  /** The rows and ops that complete one task. In Review, completing accepts (docs/REVIEW_SPEC.md §4). */
  private completionWrites(
    task: TaskRow,
    now: string,
    queuedAt: number,
  ): { mutations: LocalMutation[]; ops: OutboxOp[]; spawnedTaskId: string | null; reviewed: ConvoRow | null } {
    const mutations: LocalMutation[] = [];
    const ops: OutboxOp[] = [];

    const convo = this.existingConvo(task.id);
    const reviewed = convo.endState === "needs_verify" ? convo : null;
    if (reviewed) {
      const convoFields = { endState: "agent_assisted_done" };
      mutations.push({ entity: "convo", action: "put", id: task.id, row: { ...reviewed, ...convoFields } });
      ops.push({ clientOpId: newClientOpId(), op: "upsert", entity: "convo", id: task.id, fields: convoFields, queuedAt });
    }

    const fields: Record<string, unknown> = {
      status: "done",
      completedAt: localWallClockTimestamp(),
      touchedAt: now,
      ...(isProposal(task) ? { acknowledgedAt: now } : {}),
    };
    mutations.push({ entity: "task", action: "put", id: task.id, row: { ...task, ...fields } });
    ops.push({ clientOpId: newClientOpId(), op: "upsert", entity: "task", id: task.id, fields, queuedAt: queuedAt + 1 });

    let spawnedTaskId: string | null = null;
    if (task.recurrenceUnit && !task.recurrencePaused) {
      const nextOcc = this.buildNextRecurrenceMutations(task, localTodayYMD(), now);
      mutations.push(...nextOcc.mutations);
      ops.push(...nextOcc.ops);
      spawnedTaskId = nextOcc.spawnedTaskId;
    }
    return { mutations, ops, spawnedTaskId, reviewed };
  }

  async completeTasks(tasks: TaskRow[]): Promise<CompletionReceipt> {
    const receipt: CompletionReceipt = { before: [], spawnedTaskIds: [] };
    if (tasks.length === 0) return receipt;
    await ensureCoreReady();
    const now = new Date().toISOString();
    const queuedAt = Date.now();
    const mutations: LocalMutation[] = [];
    const ops: OutboxOp[] = [];
    tasks.forEach((row, idx) => {
      const task = this.liveTask(row.id) ?? row;
      const writes = this.completionWrites(task, now, queuedAt + idx * 10);
      mutations.push(...writes.mutations);
      ops.push(...writes.ops);
      receipt.before.push({ task, convo: writes.reviewed });
      if (writes.spawnedTaskId) receipt.spawnedTaskIds.push(writes.spawnedTaskId);
    });
    await this.commit(mutations, ops);
    return receipt;
  }

  /** Undo of a completion: the task, its place in Review with the note, and the next occurrence. */
  async undoCompletion(receipt: CompletionReceipt): Promise<void> {
    for (const { task, convo } of receipt.before) {
      await this.patchTask(this.liveTask(task.id) ?? task, {
        status: task.status,
        completedAt: task.completedAt ?? null,
        touchedAt: task.touchedAt ?? null,
        acknowledgedAt: task.acknowledgedAt ?? null,
      });
      if (convo) await this.restoreReview(convo);
    }
    for (const id of receipt.spawnedTaskIds) {
      const spawned = this.liveTask(id);
      if (spawned) await this.deleteTask(spawned);
    }
  }

  async toggleTaskDone(task: TaskRow): Promise<CompletionReceipt> {
    if (task.status !== "done") return this.completeTasks([task]);
    const now = new Date().toISOString();
    await this.patchTask(this.liveTask(task.id) ?? task, {
      status: "open",
      completedAt: null,
      touchedAt: now,
      ...(isProposal(task) ? { acknowledgedAt: now } : {}),
    });
    return { before: [{ task, convo: null }], spawnedTaskIds: [] };
  }

  async cancelTask(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, {
      status: "cancelled",
      completedAt: localWallClockTimestamp(),
      dropReason: "user",
      touchedAt: now,
    });
  }

  async reopenTask(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, {
      status: "open",
      completedAt: null,
      dropReason: null,
      fadedAt: null,
      touchedAt: now,
    });
  }

  /** Keep a task out of the Faded pile. Keeping a proposal accepts it (ADR 0039). */
  async keepFadedTask(task: TaskRow): Promise<void> {
    const now = new Date().toISOString();
    await this.patchTask(this.liveTask(task.id) ?? task, {
      fadedAt: null,
      touchedAt: now,
      deferCount: 0,
      ...(isProposal(task) ? { acknowledgedAt: now } : {}),
    });
  }

  /**
   * Let faded tasks go. Only tasks that are still faded and open: a task that
   * another device kept stays. Returns the rows it dropped.
   */
  async dropFadedTasks(tasks: TaskRow[]): Promise<TaskRow[]> {
    const dropped = tasks
      .map((t) => this.liveTask(t.id))
      .filter((t): t is TaskRow => t !== null && t.status === "open" && !t.deletedAt && Boolean(t.fadedAt));
    await this.patchTasks(dropped, {
      status: "cancelled",
      completedAt: localWallClockTimestamp(),
      dropReason: "faded",
    });
    return dropped;
  }

  /** Undo of Keep and Let Go: puts the rows back in the Faded pile with their own stamps. */
  async restoreFadedTasks(before: TaskRow[]): Promise<void> {
    for (const task of before) {
      await this.patchTask(this.liveTask(task.id) ?? task, {
        status: task.status,
        completedAt: task.completedAt ?? null,
        dropReason: task.dropReason ?? null,
        fadedAt: task.fadedAt ?? null,
        touchedAt: task.touchedAt ?? null,
        deferCount: task.deferCount ?? 0,
        acknowledgedAt: task.acknowledgedAt ?? null,
      });
    }
  }

  /**
   * Waiting On… (REVIEW_SPEC §6): the task waits on `name`. `scheduled` is the
   * day to check back: a day, null for no date, or undefined to keep When.
   */
  async setTaskWaiting(task: TaskRow, name: string, scheduled?: string | null): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const live = this.liveTask(task.id) ?? task;
    await this.patchTask(live, {
      ...setWaitingFields(live, name, localTodayYMD()),
      touchedAt: now,
      ...(isProposal(live) ? { acknowledgedAt: now } : {}),
    });
    if (scheduled === undefined) return;
    const next = this.liveTask(task.id) ?? live;
    if ((next.scheduled ?? null) === scheduled) return;
    await this.setTaskScheduled(next, scheduled);
  }

  /** Got It Back: the wait ends, the task stays open in its list. */
  async clearTaskWaiting(task: TaskRow): Promise<void> {
    const now = new Date().toISOString();
    await this.patchTask(this.liveTask(task.id) ?? task, { ...clearWaitingFields(), touchedAt: now });
  }

  async toggleTaskToday(task: TaskRow, mode: RescheduleMode = "makeException"): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const datePatch = applyDateAction(task, { type: "toggleToday", mode }, todayYMD, now);
    if (Object.keys(datePatch).length === 0) return;
    await this.patchTask(task, {
      ...datePatch,
      touchedAt: now,
      ...(isProposal(task) ? { acknowledgedAt: now } : {}),
    });
    if (
      mode === "updateRule" &&
      typeof datePatch.recurrenceAnchorDate === "string" &&
      task.recurrenceUnit &&
      !task.recurrenceAfterCompletion
    ) {
      await this.rebaseFixedSeries(task, datePatch.recurrenceAnchorDate);
    }
  }

  async toggleTaskStar(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, { starred: !task.starred, touchedAt: now });
  }

  async setTaskScheduled(
    task: TaskRow,
    day: string | null,
    mode: RescheduleMode = "makeException",
  ): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const datePatch = day
      ? applyDateAction(task, { type: "scheduleFor", day, mode }, todayYMD, now)
      : applyDateAction(task, { type: "clearWhenDate" }, todayYMD, now);
    if (Object.keys(datePatch).length === 0) return;

    const shiftedReminder = shiftReminderOnReschedule({
      reminderAt: task.reminderAt ?? null,
      oldScheduled: task.scheduled ?? null,
      newScheduled: day,
    });

    await this.patchTask(task, {
      ...datePatch,
      ...(task.reminderAt && shiftedReminder !== task.reminderAt ? { reminderAt: shiftedReminder } : {}),
      touchedAt: now,
      ...(isProposal(task) ? { acknowledgedAt: now } : {}),
    });
    if (
      mode === "updateRule" &&
      typeof datePatch.recurrenceAnchorDate === "string" &&
      task.recurrenceUnit &&
      !task.recurrenceAfterCompletion
    ) {
      await this.rebaseFixedSeries(task, datePatch.recurrenceAnchorDate);
    }
  }

  /**
   * Rebase sibling open occurrences of a fixed repeating series after "Update Schedule"
   * moves the anchor slot (#573, matching Apple `TasksBackend.rebaseFixedSeries`).
   */
  private async rebaseFixedSeries(source: TaskRow, newAnchor: string): Promise<void> {
    if (!source.recurrenceUnit || source.recurrenceAfterCompletion) return;
    const seriesID = source.recurrenceSeriesID ?? source.id;
    const liveSource = this.liveTask(source.id) ?? source;
    if (liveSource.recurrenceSeriesID !== seriesID) {
      await this.patchTask(liveSource, { recurrenceSeriesID: seriesID });
    }
    const updates = planFixedSeriesRebase(
      source,
      this.state.snapshot.tasks,
      newAnchor,
      nextScheduledDate,
    );
    for (const { task: sibling, nextDay } of updates) {
      const shiftedReminder = shiftReminderOnReschedule({
        reminderAt: sibling.reminderAt ?? null,
        oldScheduled: sibling.scheduled ?? null,
        newScheduled: nextDay,
      });
      await this.patchTask(sibling, {
        recurrenceSeriesID: seriesID,
        recurrenceAnchorDate: nextDay,
        scheduled: nextDay,
        ...(sibling.reminderAt && shiftedReminder !== sibling.reminderAt
          ? { reminderAt: shiftedReminder, reminderSnoozedUntil: null, reminderDismissedAt: null }
          : {}),
      });
    }
  }

  async setTaskDeadline(task: TaskRow, day: string | null): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const datePatch = applyDateAction(task, { type: "setDeadline", day }, todayYMD, now);
    if (Object.keys(datePatch).length === 0) return;
    await this.patchTask(task, {
      ...datePatch,
      touchedAt: now,
      ...(task.source === "mcp" && !task.acknowledgedAt ? { acknowledgedAt: now } : {}),
    });
  }

  /** Clear When (`task.clearSchedule`, TASK_DATES_SPEC A6): the When date, the deadline and the pin. */
  async clearTaskWhen(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const datePatch = applyDateAction(task, { type: "clearWhen" }, localTodayYMD(), now);
    if (Object.keys(datePatch).length === 0) return;
    await this.patchTask(task, {
      ...datePatch,
      touchedAt: now,
      ...(task.source === "mcp" && !task.acknowledgedAt ? { acknowledgedAt: now } : {}),
    });
  }

  async setTaskTimeSlot(
    task: TaskRow,
    startTime: string | null,
    durationMinutes: number | null,
  ): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const timeZone = startTime ? Intl.DateTimeFormat().resolvedOptions().timeZone : null;
    const datePatch = applyDateAction(
      task,
      { type: "setTimeSlot", startTime, durationMinutes, timeZone },
      todayYMD,
      now,
    );
    await this.patchTask(task, {
      ...datePatch,
      touchedAt: now,
      ...(task.source === "mcp" && !task.acknowledgedAt ? { acknowledgedAt: now } : {}),
    });
  }

  async setTaskRecurrence(
    task: TaskRow,
    rule: {
      unit: "day" | "week" | "month" | "year" | null;
      interval?: number;
      afterCompletion?: boolean;
      paused?: boolean;
      weekdays?: number[] | null;
      monthDay?: number | null;
      ordinalWeekday?: OrdinalWeekday | null;
    },
  ): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    if (!rule.unit) {
      await this.patchTask(task, {
        recurrenceUnit: null,
        recurrenceInterval: null,
        recurrenceAfterCompletion: false,
        recurrencePaused: false,
        recurrenceAnchorDate: null,
        recurrenceWeekdays: null,
        recurrenceMonthDay: null,
        recurrenceOrdinalWeekday: null,
        touchedAt: now,
      });
      return;
    }
    const anchor = task.scheduled ?? todayYMD;
    await this.patchTask(task, {
      recurrenceUnit: rule.unit,
      recurrenceInterval: Math.max(1, rule.interval ?? 1),
      recurrenceAfterCompletion: Boolean(rule.afterCompletion),
      recurrencePaused: Boolean(rule.paused),
      recurrenceSeriesID: task.recurrenceSeriesID ?? task.id,
      recurrenceAnchorDate: anchor,
      scheduled: task.scheduled ?? anchor,
      recurrenceWeekdays: rule.weekdays ?? null,
      recurrenceMonthDay: rule.monthDay ?? null,
      recurrenceOrdinalWeekday: rule.ordinalWeekday ?? null,
      touchedAt: now,
    });
  }

  async moveTask(
    task: TaskRow,
    target: { area: string | null; project: string | null; heading?: string | null },
  ): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const filePatch =
      target.area || target.project
        ? applyDateAction(task, { type: "fileFromTriage" }, todayYMD, now)
        : {};
    await this.patchTask(task, {
      ...filePatch,
      area: target.area,
      project: target.project,
      heading: target.heading ?? null,
      touchedAt: now,
      ...(isProposal(task) ? { acknowledgedAt: now } : {}),
    });
  }

  async updateTaskFields(task: TaskRow, fields: Record<string, unknown>): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, { ...fields, touchedAt: now });
  }

  async deleteTask(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    // Soft-delete locally (tombstone on server keeps deletedAt for 30 days in Deleted).
    const deletedRow: TaskRow = { ...task, deletedAt: now };
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "delete",
      entity: "task",
      id: task.id,
      queuedAt: Date.now(),
    };
    await this.commit([{ entity: "task", action: "put", id: task.id, row: deletedRow }], [op]);
  }

  async restoreDeletedTask(task: TaskRow): Promise<TaskRow> {
    // Re-insert as a fresh active task (server tombstones drop updates to deleted IDs).
    return this.createTask({
      title: task.title,
      notes: task.notes ?? undefined,
      today: Boolean(task.today),
      starred: Boolean(task.starred),
      scheduled: task.scheduled ?? null,
      deadline: task.deadline ?? null,
      area: task.area ?? null,
      project: task.project ?? null,
      tags: task.tags ?? null,
    });
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
    await this.commit([{ entity: "task", action: "put", id: task.id, row: updated }], [op]);
  }

  private async patchTasks(tasks: TaskRow[], fields: Record<string, unknown>): Promise<void> {
    if (tasks.length === 0) return;
    const queuedAt = Date.now();
    await this.commit(
      tasks.map((task) => ({ entity: "task", action: "put", id: task.id, row: { ...task, ...fields } })),
      tasks.map((task, idx) => ({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "task",
        id: task.id,
        fields,
        queuedAt: queuedAt + idx,
      })),
    );
  }

  private liveTask(id: string): TaskRow | null {
    return this.state.snapshot.tasks.find((t) => t.id === id) ?? null;
  }

  // ---- Checklists ----

  async addChecklistItem(taskId: string, title: string): Promise<ChecklistItemRow> {
    const trimmed = title.trim();
    if (!trimmed) throw new Error("Checklist item title is required");
    const existing = this.state.snapshot.checklistItems.filter((c) => !c.deletedAt && c.taskId === taskId);
    const maxPos = existing.reduce((m, c) => Math.max(m, c.position ?? 0), -1);
    const id = newId("chk");
    const now = new Date().toISOString();
    const fields: Record<string, unknown> = {
      taskId,
      title: trimmed,
      checked: false,
      checkedAt: null,
      position: maxPos + 1,
      createdAt: now,
    };
    const row: ChecklistItemRow = { id, taskId, title: trimmed, ...fields };
    await this.commit(
      [{ entity: "checklistItem", action: "put", id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "checklistItem", id, fields, queuedAt: Date.now() }],
    );
    return row;
  }

  async toggleChecklistItem(item: ChecklistItemRow): Promise<void> {
    const nextChecked = !item.checked;
    const now = new Date().toISOString();
    const fields: Record<string, unknown> = {
      checked: nextChecked,
      checkedAt: nextChecked ? now : null,
    };
    const row: ChecklistItemRow = { ...item, ...fields };
    await this.commit(
      [{ entity: "checklistItem", action: "put", id: item.id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "checklistItem", id: item.id, fields, queuedAt: Date.now() }],
    );
  }

  async deleteChecklistItem(item: ChecklistItemRow): Promise<void> {
    await this.commit(
      [{ entity: "checklistItem", action: "delete", id: item.id }],
      [{ clientOpId: newClientOpId(), op: "delete", entity: "checklistItem", id: item.id, queuedAt: Date.now() }],
    );
  }

  // ---- Tags ----

  async createTag(name: string, color: string | null = null): Promise<TagRow> {
    const trimmed = name.trim();
    if (!trimmed) throw new Error("Tag name is required");
    const existing = this.state.snapshot.tags.find(
      (t) => !t.deletedAt && t.name.toLowerCase() === trimmed.toLowerCase(),
    );
    if (existing) return existing;
    const id = newId("tag");
    const pos = this.state.snapshot.tags.length;
    const fields: Record<string, unknown> = { name: trimmed, color, position: pos };
    const row: TagRow = { id, name: trimmed, color, position: pos };
    await this.commit(
      [{ entity: "tag", action: "put", id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "tag", id, fields, queuedAt: Date.now() }],
    );
    return row;
  }

  async toggleTaskTag(task: TaskRow, tagId: string): Promise<void> {
    const current = Array.isArray(task.tags) ? [...task.tags] : [];
    const idx = current.indexOf(tagId);
    if (idx === -1) current.push(tagId);
    else current.splice(idx, 1);
    await this.updateTaskFields(task, { tags: current.length ? current : null });
  }

  // ---- References (validated & normalized via shared Rust WASM core) ----

  async addReference(taskId: string, rawInput: string): Promise<TaskRefRow> {
    await ensureCoreReady();
    const parsed = parseRef(rawInput.trim());
    const deletedCount = this.state.snapshot.taskRefs.filter(
      (r) => r.deletedAt && r.taskId === taskId && r.key === parsed.key,
    ).length;
    const id = taskRefId(taskId, parsed.key, deletedCount);
    const now = new Date().toISOString();
    const snapshot = {
      title: parsed.rawId,
      ...(parsed.url ? { url: parsed.url } : {}),
      rawId: parsed.rawId,
    };
    const fields: Record<string, unknown> = {
      taskId,
      key: parsed.key,
      role: "about",
      snapshot,
      createdAt: now,
    };
    const row: TaskRefRow = {
      id,
      taskId,
      key: parsed.key,
      kind: parsed.kind,
      role: "about",
      snapshot,
      createdAt: now,
    };
    await this.commit(
      [{ entity: "taskRef", action: "put", id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "taskRef", id, fields, queuedAt: Date.now() }],
    );
    return row;
  }

  async removeReference(ref: TaskRefRow): Promise<void> {
    await this.commit(
      [{ entity: "taskRef", action: "delete", id: ref.id }],
      [{ clientOpId: newClientOpId(), op: "delete", entity: "taskRef", id: ref.id, queuedAt: Date.now() }],
    );
  }

  // ---- Attachments (metadata sync + R2 binary PUT) ----

  async uploadAttachment(taskId: string, file: File): Promise<AttachmentRow> {
    await ensureCoreReady();
    const maxBytes = 26_214_400; // ENTITY_LIMITS.maxAttachmentBytes
    if (file.size > maxBytes) {
      throw new Error(`File exceeds the 25 MB attachment limit (${file.name}).`);
    }
    const id = newId("att");
    const now = new Date().toISOString();
    const existing = this.state.snapshot.attachments.filter((a) => !a.deletedAt && a.taskId === taskId);
    const maxPos = existing.reduce((m, a) => Math.max(m, a.position ?? 0), -1);
    const contentType = file.type || "application/octet-stream";
    const fields: Record<string, unknown> = {
      taskId,
      filename: file.name,
      contentType,
      byteCount: file.size,
      position: maxPos + 1,
      createdAt: now,
    };
    const row: AttachmentRow = {
      id,
      taskId,
      filename: file.name,
      contentType,
      byteCount: file.size,
      position: maxPos + 1,
      createdAt: now,
    };
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "upsert",
      entity: "attachment",
      id,
      fields,
      queuedAt: Date.now(),
    };
    // Push metadata first so the server accepts PUT /v1/attachments/:id.
    const pushRes = await this.api.push([op]);
    const rejected = pushRes.results.find((r) => r.status === "rejected");
    if (rejected && rejected.status === "rejected") {
      throw new Error(rejected.reason);
    }
    await this.api.uploadAttachmentBytes(id, file);
    const uploadedRow: AttachmentRow = { ...row, uploadedAt: new Date().toISOString() };
    await this.store.commitLocalAndQueue([{ entity: "attachment", action: "put", id, row: uploadedRow }], []);
    await this.reloadFromDisk();
    this.broadcastChange();
    this.scheduleSync();
    return uploadedRow;
  }

  async deleteAttachment(att: AttachmentRow): Promise<void> {
    await this.commit(
      [{ entity: "attachment", action: "delete", id: att.id }],
      [{ clientOpId: newClientOpId(), op: "delete", entity: "attachment", id: att.id, queuedAt: Date.now() }],
    );
  }

  // ---- Reminders ----

  async setTaskReminder(
    task: TaskRow,
    reminderAt: string | null,
    mode: "floating" | "fixed" = "floating",
  ): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, {
      reminderAt,
      reminderMode: reminderAt ? mode : null,
      reminderSnoozedUntil: null,
      reminderDismissedAt: null,
      touchedAt: now,
    });
  }

  async snoozeTaskReminder(task: TaskRow, untilIso: string): Promise<void> {
    await ensureCoreReady();
    await this.patchTask(task, {
      reminderSnoozedUntil: untilIso,
      reminderDismissedAt: null,
      touchedAt: new Date().toISOString(),
    });
  }

  async dismissTaskReminder(task: TaskRow): Promise<void> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    await this.patchTask(task, {
      reminderDismissedAt: now,
      reminderSnoozedUntil: null,
      touchedAt: now,
    });
  }

  // ---- Duplicate, Reorder, Bulk Operations, Fade Pass & JSON Import ----

  async duplicateTask(task: TaskRow): Promise<TaskRow> {
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const id = newId("w");
    const fields: Record<string, unknown> = {
      title: task.title,
      status: "open",
      kind: task.kind ?? null,
      heading: task.heading ?? null,
      area: task.area ?? null,
      project: task.project ?? null,
      notes: task.notes ?? null,
      today: Boolean(task.today),
      todaySetOn: task.today ? todayYMD : null,
      starred: Boolean(task.starred),
      scheduled: task.scheduled ?? null,
      deadline: task.deadline ?? null,
      startTime: task.startTime ?? null,
      durationMinutes: task.durationMinutes ?? null,
      timeZone: task.timeZone ?? null,
      tags: task.tags ?? null,
      created: todayYMD,
      createdAt: now,
      touchedAt: now,
      source: "app",
      sourceClient: "web",
    };
    const row: TaskRow = { id, title: task.title, status: "open", ...fields };
    const queuedAt = Date.now();
    const mutations: LocalMutation[] = [{ entity: "task", action: "put", id, row }];
    const ops: OutboxOp[] = [{ clientOpId: newClientOpId(), op: "upsert", entity: "task", id, fields, queuedAt }];

    const items = this.state.snapshot.checklistItems
      .filter((c) => !c.deletedAt && c.taskId === task.id)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
    items.forEach((item, idx) => {
      const cid = newId("chk");
      const cFields: Record<string, unknown> = {
        taskId: id,
        title: item.title,
        checked: false,
        checkedAt: null,
        position: idx,
        createdAt: now,
      };
      mutations.push({
        entity: "checklistItem",
        action: "put",
        id: cid,
        row: { id: cid, taskId: id, title: item.title, ...cFields },
      });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "checklistItem",
        id: cid,
        fields: cFields,
        queuedAt: queuedAt + idx + 1,
      });
    });

    await this.commit(mutations, ops);
    return row;
  }

  async reorderTasks(orderedIds: string[], field: "position" | "todayPosition"): Promise<void> {
    if (orderedIds.length === 0) return;
    const byId = new Map(this.state.snapshot.tasks.map((t) => [t.id, t]));
    const mutations: LocalMutation[] = [];
    const ops: OutboxOp[] = [];
    const queuedAt = Date.now();
    orderedIds.forEach((id, index) => {
      const task = byId.get(id);
      if (!task) return;
      const nextPos = (index + 1) * 1000;
      if (task[field] === nextPos) return;
      const patch = { [field]: nextPos };
      mutations.push({ entity: "task", action: "put", id, row: { ...task, ...patch } });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "task",
        id,
        fields: patch,
        queuedAt: queuedAt + index,
      });
    });
    if (mutations.length > 0) await this.commit(mutations, ops);
  }

  async bulkUpdateTasks(tasks: TaskRow[], fields: Record<string, unknown>): Promise<void> {
    await this.patchTasks(tasks, { ...fields, touchedAt: new Date().toISOString() });
  }

  async bulkToggleToday(
    tasks: TaskRow[],
    putOnToday: boolean,
    mode: RescheduleMode = "makeException",
  ): Promise<void> {
    if (tasks.length === 0) return;
    await ensureCoreReady();
    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    const queuedAt = Date.now();
    const mutations: LocalMutation[] = [];
    const ops: OutboxOp[] = [];
    const toRebase: Array<{ task: TaskRow; newAnchor: string }> = [];
    tasks.forEach((task, idx) => {
      const datePatch = applyDateAction(
        task,
        putOnToday ? { type: "putOnToday", mode } : { type: "removeFromToday" },
        todayYMD,
        now,
      );
      if (Object.keys(datePatch).length === 0) return;
      const patch = { ...datePatch, touchedAt: now };
      mutations.push({ entity: "task", action: "put", id: task.id, row: { ...task, ...patch } });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "task",
        id: task.id,
        fields: patch,
        queuedAt: queuedAt + idx,
      });
      if (
        putOnToday &&
        mode === "updateRule" &&
        typeof datePatch.recurrenceAnchorDate === "string" &&
        task.recurrenceUnit &&
        !task.recurrenceAfterCompletion
      ) {
        toRebase.push({ task, newAnchor: datePatch.recurrenceAnchorDate });
      }
    });
    if (mutations.length > 0) await this.commit(mutations, ops);
    for (const item of toRebase) {
      await this.rebaseFixedSeries(item.task, item.newAnchor);
    }
  }

  async bulkDeleteTasks(tasks: TaskRow[]): Promise<void> {
    if (tasks.length === 0) return;
    const now = new Date().toISOString();
    const queuedAt = Date.now();
    const mutations: LocalMutation[] = [];
    const ops: OutboxOp[] = [];
    tasks.forEach((task, idx) => {
      mutations.push({ entity: "task", action: "put", id: task.id, row: { ...task, deletedAt: now } });
      ops.push({
        clientOpId: newClientOpId(),
        op: "delete",
        entity: "task",
        id: task.id,
        queuedAt: queuedAt + idx,
      });
    });
    await this.commit(mutations, ops);
  }

  async purgeDeletedTasks(tasks: TaskRow[]): Promise<void> {
    if (tasks.length === 0) return;
    const mutations: LocalMutation[] = tasks.map((t) => ({
      entity: "task",
      action: "delete",
      id: t.id,
    }));
    await this.store.commitLocalAndQueue(mutations, []);
    await this.reloadFromDisk();
    this.broadcastChange();
  }

  async importBackup(preview: ParsedBackupPreview): Promise<number> {
    await ensureCoreReady();
    const snap = this.state.snapshot;
    const existingAreas = new Set(snap.areas.map((a) => a.id));
    const existingProjects = new Set(snap.projects.map((p) => p.id));
    const existingTags = new Set(snap.tags.map((t) => t.id));
    const existingTasks = new Set(snap.tasks.map((t) => t.id));
    const existingChecks = new Set(snap.checklistItems.map((c) => c.id));
    const existingRefs = new Set(snap.taskRefs.map((r) => r.id));

    const now = new Date().toISOString();
    const todayYMD = localTodayYMD();
    let queuedAt = Date.now();
    const mutations: LocalMutation[] = [];
    const ops: OutboxOp[] = [];
    let count = 0;

    for (const a of preview.areas) {
      if (existingAreas.has(a.id)) continue;
      const fields: Record<string, unknown> = {
        title: a.title,
        context: a.context ?? null,
        emoji: a.emoji ?? null,
        position: a.position ?? count,
      };
      mutations.push({ entity: "area", action: "put", id: a.id, row: { ...a, ...fields } });
      ops.push({ clientOpId: newClientOpId(), op: "upsert", entity: "area", id: a.id, fields, queuedAt: queuedAt++ });
      count++;
    }

    for (const p of preview.projects) {
      if (existingProjects.has(p.id)) continue;
      const fields: Record<string, unknown> = {
        title: p.title,
        status: p.status,
        area: p.area ?? null,
        notes: p.notes ?? null,
        created: p.created ?? todayYMD,
        position: p.position ?? count,
      };
      mutations.push({ entity: "project", action: "put", id: p.id, row: { ...p, ...fields } });
      ops.push({ clientOpId: newClientOpId(), op: "upsert", entity: "project", id: p.id, fields, queuedAt: queuedAt++ });
      count++;
    }

    for (const t of preview.tags) {
      if (existingTags.has(t.id)) continue;
      const fields: Record<string, unknown> = {
        name: t.name,
        color: t.color ?? null,
        position: t.position ?? count,
      };
      mutations.push({ entity: "tag", action: "put", id: t.id, row: { ...t, ...fields } });
      ops.push({ clientOpId: newClientOpId(), op: "upsert", entity: "tag", id: t.id, fields, queuedAt: queuedAt++ });
      count++;
    }

    for (const task of preview.tasks) {
      if (existingTasks.has(task.id)) continue;
      const fields: Record<string, unknown> = {
        title: task.title,
        status: task.status,
        kind: task.kind ?? null,
        heading: task.heading ?? null,
        area: task.area ?? null,
        project: task.project ?? null,
        notes: task.notes ?? null,
        today: Boolean(task.today),
        todaySetOn: task.todaySetOn ?? (task.today ? todayYMD : null),
        starred: Boolean(task.starred),
        scheduled: task.scheduled ?? null,
        deadline: task.deadline ?? null,
        startTime: task.startTime ?? null,
        durationMinutes: task.durationMinutes ?? null,
        tags: task.tags ?? null,
        position: task.position ?? null,
        todayPosition: task.todayPosition ?? null,
        created: task.created ?? todayYMD,
        createdAt: task.createdAt ?? now,
        completedAt: task.completedAt ?? null,
        touchedAt: now,
        source: "app",
        sourceClient: "web",
        recurrenceUnit: task.recurrenceUnit ?? null,
        recurrenceInterval: task.recurrenceInterval ?? null,
        recurrenceAfterCompletion: Boolean(task.recurrenceAfterCompletion),
        recurrencePaused: Boolean(task.recurrencePaused),
      };
      mutations.push({ entity: "task", action: "put", id: task.id, row: { ...task, ...fields } });
      ops.push({ clientOpId: newClientOpId(), op: "upsert", entity: "task", id: task.id, fields, queuedAt: queuedAt++ });
      count++;
    }

    for (const c of preview.checklistItems) {
      if (existingChecks.has(c.id)) continue;
      const fields: Record<string, unknown> = {
        taskId: c.taskId,
        title: c.title,
        checked: Boolean(c.checked),
        checkedAt: c.checkedAt ?? null,
        position: c.position ?? 0,
        createdAt: now,
      };
      mutations.push({ entity: "checklistItem", action: "put", id: c.id, row: { ...c, ...fields } });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "checklistItem",
        id: c.id,
        fields,
        queuedAt: queuedAt++,
      });
      count++;
    }

    for (const r of preview.taskRefs) {
      if (existingRefs.has(r.id)) continue;
      const fields: Record<string, unknown> = {
        taskId: r.taskId,
        key: r.key,
        role: r.role ?? "about",
        snapshot: r.snapshot ?? null,
        position: r.position ?? 0,
        createdAt: now,
      };
      mutations.push({ entity: "taskRef", action: "put", id: r.id, row: { ...r, ...fields } });
      ops.push({
        clientOpId: newClientOpId(),
        op: "upsert",
        entity: "taskRef",
        id: r.id,
        fields,
        queuedAt: queuedAt++,
      });
      count++;
    }

    if (mutations.length > 0) {
      await this.commit(mutations, ops);
    }
    return count;
  }

  // ---- Areas & Projects ----

  async createArea(title: string, emoji: string | null = null): Promise<AreaRow> {
    const trimmed = title.trim();
    if (!trimmed) throw new Error("Area title is required");
    const id = newId("area");
    const position = this.state.snapshot.areas.filter((a) => !a.deletedAt).length;
    const fields: Record<string, unknown> = { title: trimmed, emoji, position };
    const row: AreaRow = { id, title: trimmed, emoji, position };
    await this.commit(
      [{ entity: "area", action: "put", id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "area", id, fields, queuedAt: Date.now() }],
    );
    return row;
  }

  async updateArea(area: AreaRow, fields: Record<string, unknown>): Promise<void> {
    const row: AreaRow = { ...area, ...fields };
    await this.commit(
      [{ entity: "area", action: "put", id: area.id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "area", id: area.id, fields, queuedAt: Date.now() }],
    );
  }

  async deleteArea(area: AreaRow): Promise<void> {
    await this.commit(
      [{ entity: "area", action: "delete", id: area.id }],
      [{ clientOpId: newClientOpId(), op: "delete", entity: "area", id: area.id, queuedAt: Date.now() }],
    );
  }

  async createProject(title: string, areaId: string | null = null): Promise<ProjectRow> {
    const trimmed = title.trim();
    if (!trimmed) throw new Error("Project title is required");
    const id = newId("proj");
    const position = this.state.snapshot.projects.filter((p) => !p.deletedAt).length;
    const fields: Record<string, unknown> = {
      title: trimmed,
      status: "active",
      area: areaId,
      created: localTodayYMD(),
      position,
    };
    const row: ProjectRow = { id, title: trimmed, status: "active", area: areaId, position };
    await this.commit(
      [{ entity: "project", action: "put", id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "project", id, fields, queuedAt: Date.now() }],
    );
    return row;
  }

  async updateProject(project: ProjectRow, fields: Record<string, unknown>): Promise<void> {
    const row: ProjectRow = { ...project, ...fields };
    await this.commit(
      [{ entity: "project", action: "put", id: project.id, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "project", id: project.id, fields, queuedAt: Date.now() }],
    );
  }

  async deleteProject(project: ProjectRow): Promise<void> {
    await this.commit(
      [{ entity: "project", action: "delete", id: project.id }],
      [{ clientOpId: newClientOpId(), op: "delete", entity: "project", id: project.id, queuedAt: Date.now() }],
    );
  }

  // ---- Agent Conversations (Review, Agent stages, Discuss) ----

  private existingConvo(taskId: string): ConvoRow {
    return this.state.snapshot.convos.find((c) => c.id === taskId) ?? { id: taskId };
  }

  private nextTurnSeq(taskId: string): number {
    const turns = this.state.snapshot.turns.filter((t) => t.taskId === taskId);
    return turns.reduce((m, t) => Math.max(m, t.seq), 0) + 1;
  }

  async assignTaskToAgent(taskId: string, assignee: "claude" | "me"): Promise<void> {
    const convo = this.existingConvo(taskId);
    const fields: Record<string, unknown> = {
      assignee,
      ...(assignee === "claude" ? { stoppedAt: null } : {}),
    };
    const row: ConvoRow = { ...convo, ...fields };
    await this.commit(
      [{ entity: "convo", action: "put", id: taskId, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "convo", id: taskId, fields, queuedAt: Date.now() }],
    );
  }

  async stopAgentOnTask(taskId: string): Promise<void> {
    const convo = this.existingConvo(taskId);
    const fields = { stoppedAt: new Date().toISOString() };
    await this.commit(
      [{ entity: "convo", action: "put", id: taskId, row: { ...convo, ...fields } }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "convo", id: taskId, fields, queuedAt: Date.now() }],
    );
  }

  async resumeAgentOnTask(taskId: string): Promise<void> {
    const convo = this.existingConvo(taskId);
    const fields = { stoppedAt: null };
    await this.commit(
      [{ entity: "convo", action: "put", id: taskId, row: { ...convo, ...fields } }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "convo", id: taskId, fields, queuedAt: Date.now() }],
    );
  }

  async appendUserTurn(
    taskId: string,
    input: {
      step?: WireTurn["step"];
      chosen?: string | null;
      otherText?: string | null;
      inReplyTo?: number | null;
      note?: string | null;
    },
  ): Promise<void> {
    const now = new Date().toISOString();
    const seq = this.nextTurnSeq(taskId);
    const turn: WireTurn = {
      role: "user",
      step: input.step ?? (input.inReplyTo ? "decide" : "work"),
      ...(input.chosen ? { chosen: input.chosen } : {}),
      ...(input.otherText ? { otherText: input.otherText } : {}),
      ...(input.inReplyTo ? { inReplyTo: input.inReplyTo } : {}),
      ...(input.note ? { note: input.note } : {}),
      ts: now,
    };
    const localTurn: TurnRow = {
      id: turnSyntheticId(taskId, seq),
      taskId,
      seq,
      ...turn,
    };
    const op: OutboxOp = {
      clientOpId: newClientOpId(),
      op: "appendTurn",
      taskId,
      turn,
      queuedAt: Date.now(),
    };
    await this.commit([{ entity: "turn", action: "put", id: localTurn.id, row: localTurn }], [op]);
  }

  acceptAgentReview(task: TaskRow): Promise<CompletionReceipt> {
    return this.completeTasks([task]);
  }

  /** Undo of Accept and Send back: the task waits in Review again, with its note. */
  async restoreReview(convo: ConvoRow): Promise<void> {
    const fields = {
      endState: convo.endState ?? null,
      endStateNote: convo.endStateNote ?? null,
      assignee: convo.assignee ?? null,
      stoppedAt: convo.stoppedAt ?? null,
    };
    await this.commit(
      [{ entity: "convo", action: "put", id: convo.id, row: { ...this.existingConvo(convo.id), ...fields } }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "convo", id: convo.id, fields, queuedAt: Date.now() }],
    );
  }

  /** Sends a hand-off back with the user's note. Returns the conversation it replaced. */
  async sendBackAgentReview(task: TaskRow, note: string): Promise<ConvoRow> {
    const trimmed = note.trim();
    if (!trimmed) throw new Error("Send back needs a note");
    const now = new Date().toISOString();
    const convo = this.existingConvo(task.id);
    const convoFields: Record<string, unknown> = {
      endState: "open",
      endStateNote: null,
      stoppedAt: null,
      assignee: "claude",
    };
    const seq = this.nextTurnSeq(task.id);
    const turn: WireTurn = {
      role: "user",
      step: "work",
      note: trimmed,
      ts: now,
    };
    const localTurn: TurnRow = { id: turnSyntheticId(task.id, seq), taskId: task.id, seq, ...turn };
    const nowMs = Date.now();
    await this.commit(
      [
        { entity: "convo", action: "put", id: task.id, row: { ...convo, ...convoFields } },
        { entity: "turn", action: "put", id: localTurn.id, row: localTurn },
      ],
      [
        { clientOpId: newClientOpId(), op: "upsert", entity: "convo", id: task.id, fields: convoFields, queuedAt: nowMs },
        { clientOpId: newClientOpId(), op: "appendTurn", taskId: task.id, turn, queuedAt: nowMs + 1 },
      ],
    );
    return convo;
  }

  async setSetting(key: string, value: unknown): Promise<void> {
    const row = { id: key, value };
    await this.commit(
      [{ entity: "setting", action: "put", id: key, row }],
      [{ clientOpId: newClientOpId(), op: "upsert", entity: "setting", id: key, fields: { value }, queuedAt: Date.now() }],
    );
  }

  // ---- Sync loop (push with WASM bisection, then pull with WASM merge) ----

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
        await this.runFadePassIfDue();
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

  private async pushBatchWithBisection(batch: OutboxOp[]): Promise<void> {
    if (!batch.length) return;
    const sentIds = batch.map((o) => o.clientOpId);
    try {
      const res = await this.api.push(batch);
      const plan = planPushResponse(sentIds, {
        kind: "response",
        resultIds: res.results.map((r) => r.clientOpId),
      });
      if (plan.plan === "fail") {
        throw new Error(plan.reason);
      }

      const doneIds: string[] = [];
      const newlyRejected: NotSyncedItem[] = [];
      for (const r of res.results) {
        doneIds.push(r.clientOpId);
        if (r.status === "rejected") {
          const orig = batch.find((o) => o.clientOpId === r.clientOpId);
          newlyRejected.push({
            clientOpId: r.clientOpId,
            entity: orig?.op === "appendTurn" ? "turn" : (orig?.entity ?? "task"),
            id: orig?.op === "appendTurn" ? orig.taskId : (orig?.id ?? ""),
            reason: r.reason,
            at: Date.now(),
          });
        }
      }
      await this.store.removeOutboxOps(doneIds);
      if (newlyRejected.length) {
        this.emit({ notSynced: [...this.state.notSynced, ...newlyRejected].slice(-20) });
      }
    } catch (err) {
      if (!(err instanceof ApiError)) throw err;
      const plan = planPushResponse(sentIds, {
        kind: "httpFailure",
        status: err.status,
        body: err.rawBody || err.message,
      });
      if (plan.plan === "bisect") {
        await this.pushBatchWithBisection(batch.slice(0, plan.splitAt));
        await this.pushBatchWithBisection(batch.slice(plan.splitAt));
        return;
      }
      if (plan.plan === "rejectOne") {
        const orig = batch.find((o) => o.clientOpId === plan.clientOpId);
        await this.store.removeOutboxOps([plan.clientOpId]);
        this.emit({
          notSynced: [
            ...this.state.notSynced,
            {
              clientOpId: plan.clientOpId,
              entity: orig?.op === "appendTurn" ? "turn" : (orig?.entity ?? "task"),
              id: orig?.op === "appendTurn" ? orig.taskId : (orig?.id ?? ""),
              reason: plan.reason,
              at: Date.now(),
            },
          ].slice(-20),
        });
        return;
      }
      throw err;
    }
  }

  private async drainOutbox(): Promise<void> {
    while (!this.stopped) {
      const snap = await this.store.loadSnapshot();
      if (!snap.outbox.length) return;
      const batch = snap.outbox.slice(0, 100);
      await this.pushBatchWithBisection(batch);
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
        throw new Error(check.reason);
      }

      const maps: Record<SyncedEntity, Map<string, Record<string, unknown>>> = {
        task: new Map(snap.tasks.map((r) => [r.id, r])),
        area: new Map(snap.areas.map((r) => [r.id, r])),
        project: new Map(snap.projects.map((r) => [r.id, r])),
        checklistItem: new Map(snap.checklistItems.map((r) => [r.id, r])),
        tag: new Map(snap.tags.map((r) => [r.id, r])),
        taskRef: new Map(snap.taskRefs.map((r) => [r.id, r])),
        convo: new Map(snap.convos.map((r) => [r.id, r])),
        attachment: new Map(snap.attachments.map((r) => [r.id, r])),
        setting: new Map(Object.entries(snap.settings).map(([id, value]) => [id, { id, value }])),
      };

      const mutations: LocalMutation[] = [];

      for (const change of page.changes) {
        const entity = change.entity;
        if (entity === "turn") {
          const plan = planPullRow({
            entity: "turn",
            row: change.row,
            current: null,
            pendingFields: [],
            pendingDelete: false,
          });
          if (plan.plan === "turn") {
            const id = turnSyntheticId(plan.taskId, plan.seq);
            mutations.push({
              entity: "turn",
              action: "put",
              id,
              row: { ...plan.row, id, taskId: plan.taskId, seq: plan.seq },
            });
          }
          continue;
        }

        if (!isSyncedEntity(entity)) continue;
        const id = typeof change.row.id === "string" ? change.row.id : null;
        if (!id) continue;

        const entityMap = maps[entity];
        const current = entityMap.get(id) ?? null;
        const { pendingFields, pendingDelete } = pendingFieldsFor(snap.outbox, entity, id);
        const plan = planPullRow({
          entity,
          row: change.row,
          current,
          pendingFields,
          pendingDelete,
        });

        if (plan.plan === "skip" || plan.plan === "shadowOnly" || plan.plan === "turn") {
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
            entityMap.set(id, deletedRow);
          } else {
            mutations.push({ entity, action: "delete", id });
            entityMap.delete(id);
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
          entityMap.set(id, row);
        }
      }

      await this.store.applyPulledBatch(mutations, page.nextSince, Date.now());
      snap = await this.store.loadSnapshot();
      cursor = page.nextSince;

      if (check.decision === "apply") break;
    }
  }

  /**
   * The daily fade pass (docs/TASK_FADE_SPEC.md §4), as Android's
   * TaskMutator.runFadePass. It runs after a full sync, so it sees the touches
   * of other devices first, once per app day. A failed sync or a pass that the
   * setting turned off leaves the day open. It never writes `touchedAt` and is
   * not on the undo stack.
   */
  private async runFadePassIfDue(): Promise<void> {
    if (this.stopped) return;
    const snap = await this.store.loadSnapshot();
    if (!fadeSettings(snap.settings).enabled) return;
    const clock: FadeClock = {
      now: new Date().toISOString(),
      today: localTodayYMD(),
      utcOffsetSeconds: localUtcOffsetSeconds(),
    };
    const pass = `${snap.userId}:${clock.today}`;
    if (this.lastFadePass === pass) return;

    const convoById = new Map(snap.convos.map((c) => [c.id, c]));
    const turnsByTask = groupTurnsByTask(snap.turns);
    const faded = snap.tasks.filter((task) => {
      if (task.status !== "open" || task.deletedAt || task.fadedAt) return false;
      const convo = convoById.get(task.id) ?? null;
      const conversation = evaluateConversation(convo, turnsByTask.get(task.id) ?? [], clock.now);
      return shouldFade(fadeInput(task, convo, conversation, clock));
    });
    await this.patchTasks(faded, { fadedAt: clock.now });
    this.lastFadePass = pass;
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
