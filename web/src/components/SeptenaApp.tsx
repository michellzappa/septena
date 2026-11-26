"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Bell,
  Check,
  ChevronDown,
  ChevronRight,
  CircleDashed,
  CloudOff,
  Folder,
  FolderPlus,
  Inbox,
  Keyboard,
  Menu,
  PanelLeft,
  PauseCircle,
  Plus,
  RefreshCw,
  Search,
  Settings,
  Star,
  Sun,
  Tag,
  Trash2,
  Undo2,
  Wifi,
  X,
} from "lucide-react";
import { SeptenaApiClient } from "@/lib/api/client";
import {
  ensureCoreReady,
  fadeFill,
  getCoreVersion,
  localTodayYMD,
  localUtcOffsetSeconds,
  rowOpacity,
  shouldArmReminder,
  taskViewMembership,
  type CoreConversationState,
  type CoreMembership,
  type CoreProjection,
} from "@/lib/core";
import { evaluateConversation, groupTurnsByTask } from "@/lib/conversation";
import { addDays, attributeLabel, todayLabel, tomorrowLabel, type DateBoardAttribute } from "@/lib/dateBoard";
import {
  SIDEBAR_DESTINATIONS,
  BADGE_GROUP_IDS,
  destinationGroups,
  destinationInfo,
  reviewGroupOf,
  type SidebarDestination,
} from "@/lib/destinations";
import {
  fadeInput,
  fadeSettings,
  isInCurrentSweep,
  isSweepDue,
  sweepAnchorDay,
} from "@/lib/fade";
import {
  ACTIONS_CATALOG,
  DESIGN_TOKENS,
  GENERIC_EMPTY_STATE,
  SURFACES_CATALOG,
  registryText,
} from "@/lib/generated/registries";
import { hexWithAlpha, type HeaderTextureStyle } from "@/lib/headerWash";
import { loadWebPrefs, saveWebPref, type WebDisplayPrefs } from "@/lib/prefs";
import { AccountSwitchRequiredError, type AccountSwitchSummary } from "@/lib/sync/accountSwitch";
import { WebSyncEngine, type CompletionReceipt, type SyncState } from "@/lib/sync/engine";
import { compareWaiting, waitingName } from "@/lib/waiting";
import { UndoStack, type UndoSnapshot } from "@/lib/sync/undo";
import type {
  ActiveDestination,
  AreaRow,
  ProjectRow,
  SessionResponse,
  SmartDestination,
  TaskRow,
} from "@/lib/types";
import { nextIsoDay } from "@/lib/upcomingGroups";
import { AccountSwitchDialog, type AccountSwitchChoice } from "./AccountSwitchDialog";
import { ContextMenu, type ContextMenuState } from "./ContextMenu";
import { DateBoardPopover, anchorOf, type DateBoardAnchor } from "./DateBoard";
import { FadeSweepModal } from "./FadeSweepModal";
import { FirstRunModal } from "./FirstRunModal";
import { HeaderWash } from "./HeaderWash";
import { KeyboardShortcutsModal } from "./KeyboardShortcutsModal";
import { QuickAddModal, type QuickAddInitial } from "./QuickAddModal";
import { QuickFindModal } from "./QuickFindModal";
import { RegistryIcon } from "./RegistryIcon";
import { SettingsModal, type SettingsTab } from "./SettingsModal";
import { SignInScreen } from "./SignInScreen";
import { TaskPageDrawer } from "./TaskPageDrawer";
import { WaitingOnDialog } from "./WaitingOnDialog";
import {
  TaskRowItem,
  openRepeatSelect,
  repeatTitle,
  whenDay,
  type TaskRowItemProps,
} from "./TaskRowItem";

interface EvaluatedTask {
  task: TaskRow;
  membership: CoreMembership;
  opacity: number;
  convoProjection: CoreProjection | null;
  convoState: CoreConversationState | null;
}

function sumRows(groups: Array<{ items: unknown[] }>): number {
  return groups.reduce((n, g) => n + g.items.length, 0);
}

const NOTICES = SURFACES_CATALOG.notices.items;
const WEEKLY_SWEEP_NOTICE = NOTICES.find((n) => n.id === "weeklySweep")!;
const FADED_PILE_NOTICE = NOTICES.find((n) => n.id === "fadedPile")!;

function ProjectRing({ done, total }: { done: number; total: number }) {
  const pct = total > 0 ? Math.min(1, done / total) : 0;
  const r = 5.5;
  const c = 2 * Math.PI * r;
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 shrink-0" aria-hidden="true">
      <circle
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        opacity="0.35"
      />
      {pct > 0 && (
        <circle
          cx="8"
          cy="8"
          r={r}
          fill="none"
          stroke="var(--accent)"
          strokeWidth="1.75"
          strokeDasharray={`${pct * c} ${c}`}
          transform="rotate(-90 8 8)"
        />
      )}
    </svg>
  );
}

function formatDayHeading(ymd: string, todayYMD: string, lang: string): string {
  const [y, m, d] = ymd.split("-").map(Number);
  const dt = new Date(y, (m || 1) - 1, d || 1);
  const [ty, tm, td] = todayYMD.split("-").map(Number);
  const todayDt = new Date(ty, (tm || 1) - 1, td || 1);
  const diffDays = Math.round((dt.getTime() - todayDt.getTime()) / (24 * 60 * 60 * 1000));
  const formatted = dt.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  if (diffDays === 1) return `${tomorrowLabel(lang)} · ${formatted}`;
  if (diffDays === 0) return `${todayLabel(lang)} · ${formatted}`;
  return formatted;
}

/** Every field that a date action can change: what its undo entry restores. */
/** The fields Waiting On… and Got It Back can change, for their undo. */
function waitingFields(task: TaskRow): Record<string, unknown> {
  return {
    waitingOn: task.waitingOn ?? null,
    waitingSince: task.waitingSince ?? null,
    fadedAt: task.fadedAt ?? null,
    ...dateFields(task),
  };
}

function dateFields(task: TaskRow): Record<string, unknown> {
  return {
    scheduled: task.scheduled ?? null,
    deadline: task.deadline ?? null,
    deferredDeadline: task.deferredDeadline ?? null,
    today: Boolean(task.today),
    todaySetOn: task.todaySetOn ?? null,
    startTime: task.startTime ?? null,
    durationMinutes: task.durationMinutes ?? null,
    timeZone: task.timeZone ?? null,
    reminderAt: task.reminderAt ?? null,
    recurrenceAnchorDate: task.recurrenceAnchorDate ?? null,
  };
}

export function SeptenaApp() {
  const apiRef = useRef<SeptenaApiClient | null>(null);
  const engineRef = useRef<WebSyncEngine | null>(null);
  const undoRef = useRef<UndoStack | null>(null);
  if (!apiRef.current) apiRef.current = new SeptenaApiClient();
  if (!engineRef.current) engineRef.current = new WebSyncEngine(apiRef.current);
  if (!undoRef.current) undoRef.current = new UndoStack();

  const api = apiRef.current;
  const engine = engineRef.current;
  const undoStack = undoRef.current;

  const [bootPhase, setBootPhase] = useState<"loading" | "signed_out" | "signed_in">("loading");
  const [syncState, setSyncState] = useState<SyncState>(() => engine.getState());
  const [undoSnap, setUndoSnap] = useState<UndoSnapshot>(() => undoStack.getSnapshot());
  const [prefs, setPrefs] = useState<WebDisplayPrefs>(() => loadWebPrefs());
  const [systemDark, setSystemDark] = useState<boolean>(false);

  const [destination, setDestination] = useState<ActiveDestination>({ kind: "smart", id: "today" });
  const [logbookTab, setLogbookTab] = useState<"completed" | "deleted">("completed");
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set());
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [taskPageId, setTaskPageId] = useState<string | null>(null);
  const [inboxCollapsed, setInboxCollapsed] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [tagFilterId, setTagFilterId] = useState<string | null>(null);
  const [composerTitle, setComposerTitle] = useState("");
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  // Modals & notices
  const [quickFindOpen, setQuickFindOpen] = useState(false);
  const [quickAddOpen, setQuickAddOpen] = useState(false);
  const [quickAddInitial, setQuickAddInitial] = useState<QuickAddInitial | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [settingsInitialTab, setSettingsInitialTab] = useState<SettingsTab | undefined>(undefined);
  /** A new session for another account, waiting for the user's answer (#575). Null: no question. */
  const [accountSwitch, setAccountSwitch] = useState<
    { userId: string; summary: AccountSwitchSummary } | null
  >(null);
  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  /** The tasks of the open keep-or-let-go sheet, fixed when it opens. Null: closed. */
  const [sweepTasks, setSweepTasks] = useState<TaskRow[] | null>(null);
  const [waitingTaskId, setWaitingTaskId] = useState<string | null>(null);
  const [firstRunOpen, setFirstRunOpen] = useState(false);
  const [infoToast, setInfoToast] = useState<string | null>(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [datePicker, setDatePicker] = useState<{
    attribute: DateBoardAttribute;
    taskIds: string[];
    anchor: DateBoardAnchor;
  } | null>(null);

  // Inline creation & container notes
  const [creatingKind, setCreatingKind] = useState<"area" | "project" | "heading" | null>(null);
  const [newContainerTitle, setNewContainerTitle] = useState("");
  const [showContainerNotes, setShowContainerNotes] = useState(false);
  const [containerNotesDraft, setContainerNotesDraft] = useState("");

  // Drag-and-drop state
  const [draggedTaskId, setDraggedTaskId] = useState<string | null>(null);
  const [dropTargetTaskId, setDropTargetTaskId] = useState<string | null>(null);
  const [dropTargetSidebar, setDropTargetSidebar] = useState<string | null>(null);

  // Reminders
  const [dueReminderTask, setDueReminderTask] = useState<TaskRow | null>(null);
  const notifiedRemindersRef = useRef<Set<string>>(new Set());

  const [coreVersion, setCoreVersion] = useState<string>("");
  const [todayYMD, setTodayYMD] = useState<string>(() => localTodayYMD());
  const composerRef = useRef<HTMLInputElement | null>(null);

  const showToast = useCallback((msg: string) => {
    setInfoToast(msg);
    setTimeout(() => setInfoToast((prev) => (prev === msg ? null : prev)), 3200);
  }, []);

  const handleChangePref = useCallback(
    <K extends keyof WebDisplayPrefs>(key: K, value: WebDisplayPrefs[K]) => {
      setPrefs((prev) => ({ ...prev, [key]: value }));
      saveWebPref(key, value);
    },
    [],
  );

  // Track system dark mode changes cleanly.
  useEffect(() => {
    if (typeof window === "undefined") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    setSystemDark(mq.matches);
    const handler = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, []);

  // Register offline shell Service Worker.
  useEffect(() => {
    if (typeof window !== "undefined" && "serviceWorker" in navigator) {
      navigator.serviceWorker.register("/sw.js").catch(() => {});
    }
  }, []);

  // Handle PWA Web Share Target query params (?share_title=&share_text=&share_url=).
  useEffect(() => {
    if (typeof window === "undefined" || bootPhase !== "signed_in") return;
    const params = new URLSearchParams(window.location.search);
    const shareTitle = params.get("share_title") ?? "";
    const shareText = params.get("share_text") ?? "";
    const shareUrl = params.get("share_url") ?? "";
    if (!shareTitle && !shareText && !shareUrl) return;

    const extractedUrl =
      shareUrl ||
      (shareText.match(/https?:\/\/\S+/)?.[0] ?? "");
    const title = shareTitle.trim() || shareText.trim().split("\n")[0] || extractedUrl;
    const notes = shareTitle && shareText && shareText !== shareTitle ? shareText : "";

    setQuickAddInitial({
      title,
      notes,
      referenceUrl: extractedUrl || undefined,
      today: false,
    });
    setQuickAddOpen(true);
    window.history.replaceState({}, "", window.location.pathname);
  }, [bootPhase]);

  // DayClock midnight rollover watcher.
  useEffect(() => {
    const checkRollover = () => {
      const current = localTodayYMD();
      setTodayYMD((prev) => (prev === current ? prev : current));
    };
    const interval = setInterval(checkRollover, 60_000);
    window.addEventListener("focus", checkRollover);
    return () => {
      clearInterval(interval);
      window.removeEventListener("focus", checkRollover);
    };
  }, []);

  useEffect(() => engine.subscribe(setSyncState), [engine]);
  useEffect(() => undoStack.subscribe(setUndoSnap), [undoStack]);

  // Starts sync for a session. When the session is for another account and
  // this device holds that account's data, it asks first instead (#575):
  // `accountSwitch` shows the question and the boot phase does not change.
  const beginSession = useCallback(
    async (userId: string, replaceOtherAccount = false): Promise<void> => {
      if (!replaceOtherAccount) {
        const summary = await engine.accountSwitchSummary(userId);
        if (summary) {
          setAccountSwitch({ userId, summary });
          return;
        }
      }
      setBootPhase("signed_in");
      try {
        await engine.start(userId, { replaceOtherAccount });
      } catch (err) {
        if (!(err instanceof AccountSwitchRequiredError)) throw err;
        // Another tab wrote between the check and the start: ask now.
        engine.stop();
        setAccountSwitch({ userId, summary: err.summary });
      }
    },
    [engine],
  );

  // Boot: load WASM core, restore cookie session (or offline cached account).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      await ensureCoreReady();
      if (cancelled) return;
      setCoreVersion(getCoreVersion());
      const disk = await engine.loadFromDisk();

      try {
        const session = await api.restoreSession();
        if (cancelled) return;
        if (session) {
          await beginSession(session.userId);
          return;
        }
      } catch {
        if (!cancelled && disk.userId) {
          setBootPhase("signed_in");
          await engine.start(disk.userId);
          return;
        }
      }

      if (!cancelled) {
        if (!navigator.onLine && disk.userId) {
          setBootPhase("signed_in");
          await engine.start(disk.userId);
        } else {
          setBootPhase("signed_out");
        }
      }
    })();

    return () => {
      cancelled = true;
      engine.stop();
    };
  }, [api, beginSession, engine]);

  const isDark =
    prefs.appearanceMode === "dark" || (prefs.appearanceMode === "system" && systemDark);
  const accentId =
    typeof syncState.snapshot.settings.accentColor === "string"
      ? syncState.snapshot.settings.accentColor
      : "colorful";
  const activeFruit =
    DESIGN_TOKENS.fruitAccents.find((f) => f.id === accentId) ?? DESIGN_TOKENS.fruitAccents[0];
  const accentHex = isDark ? activeFruit.dark : activeFruit.light;
  const accentCheckHex = isDark ? activeFruit.checkDark : activeFruit.checkLight;
  const isColorfulAccent = activeFruit.multicolor;

  const canvasTexture = (
    typeof syncState.snapshot.settings.canvasTexture === "string"
      ? syncState.snapshot.settings.canvasTexture
      : "none"
  ) as HeaderTextureStyle;
  const textureIntensity =
    typeof syncState.snapshot.settings.textureIntensity === "number"
      ? syncState.snapshot.settings.textureIntensity
      : 55;
  const textureMotion =
    syncState.snapshot.settings.textureMotion === "slowDrift" ? "slowDrift" : "still";

  // Apply appearance mode, synced fruit accent, selection token alpha, and text scale.
  useEffect(() => {
    if (prefs.appearanceMode === "system") {
      document.documentElement.removeAttribute("data-theme");
    } else {
      document.documentElement.setAttribute("data-theme", prefs.appearanceMode);
    }
    const selAlpha = isDark
      ? DESIGN_TOKENS.selection.emphasizedAlphaDark
      : DESIGN_TOKENS.selection.emphasizedAlphaLight;
    document.documentElement.style.setProperty("--accent", accentHex);
    document.documentElement.style.setProperty("--accent-check", accentCheckHex);
    document.documentElement.style.setProperty("--bg-selected", hexWithAlpha(accentHex, selAlpha));

    const scaleObj = DESIGN_TOKENS.textScale.steps.find((s) => s.step === prefs.textSizeStep);
    document.documentElement.style.fontSize = `${Math.round((scaleObj?.factor ?? 1) * 16)}px`;
  }, [accentCheckHex, accentHex, isDark, prefs.appearanceMode, prefs.textSizeStep]);

  const handleSignedIn = useCallback(
    async (session: SessionResponse) => {
      await beginSession(session.userId);
    },
    [beginSession],
  );

  // The answer to the account-switch question. Every path ends in a phase:
  // Replace starts the new account; Cancel and Export sign the new session out
  // and keep this device's tasks (never `signOutAndWipe`).
  const handleAccountSwitchChoice = useCallback(
    async (choice: AccountSwitchChoice) => {
      const pending = accountSwitch;
      if (!pending) return;
      setAccountSwitch(null);
      if (choice === "replace") {
        undoStack.clear();
        setExpandedTaskId(null);
        setTaskPageId(null);
        setSelectedTaskId(null);
        setSelectedIds(new Set());
        try {
          await beginSession(pending.userId, true);
          return;
        } catch {
          // The replace did not start: fall through and sign out, keeping
          // whatever is still on this device, so the app never stays on Loading.
        }
      }
      try {
        await api.signOut();
      } catch {
        // The session is dropped locally either way (`signOut` clears it in `finally`).
      }
      setBootPhase("signed_out");
      if (choice === "exportFirst") {
        setSettingsInitialTab("privacy");
        setSettingsOpen(true);
      }
    },
    [accountSwitch, api, beginSession, undoStack],
  );

  const handleSignOut = useCallback(async () => {
    undoStack.clear();
    await engine.signOutAndWipe();
    setExpandedTaskId(null);
    setTaskPageId(null);
    setSelectedTaskId(null);
    setSelectedIds(new Set());
    setBootPhase("signed_out");
  }, [engine, undoStack]);

  const handleDeleteAccount = useCallback(async () => {
    undoStack.clear();
    await engine.deleteAccountAndWipe();
    setExpandedTaskId(null);
    setTaskPageId(null);
    setSelectedTaskId(null);
    setSelectedIds(new Set());
    setBootPhase("signed_out");
  }, [engine, undoStack]);

  const nowIso = new Date().toISOString();
  const utcOffsetSeconds = localUtcOffsetSeconds();

  const {
    activeAreas,
    activeProjects,
    activeTags,
    areaById,
    projectById,
    projectStats,
    checklistsByTask,
    refsByTask,
    attachmentsByTask,
    convoByTask,
    turnsByTask,
  } = useMemo(() => {
    const areas = syncState.snapshot.areas
      .filter((a) => !a.deletedAt)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0) || a.title.localeCompare(b.title));
    const projects = syncState.snapshot.projects
      .filter((p) => !p.deletedAt && p.status === "active")
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0) || a.title.localeCompare(b.title));
    const tags = syncState.snapshot.tags
      .filter((t) => !t.deletedAt)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0) || a.name.localeCompare(b.name));

    const pStats = new Map<string, { done: number; total: number }>();
    for (const t of syncState.snapshot.tasks) {
      if (t.deletedAt || t.kind === "heading" || !t.project) continue;
      const cur = pStats.get(t.project) ?? { done: 0, total: 0 };
      cur.total++;
      if (t.status === "done") cur.done++;
      pStats.set(t.project, cur);
    }

    const cMap = new Map<string, typeof syncState.snapshot.checklistItems>();
    for (const item of syncState.snapshot.checklistItems) {
      if (item.deletedAt) continue;
      const list = cMap.get(item.taskId) ?? [];
      list.push(item);
      cMap.set(item.taskId, list);
    }
    for (const list of cMap.values()) list.sort((a, b) => (a.position ?? 0) - (b.position ?? 0));

    const rMap = new Map<string, typeof syncState.snapshot.taskRefs>();
    for (const ref of syncState.snapshot.taskRefs) {
      if (ref.deletedAt) continue;
      const list = rMap.get(ref.taskId) ?? [];
      list.push(ref);
      rMap.set(ref.taskId, list);
    }

    const aMap = new Map<string, typeof syncState.snapshot.attachments>();
    for (const att of syncState.snapshot.attachments) {
      if (att.deletedAt) continue;
      const list = aMap.get(att.taskId) ?? [];
      list.push(att);
      aMap.set(att.taskId, list);
    }

    const cvMap = new Map(syncState.snapshot.convos.map((c) => [c.id, c]));

    return {
      activeAreas: areas,
      activeProjects: projects,
      activeTags: tags,
      areaById: new Map(areas.map((a) => [a.id, a])),
      projectById: new Map(projects.map((p) => [p.id, p])),
      projectStats: pStats,
      checklistsByTask: cMap,
      refsByTask: rMap,
      attachmentsByTask: aMap,
      convoByTask: cvMap,
      turnsByTask: groupTurnsByTask(syncState.snapshot.turns),
    };
  }, [syncState.snapshot]);

  const pendingTaskIds = useMemo(() => {
    const ids = new Set<string>();
    for (const op of syncState.snapshot.outbox) {
      if (op.op === "appendTurn") ids.add(op.taskId);
      else if (op.entity === "task") ids.add(op.id);
    }
    return ids;
  }, [syncState.snapshot.outbox]);

  // Synced fade settings: the "Fade inactive tasks" switch and the weekly sweep state.
  const fade = useMemo(() => fadeSettings(syncState.snapshot.settings), [syncState.snapshot.settings]);

  // Evaluate membership, fade opacity, and conversation projection/state via the shared Rust WASM core.
  const evaluatedTasks = useMemo((): EvaluatedTask[] => {
    if (bootPhase !== "signed_in") return [];
    return syncState.snapshot.tasks
      .filter((t) => t.kind !== "heading")
      .map((task) => {
        const membership = taskViewMembership(task, todayYMD, nowIso);
        const convo = convoByTask.get(task.id) ?? null;
        const turns = turnsByTask.get(task.id) ?? [];

        const conversation = evaluateConversation(convo, turns, nowIso);
        const fill = fade.enabled
          ? fadeFill(
              fadeInput(task, convo, conversation, { now: nowIso, today: todayYMD, utcOffsetSeconds }),
            )
          : null;

        return {
          task,
          membership,
          opacity: rowOpacity(fill),
          convoProjection: conversation?.projection ?? null,
          convoState: conversation?.state ?? null,
        };
      });
  }, [bootPhase, convoByTask, fade.enabled, nowIso, syncState.snapshot.tasks, todayYMD, turnsByTask, utcOffsetSeconds]);

  // A new app day syncs, and the engine's daily fade pass follows the sync.
  const syncedDayRef = useRef(todayYMD);
  useEffect(() => {
    if (syncedDayRef.current === todayYMD) return;
    syncedDayRef.current = todayYMD;
    if (bootPhase === "signed_in") engine.scheduleSync();
  }, [bootPhase, engine, todayYMD]);

  // Timed reminder watcher using Rust WASM `shouldArmReminder`.
  useEffect(() => {
    if (bootPhase !== "signed_in") return;
    const checkReminders = () => {
      const nowMs = Date.now();
      let found: TaskRow | null = null;
      for (const task of syncState.snapshot.tasks) {
        if (!task.reminderAt) continue;
        const armed = shouldArmReminder({
          status: task.status,
          isDeleted: Boolean(task.deletedAt),
          isHeading: task.kind === "heading",
          isUnratifiedProposal: false,
          reminderAt: task.reminderAt,
          reminderDismissedAt: task.reminderDismissedAt ?? null,
        });
        if (!armed) continue;
        const dueMs = Date.parse(task.reminderSnoozedUntil || task.reminderAt);
        if (!Number.isFinite(dueMs) || dueMs > nowMs) continue;
        found = task;
        const notifKey = `${task.id}:${task.reminderSnoozedUntil || task.reminderAt}`;
        if (!notifiedRemindersRef.current.has(notifKey)) {
          notifiedRemindersRef.current.add(notifKey);
          if (typeof window !== "undefined" && "Notification" in window && Notification.permission === "granted") {
            try {
              new Notification(task.title, {
                body: task.notes?.slice(0, 120) || "Task reminder",
                icon: "/icon.svg",
              });
            } catch {
              // Ignore Notification failure.
            }
          }
        }
        break;
      }
      setDueReminderTask(found);
    };
    checkReminders();
    const timer = setInterval(checkReminders, 30_000);
    return () => clearInterval(timer);
  }, [bootPhase, syncState.snapshot.tasks]);

  // Auto-open First-Run welcome for brand-new empty accounts (synced onboardedAt unset).
  const autoOnboardCheckedRef = useRef(false);
  useEffect(() => {
    if (
      bootPhase === "signed_in" &&
      !syncState.syncing &&
      syncState.snapshot.lastSyncedAt !== null &&
      !autoOnboardCheckedRef.current
    ) {
      autoOnboardCheckedRef.current = true;
      const onboarded = Boolean(syncState.snapshot.settings.onboardedAt);
      const hasTasks = syncState.snapshot.tasks.some((t) => !t.deletedAt && t.kind !== "heading");
      if (!onboarded && !hasTasks) {
        setFirstRunOpen(true);
      }
    }
  }, [bootPhase, syncState.snapshot.lastSyncedAt, syncState.snapshot.settings.onboardedAt, syncState.snapshot.tasks, syncState.syncing]);

  const smartCounts = useMemo(() => {
    const counts: Record<SmartDestination, number> = {
      today: 0,
      review: 0,
      agent: 0,
      upcoming: 0,
      repeating: 0,
      anytime: 0,
      starred: 0,
      logbook: 0,
      faded: 0,
    };
    let deletedCount = 0;

    for (const { task, membership, convoState } of evaluatedTasks) {
      if (task.deletedAt) {
        deletedCount++;
        continue;
      }
      if (task.status === "done" || task.status === "cancelled") {
        if (String(task.completedAt ?? "").startsWith(todayYMD)) counts.logbook++;
        continue;
      }
      if (task.status !== "open") continue;

      if (membership.matchesView.today) counts.today++;
      // Review holds agent work in progress and Waiting too (ADR 0046, ADR 0053); only what waits on the
      // user is in its badge. The other groups (Faded aside) keep Review in the sidebar through `agent`.
      const reviewGroup = reviewGroupOf(task, convoState);
      if (reviewGroup && BADGE_GROUP_IDS.has(reviewGroup)) counts.review++;
      else if (reviewGroup && reviewGroup !== "faded") counts.agent++;
      if (membership.matchesView.upcoming) counts.upcoming++;
      if (task.recurrenceUnit) counts.repeating++;
      if (membership.matchesView.anytime) counts.anytime++;
      if (task.starred) counts.starred++;
      if (task.fadedAt) counts.faded++;
    }
    return { counts, deletedCount };
  }, [evaluatedTasks, todayYMD]);

  // Sidebar smart lists from registry/destinations.json + synced user customization.
  const sidebarDestinations = useMemo(() => {
    const rawOrder = Array.isArray(syncState.snapshot.settings.smartListOrder)
      ? (syncState.snapshot.settings.smartListOrder as string[])
      : [];
    const hiddenSet = new Set<string>(
      Array.isArray(syncState.snapshot.settings.smartListHidden)
        ? (syncState.snapshot.settings.smartListHidden as string[])
        : [],
    );
    const placementMap =
      syncState.snapshot.settings.smartListPlacement &&
      typeof syncState.snapshot.settings.smartListPlacement === "object"
        ? (syncState.snapshot.settings.smartListPlacement as Record<string, "top" | "bottom">)
        : {};

    const destById = new Map(SIDEBAR_DESTINATIONS.map((d) => [d.id, d]));
    const isEmpty = (id: SmartDestination) =>
      // Agent work in progress and the Faded group keep Review in the sidebar, but they are not in the badge.
      (id === "review"
        ? smartCounts.counts.review + smartCounts.counts.agent + smartCounts.counts.faded
        : smartCounts.counts[id]) === 0;

    const orderedIds: SmartDestination[] = [
      ...rawOrder.filter((id): id is SmartDestination => destById.has(id as SmartDestination)),
      ...SIDEBAR_DESTINATIONS.map((d) => d.id).filter((id) => !rawOrder.includes(id)),
    ];

    const top: SidebarDestination[] = [];
    const bottom: SidebarDestination[] = [];

    for (const id of orderedIds) {
      const d = destById.get(id);
      if (!d) continue;
      const isActive = destination.kind === "smart" && destination.id === id;
      if (id !== "today" && hiddenSet.has(id) && !isActive) continue;
      if (d.visibility === "whenNonEmpty" && isEmpty(id) && !isActive) continue;

      const sec =
        id === "today"
          ? "top"
          : d.canMoveSection && (placementMap[id] === "top" || placementMap[id] === "bottom")
            ? placementMap[id]
            : (d.sidebarSection ?? "top");
      if (sec === "bottom") bottom.push(d);
      else top.push(d);
    }

    return { top, bottom, all: [...top, ...bottom] };
  }, [
    destination,
    smartCounts.counts,
    syncState.snapshot.settings.smartListHidden,
    syncState.snapshot.settings.smartListOrder,
    syncState.snapshot.settings.smartListPlacement,
  ]);

  const projectHeadings = useMemo(() => {
    if (destination.kind !== "project") return [];
    return syncState.snapshot.tasks
      .filter((t) => !t.deletedAt && t.kind === "heading" && t.project === destination.id)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  }, [destination, syncState.snapshot.tasks]);

  const listedTasks = useMemo(() => {
    const filtered = evaluatedTasks.filter(({ task, membership, convoState }) => {
      if (tagFilterId) {
        const tags = Array.isArray(task.tags) ? task.tags : [];
        if (!tags.includes(tagFilterId)) return false;
      }

      if (destination.kind === "smart") {
        if (destination.id === "logbook") {
          if (logbookTab === "deleted") return Boolean(task.deletedAt);
          return !task.deletedAt && (task.status === "done" || task.status === "cancelled");
        }
        if (task.deletedAt || task.status !== "open") return false;
        switch (destination.id) {
          case "today": return membership.matchesView.today;
          case "review": return reviewGroupOf(task, convoState) !== null;
          case "agent": return false; // a group of Review: navigateTo opens Review
          case "upcoming": return membership.matchesView.upcoming;
          case "repeating": return Boolean(task.recurrenceUnit);
          case "anytime": return membership.matchesView.anytime;
          case "starred": return Boolean(task.starred);
          case "faded": return Boolean(task.fadedAt);
        }
      }

      if (task.deletedAt || task.status !== "open") return false;
      if (!prefs.tasksShowFaded && task.fadedAt) return false;
      if (destination.kind === "area") {
        if (task.area === destination.id) return true;
        const proj = task.project ? projectById.get(task.project) : null;
        return proj?.area === destination.id;
      }
      return task.project === destination.id;
    });

    return filtered.sort((a, b) => {
      if (destination.kind === "smart" && destination.id === "logbook") {
        const ka = logbookTab === "deleted" ? String(a.task.deletedAt ?? "") : String(a.task.completedAt ?? "");
        const kb = logbookTab === "deleted" ? String(b.task.deletedAt ?? "") : String(b.task.completedAt ?? "");
        return kb.localeCompare(ka);
      }
      if (destination.kind === "smart" && destination.id === "upcoming") {
        return String(a.membership.upcomingDay ?? "").localeCompare(String(b.membership.upcomingDay ?? ""));
      }
      if (destination.kind === "smart" && destination.id === "today") {
        const pa = a.task.todayPosition ?? a.task.position ?? Number.MAX_SAFE_INTEGER;
        const pb = b.task.todayPosition ?? b.task.position ?? Number.MAX_SAFE_INTEGER;
        if (pa !== pb) return pa - pb;
      }
      const pa = a.task.position ?? Number.MAX_SAFE_INTEGER;
      const pb = b.task.position ?? Number.MAX_SAFE_INTEGER;
      if (pa !== pb) return pa - pb;
      return String(b.task.createdAt ?? "").localeCompare(String(a.task.createdAt ?? ""));
    });
  }, [destination, evaluatedTasks, logbookTab, prefs.tasksShowFaded, projectById, tagFilterId]);

  // Review grouped by what waits on the user, then agent work in progress (docs/REVIEW_SPEC.md §1), in registry order.
  const reviewGroups = useMemo(() => {
    if (!(destination.kind === "smart" && destination.id === "review")) return [];
    return destinationGroups("review")
      .map((group) => ({
        ...group,
        items: (() => {
          const items = listedTasks.filter((i) => reviewGroupOf(i.task, i.convoState) === group.id);
          // Waiting: oldest wait first (REVIEW_SPEC §6).
          return group.id === "waiting" ? [...items].sort((a, b) => compareWaiting(a.task, b.task)) : items;
        })(),
      }))
      .filter((g) => g.items.length > 0);
  }, [destination, listedTasks]);

  // The rows on screen, in order: what the keyboard and the selection work on.
  const visibleTasks = useMemo(() => {
    if (!(destination.kind === "smart" && destination.id === "review")) return listedTasks;
    return reviewGroups
      .filter((g) => g.id !== "faded" || prefs.reviewFadedExpanded)
      .flatMap((g) => g.items);
  }, [destination, listedTasks, prefs.reviewFadedExpanded, reviewGroups]);

  const headerCount =
    destination.kind === "smart" && destination.id === "review"
      ? sumRows(reviewGroups.filter((g) => g.id !== "faded"))
      : listedTasks.length;

  const completedTodayTasks = useMemo(() => {
    if (!(destination.kind === "smart" && destination.id === "today" && prefs.todayShowCompleted)) {
      return [];
    }
    return evaluatedTasks
      .filter(
        ({ task }) =>
          !task.deletedAt &&
          task.status === "done" &&
          String(task.completedAt ?? "").startsWith(todayYMD),
      )
      .sort((a, b) => String(b.task.completedAt ?? "").localeCompare(String(a.task.completedAt ?? "")));
  }, [destination, evaluatedTasks, prefs.todayShowCompleted, todayYMD]);

  // On Today: foldable Inbox band at top (matching iOS/Mac, docs/TRIAGE_BAND_SPEC.md).
  const { todayInboxTasks, todayCommittedTasks } = useMemo(() => {
    if (!(destination.kind === "smart" && destination.id === "today")) {
      return { todayInboxTasks: [] as EvaluatedTask[], todayCommittedTasks: visibleTasks };
    }
    const inboxBand: EvaluatedTask[] = [];
    const committed: EvaluatedTask[] = [];
    for (const item of visibleTasks) {
      if (item.membership.inInbox) inboxBand.push(item);
      else committed.push(item);
    }
    inboxBand.sort((a, b) => Number(b.membership.inTriageBand) - Number(a.membership.inTriageBand));
    return { todayInboxTasks: inboxBand, todayCommittedTasks: committed };
  }, [destination, visibleTasks]);

  // Group committed Today tasks by list when prefs.todayGroupByList is ON (matching iOS/macOS).
  const todayListGroups = useMemo(() => {
    if (
      !(destination.kind === "smart" && destination.id === "today" && prefs.todayGroupByList)
    ) {
      return null;
    }
    const ungrouped: EvaluatedTask[] = [];
    const groups = new Map<string, { label: string; items: EvaluatedTask[] }>();
    for (const item of todayCommittedTasks) {
      const t = item.task;
      if (t.project && projectById.has(t.project)) {
        const key = `p:${t.project}`;
        const cur = groups.get(key) ?? { label: projectById.get(t.project)!.title, items: [] };
        cur.items.push(item);
        groups.set(key, cur);
      } else if (t.area && areaById.has(t.area)) {
        const a = areaById.get(t.area)!;
        const key = `a:${t.area}`;
        const cur = groups.get(key) ?? {
          label: `${a.emoji ? `${a.emoji} ` : ""}${a.title}`,
          items: [],
        };
        cur.items.push(item);
        groups.set(key, cur);
      } else {
        ungrouped.push(item);
      }
    }
    if (groups.size === 0) return null;
    return { ungrouped, groups: Array.from(groups.entries()) };
  }, [areaById, destination, prefs.todayGroupByList, projectById, todayCommittedTasks]);

  // Upcoming grouped by day via WASM upcomingDay.
  const upcomingGroups = useMemo(() => {
    if (!(destination.kind === "smart" && destination.id === "upcoming")) return [];
    const byDay = new Map<string, EvaluatedTask[]>();
    for (const item of visibleTasks) {
      const day = item.membership.upcomingDay ?? "Later";
      const list = byDay.get(day) ?? [];
      list.push(item);
      byDay.set(day, list);
    }
    return Array.from(byDay.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  }, [destination, visibleTasks]);

  // Every faded task (the Faded group's sheet), and those of this week's sweep (the prompt on Today).
  const fadedTasks = useMemo(
    () =>
      evaluatedTasks
        .filter((i) => reviewGroupOf(i.task, i.convoState) === "faded")
        .map((i) => i.task),
    [evaluatedTasks],
  );
  const sweepCandidates = useMemo(
    () => fadedTasks.filter((t) => isInCurrentSweep(t.fadedAt, fade.sweptAt)),
    [fade.sweptAt, fadedTasks],
  );
  const sweepDue = isSweepDue(new Date(), fade, fadedTasks.map((t) => t.fadedAt));

  // Go to a place and clear the selection. Faded and Agent are groups of Review: going to one opens Review.
  const navigateTo = useCallback(
    (dest: ActiveDestination) => {
      if (dest.kind === "smart" && dest.id === "faded") {
        handleChangePref("reviewFadedExpanded", true);
        setDestination({ kind: "smart", id: "review" });
      } else if (dest.kind === "smart" && dest.id === "agent") {
        setDestination({ kind: "smart", id: "review" });
      } else {
        setDestination(dest);
      }
      setExpandedTaskId(null);
      setSelectedTaskId(null);
      setSelectedIds(new Set());
    },
    [handleChangePref],
  );

  // Complete and reopen: the one path for the checkbox, menus, shortcuts and
  // drops. In Review it is an Accept, and undo puts the task back in Review.
  const recordCompletion = useCallback(
    (label: string, receipt: CompletionReceipt, redo: () => Promise<CompletionReceipt>, toast: boolean) => {
      let latest = receipt;
      undoStack.record(
        {
          label,
          undo: () => engine.undoCompletion(latest),
          redo: async () => {
            latest = await redo();
          },
        },
        toast,
      );
    },
    [engine, undoStack],
  );

  const toggleDone = useCallback(
    async (task: TaskRow) => {
      const wasDone = task.status === "done";
      const receipt = await engine.toggleTaskDone(task);
      recordCompletion(
        wasDone ? `Reopened “${task.title}”` : `Completed “${task.title}”`,
        receipt,
        () => engine.toggleTaskDone(task),
        !wasDone,
      );
    },
    [engine, recordCompletion],
  );

  const acceptReview = useCallback(
    async (task: TaskRow) => {
      const receipt = await engine.acceptAgentReview(task);
      recordCompletion(`Accepted “${task.title}”`, receipt, () => engine.acceptAgentReview(task), true);
    },
    [engine, recordCompletion],
  );

  const completeMany = useCallback(
    async (tasks: TaskRow[]) => {
      const receipt = await engine.completeTasks(tasks);
      recordCompletion(`Completed ${tasks.length} tasks`, receipt, () => engine.completeTasks(tasks), true);
    },
    [engine, recordCompletion],
  );

  const sendBackReview = useCallback(
    async (task: TaskRow, note: string) => {
      const before = await engine.sendBackAgentReview(task, note);
      undoStack.record(
        {
          label: `Sent back “${task.title}”`,
          undo: () => engine.restoreReview(before),
          redo: () => engine.restoreReview({ ...before, endState: "open", endStateNote: null, assignee: "claude", stoppedAt: null }),
        },
        true,
      );
    },
    [engine, undoStack],
  );

  // Keep and Let Go for faded tasks, with undo back into the pile.
  const keepFaded = useCallback(
    async (task: TaskRow) => {
      await engine.keepFadedTask(task);
      undoStack.record({
        label: `Kept “${task.title}”`,
        undo: () => engine.restoreFadedTasks([task]),
        redo: () => engine.keepFadedTask(task),
      });
    },
    [engine, undoStack],
  );

  // Open a task in the list or on its page. Opening a faded task keeps it
  // (docs/TASK_FADE_SPEC.md §4). A kept row leaves the Faded group, so from
  // Review it opens on the page, which stays.
  const openTask = useCallback(
    (task: TaskRow, surface: "inline" | "page" = "inline") => {
      const faded = task.status === "open" && !task.deletedAt && Boolean(task.fadedAt);
      if (faded) void keepFaded(task);
      const onReview = destination.kind === "smart" && destination.id === "review";
      if (surface === "page" || (faded && onReview)) {
        setTaskPageId(task.id);
      } else {
        setExpandedTaskId(task.id);
      }
    },
    [destination, keepFaded],
  );

  const toggleExpanded = useCallback(
    (task: TaskRow) => {
      if (expandedTaskId === task.id) setExpandedTaskId(null);
      else openTask(task);
    },
    [expandedTaskId, openTask],
  );

  const letGoFaded = useCallback(
    async (tasks: TaskRow[]) => {
      const dropped = await engine.dropFadedTasks(tasks);
      if (dropped.length === 0) return;
      undoStack.record(
        {
          label: dropped.length === 1 ? "Let 1 faded task go" : `Let ${dropped.length} faded tasks go`,
          undo: () => engine.restoreFadedTasks(dropped),
          redo: async () => {
            await engine.dropFadedTasks(dropped);
          },
        },
        true,
      );
    },
    [engine, undoStack],
  );

  // Sync container notes draft when switching Area / Project.
  useEffect(() => {
    setShowContainerNotes(false);
    setSelectedIds(new Set());
    if (destination.kind === "area") {
      setContainerNotesDraft(areaById.get(destination.id)?.context ?? "");
    } else if (destination.kind === "project") {
      setContainerNotesDraft(projectById.get(destination.id)?.notes ?? "");
    }
  }, [areaById, destination, projectById]);

  const activeSelectedTasks = useMemo(() => {
    if (selectedIds.size > 0) {
      return visibleTasks.filter((v) => selectedIds.has(v.task.id)).map((v) => v.task);
    }
    if (selectedTaskId) {
      const found = visibleTasks.find((v) => v.task.id === selectedTaskId);
      return found ? [found.task] : [];
    }
    return [];
  }, [selectedIds, selectedTaskId, visibleTasks]);

  const findTasks = useCallback(
    (ids: string[]) => {
      const tasks = engine.getState().snapshot.tasks;
      return ids.flatMap((id) => tasks.find((t) => t.id === id) ?? []);
    },
    [engine],
  );

  const setTaskDay = useCallback(
    async (attribute: DateBoardAttribute, taskIds: string[], day: string | null) => {
      const before = findTasks(taskIds);
      const apply = async () => {
        for (const task of findTasks(taskIds)) {
          if (attribute === "when") await engine.setTaskScheduled(task, day);
          else await engine.setTaskDeadline(task, day);
        }
      };
      await apply();
      const name = before.length === 1 ? `“${before[0].title}”` : `${before.length} tasks`;
      undoStack.record({
        label: `${attributeLabel(attribute, prefs.language)}: ${name}`,
        undo: async () => {
          for (const prev of before) {
            const [task] = findTasks([prev.id]);
            if (task) await engine.updateTaskFields(task, dateFields(prev));
          }
        },
        redo: apply,
      });
    },
    [engine, findTasks, prefs.language, undoStack],
  );

  const openDatePicker = useCallback(
    (attribute: DateBoardAttribute, taskIds: string[], anchor?: DateBoardAnchor) => {
      if (taskIds.length === 0) return;
      const row = document.querySelector(`[data-task-id="${CSS.escape(taskIds[0])}"]`);
      setDatePicker({
        attribute,
        taskIds,
        anchor: anchor ?? (row ? anchorOf(row) : { left: window.innerWidth / 2, top: 96, bottom: 96 }),
      });
    },
    [],
  );

  // Waiting On… and Got It Back (REVIEW_SPEC §6), with undo back to the fields before.
  const setWaiting = useCallback(
    async (task: TaskRow, name: string, checkBack: string | null) => {
      const [before] = findTasks([task.id]);
      const prev = waitingFields(before ?? task);
      await engine.setTaskWaiting(before ?? task, name, checkBack);
      undoStack.record({
        label: `${registryText(ACTIONS_CATALOG.actions["task.waitingOn"].title, prefs.language)} “${task.title}”`,
        undo: async () => {
          const [live] = findTasks([task.id]);
          if (live) await engine.updateTaskFields(live, prev);
        },
        redo: async () => {
          const [live] = findTasks([task.id]);
          if (live) await engine.setTaskWaiting(live, name, checkBack);
        },
      });
    },
    [engine, findTasks, prefs.language, undoStack],
  );

  const gotItBack = useCallback(
    async (tasks: TaskRow[]) => {
      const waiting = findTasks(tasks.map((t) => t.id)).filter((t) => waitingName(t));
      if (waiting.length === 0) return;
      const before = waiting.map((t) => ({ id: t.id, fields: waitingFields(t) }));
      for (const t of waiting) await engine.clearTaskWaiting(t);
      undoStack.record({
        label:
          waiting.length === 1
            ? `${registryText(ACTIONS_CATALOG.actions["task.gotItBack"].title, prefs.language)}: “${waiting[0].title}”`
            : `${registryText(ACTIONS_CATALOG.actions["task.gotItBack"].title, prefs.language)}: ${waiting.length} tasks`,
        undo: async () => {
          for (const b of before) {
            const [live] = findTasks([b.id]);
            if (live) await engine.updateTaskFields(live, b.fields);
          }
        },
        redo: async () => {
          for (const live of findTasks(before.map((b) => b.id))) await engine.clearTaskWaiting(live);
        },
      });
    },
    [engine, findTasks, prefs.language, undoStack],
  );

  const handleShareTask = useCallback(
    async (task: TaskRow) => {
      const text = task.notes ? `${task.title}\n\n${task.notes}` : task.title;
      if (typeof navigator !== "undefined" && navigator.share) {
        try {
          await navigator.share({ title: task.title, text });
          return;
        } catch {
          // User cancelled or share blocked; fall back to copy.
        }
      }
      try {
        await navigator.clipboard.writeText(text);
        showToast("Copied task to clipboard");
      } catch {
        showToast("Could not copy task");
      }
    },
    [showToast],
  );

  const handleCopyTasks = useCallback(
    async (tasks: TaskRow[]) => {
      if (tasks.length === 0) return;
      const text = tasks
        .map((t) => (t.notes ? `${t.title}\n${t.notes}` : t.title))
        .join("\n\n");
      try {
        await navigator.clipboard.writeText(text);
        showToast(tasks.length === 1 ? "Copied task" : `Copied ${tasks.length} tasks`);
      } catch {
        // Ignore clipboard denial.
      }
    },
    [showToast],
  );

  const canManualOrder =
    destination.kind === "area" ||
    destination.kind === "project" ||
    (destination.kind === "smart" && (destination.id === "today" || destination.id === "anytime"));

  const handleDropOnTask = useCallback(
    async (targetId: string) => {
      const sourceId = draggedTaskId;
      setDraggedTaskId(null);
      setDropTargetTaskId(null);
      if (!sourceId || sourceId === targetId || !canManualOrder) return;
      const ids = visibleTasks.map((v) => v.task.id);
      const fromIdx = ids.indexOf(sourceId);
      const toIdx = ids.indexOf(targetId);
      if (fromIdx < 0 || toIdx < 0) return;
      const reordered = [...ids];
      const [moved] = reordered.splice(fromIdx, 1);
      reordered.splice(toIdx, 0, moved);
      const field =
        destination.kind === "smart" && destination.id === "today" ? "todayPosition" : "position";
      await engine.reorderTasks(reordered, field);
    },
    [canManualOrder, destination, draggedTaskId, engine, visibleTasks],
  );

  const handleDropOnSidebarSmart = useCallback(
    async (destId: SmartDestination) => {
      const sourceId = draggedTaskId;
      setDraggedTaskId(null);
      setDropTargetSidebar(null);
      if (!sourceId) return;
      const task = syncState.snapshot.tasks.find((t) => t.id === sourceId);
      if (!task) return;
      const reg = destinationInfo(destId);
      if (!reg) return;
      switch (reg.dropBehavior) {
        case "setToday":
          await engine.bulkToggleToday([task], true);
          showToast(`Moved “${task.title}” to Today`);
          break;
        case "scheduleTomorrow":
          await engine.setTaskScheduled(task, addDays(todayYMD, 1));
          showToast(`Scheduled “${task.title}” for tomorrow`);
          break;
        case "clearDates":
          await engine.clearTaskWhen(task);
          showToast(`Moved “${task.title}” to Anytime`);
          break;
        case "complete":
          await toggleDone(task);
          break;
        case "delete":
          await engine.deleteTask(task);
          break;
      }
    },
    [draggedTaskId, engine, showToast, syncState.snapshot.tasks, todayYMD, toggleDone],
  );

  const handleDropOnSidebarPlace = useCallback(
    async (target: { area: string | null; project: string | null; label: string }) => {
      const sourceId = draggedTaskId;
      setDraggedTaskId(null);
      setDropTargetSidebar(null);
      if (!sourceId) return;
      const task = syncState.snapshot.tasks.find((t) => t.id === sourceId);
      if (!task) return;
      await engine.moveTask(task, { area: target.area, project: target.project });
      showToast(`Moved to ${target.label}`);
    },
    [draggedTaskId, engine, showToast, syncState.snapshot.tasks],
  );

  // Full registry keyboard shortcuts (registry/actions.json + registry/destinations.json).
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (bootPhase !== "signed_in") return;
      const primary = e.metaKey || e.ctrlKey;
      const key = e.key.toLowerCase();
      const target = e.target as HTMLElement | null;
      const typing =
        target?.tagName === "INPUT" ||
        target?.tagName === "TEXTAREA" ||
        target?.tagName === "SELECT" ||
        target?.isContentEditable;

      // Global shortcuts even when browsing
      if (primary && e.shiftKey && key === "f") {
        e.preventDefault();
        setQuickFindOpen((v) => !v);
        return;
      }
      if (primary && key === ",") {
        e.preventDefault();
        setSettingsOpen((v) => !v);
        return;
      }
      if (primary && e.shiftKey && (key === "/" || key === "?")) {
        e.preventDefault();
        setShortcutsOpen((v) => !v);
        return;
      }
      if (e.ctrlKey && e.metaKey && key === "s") {
        e.preventDefault();
        setSidebarOpen((v) => !v);
        return;
      }
      if (primary && !e.altKey && !e.shiftKey && key === "i") {
        e.preventDefault();
        setQuickAddInitial({
          today: destination.kind === "smart" && destination.id === "today",
          area: destination.kind === "area" ? destination.id : null,
          project: destination.kind === "project" ? destination.id : null,
        });
        setQuickAddOpen(true);
        return;
      }
      if (primary && !e.altKey && !e.shiftKey && (key === "=" || key === "+")) {
        e.preventDefault();
        handleChangePref("textSizeStep", Math.min(2, prefs.textSizeStep + 1));
        return;
      }
      if (primary && !e.altKey && !e.shiftKey && key === "-") {
        e.preventDefault();
        handleChangePref("textSizeStep", Math.max(-2, prefs.textSizeStep - 1));
        return;
      }
      if (primary && !e.altKey && !e.shiftKey && key === "0") {
        e.preventDefault();
        handleChangePref("textSizeStep", 0);
        return;
      }

      // Alt+1..9 sidebar smart list navigation
      if (e.altKey && !primary && /^[1-9]$/.test(e.key)) {
        const idx = Number(e.key) - 1;
        const dest = sidebarDestinations.all[idx];
        if (dest) {
          e.preventDefault();
          navigateTo({ kind: "smart", id: dest.id });
        }
        return;
      }

      const anyModalOpen =
        quickFindOpen || quickAddOpen || settingsOpen || shortcutsOpen || sweepTasks !== null || firstRunOpen;
      if (anyModalOpen) return;

      if (primary && !e.altKey && key === "z" && !typing) {
        e.preventDefault();
        if (e.shiftKey) void undoStack.redo();
        else void undoStack.undo();
        return;
      }

      if (typing) return;

      if (primary && !e.shiftKey && !e.altKey && key === "n") {
        e.preventDefault();
        composerRef.current?.focus();
        return;
      }
      if (!primary && !e.altKey && key === "n") {
        e.preventDefault();
        composerRef.current?.focus();
        return;
      }
      if (!primary && !e.altKey && e.key === "/") {
        e.preventDefault();
        setQuickFindOpen(true);
        return;
      }
      if (!primary && !e.altKey && e.key === "?") {
        e.preventDefault();
        setShortcutsOpen(true);
        return;
      }
      if (primary && !e.shiftKey && !e.altKey && key === "a" && visibleTasks.length > 0) {
        e.preventDefault();
        setSelectedIds(new Set(visibleTasks.map((v) => v.task.id)));
        return;
      }

      // Row-level shortcuts from registry/actions.json when task(s) are selected
      if (activeSelectedTasks.length > 0) {
        const single = activeSelectedTasks[0];
        if (primary && !e.shiftKey && !e.altKey && key === "k") {
          e.preventDefault();
          if (activeSelectedTasks.length === 1) void toggleDone(single);
          else void completeMany(activeSelectedTasks);
          return;
        }
        if (primary && e.altKey && key === "k") {
          e.preventDefault();
          void engine.bulkUpdateTasks(activeSelectedTasks, {
            status: "cancelled",
            completedAt: new Date().toISOString(),
            dropReason: "user",
          });
          return;
        }
        if (primary && !e.shiftKey && !e.altKey && key === "t") {
          e.preventDefault();
          if (activeSelectedTasks.length === 1) void engine.toggleTaskToday(single);
          else {
            const anyNotToday = activeSelectedTasks.some((t) => !t.today);
            void engine.bulkToggleToday(activeSelectedTasks, anyNotToday);
          }
          return;
        }
        if (primary && e.altKey && key === "s") {
          e.preventDefault();
          if (activeSelectedTasks.length === 1) void engine.toggleTaskStar(single);
          else void engine.bulkUpdateTasks(activeSelectedTasks, { starred: !single.starred });
          return;
        }
        if (primary && !e.shiftKey && !e.altKey && key === "s") {
          e.preventDefault();
          openDatePicker("when", activeSelectedTasks.map((t) => t.id));
          return;
        }
        if (primary && e.shiftKey && !e.altKey && key === "d") {
          e.preventDefault();
          openDatePicker("deadline", activeSelectedTasks.map((t) => t.id));
          return;
        }
        if (primary && !e.shiftKey && !e.altKey && key === "d") {
          e.preventDefault();
          void Promise.all(activeSelectedTasks.map((t) => engine.duplicateTask(t)));
          showToast(activeSelectedTasks.length === 1 ? "Duplicated task" : `Duplicated ${activeSelectedTasks.length} tasks`);
          return;
        }
        if (primary && !e.shiftKey && !e.altKey && key === "c") {
          e.preventDefault();
          void handleCopyTasks(activeSelectedTasks);
          return;
        }
        if (primary && e.altKey && key === "i") {
          e.preventDefault();
          if (taskPageId === single.id) setTaskPageId(null);
          else openTask(single, "page");
          return;
        }
        if (primary && !e.shiftKey && !e.altKey && key === "r") {
          e.preventDefault();
          openTask(single);
          return;
        }
        if (primary && e.shiftKey && e.key === ".") {
          e.preventDefault();
          void Promise.all(activeSelectedTasks.map((t) => engine.clearTaskWhen(t)));
          return;
        }
        if (primary && (e.key === "Backspace" || e.key === "Delete")) {
          e.preventDefault();
          void engine.bulkDeleteTasks(activeSelectedTasks);
          setSelectedIds(new Set());
          setSelectedTaskId(null);
          setExpandedTaskId(null);
          return;
        }
      } else if (primary && !e.shiftKey && !e.altKey && key === "k") {
        // Fallback: Cmd+K opens Quick Find when no task is selected.
        e.preventDefault();
        setQuickFindOpen((v) => !v);
        return;
      }

      if (e.key === "ArrowDown" && visibleTasks.length > 0) {
        e.preventDefault();
        const idx = visibleTasks.findIndex((t) => t.task.id === selectedTaskId);
        const next = visibleTasks[Math.min(visibleTasks.length - 1, idx + 1)];
        if (next) {
          setSelectedTaskId(next.task.id);
          setSelectedIds(new Set([next.task.id]));
        }
      } else if (e.key === "ArrowUp" && visibleTasks.length > 0) {
        e.preventDefault();
        const idx = visibleTasks.findIndex((t) => t.task.id === selectedTaskId);
        const prev = visibleTasks[Math.max(0, idx <= 0 ? 0 : idx - 1)];
        if (prev) {
          setSelectedTaskId(prev.task.id);
          setSelectedIds(new Set([prev.task.id]));
        }
      } else if (e.key === "Enter" && selectedTaskId) {
        e.preventDefault();
        const selected = visibleTasks.find((v) => v.task.id === selectedTaskId);
        if (selected) toggleExpanded(selected.task);
      } else if (e.key === "Escape") {
        setExpandedTaskId(null);
        setSelectedTaskId(null);
        setSelectedIds(new Set());
        setTaskPageId(null);
        setContextMenu(null);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [
    activeSelectedTasks,
    bootPhase,
    completeMany,
    destination,
    engine,
    firstRunOpen,
    handleChangePref,
    handleCopyTasks,
    navigateTo,
    openTask,
    openDatePicker,
    prefs.textSizeStep,
    quickAddOpen,
    quickFindOpen,
    selectedTaskId,
    settingsOpen,
    shortcutsOpen,
    showToast,
    sidebarDestinations.all,
    sweepTasks,
    taskPageId,
    toggleDone,
    toggleExpanded,
    undoStack,
    visibleTasks,
  ]);

  const lang = prefs.language;
  const waitingTask = waitingTaskId
    ? (syncState.snapshot.tasks.find((t) => t.id === waitingTaskId && t.status === "open" && !t.deletedAt) ?? null)
    : null;
  const pickerTask = datePicker
    ? syncState.snapshot.tasks.find((t) => t.id === datePicker.taskIds[0])
    : undefined;

  const pageMeta = useMemo(() => {
    if (destination.kind === "smart") {
      const reg = destinationInfo(destination.id);
      const empty =
        destination.id === "logbook" && logbookTab === "deleted"
          ? destinationInfo("recentlyDeleted")?.emptyState
          : reg?.emptyState;
      return {
        title: registryText(reg?.title ?? destination.id, lang),
        subtitle: null as string | null,
        emptyTitle: empty?.title ?? GENERIC_EMPTY_STATE.title,
        emptyDetail: empty?.detail ?? GENERIC_EMPTY_STATE.detail,
        supportsInlineCreate: reg?.supportsInlineCreate ?? false,
      };
    }
    if (destination.kind === "area") {
      const area = areaById.get(destination.id);
      return {
        title: area ? `${area.emoji ? `${area.emoji} ` : ""}${area.title}` : "Area",
        subtitle: "Area",
        emptyTitle: GENERIC_EMPTY_STATE.title,
        emptyDetail: GENERIC_EMPTY_STATE.detail,
        supportsInlineCreate: true,
      };
    }
    const proj = projectById.get(destination.id);
    const parentArea = proj?.area ? areaById.get(proj.area) : null;
    return {
      title: proj?.title ?? "Project",
      subtitle: parentArea ? parentArea.title : "Project",
      emptyTitle: GENERIC_EMPTY_STATE.title,
      emptyDetail: GENERIC_EMPTY_STATE.detail,
      supportsInlineCreate: true,
    };
  }, [areaById, destination, lang, logbookTab, projectById]);

  const handleQuickAddInline = async (e: React.FormEvent) => {
    e.preventDefault();
    const title = composerTitle.trim();
    if (!title) return;
    setComposerTitle("");

    const opts: Parameters<WebSyncEngine["createTask"]>[0] = { title };
    if (tagFilterId) opts.tags = [tagFilterId];
    if (destination.kind === "smart") {
      if (destination.id === "today") opts.today = true;
      else if (destination.id === "upcoming") opts.scheduled = nextIsoDay(todayYMD);
      else if (destination.id === "starred") opts.starred = true;
    } else if (destination.kind === "area") {
      opts.area = destination.id;
    } else if (destination.kind === "project") {
      opts.project = destination.id;
      const proj = projectById.get(destination.id);
      if (proj?.area) opts.area = proj.area;
    }
    await engine.createTask(opts);
  };

  const handleCreateContainer = async (e: React.FormEvent) => {
    e.preventDefault();
    const title = newContainerTitle.trim();
    if (!title || !creatingKind) return;
    setNewContainerTitle("");
    const kind = creatingKind;
    setCreatingKind(null);
    if (kind === "area") {
      const area = await engine.createArea(title);
      setDestination({ kind: "area", id: area.id });
    } else if (kind === "project") {
      const areaId = destination.kind === "area" ? destination.id : null;
      const proj = await engine.createProject(title, areaId);
      setDestination({ kind: "project", id: proj.id });
    } else if (kind === "heading" && destination.kind === "project") {
      await engine.createTask({ title, kind: "heading", project: destination.id });
    }
  };

  const openAreaContextMenu = (e: React.MouseEvent, area: AreaRow) => {
    e.preventDefault();
    setContextMenu({
      x: e.clientX,
      y: e.clientY,
      items: [
        {
          kind: "item",
          label: "New Project in Area",
          onSelect: () => {
            setDestination({ kind: "area", id: area.id });
            setCreatingKind("project");
            setNewContainerTitle("");
          },
        },
        { kind: "divider" },
        {
          kind: "item",
          label: "Rename",
          onSelect: () => {
            const next = window.prompt("Rename Area", area.title)?.trim();
            if (next && next !== area.title) void engine.updateArea(area, { title: next });
          },
        },
        {
          kind: "item",
          label: "Change Emoji…",
          onSelect: () => {
            const next = window.prompt("Area emoji (leave blank to clear)", area.emoji ?? "");
            if (next !== null) void engine.updateArea(area, { emoji: next.trim() || null });
          },
        },
        { kind: "divider" },
        {
          kind: "item",
          label: "Delete Area",
          destructive: true,
          onSelect: () => {
            if (window.confirm(`Delete “${area.title}”?`)) {
              void engine.deleteArea(area);
              if (destination.kind === "area" && destination.id === area.id) {
                setDestination({ kind: "smart", id: "today" });
              }
            }
          },
        },
      ],
    });
  };

  const openProjectContextMenu = (e: React.MouseEvent, proj: ProjectRow) => {
    e.preventDefault();
    setContextMenu({
      x: e.clientX,
      y: e.clientY,
      items: [
        {
          kind: "item",
          label: "Rename",
          onSelect: () => {
            const next = window.prompt("Rename Project", proj.title)?.trim();
            if (next && next !== proj.title) void engine.updateProject(proj, { title: next });
          },
        },
        { kind: "divider" },
        {
          kind: "item",
          label: "Mark Done",
          onSelect: () => {
            void engine.updateProject(proj, {
              status: "done",
              completedAt: new Date().toISOString(),
            });
            if (destination.kind === "project" && destination.id === proj.id) {
              setDestination({ kind: "smart", id: "today" });
            }
          },
        },
        {
          kind: "item",
          label: "Cancel Project",
          onSelect: () => {
            void engine.updateProject(proj, {
              status: "cancelled",
              completedAt: new Date().toISOString(),
            });
            if (destination.kind === "project" && destination.id === proj.id) {
              setDestination({ kind: "smart", id: "today" });
            }
          },
        },
        { kind: "divider" },
        {
          kind: "item",
          label: "Delete Project",
          destructive: true,
          onSelect: () => {
            if (window.confirm(`Delete “${proj.title}”?`)) {
              void engine.deleteProject(proj);
              if (destination.kind === "project" && destination.id === proj.id) {
                setDestination({ kind: "smart", id: "today" });
              }
            }
          },
        },
      ],
    });
  };

  const buildTaskRowProps = (item: EvaluatedTask, hideContainerLabel = false): TaskRowItemProps => {
    const { task, membership, opacity, convoProjection, convoState } = item;
    let containerLabel: string | null = null;
    if (!hideContainerLabel && destination.kind === "smart") {
      if (task.project && projectById.has(task.project)) {
        containerLabel = projectById.get(task.project)!.title;
      } else if (task.area && areaById.has(task.area)) {
        const a = areaById.get(task.area)!;
        containerLabel = `${a.emoji ? `${a.emoji} ` : ""}${a.title}`;
      }
    }

    const isDeletedView =
      destination.kind === "smart" && destination.id === "logbook" && logbookTab === "deleted";
    const isFadedView =
      destination.kind === "smart" &&
      destination.id === "review" &&
      reviewGroupOf(task, convoState) === "faded";

    return {
      task,
      membership,
      opacity: isDeletedView ? 0.75 : opacity,
      containerLabel,
      hasPendingOp: pendingTaskIds.has(task.id),
      selected: selectedTaskId === task.id,
      multiSelected: selectedIds.has(task.id),
      expanded: expandedTaskId === task.id,
      isDeletedView,
      isFadedView,
      todayYMD,
      lang,
      isColorfulAccent,
      animateCompletion: prefs.loggingAnimationsEnabled,
      draggable: canManualOrder && !isDeletedView,
      isDropTarget: dropTargetTaskId === task.id && draggedTaskId !== task.id,
      checklistItems: checklistsByTask.get(task.id) ?? [],
      allTags: activeTags,
      taskRefs: refsByTask.get(task.id) ?? [],
      attachments: attachmentsByTask.get(task.id) ?? [],
      convo: convoByTask.get(task.id) ?? null,
      turns: turnsByTask.get(task.id) ?? [],
      convoProjection,
      convoState,
      areas: activeAreas,
      projects: activeProjects,
      onRowClick: (e) => {
        if (e.metaKey || e.ctrlKey) {
          e.preventDefault();
          setExpandedTaskId(null);
          setSelectedIds((prev) => {
            const next = new Set(prev);
            if (next.has(task.id)) next.delete(task.id);
            else next.add(task.id);
            return next;
          });
          setSelectedTaskId(task.id);
          return;
        }
        if (e.shiftKey && selectedTaskId) {
          e.preventDefault();
          setExpandedTaskId(null);
          const ids = visibleTasks.map((v) => v.task.id);
          const a = ids.indexOf(selectedTaskId);
          const b = ids.indexOf(task.id);
          if (a >= 0 && b >= 0) {
            const [lo, hi] = a < b ? [a, b] : [b, a];
            setSelectedIds(new Set(ids.slice(lo, hi + 1)));
            return;
          }
        }
        setSelectedIds(new Set([task.id]));
        setSelectedTaskId(task.id);
        toggleExpanded(task);
      },
      onContextMenu: (e) => {
        e.preventDefault();
        setSelectedTaskId(task.id);
        if (!selectedIds.has(task.id)) setSelectedIds(new Set([task.id]));
        const menuTaskIds = selectedIds.has(task.id) ? [...selectedIds] : [task.id];
        const menuAnchor = { left: e.clientX, top: e.clientY, bottom: e.clientY };

        if (isDeletedView) {
          setContextMenu({
            x: e.clientX,
            y: e.clientY,
            items: [
              { kind: "item", label: "Restore", onSelect: () => void engine.restoreDeletedTask(task) },
              { kind: "divider" },
              {
                kind: "item",
                label: "Delete Permanently",
                destructive: true,
                onSelect: () => {
                  if (window.confirm("Delete this task permanently? You can’t undo this.")) {
                    void engine.purgeDeletedTasks([task]);
                  }
                },
              },
            ],
          });
          return;
        }

        if (isFadedView) {
          setContextMenu({
            x: e.clientX,
            y: e.clientY,
            items: [
              {
                kind: "item",
                label: registryText(ACTIONS_CATALOG.actions["task.keepFaded"].title, lang),
                onSelect: () => void keepFaded(task),
              },
              {
                kind: "item",
                label: registryText(ACTIONS_CATALOG.actions["task.letGoFaded"].title, lang),
                onSelect: () => void letGoFaded([task]),
              },
              { kind: "divider" },
              { kind: "item", label: "Delete", destructive: true, onSelect: () => void engine.deleteTask(task) },
            ],
          });
          return;
        }

        setContextMenu({
          x: e.clientX,
          y: e.clientY,
          items: [
            ...(convoState?.needsHumanReview
              ? [
                  {
                    kind: "item" as const,
                    label: registryText(ACTIONS_CATALOG.actions["task.acceptReview"].title, lang),
                    onSelect: () => void acceptReview(task),
                  },
                  { kind: "divider" as const },
                ]
              : []),
            ...(waitingName(task)
              ? [
                  {
                    kind: "item" as const,
                    label: registryText(ACTIONS_CATALOG.actions["task.gotItBack"].title, lang),
                    onSelect: () => void gotItBack(findTasks(menuTaskIds)),
                  },
                  { kind: "divider" as const },
                ]
              : []),
            {
              kind: "item",
              label: membership.isOnToday ? "Remove from Today" : "Move to Today",
              shortcut: "⌘T",
              onSelect: () => void engine.toggleTaskToday(task),
            },
            {
              kind: "item",
              label: task.starred ? "Unfavorite" : "Favorite",
              shortcut: "⌘⌥S",
              onSelect: () => void engine.toggleTaskStar(task),
            },
            {
              kind: "item",
              label: registryText(ACTIONS_CATALOG.actions["task.when"].title, lang),
              shortcut: "⌘S",
              onSelect: () => openDatePicker("when", menuTaskIds, menuAnchor),
            },
            {
              kind: "item",
              label: registryText(ACTIONS_CATALOG.actions["task.deadline"].title, lang),
              shortcut: "⇧⌘D",
              onSelect: () => openDatePicker("deadline", menuTaskIds, menuAnchor),
            },
            {
              kind: "item",
              label: registryText(ACTIONS_CATALOG.actions["task.waitingOn"].title, lang),
              onSelect: () => setWaitingTaskId(task.id),
            },
            { kind: "divider" },
            {
              kind: "item",
              label: "Open Task Page",
              shortcut: "⌘⌥I",
              onSelect: () => openTask(task, "page"),
            },
            {
              kind: "item",
              label: "Rename / Edit",
              shortcut: "⌘R",
              onSelect: () => openTask(task),
            },
            {
              kind: "item",
              label: "Duplicate",
              shortcut: "⌘D",
              onSelect: () => void engine.duplicateTask(task),
            },
            {
              kind: "item",
              label: "Copy",
              shortcut: "⌘C",
              onSelect: () => void handleCopyTasks([task]),
            },
            {
              kind: "item",
              label: "Share…",
              onSelect: () => void handleShareTask(task),
            },
            { kind: "divider" },
            {
              kind: "item",
              label: task.status === "done" ? "Mark as Open" : "Mark as Complete",
              shortcut: "⌘K",
              onSelect: () => void toggleDone(task),
            },
            {
              kind: "item",
              label: "Cancel Task",
              shortcut: "⌘⌥K",
              onSelect: () => void engine.cancelTask(task),
            },
            { kind: "divider" },
            {
              kind: "item",
              label: "Delete",
              shortcut: "⌘⌫",
              destructive: true,
              onSelect: () => void engine.deleteTask(task),
            },
          ],
        });
      },
      onDragStart: (e) => {
        setDraggedTaskId(task.id);
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", task.id);
      },
      onDragOver: (e) => {
        if (!draggedTaskId || !canManualOrder) return;
        e.preventDefault();
        setDropTargetTaskId(task.id);
      },
      onDragLeave: () => {
        setDropTargetTaskId((prev) => (prev === task.id ? null : prev));
      },
      onDrop: (e) => {
        e.preventDefault();
        void handleDropOnTask(task.id);
      },
      onOpenTaskPage: () => openTask(task, "page"),
      onCollapse: () => setExpandedTaskId(null),
      onToggleDone: () => void toggleDone(task),
      onToggleToday: async () => {
        const prev = {
          today: Boolean(task.today),
          todaySetOn: task.todaySetOn ?? null,
          scheduled: task.scheduled ?? null,
          deadline: task.deadline ?? null,
          deferredDeadline: task.deferredDeadline ?? null,
        };
        await engine.toggleTaskToday(task);
        undoStack.record({
          label: prev.today ? `Removed “${task.title}” from Today` : `Moved “${task.title}” to Today`,
          undo: () => engine.updateTaskFields(task, prev),
          redo: () => engine.toggleTaskToday(task),
        });
      },
      onToggleStar: () => void engine.toggleTaskStar(task),
      onDuplicate: async () => {
        await engine.duplicateTask(task);
        showToast(`Duplicated “${task.title}”`);
      },
      onShare: () => void handleShareTask(task),
      onUpdateFields: (fields) => void engine.updateTaskFields(task, fields),
      onSetScheduled: (day) => void setTaskDay("when", [task.id], day),
      onSetDeadline: (day) => void setTaskDay("deadline", [task.id], day),
      onSetTimeSlot: (st, dur) => void engine.setTaskTimeSlot(task, st, dur),
      onSetReminder: (reminderAt) => void engine.setTaskReminder(task, reminderAt),
      onSetRecurrence: (rule) => void engine.setTaskRecurrence(task, rule),
      onMoveTask: (target) => void engine.moveTask(task, target),
      onAddChecklistItem: (title) => void engine.addChecklistItem(task.id, title),
      onToggleChecklistItem: (c) => void engine.toggleChecklistItem(c),
      onDeleteChecklistItem: (c) => void engine.deleteChecklistItem(c),
      onToggleTag: (tid) => void engine.toggleTaskTag(task, tid),
      onCreateAndToggleTag: async (name) => {
        const tag = await engine.createTag(name);
        await engine.toggleTaskTag(task, tag.id);
      },
      onAddReference: async (input) => {
        await engine.addReference(task.id, input);
      },
      onRemoveReference: (ref) => void engine.removeReference(ref),
      onUploadAttachment: async (file) => {
        await engine.uploadAttachment(task.id, file);
      },
      onDownloadAttachment: (att) => void api.downloadAttachment(att.id, att.filename),
      onDeleteAttachment: (att) => void engine.deleteAttachment(att),
      onAssignToAgent: (assignee) => void engine.assignTaskToAgent(task.id, assignee),
      onAnswerQuestion: (inReplyTo, chosen) =>
        void engine.appendUserTurn(task.id, { step: "decide", inReplyTo, chosen }),
      onSendReply: (note) => void engine.appendUserTurn(task.id, { step: "work", note }),
      onAcceptReview: () => void acceptReview(task),
      onSendBackReview: (note) => void sendBackReview(task, note),
      onStopAgent: () => void engine.stopAgentOnTask(task.id),
      onResumeAgent: () => void engine.resumeAgentOnTask(task.id),
      onLoadHistory: () => api.getChanges("task", task.id),
      onKeepFaded: () => void keepFaded(task),
      onWaitingOn: () => setWaitingTaskId(task.id),
      onGotItBack: () => void gotItBack([task]),
      onDropFaded: () => void letGoFaded([task]),
      onRestoreDeleted: () => void engine.restoreDeletedTask(task),
      onCancelTask: async () => {
        await engine.cancelTask(task);
        setExpandedTaskId(null);
        undoStack.record(
          {
            label: `Cancelled “${task.title}”`,
            undo: () => engine.reopenTask(task),
            redo: () => engine.cancelTask(task),
          },
          true,
        );
      },
      onDelete: async () => {
        setExpandedTaskId(null);
        if (taskPageId === task.id) setTaskPageId(null);
        await engine.deleteTask(task);
        undoStack.record(
          {
            label: `Deleted “${task.title}”`,
            undo: async () => {
              await engine.restoreDeletedTask(task);
            },
            redo: () => engine.deleteTask(task),
          },
          true,
        );
      },
    };
  };

  const renderTaskRow = (item: EvaluatedTask, hideContainerLabel = false) => (
    <TaskRowItem key={item.task.id} {...buildTaskRowProps(item, hideContainerLabel)} />
  );

  const renderGroupHeader = (
    group: { title: string; icon: string; items: EvaluatedTask[] },
    collapse?: { expanded: boolean; onToggle: () => void },
  ) => {
    const Chevron = collapse?.expanded ? ChevronDown : ChevronRight;
    const content = (
      <>
        <RegistryIcon token={group.icon} className="h-3.5 w-3.5 text-[var(--text-muted)]" />
        <span>{registryText(group.title, lang)}</span>
        <span className="font-mono-tabular ml-auto font-normal text-[var(--text-muted)]">
          {group.items.length}
        </span>
        {collapse && <Chevron className="h-3.5 w-3.5 text-[var(--text-muted)]" />}
      </>
    );
    const className =
      "mb-1.5 flex w-full items-center gap-2 border-b border-[var(--border-subtle)] pb-1.5 text-left text-xs font-semibold tracking-wide text-[var(--text-secondary)] uppercase";
    if (!collapse) return <div className={className}>{content}</div>;
    return (
      <button
        type="button"
        aria-expanded={collapse.expanded}
        onClick={collapse.onToggle}
        className={`${className} hover:text-[var(--text-primary)]`}
      >
        {content}
      </button>
    );
  };

  const taskPageItem = useMemo(() => {
    if (!taskPageId) return null;
    return evaluatedTasks.find((e) => e.task.id === taskPageId) ?? null;
  }, [evaluatedTasks, taskPageId]);

  const settingsModal = (
    <SettingsModal
      open={settingsOpen}
      initialTab={settingsInitialTab}
      onClose={() => {
        setSettingsOpen(false);
        setSettingsInitialTab(undefined);
      }}
      api={api}
      engine={engine}
      snapshot={syncState.snapshot}
      notSynced={syncState.notSynced}
      onClearNotSynced={() => engine.clearNotSynced()}
      coreVersion={coreVersion}
      dayISO={todayYMD}
      isDark={isDark}
      accentHex={accentHex}
      prefs={prefs}
      onChangePref={handleChangePref}
      onSignOut={() => void handleSignOut()}
      onDeleteAccount={handleDeleteAccount}
      onShowWelcomeAgain={() => setFirstRunOpen(true)}
      onOpenShortcuts={() => setShortcutsOpen(true)}
    />
  );

  if (accountSwitch) {
    return (
      <main className="min-h-screen bg-[var(--bg-canvas)]">
        <AccountSwitchDialog
          summary={accountSwitch.summary}
          language={prefs.language}
          onChoose={handleAccountSwitchChoice}
        />
      </main>
    );
  }

  if (bootPhase === "loading") {
    return (
      <main className="flex min-h-screen items-center justify-center bg-[var(--bg-canvas)] text-sm text-[var(--text-muted)]">
        Loading Septena…
      </main>
    );
  }

  if (bootPhase === "signed_out") {
    // Settings can open here after "Export a Backup First" (#575): the other
    // account's tasks are still on this device, ready to export.
    return (
      <>
        <SignInScreen api={api} language={prefs.language} onSignedIn={(s) => void handleSignedIn(s)} />
        {settingsModal}
      </>
    );
  }

  const outboxCount = syncState.snapshot.outbox.length;
  const agentsPaused = Boolean(syncState.snapshot.settings.agentsPaused);
  const getStartedDismissed = Boolean(syncState.snapshot.settings.getStartedDismissed);
  const hasAnyActiveTasks = syncState.snapshot.tasks.some((t) => !t.deletedAt && t.kind !== "heading");
  const todayIconColor = isColorfulAccent ? "var(--today-gold)" : "var(--accent)";

  const renderSidebarButton = (dest: (typeof sidebarDestinations.top)[number]) => {
    const selected = destination.kind === "smart" && destination.id === dest.id;
    const count = smartCounts.counts[dest.id];
    const isDropOver = dropTargetSidebar === `smart:${dest.id}`;
    return (
      <button
        key={dest.id}
        type="button"
        onDragOver={(e) => {
          if (!draggedTaskId || dest.dropBehavior === "none") return;
          e.preventDefault();
          setDropTargetSidebar(`smart:${dest.id}`);
        }}
        onDragLeave={() => setDropTargetSidebar((p) => (p === `smart:${dest.id}` ? null : p))}
        onDrop={(e) => {
          e.preventDefault();
          void handleDropOnSidebarSmart(dest.id);
        }}
        onClick={() => {
          navigateTo({ kind: "smart", id: dest.id });
          setMobileMenuOpen(false);
        }}
        className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-sm transition-colors ${
          isDropOver
            ? "ring-2 ring-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
            : selected
              ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
              : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
        }`}
      >
        <RegistryIcon
          token={dest.icon}
          className="h-4 w-4 shrink-0"
          style={
            dest.id === "today"
              ? { color: todayIconColor }
              : dest.id === "starred"
                ? { color: isColorfulAccent ? "#f59e0b" : "var(--accent)", fill: selected ? (isColorfulAccent ? "#f59e0b" : "var(--accent)") : "none" }
                : undefined
          }
        />
        <span className="flex-1 truncate text-left">{registryText(dest.title, lang)}</span>
        {prefs.sidebarCounts && count > 0 && (
          <span className="font-mono-tabular text-xs text-[var(--text-muted)]">{count}</span>
        )}
      </button>
    );
  };

  const sidebarContent = (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between gap-2 px-4 pt-4 pb-2">
        <div className="flex items-center gap-2">
          <img src="/icon.svg" alt="" className="h-6 w-6 rounded-md" />
          <span className="text-sm font-semibold tracking-tight text-[var(--text-primary)]">
            Septena
          </span>
        </div>
        <div className="flex items-center gap-0.5">
          <button
            type="button"
            onClick={() => setQuickFindOpen(true)}
            title="Quick Find (⌘⇧F)"
            className="rounded-md p-1.5 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            <Search className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => setShortcutsOpen(true)}
            title="Keyboard Shortcuts (⌘⇧/)"
            className="hidden rounded-md p-1.5 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)] sm:inline-flex"
          >
            <Keyboard className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => setSettingsOpen(true)}
            title="Settings (⌘,)"
            className="rounded-md p-1.5 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            <Settings className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => setMobileMenuOpen(false)}
            className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] md:hidden"
            aria-label="Close sidebar"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
      </div>

      <nav className="flex-1 overflow-y-auto px-2 py-2">
        <div className="space-y-0.5">{sidebarDestinations.top.map(renderSidebarButton)}</div>

        <div className="mt-4 border-t border-[var(--border-subtle)] pt-3">
          {activeAreas.map((area) => {
            const areaSelected = destination.kind === "area" && destination.id === area.id;
            const areaProjects = activeProjects.filter((p) => p.area === area.id);
            const isAreaDrop = dropTargetSidebar === `area:${area.id}`;
            return (
              <div key={area.id} className="mb-2">
                <button
                  type="button"
                  onContextMenu={(e) => openAreaContextMenu(e, area)}
                  onDragOver={(e) => {
                    if (!draggedTaskId) return;
                    e.preventDefault();
                    setDropTargetSidebar(`area:${area.id}`);
                  }}
                  onDragLeave={() => setDropTargetSidebar((p) => (p === `area:${area.id}` ? null : p))}
                  onDrop={(e) => {
                    e.preventDefault();
                    void handleDropOnSidebarPlace({ area: area.id, project: null, label: area.title });
                  }}
                  onClick={() => {
                    setDestination({ kind: "area", id: area.id });
                    setExpandedTaskId(null);
                    setSelectedTaskId(null);
                    setSelectedIds(new Set());
                    setMobileMenuOpen(false);
                  }}
                  className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors ${
                    isAreaDrop
                      ? "ring-2 ring-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : areaSelected
                        ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                        : "text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  }`}
                >
                  {area.emoji ? (
                    <span className="w-4 text-center text-sm leading-none">{area.emoji}</span>
                  ) : (
                    <Folder className="h-4 w-4 shrink-0 text-[var(--text-muted)]" />
                  )}
                  <span className="truncate">{area.title}</span>
                </button>

                {areaProjects.length > 0 && (
                  <div className="mt-0.5 space-y-0.5 pl-4">
                    {areaProjects.map((proj) => {
                      const projSelected = destination.kind === "project" && destination.id === proj.id;
                      const isProjDrop = dropTargetSidebar === `project:${proj.id}`;
                      const stats = projectStats.get(proj.id) ?? { done: 0, total: 0 };
                      return (
                        <button
                          key={proj.id}
                          type="button"
                          onContextMenu={(e) => openProjectContextMenu(e, proj)}
                          onDragOver={(e) => {
                            if (!draggedTaskId) return;
                            e.preventDefault();
                            setDropTargetSidebar(`project:${proj.id}`);
                          }}
                          onDragLeave={() =>
                            setDropTargetSidebar((p) => (p === `project:${proj.id}` ? null : p))
                          }
                          onDrop={(e) => {
                            e.preventDefault();
                            void handleDropOnSidebarPlace({
                              area: proj.area ?? null,
                              project: proj.id,
                              label: proj.title,
                            });
                          }}
                          onClick={() => {
                            setDestination({ kind: "project", id: proj.id });
                            setExpandedTaskId(null);
                            setSelectedTaskId(null);
                            setSelectedIds(new Set());
                            setMobileMenuOpen(false);
                          }}
                          className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-1 text-sm transition-colors ${
                            isProjDrop
                              ? "ring-2 ring-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                              : projSelected
                                ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                                : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                          }`}
                        >
                          <ProjectRing done={stats.done} total={stats.total} />
                          <span className="flex-1 truncate text-left">{proj.title}</span>
                          {prefs.sidebarCounts && stats.total - stats.done > 0 && (
                            <span className="font-mono-tabular text-xs text-[var(--text-muted)]">
                              {stats.total - stats.done}
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            );
          })}

          {activeProjects
            .filter((p) => !p.area || !areaById.has(p.area))
            .map((proj) => {
              const projSelected = destination.kind === "project" && destination.id === proj.id;
              const isProjDrop = dropTargetSidebar === `project:${proj.id}`;
              const stats = projectStats.get(proj.id) ?? { done: 0, total: 0 };
              return (
                <button
                  key={proj.id}
                  type="button"
                  onContextMenu={(e) => openProjectContextMenu(e, proj)}
                  onDragOver={(e) => {
                    if (!draggedTaskId) return;
                    e.preventDefault();
                    setDropTargetSidebar(`project:${proj.id}`);
                  }}
                  onDragLeave={() =>
                    setDropTargetSidebar((p) => (p === `project:${proj.id}` ? null : p))
                  }
                  onDrop={(e) => {
                    e.preventDefault();
                    void handleDropOnSidebarPlace({
                      area: null,
                      project: proj.id,
                      label: proj.title,
                    });
                  }}
                  onClick={() => {
                    setDestination({ kind: "project", id: proj.id });
                    setExpandedTaskId(null);
                    setSelectedTaskId(null);
                    setSelectedIds(new Set());
                    setMobileMenuOpen(false);
                  }}
                  className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm transition-colors ${
                    isProjDrop
                      ? "ring-2 ring-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : projSelected
                        ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                        : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                  }`}
                >
                  <ProjectRing done={stats.done} total={stats.total} />
                  <span className="flex-1 truncate text-left">{proj.title}</span>
                  {prefs.sidebarCounts && stats.total - stats.done > 0 && (
                    <span className="font-mono-tabular text-xs text-[var(--text-muted)]">
                      {stats.total - stats.done}
                    </span>
                  )}
                </button>
              );
            })}

          {creatingKind && creatingKind !== "heading" ? (
            <form onSubmit={(e) => void handleCreateContainer(e)} className="mt-2 px-1">
              <input
                type="text"
                autoFocus
                value={newContainerTitle}
                onChange={(e) => setNewContainerTitle(e.target.value)}
                onBlur={() => {
                  if (!newContainerTitle.trim()) setCreatingKind(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === "Escape") {
                    setCreatingKind(null);
                    setNewContainerTitle("");
                  }
                }}
                placeholder={creatingKind === "area" ? "New area name…" : "New project name…"}
                className="w-full rounded-lg border border-[var(--accent)] bg-[var(--bg-elevated)] px-2.5 py-1 text-xs text-[var(--text-primary)] outline-none"
              />
            </form>
          ) : (
            <div className="mt-2 flex items-center gap-1 px-1.5 text-[11px] text-[var(--text-muted)]">
              <button
                type="button"
                onClick={() => {
                  setCreatingKind("project");
                  setNewContainerTitle("");
                }}
                className="inline-flex items-center gap-1 rounded px-1.5 py-1 hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
              >
                <Plus className="h-3 w-3" />
                Project
              </button>
              <button
                type="button"
                onClick={() => {
                  setCreatingKind("area");
                  setNewContainerTitle("");
                }}
                className="inline-flex items-center gap-1 rounded px-1.5 py-1 hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
              >
                <FolderPlus className="h-3 w-3" />
                Area
              </button>
            </div>
          )}
        </div>

        {sidebarDestinations.bottom.length > 0 && (
          <div className="mt-4 space-y-0.5 border-t border-[var(--border-subtle)] pt-3">
            {sidebarDestinations.bottom.map(renderSidebarButton)}
          </div>
        )}
      </nav>

      <div className="border-t border-[var(--border-subtle)] p-3 text-xs">
        <div className="mb-1 flex items-center justify-between gap-2 text-[var(--text-muted)]">
          <span className="inline-flex items-center gap-1.5 truncate">
            {!syncState.online ? (
              <>
                <CloudOff className="h-3.5 w-3.5 text-amber-500" />
                <span className="text-amber-600 dark:text-amber-400">
                  Offline{outboxCount > 0 ? ` · ${outboxCount} queued` : ""}
                </span>
              </>
            ) : syncState.syncing ? (
              <>
                <RefreshCw className="h-3.5 w-3.5 animate-spin" />
                <span>Syncing…</span>
              </>
            ) : outboxCount > 0 ? (
              <>
                <RefreshCw className="h-3.5 w-3.5 text-amber-500" />
                <span>{outboxCount} pending</span>
              </>
            ) : (
              <>
                <Wifi className={`h-3.5 w-3.5 ${syncState.liveConnected ? "text-emerald-500" : ""}`} />
                <span>{syncState.liveConnected ? "Live" : "Synced"}</span>
              </>
            )}
          </span>
          <button
            type="button"
            onClick={() => void engine.syncNow()}
            disabled={!syncState.online || syncState.syncing}
            className="rounded px-1.5 py-0.5 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] disabled:opacity-40"
          >
            Sync
          </button>
        </div>
        <div className="font-mono-tabular flex items-center justify-between text-[11px] text-[var(--text-muted)]">
          <span>rev {syncState.snapshot.cursor}</span>
          <span>core {coreVersion}</span>
        </div>
      </div>
    </div>
  );

  return (
    <div className="flex h-screen overflow-hidden bg-[var(--bg-canvas)]">
      {/* Desktop sidebar */}
      {sidebarOpen && (
        <aside className="hidden w-60 shrink-0 border-r border-[var(--border-subtle)] bg-[var(--bg-sidebar)] md:block">
          {sidebarContent}
        </aside>
      )}

      {/* Mobile sidebar drawer */}
      {mobileMenuOpen && (
        <div className="fixed inset-0 z-40 flex md:hidden">
          <div className="w-64 border-r border-[var(--border-subtle)] bg-[var(--bg-sidebar)] shadow-xl">
            {sidebarContent}
          </div>
          <button
            type="button"
            aria-label="Dismiss navigation"
            onClick={() => setMobileMenuOpen(false)}
            className="flex-1 bg-black/30"
          />
        </div>
      )}

      {/* Main list column */}
      <main className="relative flex min-w-0 flex-1 flex-col overflow-hidden">
        {/* Procedural Header Wash backdrop synced with Apple/Android (ADR 0019) */}
        <HeaderWash
          style={canvasTexture}
          isDark={isDark}
          accentHex={accentHex}
          intensity={textureIntensity}
          motion={textureMotion}
          dayISO={todayYMD}
          projectId={destination.kind === "project" ? destination.id : null}
          fadeHeight={240}
        />

        <header className="relative z-10 flex flex-wrap items-center gap-3 border-b border-[var(--border-subtle)]/70 px-4 py-3 md:px-10 md:py-5">
          <button
            type="button"
            onClick={() => setMobileMenuOpen(true)}
            className="rounded-lg p-1.5 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] md:hidden"
            aria-label="Open navigation"
          >
            <Menu className="h-5 w-5" />
          </button>
          <button
            type="button"
            onClick={() => setSidebarOpen((v) => !v)}
            title="Show / Hide Sidebar (⌃⌘S)"
            className="hidden rounded-lg p-1.5 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)] md:inline-flex"
          >
            <PanelLeft className="h-4 w-4" />
          </button>

          <div className="min-w-0 flex-1">
            {pageMeta.subtitle && (
              <p className="text-xs font-medium text-[var(--text-muted)]">{pageMeta.subtitle}</p>
            )}
            <div className="flex items-baseline gap-2.5">
              <h1 className="truncate text-2xl font-semibold tracking-tight text-[var(--text-primary)]">
                {pageMeta.title}
              </h1>
              <span className="font-mono-tabular text-sm text-[var(--text-muted)]">
                {headerCount}
              </span>
            </div>
          </div>

          <div className="flex items-center gap-2 text-xs">
            <button
              type="button"
              onClick={() => {
                setQuickAddInitial({
                  today: destination.kind === "smart" && destination.id === "today",
                  area: destination.kind === "area" ? destination.id : null,
                  project: destination.kind === "project" ? destination.id : null,
                });
                setQuickAddOpen(true);
              }}
              title="Quick Add (⌘I)"
              className="inline-flex items-center gap-1 rounded-lg bg-[var(--accent)] px-2.5 py-1.5 font-medium hover:opacity-90"
              style={{ color: "var(--accent-check)" }}
            >
              <Plus className="h-3.5 w-3.5" />
              <span className="hidden sm:inline">Quick Add</span>
            </button>

            {destination.kind === "smart" && destination.id === "logbook" && (
              <div className="inline-flex rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/80 p-0.5">
                <button
                  type="button"
                  onClick={() => setLogbookTab("completed")}
                  className={`rounded-md px-2.5 py-1 font-medium ${
                    logbookTab === "completed"
                      ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : "text-[var(--text-muted)]"
                  }`}
                >
                  Logbook
                </button>
                <button
                  type="button"
                  onClick={() => setLogbookTab("deleted")}
                  className={`inline-flex items-center gap-1 rounded-md px-2.5 py-1 font-medium ${
                    logbookTab === "deleted"
                      ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : "text-[var(--text-muted)]"
                  }`}
                >
                  <Trash2 className="h-3 w-3" />
                  Deleted
                  {smartCounts.deletedCount > 0 && (
                    <span className="font-mono-tabular text-[11px] opacity-75">
                      {smartCounts.deletedCount}
                    </span>
                  )}
                </button>
              </div>
            )}

            {destination.kind === "smart" &&
              destination.id === "logbook" &&
              logbookTab === "deleted" &&
              visibleTasks.length > 0 && (
                <button
                  type="button"
                  onClick={() => {
                    if (
                      window.confirm(
                        `Delete all ${visibleTasks.length} deleted tasks permanently? You can’t undo this.`,
                      )
                    ) {
                      void engine.purgeDeletedTasks(visibleTasks.map((v) => v.task));
                    }
                  }}
                  className="rounded-lg border border-[var(--overdue-red)]/30 px-2.5 py-1 font-medium text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                >
                  Empty Trash
                </button>
              )}

            {(destination.kind === "area" || destination.kind === "project") && (
              <button
                type="button"
                onClick={() => setShowContainerNotes((v) => !v)}
                className={`rounded-lg px-2.5 py-1 font-medium ${
                  showContainerNotes
                    ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                    : "bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                }`}
              >
                Notes
              </button>
            )}

            {destination.kind === "project" && (
              <button
                type="button"
                onClick={() => {
                  setCreatingKind("heading");
                  setNewContainerTitle("");
                }}
                className="rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              >
                + Section
              </button>
            )}

            {destination.kind === "smart" && destination.id === "review" && (
              <button
                type="button"
                onClick={() => void engine.setSetting("agentsPaused", !agentsPaused)}
                className={`inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 font-medium ${
                  agentsPaused
                    ? "bg-amber-500/15 text-amber-600 dark:text-amber-400"
                    : "bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                }`}
              >
                <PauseCircle className="h-3.5 w-3.5" />
                {agentsPaused ? "Agents paused" : "Pause all agents"}
              </button>
            )}
          </div>
        </header>

        <div className="relative z-10 flex-1 overflow-y-auto px-4 py-4 md:px-10 md:py-6">
          <div className="mx-auto max-w-2xl pb-16">
            {/* Due Timed Reminder Banner */}
            {dueReminderTask && (
              <div className="mb-4 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-[var(--accent)]/40 bg-[var(--bg-elevated)] px-4 py-2.5 text-xs shadow-sm">
                <div className="flex min-w-0 items-center gap-2">
                  <Bell className="h-4 w-4 shrink-0 text-[var(--accent)]" />
                  <span className="truncate font-medium text-[var(--text-primary)]">
                    Reminder: {dueReminderTask.title}
                  </span>
                </div>
                <div className="flex items-center gap-1.5">
                  <button
                    type="button"
                    onClick={() => openTask(dueReminderTask, "page")}
                    className="rounded-md bg-[var(--bg-hover)] px-2 py-1 font-medium text-[var(--text-primary)]"
                  >
                    Open
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      void engine.snoozeTaskReminder(
                        dueReminderTask,
                        new Date(Date.now() + 15 * 60_000).toISOString(),
                      )
                    }
                    className="rounded-md bg-[var(--bg-hover)] px-2 py-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                  >
                    +15m
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      void engine.snoozeTaskReminder(
                        dueReminderTask,
                        new Date(Date.now() + 60 * 60_000).toISOString(),
                      )
                    }
                    className="rounded-md bg-[var(--bg-hover)] px-2 py-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                  >
                    +1h
                  </button>
                  <button
                    type="button"
                    onClick={() => void engine.dismissTaskReminder(dueReminderTask)}
                    className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium"
                    style={{ color: "var(--accent-check)" }}
                  >
                    Dismiss
                  </button>
                </div>
              </div>
            )}

            {/* Weekly sweep prompt on Today, on the sweep day only (docs/TASK_FADE_SPEC.md §5) */}
            {destination.kind === "smart" && destination.id === "today" && sweepDue && (
              <div className="mb-4 flex items-center justify-between gap-3 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/90 px-4 py-2.5 text-xs">
                <div className="flex items-center gap-2.5">
                  <RegistryIcon
                    token={WEEKLY_SWEEP_NOTICE.icon}
                    className="h-4 w-4 shrink-0 text-[var(--text-muted)]"
                  />
                  <span className="text-[var(--text-secondary)]">
                    <strong className="font-medium text-[var(--text-primary)]">
                      {registryText(WEEKLY_SWEEP_NOTICE.title.other, lang, { count: sweepCandidates.length })}
                    </strong>{" "}
                    {registryText(WEEKLY_SWEEP_NOTICE.detail, lang)}
                  </span>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => setSweepTasks(sweepCandidates)}
                    className="rounded-md bg-[var(--bg-selected)] px-2.5 py-1 font-medium text-[var(--text-primary)]"
                  >
                    {registryText(WEEKLY_SWEEP_NOTICE.primaryTitle, lang)}
                  </button>
                  <button
                    type="button"
                    onClick={() => void engine.setSetting("fadeSweepDismissedOn", sweepAnchorDay(new Date()))}
                    className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                    aria-label={registryText(SURFACES_CATALOG.notices.dismissTitle, lang)}
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>
            )}

            {/* Get Started Notice on Today (synced getStartedDismissed) */}
            {destination.kind === "smart" &&
              destination.id === "today" &&
              !getStartedDismissed &&
              !hasAnyActiveTasks && (
                <div className="mb-4 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/90 p-4 text-xs">
                  <div className="mb-2 flex items-center justify-between">
                    <span className="font-semibold text-[var(--text-primary)]">
                      Get started with Septena
                    </span>
                    <button
                      type="button"
                      onClick={() => void engine.setSetting("getStartedDismissed", true)}
                      className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                    >
                      Dismiss
                    </button>
                  </div>
                  <div className="space-y-1.5 text-[var(--text-secondary)]">
                    <button
                      type="button"
                      onClick={() => setFirstRunOpen(true)}
                      className="flex w-full items-center justify-between rounded-lg px-2 py-1.5 text-left hover:bg-[var(--bg-hover)]"
                    >
                      <span>Connect your agent — Let Claude work your list</span>
                      <ChevronRight className="h-3.5 w-3.5 text-[var(--text-muted)]" />
                    </button>
                    <button
                      type="button"
                      onClick={() => composerRef.current?.focus()}
                      className="flex w-full items-center justify-between rounded-lg px-2 py-1.5 text-left hover:bg-[var(--bg-hover)]"
                    >
                      <span>Add your first task — Lands in Inbox at the top of Today</span>
                      <ChevronRight className="h-3.5 w-3.5 text-[var(--text-muted)]" />
                    </button>
                  </div>
                </div>
              )}

            {agentsPaused &&
              destination.kind === "smart" &&
              destination.id === "review" && (
                <div className="mb-4 flex items-center justify-between rounded-lg border border-amber-500/30 bg-amber-500/10 px-3.5 py-2 text-xs text-amber-700 dark:text-amber-300">
                  <span>All agents are paused. Connected agents cannot claim or edit tasks.</span>
                  <button
                    type="button"
                    onClick={() => void engine.setSetting("agentsPaused", false)}
                    className="font-semibold underline"
                  >
                    Resume
                  </button>
                </div>
              )}

            {syncState.lastError && (
              <div className="mb-4 rounded-lg border border-amber-500/30 bg-amber-500/10 px-3.5 py-2 text-xs text-amber-700 dark:text-amber-300">
                {syncState.lastError}
              </div>
            )}

            {syncState.notSynced.length > 0 && (
              <div className="mb-4 flex items-center justify-between gap-2 rounded-lg border border-red-500/30 bg-red-500/10 px-3.5 py-2 text-xs text-red-700 dark:text-red-300">
                <span>
                  {syncState.notSynced.length} change(s) could not be synced:{" "}
                  {syncState.notSynced[syncState.notSynced.length - 1].reason}
                </span>
                <button
                  type="button"
                  onClick={() => engine.clearNotSynced()}
                  className="shrink-0 font-medium underline"
                >
                  Dismiss
                </button>
              </div>
            )}

            {/* Area / Project Notes (ADR 0012: brief + ## Log) */}
            {showContainerNotes && (destination.kind === "area" || destination.kind === "project") && (
              <div className="mb-4 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3.5">
                <p className="mb-1.5 text-xs font-medium text-[var(--text-muted)]">
                  {destination.kind === "project" ? "Project notes & agent brief" : "Area notes"}
                </p>
                <textarea
                  value={containerNotesDraft}
                  onChange={(e) => setContainerNotesDraft(e.target.value)}
                  onBlur={() => {
                    const normalized = containerNotesDraft.trim() ? containerNotesDraft : null;
                    if (destination.kind === "area") {
                      const area = areaById.get(destination.id);
                      if (area && normalized !== (area.context ?? null)) {
                        void engine.updateArea(area, { context: normalized });
                      }
                    } else if (destination.kind === "project") {
                      const proj = projectById.get(destination.id);
                      if (proj && normalized !== (proj.notes ?? null)) {
                        void engine.updateProject(proj, { notes: normalized });
                      }
                    }
                  }}
                  rows={5}
                  placeholder="Write context, decisions, or goals for this list…"
                  className="w-full resize-y bg-transparent text-sm leading-relaxed text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
                />
              </div>
            )}

            {/* Inline Section (heading) creator for Projects */}
            {creatingKind === "heading" && destination.kind === "project" && (
              <form onSubmit={(e) => void handleCreateContainer(e)} className="mb-3 flex gap-2">
                <input
                  type="text"
                  autoFocus
                  value={newContainerTitle}
                  onChange={(e) => setNewContainerTitle(e.target.value)}
                  placeholder="Section heading title…"
                  className="min-w-0 flex-1 rounded-lg border border-[var(--accent)] bg-[var(--bg-elevated)] px-3 py-1.5 text-sm outline-none"
                />
                <button
                  type="submit"
                  className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium"
                  style={{ color: "var(--accent-check)" }}
                >
                  Add
                </button>
                <button
                  type="button"
                  onClick={() => setCreatingKind(null)}
                  className="rounded-lg bg-[var(--bg-hover)] px-2.5 py-1.5 text-xs text-[var(--text-secondary)]"
                >
                  Cancel
                </button>
              </form>
            )}

            {/* Tag filter strip */}
            {activeTags.length > 0 && !(destination.kind === "smart" && destination.id === "logbook") && (
              <div className="mb-3 flex flex-wrap items-center gap-1.5 text-xs">
                <Tag className="h-3 w-3 text-[var(--text-muted)]" />
                {tagFilterId && (
                  <button
                    type="button"
                    onClick={() => setTagFilterId(null)}
                    className="inline-flex items-center gap-1 rounded-full bg-[var(--bg-hover)] px-2 py-0.5 text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                  >
                    All <X className="h-3 w-3" />
                  </button>
                )}
                {activeTags.map((t) => {
                  const active = tagFilterId === t.id;
                  return (
                    <button
                      key={t.id}
                      type="button"
                      onClick={() => setTagFilterId(active ? null : t.id)}
                      className={`rounded-full px-2.5 py-0.5 transition-colors ${
                        active
                          ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                          : "bg-[var(--bg-hover)] text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                      }`}
                    >
                      {t.name}
                    </button>
                  );
                })}
              </div>
            )}

            {/* Inline Quick-Add Composer */}
            {pageMeta.supportsInlineCreate && (
              <form
                onSubmit={(e) => void handleQuickAddInline(e)}
                className="mb-4 flex items-center gap-2 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/95 px-3 py-2 focus-within:border-[var(--accent)]"
              >
                <Plus className="h-4 w-4 shrink-0 text-[var(--text-muted)]" />
                <input
                  ref={composerRef}
                  type="text"
                  value={composerTitle}
                  onChange={(e) => setComposerTitle(e.target.value)}
                  placeholder={`New task in ${pageMeta.title}… (press N)`}
                  className="min-w-0 flex-1 bg-transparent text-sm text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
                />
                {composerTitle.trim() && (
                  <button
                    type="submit"
                    className="rounded-md bg-[var(--accent)] px-2.5 py-1 text-xs font-medium hover:opacity-90"
                    style={{ color: "var(--accent-check)" }}
                  >
                    Add
                  </button>
                )}
              </form>
            )}

            {/* Task Lists */}
            {listedTasks.length === 0 && projectHeadings.length === 0 && completedTodayTasks.length === 0 ? (
              <div className="py-16 text-center">
                <p className="text-sm font-medium text-[var(--text-secondary)]">{pageMeta.emptyTitle}</p>
                <p className="mt-1 text-xs text-[var(--text-muted)]">{pageMeta.emptyDetail}</p>
              </div>
            ) : destination.kind === "smart" && destination.id === "today" ? (
              <div className="space-y-6">
                {todayInboxTasks.length > 0 && (
                  <section aria-label="Inbox">
                    <button
                      type="button"
                      onClick={() => setInboxCollapsed((v) => !v)}
                      className="mb-1.5 flex w-full items-center gap-2 border-b border-[var(--border-subtle)] pb-1.5 text-left text-xs font-semibold tracking-wide text-[var(--text-secondary)] uppercase hover:text-[var(--text-primary)]"
                    >
                      <Inbox className="h-3.5 w-3.5 text-[var(--accent)]" />
                      <span>Inbox</span>
                      <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                        {todayInboxTasks.length}
                      </span>
                      <span className="ml-auto text-[var(--text-muted)]">
                        {inboxCollapsed ? (
                          <ChevronRight className="h-3.5 w-3.5" />
                        ) : (
                          <ChevronDown className="h-3.5 w-3.5" />
                        )}
                      </span>
                    </button>
                    {!inboxCollapsed && (
                      <div className="space-y-0.5">{todayInboxTasks.map((i) => renderTaskRow(i))}</div>
                    )}
                  </section>
                )}

                {todayCommittedTasks.length > 0 && (
                  <section aria-label="Today" className="space-y-4">
                    {todayInboxTasks.length > 0 && !todayListGroups && (
                      <div className="mb-1.5 flex items-center gap-2 border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold tracking-wide text-[var(--text-secondary)] uppercase">
                        <Sun className="h-3.5 w-3.5" style={{ color: todayIconColor }} />
                        <span>Today</span>
                        <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                          {todayCommittedTasks.length}
                        </span>
                      </div>
                    )}

                    {todayListGroups ? (
                      <>
                        {todayListGroups.ungrouped.length > 0 && (
                          <div className="space-y-0.5">
                            {todayListGroups.ungrouped.map((i) => renderTaskRow(i, true))}
                          </div>
                        )}
                        {todayListGroups.groups.map(([key, grp]) => (
                          <div key={key}>
                            <div className="mb-1 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1 text-xs font-semibold text-[var(--text-secondary)]">
                              <span>{grp.label}</span>
                              <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                                {grp.items.length}
                              </span>
                            </div>
                            <div className="space-y-0.5">
                              {grp.items.map((i) => renderTaskRow(i, true))}
                            </div>
                          </div>
                        ))}
                      </>
                    ) : (
                      <div className="space-y-0.5">
                        {todayCommittedTasks.map((i) => renderTaskRow(i))}
                      </div>
                    )}
                  </section>
                )}

                {completedTodayTasks.length > 0 && (
                  <section aria-label="Completed today">
                    <div className="mb-1.5 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                      <span>Completed today</span>
                      <span className="font-mono-tabular font-normal">{completedTodayTasks.length}</span>
                    </div>
                    <div className="space-y-0.5">
                      {completedTodayTasks.map((i) => renderTaskRow(i))}
                    </div>
                  </section>
                )}
              </div>
            ) : destination.kind === "smart" && destination.id === "upcoming" ? (
              <div className="space-y-5">
                {upcomingGroups.map(([day, items]) => (
                  <section key={day}>
                    <div className="mb-1.5 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold text-[var(--text-secondary)]">
                      <span>{formatDayHeading(day, todayYMD, lang)}</span>
                      <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                        {items.length}
                      </span>
                    </div>
                    <div className="space-y-0.5">{items.map((i) => renderTaskRow(i))}</div>
                  </section>
                ))}
              </div>
            ) : destination.kind === "smart" && destination.id === "review" ? (
              <div className="space-y-5">
                {reviewGroups.map((group) => {
                  if (group.id !== "faded") {
                    return (
                      <section key={group.id}>
                        {renderGroupHeader(group)}
                        <div className="space-y-0.5">{group.items.map((i) => renderTaskRow(i))}</div>
                      </section>
                    );
                  }
                  return (
                    <section key={group.id}>
                      {renderGroupHeader(group, {
                        expanded: prefs.reviewFadedExpanded,
                        onToggle: () =>
                          handleChangePref("reviewFadedExpanded", !prefs.reviewFadedExpanded),
                      })}
                      {prefs.reviewFadedExpanded && (
                        <>
                          <div className="my-2 flex items-center justify-between gap-3 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/90 px-4 py-3 text-xs">
                            <div>
                              <p className="font-medium text-[var(--text-primary)]">
                                {registryText(FADED_PILE_NOTICE.title, lang)}
                              </p>
                              <p className="mt-0.5 text-[var(--text-muted)]">
                                {registryText(FADED_PILE_NOTICE.detail, lang)}
                              </p>
                            </div>
                            <button
                              type="button"
                              onClick={() => setSweepTasks(fadedTasks)}
                              className="shrink-0 rounded-lg bg-[var(--accent)] px-3 py-1.5 font-medium"
                              style={{ color: "var(--accent-check)" }}
                            >
                              {registryText(FADED_PILE_NOTICE.primaryTitle, lang)}
                            </button>
                          </div>
                          <div className="space-y-0.5">{group.items.map((i) => renderTaskRow(i))}</div>
                        </>
                      )}
                    </section>
                  );
                })}
              </div>
            ) : destination.kind === "project" && projectHeadings.length > 0 ? (
              <div className="space-y-5">
                {visibleTasks.filter((i) => !i.task.heading).length > 0 && (
                  <div className="space-y-0.5">
                    {visibleTasks.filter((i) => !i.task.heading).map((i) => renderTaskRow(i))}
                  </div>
                )}
                {projectHeadings.map((h) => {
                  const under = visibleTasks.filter((i) => i.task.heading === h.id);
                  return (
                    <section key={h.id}>
                      <div
                        onContextMenu={(e) => {
                          e.preventDefault();
                          setContextMenu({
                            x: e.clientX,
                            y: e.clientY,
                            items: [
                              {
                                kind: "item",
                                label: "Rename Section",
                                onSelect: () => {
                                  const next = window.prompt("Rename Section", h.title)?.trim();
                                  if (next && next !== h.title) void engine.updateTaskFields(h, { title: next });
                                },
                              },
                              { kind: "divider" },
                              {
                                kind: "item",
                                label: "Delete Section",
                                destructive: true,
                                onSelect: () => {
                                  if (window.confirm("Delete this section? Its tasks stay in the project.")) {
                                    void engine.deleteTask(h);
                                  }
                                },
                              },
                            ],
                          });
                        }}
                        className="mb-1.5 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold text-[var(--text-secondary)]"
                      >
                        <span>{h.title}</span>
                        <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                          {under.length}
                        </span>
                      </div>
                      <div className="space-y-0.5">{under.map((i) => renderTaskRow(i))}</div>
                    </section>
                  );
                })}
              </div>
            ) : (
              <div className="space-y-0.5">{visibleTasks.map((i) => renderTaskRow(i))}</div>
            )}
          </div>
        </div>

        {/* Multi-Select Floating Action Bar (when >= 2 tasks selected) */}
        {selectedIds.size > 1 && (
          <div className="pointer-events-none fixed right-0 bottom-5 left-0 z-30 flex justify-center px-4">
            <div className="pointer-events-auto flex flex-wrap items-center gap-2 rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-4 py-2.5 text-xs shadow-2xl">
              <span className="font-semibold text-[var(--text-primary)]">
                {selectedIds.size} selected
              </span>
              <span className="h-4 w-px bg-[var(--border-subtle)]" />
              <button
                type="button"
                onClick={async () => {
                  const anyNotToday = activeSelectedTasks.some((t) => !t.today);
                  await engine.bulkToggleToday(activeSelectedTasks, anyNotToday);
                  showToast(anyNotToday ? `Moved ${activeSelectedTasks.length} tasks to Today` : `Removed from Today`);
                }}
                className="inline-flex items-center gap-1 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
              >
                <Sun className="h-3.5 w-3.5" style={{ color: todayIconColor }} />
                Today
              </button>
              <button
                type="button"
                onClick={async () => {
                  await completeMany(activeSelectedTasks);
                  setSelectedIds(new Set());
                }}
                className="inline-flex items-center gap-1 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
              >
                <Check className="h-3.5 w-3.5" />
                Complete
              </button>
              <button
                type="button"
                onClick={async () => {
                  const tasks = activeSelectedTasks;
                  await engine.bulkDeleteTasks(tasks);
                  setSelectedIds(new Set());
                  showToast(`${tasks.length} tasks deleted`);
                }}
                className="inline-flex items-center gap-1 rounded-lg px-2.5 py-1 font-medium text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
              >
                <Trash2 className="h-3.5 w-3.5" />
                Delete
              </button>
              <button
                type="button"
                onClick={() => setSelectedIds(new Set())}
                className="ml-1 rounded-lg bg-[var(--bg-selected)] px-2.5 py-1 font-medium text-[var(--text-primary)]"
              >
                Done
              </button>
            </div>
          </div>
        )}

        {/* Shared Undo / Info Toast */}
        {(undoSnap.toast || infoToast) && selectedIds.size <= 1 && (
          <div className="pointer-events-none fixed right-0 bottom-5 left-0 z-30 flex justify-center px-4">
            <div className="pointer-events-auto flex items-center gap-3 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-4 py-2.5 text-xs shadow-lg">
              <span className="text-[var(--text-primary)]">
                {infoToast ?? undoSnap.toast?.label}
              </span>
              {!infoToast && undoSnap.canUndo && (
                <button
                  type="button"
                  onClick={() => void undoStack.undo()}
                  className="inline-flex items-center gap-1 rounded-md bg-[var(--bg-selected)] px-2 py-1 font-medium text-[var(--text-primary)]"
                >
                  <Undo2 className="h-3 w-3" />
                  Undo
                </button>
              )}
              <button
                type="button"
                onClick={() => {
                  setInfoToast(null);
                  undoStack.dismissToast();
                }}
                className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                aria-label="Dismiss"
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          </div>
        )}
      </main>

      <ContextMenu menu={contextMenu} onClose={() => setContextMenu(null)} />

      {datePicker && pickerTask && (
        <DateBoardPopover
          attribute={datePicker.attribute}
          anchor={datePicker.anchor}
          value={
            datePicker.attribute === "when" ? whenDay(pickerTask, todayYMD) : (pickerTask.deadline ?? null)
          }
          today={todayYMD}
          lang={lang}
          startTime={pickerTask.startTime}
          durationMinutes={pickerTask.durationMinutes}
          repeatTitle={repeatTitle(pickerTask, lang)}
          onPick={(day) => void setTaskDay(datePicker.attribute, datePicker.taskIds, day)}
          onClear={() => void setTaskDay(datePicker.attribute, datePicker.taskIds, null)}
          // The time and the repeat belong to one task, so a selection of several has no such rows.
          {...(datePicker.attribute === "when" && datePicker.taskIds.length === 1
            ? {
                onTimeSlotChange: (start: string | null, minutes: number | null) =>
                  void engine.setTaskTimeSlot(pickerTask, start, minutes),
                onRepeat: () => {
                  setExpandedTaskId(pickerTask.id);
                  setTimeout(() =>
                    openRepeatSelect(
                      document.querySelector<HTMLSelectElement>(
                        `[data-repeat-task="${CSS.escape(pickerTask.id)}"]`,
                      ),
                    ),
                  );
                },
              }
            : {})}
          onClose={() => setDatePicker(null)}
        />
      )}

      <TaskPageDrawer
        open={Boolean(taskPageItem)}
        itemProps={taskPageItem ? buildTaskRowProps(taskPageItem) : null}
        onClose={() => setTaskPageId(null)}
      />

      <QuickAddModal
        open={quickAddOpen}
        initial={quickAddInitial}
        areas={activeAreas}
        projects={activeProjects}
        todayYMD={todayYMD}
        lang={lang}
        onClose={() => {
          setQuickAddOpen(false);
          setQuickAddInitial(null);
        }}
        onCreate={async (input) => {
          const created = await engine.createTask({
            title: input.title,
            notes: input.notes,
            today: input.today,
            starred: input.starred,
            scheduled: input.scheduled,
            deadline: input.deadline,
            area: input.area,
            project: input.project,
          });
          if (input.referenceUrl) {
            try {
              await engine.addReference(created.id, input.referenceUrl);
            } catch {
              // Ignore unparseable reference URL.
            }
          }
        }}
      />

      <QuickFindModal
        open={quickFindOpen}
        onClose={() => setQuickFindOpen(false)}
        tasks={syncState.snapshot.tasks}
        areas={activeAreas}
        projects={activeProjects}
        tags={activeTags}
        language={lang}
        onNavigate={navigateTo}
        onSelectTask={(task) => {
          if (task.status === "done" || task.status === "cancelled") {
            setDestination({ kind: "smart", id: "logbook" });
            setLogbookTab("completed");
          } else if (task.project && projectById.has(task.project)) {
            setDestination({ kind: "project", id: task.project });
          } else if (task.area && areaById.has(task.area)) {
            setDestination({ kind: "area", id: task.area });
          } else {
            setDestination({ kind: "smart", id: "today" });
          }
          setSelectedTaskId(task.id);
          setSelectedIds(new Set([task.id]));
          openTask(task);
        }}
        onSelectTagFilter={(tid) => {
          setDestination({ kind: "smart", id: "anytime" });
          setTagFilterId(tid);
        }}
      />

      {waitingTask && (
        <WaitingOnDialog
          key={waitingTask.id}
          task={waitingTask}
          todayYMD={todayYMD}
          language={lang}
          onClose={() => setWaitingTaskId(null)}
          onSave={(name, checkBack) => setWaiting(waitingTask, name, checkBack)}
        />
      )}

      {sweepTasks && (
        <FadeSweepModal
          tasks={sweepTasks}
          areas={activeAreas}
          projects={activeProjects}
          language={lang}
          onClose={() => setSweepTasks(null)}
          onKeep={keepFaded}
          onLetRestGo={letGoFaded}
          onSwept={() => engine.setSetting("fadeSweptAt", new Date().toISOString())}
        />
      )}

      <KeyboardShortcutsModal
        open={shortcutsOpen}
        language={lang}
        orderedDestinations={sidebarDestinations.all.map((d) => ({ id: d.id, title: d.title }))}
        onClose={() => setShortcutsOpen(false)}
      />

      <FirstRunModal
        open={firstRunOpen}
        language={lang}
        api={api}
        hasExistingTasks={hasAnyActiveTasks}
        onFinish={async () => {
          await engine.setSetting("onboardedAt", new Date().toISOString());
          setFirstRunOpen(false);
          setDestination({ kind: "smart", id: "today" });
        }}
        onClose={() => setFirstRunOpen(false)}
      />

      {settingsModal}
    </div>
  );
}
