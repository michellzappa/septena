"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Calendar,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Circle,
  CloudOff,
  Folder,
  FolderPlus,
  Inbox,
  Layers,
  Menu,
  PauseCircle,
  Plus,
  RefreshCw,
  Repeat,
  Search,
  Settings,
  Sparkles,
  Star,
  Tag,
  Trash2,
  Undo2,
  Wifi,
  Wind,
  X,
} from "lucide-react";
import { SeptenaApiClient } from "@/lib/api/client";
import {
  conversationState,
  deriveConversation,
  ensureCoreReady,
  fadeFill,
  getCoreVersion,
  localTodayYMD,
  localUtcOffsetSeconds,
  rowOpacity,
  taskViewMembership,
  type AgentStage,
  type CoreConversation,
  type CoreConversationState,
  type CoreMembership,
  type CoreProjection,
} from "@/lib/core";
import {
  DESIGN_TOKENS,
  DESTINATIONS,
  GENERIC_EMPTY_STATE,
  registryText,
} from "@/lib/generated/registries";
import { WebSyncEngine, type SyncState } from "@/lib/sync/engine";
import { UndoStack, type UndoSnapshot } from "@/lib/sync/undo";
import type {
  ActiveDestination,
  SessionResponse,
  SmartDestination,
  TaskRow,
} from "@/lib/types";
import { groupUpcomingByDate, nextIsoDay } from "@/lib/upcomingGroups";
import { QuickFindModal } from "./QuickFindModal";
import { SettingsModal } from "./SettingsModal";
import { SignInScreen } from "./SignInScreen";
import { TaskRowItem } from "./TaskRowItem";

interface EvaluatedTask {
  task: TaskRow;
  membership: CoreMembership;
  opacity: number;
  convoProjection: CoreProjection | null;
  convoState: CoreConversationState | null;
}

const AGENT_STAGE_ORDER: Array<{ id: Exclude<AgentStage, null>; title: string }> = [
  { id: "yourTurn", title: "Your turn" },
  { id: "review", title: "Review" },
  { id: "working", title: "Working" },
  { id: "queued", title: "Queued" },
  { id: "done", title: "Done" },
];

function iconForDestination(id: SmartDestination) {
  switch (id) {
    case "today": return Star;
    case "review": return CheckCircle2;
    case "agent": return Sparkles;
    case "upcoming": return Calendar;
    case "repeating": return Repeat;
    case "anytime": return Layers;
    case "starred": return Star;
    case "logbook": return CheckCircle2;
    case "faded": return Wind;
  }
}

function formatDayHeading(ymd: string, todayYMD: string): string {
  const [y, m, d] = ymd.split("-").map(Number);
  const dt = new Date(y, (m || 1) - 1, d || 1);
  const [ty, tm, td] = todayYMD.split("-").map(Number);
  const todayDt = new Date(ty, (tm || 1) - 1, td || 1);
  const diffDays = Math.round((dt.getTime() - todayDt.getTime()) / (24 * 60 * 60 * 1000));
  const formatted = dt.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  if (diffDays === 1) return `Tomorrow · ${formatted}`;
  if (diffDays === 0) return `Today · ${formatted}`;
  return formatted;
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
  const [destination, setDestination] = useState<ActiveDestination>({ kind: "smart", id: "today" });
  const [logbookTab, setLogbookTab] = useState<"completed" | "deleted">("completed");
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [inboxCollapsed, setInboxCollapsed] = useState(false);
  const [tagFilterId, setTagFilterId] = useState<string | null>(null);
  const [composerTitle, setComposerTitle] = useState("");
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [quickFindOpen, setQuickFindOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [creatingKind, setCreatingKind] = useState<"area" | "project" | "heading" | null>(null);
  const [newContainerTitle, setNewContainerTitle] = useState("");
  const [showContainerNotes, setShowContainerNotes] = useState(false);
  const [containerNotesDraft, setContainerNotesDraft] = useState("");
  const [coreVersion, setCoreVersion] = useState<string>("");
  const [todayYMD, setTodayYMD] = useState<string>(() => localTodayYMD());
  const [appearanceMode, setAppearanceMode] = useState<"system" | "light" | "dark">("system");
  const [textScaleStep, setTextScaleStep] = useState<number>(0);
  const [language, setLanguage] = useState<string>("en");
  const composerRef = useRef<HTMLInputElement | null>(null);

  // Register offline shell Service Worker.
  useEffect(() => {
    if (typeof window !== "undefined" && "serviceWorker" in navigator) {
      navigator.serviceWorker.register("/sw.js").catch(() => {});
    }
  }, []);

  // Load device-local UI preferences.
  useEffect(() => {
    try {
      const m = localStorage.getItem("septena.web.appearanceMode");
      if (m === "light" || m === "dark" || m === "system") setAppearanceMode(m);
      const s = Number(localStorage.getItem("septena.web.textScaleStep"));
      if (Number.isInteger(s) && s >= -2 && s <= 2) setTextScaleStep(s);
      const l = localStorage.getItem("septena.web.language");
      if (l) setLanguage(l);
    } catch {
      // Ignore storage access errors.
    }
  }, []);

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
          setBootPhase("signed_in");
          await engine.start(session.userId);
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
  }, [api, engine]);

  // Apply appearance mode, synced fruit accent, and text scale.
  useEffect(() => {
    if (appearanceMode === "system") {
      document.documentElement.removeAttribute("data-theme");
    } else {
      document.documentElement.setAttribute("data-theme", appearanceMode);
    }
    const accentId = typeof syncState.snapshot.settings.accentColor === "string"
      ? syncState.snapshot.settings.accentColor
      : "colorful";
    const fruit =
      DESIGN_TOKENS.fruitAccents.find((f) => f.id === accentId) ??
      DESIGN_TOKENS.fruitAccents[0];
    const prefersDark =
      appearanceMode === "dark" ||
      (appearanceMode === "system" &&
        typeof window !== "undefined" &&
        window.matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.style.setProperty("--accent", prefersDark ? fruit.dark : fruit.light);

    const scaleObj = DESIGN_TOKENS.textScale.steps.find((s) => s.step === textScaleStep);
    document.documentElement.style.fontSize = `${Math.round((scaleObj?.factor ?? 1) * 16)}px`;
  }, [appearanceMode, syncState.snapshot.settings.accentColor, textScaleStep]);

  const handleChangeAppearance = (mode: "system" | "light" | "dark") => {
    setAppearanceMode(mode);
    try { localStorage.setItem("septena.web.appearanceMode", mode); } catch {}
  };

  const handleChangeTextScale = (step: number) => {
    setTextScaleStep(step);
    try { localStorage.setItem("septena.web.textScaleStep", String(step)); } catch {}
  };

  const handleChangeLanguage = (lang: string) => {
    setLanguage(lang);
    try { localStorage.setItem("septena.web.language", lang); } catch {}
  };

  const handleSignedIn = useCallback(
    async (session: SessionResponse) => {
      setBootPhase("signed_in");
      await engine.start(session.userId);
    },
    [engine],
  );

  const handleSignOut = useCallback(async () => {
    undoStack.clear();
    await engine.signOutAndWipe();
    setExpandedTaskId(null);
    setSelectedTaskId(null);
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

    const tMap = new Map<string, typeof syncState.snapshot.turns>();
    for (const turn of syncState.snapshot.turns) {
      const list = tMap.get(turn.taskId) ?? [];
      list.push(turn);
      tMap.set(turn.taskId, list);
    }
    for (const list of tMap.values()) list.sort((a, b) => a.seq - b.seq);

    return {
      activeAreas: areas,
      activeProjects: projects,
      activeTags: tags,
      areaById: new Map(areas.map((a) => [a.id, a])),
      projectById: new Map(projects.map((p) => [p.id, p])),
      checklistsByTask: cMap,
      refsByTask: rMap,
      attachmentsByTask: aMap,
      convoByTask: cvMap,
      turnsByTask: tMap,
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

  // Evaluate membership, fade opacity, and conversation projection/state via the shared Rust WASM core.
  const evaluatedTasks = useMemo((): EvaluatedTask[] => {
    if (bootPhase !== "signed_in") return [];
    return syncState.snapshot.tasks
      .filter((t) => t.kind !== "heading")
      .map((task) => {
        const membership = taskViewMembership(task, todayYMD, nowIso);
        const convo = convoByTask.get(task.id) ?? null;
        const turns = turnsByTask.get(task.id) ?? [];

        let convoProj: CoreProjection | null = null;
        let cState: CoreConversationState | null = null;
        if (convo || turns.length > 0) {
          const coreConvo: CoreConversation = {
            confirmedIntent: convo?.confirmedIntent ?? null,
            thread: turns.map((t) => ({
              seq: t.seq,
              role: t.role,
              step: t.step,
              provider: t.provider ?? null,
              options: t.options ?? null,
              confidence: t.confidence ?? null,
            })),
            artifactExists: Boolean(convo?.artifact),
            handoffExists: Boolean(convo?.handoff),
            endState: convo?.endState ?? null,
            endStateNote: convo?.endStateNote ?? null,
            assignee: convo?.assignee ?? null,
            stoppedAt: convo?.stoppedAt ?? null,
            claimUntil: convo?.claimUntil ?? null,
          };
          convoProj = deriveConversation(coreConvo, nowIso);
          cState = conversationState(coreConvo, nowIso);
        }

        const fill = fadeFill({
          isOpen: task.status === "open",
          isHeading: false,
          isDeleted: Boolean(task.deletedAt),
          isFaded: Boolean(task.fadedAt),
          deadline: task.deadline ?? null,
          scheduled: task.scheduled ?? null,
          hasRecurrence: Boolean(task.recurrenceUnit),
          isAgentTurn: Boolean(cState?.isClaimed || convoProj?.badge === "working"),
          isAssignedToClaude: convo?.assignee === "claude",
          isAwaitingHuman: Boolean(cState?.awaitsHuman),
          showsAgentCue: task.source === "mcp" && !task.acknowledgedAt,
          touchedAt: task.touchedAt ?? null,
          createdAt: task.createdAt ?? null,
          created: task.created ?? null,
          now: nowIso,
          today: todayYMD,
          utcOffsetSeconds,
        });

        return {
          task,
          membership,
          opacity: rowOpacity(fill),
          convoProjection: convoProj,
          convoState: cState,
        };
      });
  }, [bootPhase, convoByTask, nowIso, syncState.snapshot.tasks, todayYMD, turnsByTask, utcOffsetSeconds]);

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
      if (convoState?.needsHumanReview) counts.review++;
      if (convoState?.agentStage !== null && convoState?.agentStage !== undefined) counts.agent++;
      if (membership.matchesView.upcoming) counts.upcoming++;
      if (task.recurrenceUnit) counts.repeating++;
      if (membership.matchesView.anytime) counts.anytime++;
      if (task.starred) counts.starred++;
      if (task.fadedAt) counts.faded++;
    }
    return { counts, deletedCount };
  }, [evaluatedTasks, todayYMD]);

  // Sidebar smart lists from registry/destinations.json.
  const sidebarDestinations = useMemo(() => {
    const allowedIds = new Set<SmartDestination>([
      "today",
      "review",
      "agent",
      "upcoming",
      "repeating",
      "anytime",
      "starred",
      "logbook",
      "faded",
    ]);
    const list = DESTINATIONS.filter(
      (d): d is (typeof DESTINATIONS)[number] & { id: SmartDestination } =>
        allowedIds.has(d.id as SmartDestination) &&
        d.visibility !== "todayBand" &&
        d.visibility !== "logbookTab",
    );
    const visible = list.filter((d) => {
      if (d.visibility === "whenNonEmpty") {
        const c = smartCounts.counts[d.id];
        const isActive = destination.kind === "smart" && destination.id === d.id;
        return c > 0 || isActive;
      }
      return true;
    });
    const top = visible
      .filter((d) => (d.sidebarSection ?? "top") === "top")
      .sort((a, b) => (a.sidebarOrder ?? 99) - (b.sidebarOrder ?? 99));
    const bottom = visible
      .filter((d) => d.sidebarSection === "bottom")
      .sort((a, b) => (a.sidebarOrder ?? 99) - (b.sidebarOrder ?? 99));
    return { top, bottom };
  }, [destination, smartCounts.counts]);

  const projectHeadings = useMemo(() => {
    if (destination.kind !== "project") return [];
    return syncState.snapshot.tasks
      .filter((t) => !t.deletedAt && t.kind === "heading" && t.project === destination.id)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  }, [destination, syncState.snapshot.tasks]);

  const visibleTasks = useMemo(() => {
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
          case "review": return Boolean(convoState?.needsHumanReview);
          case "agent": return convoState?.agentStage !== null && convoState?.agentStage !== undefined;
          case "upcoming": return membership.matchesView.upcoming;
          case "repeating": return Boolean(task.recurrenceUnit);
          case "anytime": return membership.matchesView.anytime;
          case "starred": return Boolean(task.starred);
          case "faded": return Boolean(task.fadedAt);
        }
      }

      if (task.deletedAt || task.status !== "open") return false;
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
  }, [destination, evaluatedTasks, logbookTab, projectById, tagFilterId]);

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

  // Agent grouped by WASM conversationState.agentStage.
  const agentGroups = useMemo(() => {
    if (!(destination.kind === "smart" && destination.id === "agent")) return [];
    return AGENT_STAGE_ORDER.map((stage) => ({
      ...stage,
      items: visibleTasks.filter((i) => i.convoState?.agentStage === stage.id),
    })).filter((g) => g.items.length > 0);
  }, [destination, visibleTasks]);

  // Sync container notes draft when switching Area / Project.
  useEffect(() => {
    setShowContainerNotes(false);
    if (destination.kind === "area") {
      setContainerNotesDraft(areaById.get(destination.id)?.context ?? "");
    } else if (destination.kind === "project") {
      setContainerNotesDraft(projectById.get(destination.id)?.notes ?? "");
    }
  }, [areaById, destination, projectById]);

  // Global keyboard shortcuts (Cmd/Ctrl+K Quick Find, Cmd/Ctrl+Z Undo, N new task, Up/Down/Enter/Esc).
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (bootPhase !== "signed_in") return;
      const primary = e.metaKey || e.ctrlKey;

      if (primary && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setQuickFindOpen((v) => !v);
        return;
      }

      if (primary && e.key.toLowerCase() === "z" && !quickFindOpen && !settingsOpen) {
        const tag = (e.target as HTMLElement | null)?.tagName;
        if (tag === "INPUT" || tag === "TEXTAREA") return;
        e.preventDefault();
        if (e.shiftKey) void undoStack.redo();
        else void undoStack.undo();
        return;
      }

      if (quickFindOpen || settingsOpen) return;
      const tag = (e.target as HTMLElement | null)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;

      if (!primary && !e.altKey && (e.key === "n" || e.key === "N")) {
        e.preventDefault();
        composerRef.current?.focus();
      } else if (e.key === "ArrowDown" && visibleTasks.length > 0) {
        e.preventDefault();
        const idx = visibleTasks.findIndex((t) => t.task.id === selectedTaskId);
        const next = visibleTasks[Math.min(visibleTasks.length - 1, idx + 1)];
        if (next) setSelectedTaskId(next.task.id);
      } else if (e.key === "ArrowUp" && visibleTasks.length > 0) {
        e.preventDefault();
        const idx = visibleTasks.findIndex((t) => t.task.id === selectedTaskId);
        const prev = visibleTasks[Math.max(0, idx <= 0 ? 0 : idx - 1)];
        if (prev) setSelectedTaskId(prev.task.id);
      } else if (e.key === "Enter" && selectedTaskId) {
        e.preventDefault();
        setExpandedTaskId((prev) => (prev === selectedTaskId ? null : selectedTaskId));
      } else if (e.key === "Escape") {
        setExpandedTaskId(null);
        setSelectedTaskId(null);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [bootPhase, quickFindOpen, selectedTaskId, settingsOpen, undoStack, visibleTasks]);

  const pageMeta = useMemo(() => {
    if (destination.kind === "smart") {
      const reg = DESTINATIONS.find((d) => d.id === destination.id);
      const empty =
        destination.id === "logbook" && logbookTab === "deleted"
          ? DESTINATIONS.find((d) => d.id === "recentlyDeleted")?.emptyState
          : reg?.emptyState;
      return {
        title: registryText(reg?.title ?? destination.id, language),
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
  }, [areaById, destination, language, logbookTab, projectById]);

  const isUpcoming = destination.kind === "smart" && destination.id === "upcoming";
  const upcomingGroups = useMemo(
    () => (isUpcoming ? groupUpcomingByDate(visibleTasks, localTodayYMD()) : []),
    [isUpcoming, visibleTasks],
  );

  const handleQuickAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    const title = composerTitle.trim();
    if (!title) return;
    setComposerTitle("");

    const opts: Parameters<WebSyncEngine["createTask"]>[0] = { title };
    if (tagFilterId) opts.tags = [tagFilterId];
    if (destination.kind === "smart") {
      if (destination.id === "today") opts.today = true;
      else if (destination.id === "upcoming") opts.scheduled = nextIsoDay(localTodayYMD());
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

  const renderTaskRow = (item: EvaluatedTask) => {
    const { task, membership, opacity, convoProjection, convoState } = item;
    let containerLabel: string | null = null;
    if (destination.kind === "smart") {
      if (task.project && projectById.has(task.project)) {
        containerLabel = projectById.get(task.project)!.title;
      } else if (task.area && areaById.has(task.area)) {
        const a = areaById.get(task.area)!;
        containerLabel = `${a.emoji ? `${a.emoji} ` : ""}${a.title}`;
      }
    }

    const isDeletedView = destination.kind === "smart" && destination.id === "logbook" && logbookTab === "deleted";
    const isFadedView = destination.kind === "smart" && destination.id === "faded";

    return (
      <TaskRowItem
        key={task.id}
        task={task}
        membership={membership}
        opacity={isDeletedView ? 0.75 : opacity}
        containerLabel={containerLabel}
        hasPendingOp={pendingTaskIds.has(task.id)}
        selected={selectedTaskId === task.id}
        expanded={expandedTaskId === task.id}
        isDeletedView={isDeletedView}
        isFadedView={isFadedView}
        checklistItems={checklistsByTask.get(task.id) ?? []}
        allTags={activeTags}
        taskRefs={refsByTask.get(task.id) ?? []}
        attachments={attachmentsByTask.get(task.id) ?? []}
        convo={convoByTask.get(task.id) ?? null}
        turns={turnsByTask.get(task.id) ?? []}
        convoProjection={convoProjection}
        convoState={convoState}
        areas={activeAreas}
        projects={activeProjects}
        onSelect={() => {
          setSelectedTaskId(task.id);
          setExpandedTaskId((prev) => (prev === task.id ? null : task.id));
        }}
        onToggleDone={async () => {
          const wasDone = task.status === "done";
          const { spawnedTaskId } = await engine.toggleTaskDone(task);
          undoStack.record(
            {
              label: wasDone ? `Reopened “${task.title}”` : `Completed “${task.title}”`,
              undo: async () => {
                await engine.updateTaskFields(task, {
                  status: task.status,
                  completedAt: task.completedAt ?? null,
                });
                if (spawnedTaskId) {
                  const spawned = engine.getState().snapshot.tasks.find((t) => t.id === spawnedTaskId);
                  if (spawned) await engine.deleteTask(spawned);
                }
              },
              redo: async () => {
                await engine.toggleTaskDone(task);
              },
            },
            !wasDone,
          );
        }}
        onToggleToday={async () => {
          const prev = { today: Boolean(task.today), todaySetOn: task.todaySetOn ?? null, scheduled: task.scheduled ?? null };
          await engine.toggleTaskToday(task);
          undoStack.record({
            label: prev.today ? `Removed “${task.title}” from Today` : `Moved “${task.title}” to Today`,
            undo: () => engine.updateTaskFields(task, prev),
            redo: () => engine.toggleTaskToday(task),
          });
        }}
        onToggleStar={() => void engine.toggleTaskStar(task)}
        onUpdateFields={(fields) => void engine.updateTaskFields(task, fields)}
        onSetScheduled={(day) => void engine.setTaskScheduled(task, day)}
        onSetDeadline={(day) => void engine.setTaskDeadline(task, day)}
        onSetTimeSlot={(st, dur) => void engine.setTaskTimeSlot(task, st, dur)}
        onSetRecurrence={(rule) => void engine.setTaskRecurrence(task, rule)}
        onMoveTask={(target) => void engine.moveTask(task, target)}
        onAddChecklistItem={(title) => void engine.addChecklistItem(task.id, title)}
        onToggleChecklistItem={(c) => void engine.toggleChecklistItem(c)}
        onDeleteChecklistItem={(c) => void engine.deleteChecklistItem(c)}
        onToggleTag={(tid) => void engine.toggleTaskTag(task, tid)}
        onCreateAndToggleTag={async (name) => {
          const tag = await engine.createTag(name);
          await engine.toggleTaskTag(task, tag.id);
        }}
        onAddReference={async (input) => {
          await engine.addReference(task.id, input);
        }}
        onRemoveReference={(ref) => void engine.removeReference(ref)}
        onDownloadAttachment={(att) => void api.downloadAttachment(att.id, att.filename)}
        onAssignToAgent={(assignee) => void engine.assignTaskToAgent(task.id, assignee)}
        onAnswerQuestion={(inReplyTo, chosen) =>
          void engine.appendUserTurn(task.id, { step: "decide", inReplyTo, chosen })
        }
        onSendReply={(note) => void engine.appendUserTurn(task.id, { step: "work", note })}
        onAcceptReview={() => void engine.acceptAgentReview(task)}
        onSendBackReview={(note) => void engine.sendBackAgentReview(task, note)}
        onStopAgent={() => void engine.stopAgentOnTask(task.id)}
        onResumeAgent={() => void engine.resumeAgentOnTask(task.id)}
        onLoadHistory={() => api.getChanges("task", task.id)}
        onKeepFaded={() => void engine.keepFadedTask(task)}
        onDropFaded={() => void engine.dropFadedTask(task)}
        onRestoreDeleted={() => void engine.restoreDeletedTask(task)}
        onCancelTask={async () => {
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
        }}
        onDelete={async () => {
          setExpandedTaskId(null);
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
        }}
      />
    );
  };

  if (bootPhase === "loading") {
    return (
      <main className="flex min-h-screen items-center justify-center bg-[var(--bg-canvas)] text-sm text-[var(--text-muted)]">
        Loading Septena…
      </main>
    );
  }

  if (bootPhase === "signed_out") {
    return <SignInScreen api={api} onSignedIn={(s) => void handleSignedIn(s)} />;
  }

  const outboxCount = syncState.snapshot.outbox.length;
  const agentsPaused = Boolean(syncState.snapshot.settings.agentsPaused);

  const renderSidebarButton = (dest: (typeof sidebarDestinations.top)[number]) => {
    const Icon = iconForDestination(dest.id);
    const selected = destination.kind === "smart" && destination.id === dest.id;
    const count = smartCounts.counts[dest.id];
    return (
      <button
        key={dest.id}
        type="button"
        onClick={() => {
          setDestination({ kind: "smart", id: dest.id });
          setExpandedTaskId(null);
          setSelectedTaskId(null);
          setMobileMenuOpen(false);
        }}
        className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-sm transition-colors ${
          selected
            ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
            : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
        }`}
      >
        <Icon
          className="h-4 w-4 shrink-0"
          style={
            dest.id === "today"
              ? { color: "var(--today-gold)", fill: selected ? "var(--today-gold)" : "none" }
              : dest.id === "starred"
                ? { color: "#f59e0b", fill: selected ? "#f59e0b" : "none" }
                : undefined
          }
        />
        <span className="flex-1 truncate text-left">{registryText(dest.title, language)}</span>
        {count > 0 && (
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
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={() => setQuickFindOpen(true)}
            title="Quick Find (⌘K)"
            className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            <Search className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => setSettingsOpen(true)}
            title="Settings"
            className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
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
            return (
              <div key={area.id} className="mb-2">
                <button
                  type="button"
                  onClick={() => {
                    setDestination({ kind: "area", id: area.id });
                    setExpandedTaskId(null);
                    setSelectedTaskId(null);
                    setMobileMenuOpen(false);
                  }}
                  className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors ${
                    areaSelected
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
                      return (
                        <button
                          key={proj.id}
                          type="button"
                          onClick={() => {
                            setDestination({ kind: "project", id: proj.id });
                            setExpandedTaskId(null);
                            setSelectedTaskId(null);
                            setMobileMenuOpen(false);
                          }}
                          className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-1 text-sm transition-colors ${
                            projSelected
                              ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                              : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                          }`}
                        >
                          <Circle className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
                          <span className="truncate">{proj.title}</span>
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
              return (
                <button
                  key={proj.id}
                  type="button"
                  onClick={() => {
                    setDestination({ kind: "project", id: proj.id });
                    setExpandedTaskId(null);
                    setSelectedTaskId(null);
                    setMobileMenuOpen(false);
                  }}
                  className={`flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm transition-colors ${
                    projSelected
                      ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                      : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                  }`}
                >
                  <Circle className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
                  <span className="truncate">{proj.title}</span>
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
      <aside className="hidden w-60 shrink-0 border-r border-[var(--border-subtle)] bg-[var(--bg-sidebar)] md:block">
        {sidebarContent}
      </aside>

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
        <header className="flex flex-wrap items-center gap-3 border-b border-[var(--border-subtle)] px-4 py-3 md:px-10 md:py-5">
          <button
            type="button"
            onClick={() => setMobileMenuOpen(true)}
            className="rounded-lg p-1.5 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] md:hidden"
            aria-label="Open navigation"
          >
            <Menu className="h-5 w-5" />
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
                {visibleTasks.length}
              </span>
            </div>
          </div>

          <div className="flex items-center gap-2 text-xs">
            {destination.kind === "smart" && destination.id === "logbook" && (
              <div className="inline-flex rounded-lg border border-[var(--border-subtle)] p-0.5">
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

            {destination.kind === "smart" && destination.id === "agent" && (
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

        <div className="flex-1 overflow-y-auto px-4 py-4 md:px-10 md:py-6">
          <div className="mx-auto max-w-2xl">
            {agentsPaused && destination.kind === "smart" && (destination.id === "agent" || destination.id === "review") && (
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
                  className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium text-white"
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

            {/* Quick-add composer */}
            {pageMeta.supportsInlineCreate && (
              <form
                onSubmit={(e) => void handleQuickAdd(e)}
                className="mb-4 flex items-center gap-2 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-3 py-2 focus-within:border-[var(--accent)]"
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
                    className="rounded-md bg-[var(--accent)] px-2.5 py-1 text-xs font-medium text-white hover:opacity-90"
                  >
                    Add
                  </button>
                )}
              </form>
            )}

            {/* Task lists */}
            {visibleTasks.length === 0 && projectHeadings.length === 0 ? (
              <div className="py-16 text-center">
                <p className="text-sm font-medium text-[var(--text-secondary)]">{pageMeta.emptyTitle}</p>
                <p className="mt-1 text-xs text-[var(--text-muted)]">{pageMeta.emptyDetail}</p>
              </div>
            ) : isUpcoming ? (
              <div className="space-y-5">
                {upcomingGroups.map((group) => (
                  <section key={group.day} aria-label={group.label}>
                    <div className="mb-1.5 flex items-center gap-2 border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold tracking-wide text-[var(--text-secondary)]">
                      <Calendar className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
                      <h2>{group.label}</h2>
                    </div>
                    <div className="space-y-0.5">
                      {group.items.map(({ task, membership }) => {
                        let containerLabel: string | null = null;
                        if (task.project && projectById.has(task.project)) {
                          containerLabel = projectById.get(task.project)!.title;
                        } else if (task.area && areaById.has(task.area)) {
                          const a = areaById.get(task.area)!;
                          containerLabel = `${a.emoji ? `${a.emoji} ` : ""}${a.title}`;
                        }
                        return (
                          <TaskRowItem
                            key={task.id}
                            task={task}
                            membership={membership}
                            containerLabel={containerLabel}
                            hasPendingOp={pendingTaskIds.has(task.id)}
                            expanded={expandedTaskId === task.id}
                            onSelect={() => setExpandedTaskId((prev) => (prev === task.id ? null : task.id))}
                            onToggleDone={() => void engine.toggleTaskDone(task)}
                            onToggleToday={() => void engine.toggleTaskToday(task)}
                            onUpdateFields={(fields) => void engine.updateTaskFields(task, fields)}
                            onSetScheduled={(day) => void engine.setTaskScheduled(task, day)}
                            onSetDeadline={(day) => void engine.setTaskDeadline(task, day)}
                            onDelete={() => {
                              setExpandedTaskId(null);
                              void engine.deleteTask(task);
                            }}
                          />
                        );
                      })}
                    </div>
                  </section>
                ))}
              </div>
            ) : destination.kind === "smart" && destination.id === "today" && todayInboxTasks.length > 0 ? (
              <div className="space-y-5">
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
                      {inboxCollapsed ? <ChevronRight className="h-3.5 w-3.5" /> : <ChevronDown className="h-3.5 w-3.5" />}
                    </span>
                  </button>
                  {!inboxCollapsed && <div className="space-y-0.5">{todayInboxTasks.map(renderTaskRow)}</div>}
                </section>

                {todayCommittedTasks.length > 0 && (
                  <section aria-label="Today">
                    <div className="mb-1.5 flex items-center gap-2 border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold tracking-wide text-[var(--text-secondary)] uppercase">
                      <Star
                        className="h-3.5 w-3.5"
                        style={{ color: "var(--today-gold)", fill: "var(--today-gold)" }}
                      />
                      <span>Today</span>
                      <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                        {todayCommittedTasks.length}
                      </span>
                    </div>
                    <div className="space-y-0.5">{todayCommittedTasks.map(renderTaskRow)}</div>
                  </section>
                )}
              </div>
            ) : destination.kind === "smart" && destination.id === "upcoming" ? (
              <div className="space-y-5">
                {upcomingGroups.map(([day, items]) => (
                  <section key={day}>
                    <div className="mb-1.5 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold text-[var(--text-secondary)]">
                      <span>{formatDayHeading(day, todayYMD)}</span>
                      <span className="font-mono-tabular font-normal text-[var(--text-muted)]">{items.length}</span>
                    </div>
                    <div className="space-y-0.5">{items.map(renderTaskRow)}</div>
                  </section>
                ))}
              </div>
            ) : destination.kind === "smart" && destination.id === "agent" ? (
              <div className="space-y-5">
                {agentGroups.map((group) => (
                  <section key={group.id}>
                    <div className="mb-1.5 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold tracking-wide text-[var(--text-secondary)] uppercase">
                      <span>{group.title}</span>
                      <span className="font-mono-tabular font-normal text-[var(--text-muted)]">
                        {group.items.length}
                      </span>
                    </div>
                    <div className="space-y-0.5">{group.items.map(renderTaskRow)}</div>
                  </section>
                ))}
              </div>
            ) : destination.kind === "project" && projectHeadings.length > 0 ? (
              <div className="space-y-5">
                {visibleTasks.filter((i) => !i.task.heading).length > 0 && (
                  <div className="space-y-0.5">
                    {visibleTasks.filter((i) => !i.task.heading).map(renderTaskRow)}
                  </div>
                )}
                {projectHeadings.map((h) => {
                  const under = visibleTasks.filter((i) => i.task.heading === h.id);
                  return (
                    <section key={h.id}>
                      <div className="mb-1.5 flex items-center justify-between border-b border-[var(--border-subtle)] pb-1.5 text-xs font-semibold text-[var(--text-secondary)]">
                        <span>{h.title}</span>
                        <span className="font-mono-tabular font-normal text-[var(--text-muted)]">{under.length}</span>
                      </div>
                      <div className="space-y-0.5">{under.map(renderTaskRow)}</div>
                    </section>
                  );
                })}
              </div>
            ) : (
              <div className="space-y-0.5">{visibleTasks.map(renderTaskRow)}</div>
            )}
          </div>
        </div>

        {/* Shared Undo toast */}
        {undoSnap.toast && (
          <div className="pointer-events-none fixed right-0 bottom-5 left-0 z-40 flex justify-center px-4">
            <div className="pointer-events-auto flex items-center gap-3 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-4 py-2.5 text-xs shadow-lg">
              <span className="text-[var(--text-primary)]">{undoSnap.toast.label}</span>
              {undoSnap.canUndo && (
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
                onClick={() => undoStack.dismissToast()}
                className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                aria-label="Dismiss"
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          </div>
        )}
      </main>

      <QuickFindModal
        open={quickFindOpen}
        onClose={() => setQuickFindOpen(false)}
        tasks={syncState.snapshot.tasks}
        areas={activeAreas}
        projects={activeProjects}
        tags={activeTags}
        onNavigate={(dest) => {
          setDestination(dest);
          setExpandedTaskId(null);
          setSelectedTaskId(null);
        }}
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
          setExpandedTaskId(task.id);
        }}
        onSelectTagFilter={(tid) => {
          setDestination({ kind: "smart", id: "anytime" });
          setTagFilterId(tid);
        }}
      />

      <SettingsModal
        open={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        api={api}
        engine={engine}
        snapshot={syncState.snapshot}
        coreVersion={coreVersion}
        appearanceMode={appearanceMode}
        onChangeAppearanceMode={handleChangeAppearance}
        textScaleStep={textScaleStep}
        onChangeTextScaleStep={handleChangeTextScale}
        language={language}
        onChangeLanguage={handleChangeLanguage}
        onSignOut={() => void handleSignOut()}
      />
    </div>
  );
}
