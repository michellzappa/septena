"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Calendar,
  CheckCircle2,
  Circle,
  CloudOff,
  Folder,
  Inbox,
  Layers,
  LogOut,
  Menu,
  Plus,
  RefreshCw,
  Star,
  Wifi,
  X,
} from "lucide-react";
import { SeptenaApiClient } from "@/lib/api/client";
import {
  ensureCoreReady,
  getCoreVersion,
  localTodayYMD,
  taskViewMembership,
  type CoreMembership,
} from "@/lib/core";
import { WebSyncEngine, type SyncState } from "@/lib/sync/engine";
import { FRUIT_ACCENTS, type ActiveDestination, type SessionResponse, type SmartDestination, type TaskRow } from "@/lib/types";
import { groupUpcomingByDate, nextIsoDay } from "@/lib/upcomingGroups";
import { SignInScreen } from "./SignInScreen";
import { TaskRowItem } from "./TaskRowItem";

const SMART_LISTS: Array<{
  id: SmartDestination;
  label: string;
  icon: typeof Inbox;
}> = [
  { id: "inbox", label: "Inbox", icon: Inbox },
  { id: "today", label: "Today", icon: Star },
  { id: "upcoming", label: "Upcoming", icon: Calendar },
  { id: "anytime", label: "Anytime", icon: Layers },
  { id: "logbook", label: "Logbook", icon: CheckCircle2 },
];

export function SeptenaApp() {
  const apiRef = useRef<SeptenaApiClient | null>(null);
  const engineRef = useRef<WebSyncEngine | null>(null);
  if (!apiRef.current) apiRef.current = new SeptenaApiClient();
  if (!engineRef.current) engineRef.current = new WebSyncEngine(apiRef.current);

  const api = apiRef.current;
  const engine = engineRef.current;

  const [bootPhase, setBootPhase] = useState<"loading" | "signed_out" | "signed_in">("loading");
  const [syncState, setSyncState] = useState<SyncState>(() => engine.getState());
  const [destination, setDestination] = useState<ActiveDestination>({ kind: "smart", id: "today" });
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [composerTitle, setComposerTitle] = useState("");
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [coreVersion, setCoreVersion] = useState<string>("");
  const composerRef = useRef<HTMLInputElement | null>(null);

  // Register offline shell Service Worker.
  useEffect(() => {
    if (typeof window !== "undefined" && "serviceWorker" in navigator) {
      navigator.serviceWorker.register("/sw.js").catch(() => {
        // Non-fatal in dev or private browsing.
      });
    }
  }, []);

  // Subscribe to engine state.
  useEffect(() => engine.subscribe(setSyncState), [engine]);

  // Boot: load WASM core, restore cookie session (or fall back to offline cached account).
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
        // Network offline during boot: open cached account if IndexedDB has one.
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

  // Apply synced fruit accent color.
  useEffect(() => {
    const accentId = typeof syncState.snapshot.settings.accentColor === "string"
      ? syncState.snapshot.settings.accentColor
      : "colorful";
    const accent = FRUIT_ACCENTS[accentId] ?? FRUIT_ACCENTS.colorful;
    const isDark = typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches;
    document.documentElement.style.setProperty("--accent", isDark ? accent.dark : accent.light);
  }, [syncState.snapshot.settings.accentColor]);

  // Press 'n' outside inputs to focus the quick-add composer.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (bootPhase !== "signed_in") return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const tag = (e.target as HTMLElement | null)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
      if (e.key === "n" || e.key === "N") {
        e.preventDefault();
        composerRef.current?.focus();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [bootPhase]);

  const handleSignedIn = useCallback(
    async (session: SessionResponse) => {
      setBootPhase("signed_in");
      await engine.start(session.userId);
    },
    [engine],
  );

  const handleSignOut = useCallback(async () => {
    await engine.signOutAndWipe();
    setExpandedTaskId(null);
    setBootPhase("signed_out");
  }, [engine]);

  const todayYMD = localTodayYMD();
  const nowIso = new Date().toISOString();

  const { activeAreas, activeProjects, areaById, projectById } = useMemo(() => {
    const areas = syncState.snapshot.areas
      .filter((a) => !a.deletedAt)
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0) || a.title.localeCompare(b.title));
    const projects = syncState.snapshot.projects
      .filter((p) => !p.deletedAt && p.status === "active")
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0) || a.title.localeCompare(b.title));
    return {
      activeAreas: areas,
      activeProjects: projects,
      areaById: new Map(areas.map((a) => [a.id, a])),
      projectById: new Map(projects.map((p) => [p.id, p])),
    };
  }, [syncState.snapshot.areas, syncState.snapshot.projects]);

  const pendingTaskIds = useMemo(() => {
    const ids = new Set<string>();
    for (const op of syncState.snapshot.outbox) {
      if (op.entity === "task") ids.add(op.id);
    }
    return ids;
  }, [syncState.snapshot.outbox]);

  // Evaluate membership for every non-deleted, non-heading task via the WASM core.
  const evaluatedTasks = useMemo(() => {
    if (bootPhase !== "signed_in") return [] as Array<{ task: TaskRow; membership: CoreMembership }>;
    return syncState.snapshot.tasks
      .filter((t) => !t.deletedAt && t.kind !== "heading")
      .map((task) => ({
        task,
        membership: taskViewMembership(task, todayYMD, nowIso),
      }));
  }, [bootPhase, syncState.snapshot.tasks, todayYMD, nowIso]);

  const smartCounts = useMemo(() => {
    const counts: Record<SmartDestination, number> = {
      inbox: 0,
      today: 0,
      upcoming: 0,
      anytime: 0,
      logbook: 0,
    };
    for (const { task, membership } of evaluatedTasks) {
      if (task.status === "done") {
        counts.logbook++;
        continue;
      }
      if (task.status !== "open") continue;
      if (membership.matchesView.inbox) counts.inbox++;
      if (membership.matchesView.today) counts.today++;
      if (membership.matchesView.upcoming) counts.upcoming++;
      if (membership.matchesView.anytime) counts.anytime++;
    }
    return counts;
  }, [evaluatedTasks]);

  const visibleTasks = useMemo(() => {
    const filtered = evaluatedTasks.filter(({ task, membership }) => {
      if (destination.kind === "smart") {
        if (destination.id === "logbook") return task.status === "done";
        if (task.status !== "open") return false;
        return membership.matchesView[destination.id];
      }
      if (destination.kind === "area") {
        if (task.status !== "open") return false;
        if (task.area === destination.id) return true;
        const proj = task.project ? projectById.get(task.project) : null;
        return proj?.area === destination.id;
      }
      return task.status === "open" && task.project === destination.id;
    });

    return filtered.sort((a, b) => {
      if (destination.kind === "smart" && destination.id === "logbook") {
        return String(b.task.completedAt ?? "").localeCompare(String(a.task.completedAt ?? ""));
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
  }, [destination, evaluatedTasks, projectById]);

  const pageMeta = useMemo(() => {
    if (destination.kind === "smart") {
      const found = SMART_LISTS.find((s) => s.id === destination.id)!;
      return { title: found.label, subtitle: null as string | null };
    }
    if (destination.kind === "area") {
      const area = areaById.get(destination.id);
      return {
        title: area ? `${area.emoji ? `${area.emoji} ` : ""}${area.title}` : "Area",
        subtitle: "Area",
      };
    }
    const proj = projectById.get(destination.id);
    const parentArea = proj?.area ? areaById.get(proj.area) : null;
    return {
      title: proj?.title ?? "Project",
      subtitle: parentArea ? parentArea.title : "Project",
    };
  }, [areaById, destination, projectById]);

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
    if (destination.kind === "smart") {
      if (destination.id === "today") opts.today = true;
      else if (destination.id === "upcoming") opts.scheduled = nextIsoDay(localTodayYMD());
    } else if (destination.kind === "area") {
      opts.area = destination.id;
    } else if (destination.kind === "project") {
      opts.project = destination.id;
      const proj = projectById.get(destination.id);
      if (proj?.area) opts.area = proj.area;
    }
    await engine.createTask(opts);
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

  const sidebarContent = (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between px-4 pt-4 pb-2">
        <div className="flex items-center gap-2">
          <img src="/icon.svg" alt="" className="h-6 w-6 rounded-md" />
          <span className="text-sm font-semibold tracking-tight text-[var(--text-primary)]">
            Septena
          </span>
        </div>
        <button
          type="button"
          onClick={() => setMobileMenuOpen(false)}
          className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] md:hidden"
          aria-label="Close sidebar"
        >
          <X className="h-4 w-4" />
        </button>
      </div>

      <nav className="flex-1 overflow-y-auto px-2 py-2">
        <div className="space-y-0.5">
          {SMART_LISTS.map((item) => {
            const Icon = item.icon;
            const selected = destination.kind === "smart" && destination.id === item.id;
            const count = smartCounts[item.id];
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => {
                  setDestination({ kind: "smart", id: item.id });
                  setExpandedTaskId(null);
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
                    item.id === "today"
                      ? { color: "var(--today-gold)", fill: selected ? "var(--today-gold)" : "none" }
                      : undefined
                  }
                />
                <span className="flex-1 truncate text-left">{item.label}</span>
                {count > 0 && item.id !== "logbook" && (
                  <span className="font-mono-tabular text-xs text-[var(--text-muted)]">{count}</span>
                )}
              </button>
            );
          })}
        </div>

        {(activeAreas.length > 0 || activeProjects.length > 0) && (
          <div className="mt-5 border-t border-[var(--border-subtle)] pt-3">
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
          </div>
        )}
      </nav>

      <div className="border-t border-[var(--border-subtle)] p-3 text-xs">
        <div className="mb-2 flex items-center justify-between gap-2 text-[var(--text-muted)]">
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

        <div className="flex items-center justify-between text-[11px] text-[var(--text-muted)]">
          <span className="font-mono-tabular">
            rev {syncState.snapshot.cursor} · core {coreVersion}
          </span>
          <button
            type="button"
            onClick={() => void handleSignOut()}
            className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            <LogOut className="h-3 w-3" />
            Sign out
          </button>
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
      <main className="flex min-w-0 flex-1 flex-col overflow-hidden">
        <header className="flex items-center gap-3 border-b border-[var(--border-subtle)] px-4 py-3 md:px-10 md:py-5">
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
        </header>

        <div className="flex-1 overflow-y-auto px-4 py-4 md:px-10 md:py-6">
          <div className="mx-auto max-w-2xl">
            {syncState.lastError && (
              <div className="mb-4 rounded-lg border border-amber-500/30 bg-amber-500/10 px-3.5 py-2 text-xs text-amber-700 dark:text-amber-300">
                {syncState.lastError}
              </div>
            )}

            {syncState.notSynced.length > 0 && (
              <div className="mb-4 rounded-lg border border-red-500/30 bg-red-500/10 px-3.5 py-2 text-xs text-red-700 dark:text-red-300">
                {syncState.notSynced.length} change(s) could not be synced:{" "}
                {syncState.notSynced[syncState.notSynced.length - 1].reason}
              </div>
            )}

            {/* Quick-add composer */}
            {!(destination.kind === "smart" && destination.id === "logbook") && (
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

            {/* Task rows */}
            {visibleTasks.length === 0 ? (
              <div className="py-16 text-center text-sm text-[var(--text-muted)]">
                Nothing here yet.
              </div>
            ) : isUpcoming ? (
              <div className="space-y-5">
                {upcomingGroups.map((group) => (
                  <section key={group.day} aria-label={group.label}>
                    <div className="mb-1.5 flex items-center gap-2 px-2">
                      <Calendar className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
                      <h2 className="text-xs font-semibold tracking-wide text-[var(--text-secondary)]">
                        {group.label}
                      </h2>
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
            ) : (
              <div className="space-y-0.5">
                {visibleTasks.map(({ task, membership }) => {
                  let containerLabel: string | null = null;
                  if (destination.kind === "smart") {
                    if (task.project && projectById.has(task.project)) {
                      containerLabel = projectById.get(task.project)!.title;
                    } else if (task.area && areaById.has(task.area)) {
                      const a = areaById.get(task.area)!;
                      containerLabel = `${a.emoji ? `${a.emoji} ` : ""}${a.title}`;
                    }
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
            )}
          </div>
        </div>
      </main>
    </div>
  );
}
