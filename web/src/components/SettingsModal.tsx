"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  Activity,
  ArrowDown,
  ArrowUp,
  Bell,
  BookOpen,
  Bot,
  Calendar,
  Check,
  Code,
  Copy,
  Cpu,
  Download,
  ExternalLink,
  Eye,
  EyeOff,
  Info,
  KeyRound,
  Keyboard,
  Link2,
  LogOut,
  MonitorSmartphone,
  PauseCircle,
  Pencil,
  PlayCircle,
  RefreshCw,
  RotateCcw,
  Send,
  Shield,
  SlidersHorizontal,
  Trash2,
  Upload,
  UserCircle,
  Users,
  X,
} from "lucide-react";
import {
  DESIGN_TOKENS,
  FIRST_RUN,
  HELP_URL,
  REGISTRY_LANGUAGES,
  SETTINGS_REGISTRY,
  registryText,
} from "@/lib/generated/registries";
import {
  exportAsCsv,
  exportAsJson,
  exportAsMarkdown,
  parseImportJson,
  type ParsedBackupPreview,
} from "@/lib/export";
import { SIDEBAR_DESTINATIONS, destinationInfo } from "@/lib/destinations";
import { fadeSettings } from "@/lib/fade";
import type { HeaderTextureStyle } from "@/lib/headerWash";
import type { WebDisplayPrefs } from "@/lib/prefs";
import type { SeptenaApiClient } from "@/lib/api/client";
import type { WebSyncEngine } from "@/lib/sync/engine";
import type {
  AccessSummary,
  IcalFeedSettings,
  NotSyncedItem,
  SmartDestination,
  StoreSnapshot,
} from "@/lib/types";
import { HeaderWashPreview } from "./HeaderWash";

type SettingsTab =
  | "account"
  | "general"
  | "ai_agents"
  | "connections_data"
  | "privacy"
  | "about";

interface SettingsModalProps {
  open: boolean;
  onClose: () => void;
  api: SeptenaApiClient;
  engine: WebSyncEngine;
  snapshot: StoreSnapshot;
  notSynced: NotSyncedItem[];
  onClearNotSynced: () => void;
  coreVersion: string;
  dayISO: string;
  isDark: boolean;
  accentHex: string;
  prefs: WebDisplayPrefs;
  onChangePref: <K extends keyof WebDisplayPrefs>(key: K, value: WebDisplayPrefs[K]) => void;
  onSignOut: () => void;
  onDeleteAccount: () => Promise<void>;
  onShowWelcomeAgain: () => void;
  onOpenShortcuts: () => void;
}

const TABS: Array<{ id: SettingsTab; title: string; icon: typeof UserCircle }> = [
  { id: "account", title: "Account", icon: UserCircle },
  { id: "general", title: "General", icon: SlidersHorizontal },
  { id: "ai_agents", title: "AI & Agents", icon: Cpu },
  { id: "connections_data", title: "Connections", icon: Link2 },
  { id: "privacy", title: "Privacy & Data", icon: Shield },
  { id: "about", title: "About", icon: Info },
];

const CUSTOMIZABLE_SMART_LISTS: SmartDestination[] = SIDEBAR_DESTINATIONS.map((d) => d.id);

const SETTING_ROWS: ReadonlyArray<{ key?: string; label?: string; detail?: string }> =
  SETTINGS_REGISTRY.rootGroups.flatMap((g): ReadonlyArray<object> => g.items);
const FADE_SETTING_ROW = SETTING_ROWS.find((r) => r.key === "tasksShowAging");

function ToggleRow({
  label,
  detail,
  checked,
  onChange,
}: {
  label: string;
  detail?: string;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <label className="flex cursor-pointer items-center justify-between gap-3 py-2">
      <div className="min-w-0">
        <p className="text-xs font-medium text-[var(--text-primary)]">{label}</p>
        {detail && <p className="text-[11px] text-[var(--text-muted)]">{detail}</p>}
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        onClick={() => onChange(!checked)}
        className={`relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors ${
          checked ? "bg-[var(--accent)]" : "bg-[var(--border-subtle)]"
        }`}
      >
        <span
          className={`inline-block h-3.5 w-3.5 transform rounded-full bg-white shadow transition-transform ${
            checked ? "translate-x-4.5" : "translate-x-0.5"
          }`}
        />
      </button>
    </label>
  );
}

export function SettingsModal({
  open,
  onClose,
  api,
  engine,
  snapshot,
  notSynced,
  onClearNotSynced,
  coreVersion,
  dayISO,
  isDark,
  accentHex,
  prefs,
  onChangePref,
  onSignOut,
  onDeleteAccount,
  onShowWelcomeAgain,
  onOpenShortcuts,
}: SettingsModalProps) {
  const [tab, setTab] = useState<SettingsTab>("general");
  const [access, setAccess] = useState<AccessSummary | null>(null);
  const [accessError, setAccessError] = useState<string | null>(null);
  const [pairCode, setPairCode] = useState("");
  const [pairPreview, setPairPreview] = useState<{ kind: "connector" | "device"; client: string } | null>(null);
  const [pairStatus, setPairStatus] = useState<string | null>(null);
  const [renamingAgentId, setRenamingAgentId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState("");
  const [welcomeNameDraft, setWelcomeNameDraft] = useState("");
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleteConfirmText, setDeleteConfirmText] = useState("");
  const [deletingAccount, setDeletingAccount] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  const [ical, setIcal] = useState<IcalFeedSettings | null>(null);
  const [icalBusy, setIcalBusy] = useState(false);
  const [icalError, setIcalError] = useState<string | null>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [confirmRotateIcal, setConfirmRotateIcal] = useState(false);

  const [skillText, setSkillText] = useState<string | null>(null);
  const [showSkill, setShowSkill] = useState(false);
  const [showAiExplainer, setShowAiExplainer] = useState(false);
  const [showSmartListEditor, setShowSmartListEditor] = useState(false);

  const [importPreview, setImportPreview] = useState<ParsedBackupPreview | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [importStatus, setImportStatus] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [notifPerm, setNotifPerm] = useState<NotificationPermission | "unsupported">(() => {
    if (typeof window === "undefined" || !("Notification" in window)) return "unsupported";
    return Notification.permission;
  });

  useEffect(() => {
    if (open) {
      setWelcomeNameDraft(
        typeof snapshot.settings.welcomeName === "string" ? snapshot.settings.welcomeName : "",
      );
      setDeleteDialogOpen(false);
      setDeleteConfirmText("");
      setDeleteError(null);
      setImportError(null);
      setImportStatus(null);
    }
  }, [open, snapshot.settings.welcomeName]);

  const loadAccess = useCallback(async () => {
    setAccessError(null);
    try {
      setAccess(await api.getAccessSummary());
    } catch (err) {
      setAccessError(err instanceof Error ? err.message : "Could not load devices & agents");
    }
  }, [api]);

  const loadIcal = useCallback(async () => {
    setIcalError(null);
    try {
      setIcal(await api.getIcalSettings());
    } catch (err) {
      setIcalError(err instanceof Error ? err.message : "Could not load calendar feed settings");
    }
  }, [api]);

  useEffect(() => {
    if (!open) return;
    if (tab === "account" || tab === "ai_agents") void loadAccess();
    if (tab === "connections_data") void loadIcal();
  }, [loadAccess, loadIcal, open, tab]);

  if (!open) return null;

  const lang = prefs.language;
  const currentAccent =
    typeof snapshot.settings.accentColor === "string" ? snapshot.settings.accentColor : "colorful";
  const currentTexture = (
    typeof snapshot.settings.canvasTexture === "string" ? snapshot.settings.canvasTexture : "none"
  ) as HeaderTextureStyle;
  const textureIntensity =
    typeof snapshot.settings.textureIntensity === "number"
      ? snapshot.settings.textureIntensity
      : 55;
  const textureMotion =
    snapshot.settings.textureMotion === "slowDrift" ? "slowDrift" : "still";
  const agentsPaused = Boolean(snapshot.settings.agentsPaused);

  // Synced smart list sidebar customization.
  const rawOrder = Array.isArray(snapshot.settings.smartListOrder)
    ? (snapshot.settings.smartListOrder as string[])
    : [];
  const hiddenSet = new Set<string>(
    Array.isArray(snapshot.settings.smartListHidden)
      ? (snapshot.settings.smartListHidden as string[])
      : [],
  );
  const placementMap =
    snapshot.settings.smartListPlacement && typeof snapshot.settings.smartListPlacement === "object"
      ? (snapshot.settings.smartListPlacement as Record<string, "top" | "bottom">)
      : {};

  const orderedSmartListIds: SmartDestination[] = [
    ...rawOrder.filter((id): id is SmartDestination =>
      CUSTOMIZABLE_SMART_LISTS.includes(id as SmartDestination),
    ),
    ...CUSTOMIZABLE_SMART_LISTS.filter((id) => !rawOrder.includes(id)),
  ];

  const sectionFor = (id: SmartDestination): "top" | "bottom" => {
    if (id === "today") return "top";
    const info = destinationInfo(id);
    const override = info?.canMoveSection ? placementMap[id] : undefined;
    if (override === "top" || override === "bottom") return override;
    return info?.sidebarSection ?? "top";
  };

  const moveSmartListOrder = async (id: SmartDestination, delta: -1 | 1) => {
    const sec = sectionFor(id);
    const inSec = orderedSmartListIds.filter((x) => sectionFor(x) === sec);
    const idx = inSec.indexOf(id);
    const swapIdx = idx + delta;
    if (idx < 0 || swapIdx < 0 || swapIdx >= inSec.length) return;
    const swapped = [...inSec];
    [swapped[idx], swapped[swapIdx]] = [swapped[swapIdx], swapped[idx]];
    const otherSec = orderedSmartListIds.filter((x) => sectionFor(x) !== sec);
    const nextOrder = sec === "top" ? [...swapped, ...otherSec] : [...otherSec, ...swapped];
    await engine.setSetting("smartListOrder", nextOrder);
  };

  const toggleSmartListHidden = async (id: SmartDestination) => {
    if (id === "today") return;
    const next = new Set(hiddenSet);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    await engine.setSetting("smartListHidden", Array.from(next));
  };

  const toggleSmartListSection = async (id: SmartDestination) => {
    if (id === "today") return;
    const nextSection = sectionFor(id) === "top" ? "bottom" : "top";
    await engine.setSetting("smartListPlacement", { ...placementMap, [id]: nextSection });
  };

  const resetSmartLists = async () => {
    await engine.setSetting("smartListOrder", []);
    await engine.setSetting("smartListHidden", []);
    await engine.setSetting("smartListPlacement", {});
  };

  const copyText = async (id: string, value: string) => {
    try {
      await navigator.clipboard.writeText(value);
      setCopiedId(id);
      setTimeout(() => setCopiedId((prev) => (prev === id ? null : prev)), 2000);
    } catch {
      // Clipboard blocked.
    }
  };

  const handleInspectCode = async (e: React.FormEvent) => {
    e.preventDefault();
    const cleaned = pairCode.trim();
    if (!cleaned) return;
    setPairStatus(null);
    setPairPreview(null);
    try {
      const res = await api.inspectPairingCode(cleaned);
      setPairPreview({ kind: res.kind, client: res.client });
    } catch (err) {
      setPairStatus(err instanceof Error ? err.message : "That code is wrong or has expired.");
    }
  };

  const handleApproveCode = async () => {
    if (!pairPreview) return;
    try {
      await api.approvePairingCode(pairCode.trim(), pairPreview.kind);
      setPairStatus(
        pairPreview.kind === "connector"
          ? "Claude is connected. Go back to your browser to finish."
          : `${pairPreview.client} is signed in.`,
      );
      setPairPreview(null);
      setPairCode("");
      void loadAccess();
    } catch (err) {
      setPairStatus(err instanceof Error ? err.message : "Approval failed");
    }
  };

  const handleIcalUpdate = async (body: {
    enabled?: boolean;
    scope?: "all" | "timed";
    rotate?: boolean;
  }) => {
    setIcalBusy(true);
    setIcalError(null);
    try {
      const updated = await api.updateIcalSettings(body);
      setIcal(updated);
      setConfirmRotateIcal(false);
    } catch (err) {
      setIcalError(err instanceof Error ? err.message : "Could not update calendar feed");
    } finally {
      setIcalBusy(false);
    }
  };

  const handlePickImportFile = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    setImportError(null);
    setImportStatus(null);
    try {
      const text = await file.text();
      setImportPreview(parseImportJson(text));
    } catch (err) {
      setImportError(err instanceof Error ? err.message : "Import failed.");
    }
  };

  const handleConfirmImport = async () => {
    if (!importPreview || importing) return;
    setImporting(true);
    setImportError(null);
    try {
      const imported = await engine.importBackup(importPreview);
      setImportStatus(`Imported ${imported} items.`);
      setImportPreview(null);
    } catch (err) {
      setImportError(err instanceof Error ? err.message : "Import failed.");
    } finally {
      setImporting(false);
    }
  };

  const handleRequestNotifications = async () => {
    if (typeof window === "undefined" || !("Notification" in window)) return;
    const perm = await Notification.requestPermission();
    setNotifPerm(perm);
  };

  const handleToggleSkillBrief = async () => {
    const next = !showSkill;
    setShowSkill(next);
    if (next && skillText === null) {
      try {
        setSkillText(await api.fetchSkillMarkdown());
      } catch {
        setSkillText("The brief did not load. Check your connection and open this page again.");
      }
    }
  };

  const handleDeleteAccount = async () => {
    if (deletingAccount) return;
    setDeletingAccount(true);
    setDeleteError(null);
    try {
      await onDeleteAccount();
      onClose();
    } catch (err) {
      setDeleteError(
        err instanceof Error ? err.message : "Couldn’t delete your account. Nothing was deleted.",
      );
    } finally {
      setDeletingAccount(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-4"
      onClick={onClose}
    >
      <div
        className="flex h-[84vh] max-h-[680px] w-full max-w-3xl overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Left Settings Sidebar matching Mac desktopTabs */}
        <aside className="hidden w-48 shrink-0 flex-col border-r border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-2.5 sm:flex">
          <div className="px-2.5 py-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
            {registryText("Settings", lang)}
          </div>
          <nav className="space-y-0.5">
            {TABS.map((t) => {
              const Icon = t.icon;
              const active = tab === t.id;
              return (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => setTab(t.id)}
                  className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left text-xs font-medium transition-colors ${
                    active
                      ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                  }`}
                >
                  <Icon className="h-4 w-4 shrink-0" />
                  <span className="truncate">{registryText(t.title, lang)}</span>
                </button>
              );
            })}
          </nav>
        </aside>

        {/* Right content column */}
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
            <h2 className="text-base font-semibold text-[var(--text-primary)]">
              {registryText(TABS.find((t) => t.id === tab)?.title ?? "Settings", lang)}
            </h2>
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
              aria-label="Close settings"
            >
              <X className="h-4 w-4" />
            </button>
          </div>

          {/* Compact tab strip on narrow screens */}
          <div className="flex gap-1 overflow-x-auto border-b border-[var(--border-subtle)] px-3 py-2 text-xs sm:hidden">
            {TABS.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => setTab(t.id)}
                className={`shrink-0 rounded-lg px-2.5 py-1 font-medium ${
                  tab === t.id
                    ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                    : "text-[var(--text-secondary)]"
                }`}
              >
                {registryText(t.title, lang)}
              </button>
            ))}
          </div>

          <div className="flex-1 space-y-6 overflow-y-auto p-5 text-sm">
            {/* ACCOUNT TAB */}
            {tab === "account" && (
              <>
                <section className="rounded-xl border border-[var(--border-subtle)] p-4">
                  <label className="block text-xs font-medium text-[var(--text-primary)]">
                    Your name
                  </label>
                  <input
                    type="text"
                    value={welcomeNameDraft}
                    onChange={(e) => setWelcomeNameDraft(e.target.value)}
                    onBlur={() => {
                      const trimmed = welcomeNameDraft.trim();
                      if (trimmed !== (snapshot.settings.welcomeName ?? "")) {
                        void engine.setSetting("welcomeName", trimmed);
                      }
                    }}
                    placeholder="Your name"
                    className="mt-1.5 w-full rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-sm text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                  <p className="mt-1.5 text-[11px] text-[var(--text-muted)]">
                    Your name stays on this device, and syncs when you sign in.
                  </p>
                </section>

                {snapshot.userId && (
                  <section className="rounded-xl border border-[var(--border-subtle)] p-4">
                    <div className="flex items-center justify-between gap-3">
                      <div className="min-w-0">
                        <p className="text-xs font-medium text-[var(--text-primary)]">
                          {registryText(
                            SETTINGS_REGISTRY.copy.sync_account_status.find((c) => c.id === "accountIdLabel")?.label ?? "Account ID",
                            lang,
                          )}
                        </p>
                        <p className="font-mono-tabular mt-1 truncate text-xs text-[var(--text-secondary)]">
                          {snapshot.userId}
                        </p>
                      </div>
                      <button
                        type="button"
                        onClick={() => void copyText("account-id", snapshot.userId!)}
                        className="flex shrink-0 items-center gap-1 rounded-lg border border-[var(--border-subtle)] px-2.5 py-1 text-xs text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                      >
                        {copiedId === "account-id" ? (
                          <>
                            <Check className="h-3.5 w-3.5 text-[var(--accent)]" />
                            <span>
                              {registryText(
                                SETTINGS_REGISTRY.copy.sync_account_status.find((c) => c.id === "copied")?.label ?? "Copied",
                                lang,
                              )}
                            </span>
                          </>
                        ) : (
                          <>
                            <Copy className="h-3.5 w-3.5" />
                            <span>
                              {registryText(
                                SETTINGS_REGISTRY.copy.sync_account_status.find((c) => c.id === "copy")?.label ?? "Copy",
                                lang,
                              )}
                            </span>
                          </>
                        )}
                      </button>
                    </div>
                    <p className="mt-1.5 text-[11px] text-[var(--text-muted)]">
                      {registryText(
                        SETTINGS_REGISTRY.copy.sync_account_status.find((c) => c.id === "accountIdFooter")?.label ?? "",
                        lang,
                      )}
                    </p>
                  </section>
                )}

                <section className="rounded-xl border border-[var(--border-subtle)] p-4">
                  <h3 className="mb-1.5 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    <KeyRound className="h-3.5 w-3.5" />
                    Approve a sign-in
                  </h3>
                  <p className="mb-2.5 text-[11px] text-[var(--text-muted)]">
                    Enter the code from the other device. If you&apos;re connecting Claude, the code is in your browser.
                  </p>
                  <form onSubmit={(e) => void handleInspectCode(e)} className="flex gap-2">
                    <input
                      type="text"
                      value={pairCode}
                      onChange={(e) => setPairCode(e.target.value)}
                      placeholder="ABCD-EFGH"
                      className="font-mono-tabular min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                    />
                    <button
                      type="submit"
                      className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium hover:opacity-90"
                      style={{ color: "var(--accent-check)" }}
                    >
                      Continue
                    </button>
                  </form>
                  {pairPreview && (
                    <div className="mt-3 flex items-center justify-between rounded-lg bg-[var(--bg-hover)] p-2.5 text-xs">
                      <span>
                        {pairPreview.kind === "connector"
                          ? `Connect ${pairPreview.client} to your tasks?`
                          : `Sign in on ${pairPreview.client}?`}
                      </span>
                      <div className="flex items-center gap-1.5">
                        <button
                          type="button"
                          onClick={() => setPairPreview(null)}
                          className="rounded-md px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-elevated)]"
                        >
                          Don&apos;t approve
                        </button>
                        <button
                          type="button"
                          onClick={() => void handleApproveCode()}
                          className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium"
                          style={{ color: "var(--accent-check)" }}
                        >
                          Approve
                        </button>
                      </div>
                    </div>
                  )}
                  {pairStatus && <p className="mt-2 text-xs text-[var(--text-secondary)]">{pairStatus}</p>}
                  <p className="mt-2 text-[11px] text-[var(--text-muted)]">
                    Only approve a code you started yourself. Septena never asks for a code by email, text or phone call.
                  </p>
                </section>

                <section>
                  <h3 className="mb-2 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    <MonitorSmartphone className="h-3.5 w-3.5" />
                    Devices ({access?.devices.length ?? 0})
                  </h3>
                  {accessError && <p className="text-xs text-[var(--overdue-red)]">{accessError}</p>}
                  <div className="space-y-1.5">
                    {(access?.devices ?? []).map((dev) => (
                      <div
                        key={dev.sid}
                        className="flex items-center justify-between rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs"
                      >
                        <div>
                          <p className="font-medium text-[var(--text-primary)]">
                            {dev.client || "Septena device"}
                            {dev.current && (
                              <span className="ml-2 rounded bg-[var(--bg-selected)] px-1.5 py-0.5 text-[10px]">
                                Current device
                              </span>
                            )}
                          </p>
                          {dev.lastUsedAt && (
                            <p className="text-[11px] text-[var(--text-muted)]">
                              Active {new Date(dev.lastUsedAt).toLocaleDateString()}
                              {dev.syncing === false ? " · not syncing" : ""}
                            </p>
                          )}
                        </div>
                        {!dev.current && (
                          <button
                            type="button"
                            onClick={async () => {
                              await api.revokeDevice(dev.sid);
                              void loadAccess();
                            }}
                            className="rounded px-2 py-1 text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                          >
                            Sign out
                          </button>
                        )}
                      </div>
                    ))}
                  </div>
                </section>

                <section className="space-y-3 border-t border-[var(--border-subtle)] pt-4">
                  <div className="flex flex-wrap items-center gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        onClose();
                        onSignOut();
                      }}
                      className="inline-flex items-center gap-2 rounded-lg border border-[var(--border-subtle)] px-3.5 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      <LogOut className="h-3.5 w-3.5" />
                      Sign out and clear local browser data
                    </button>

                    <button
                      type="button"
                      onClick={() => setDeleteDialogOpen(true)}
                      className="inline-flex items-center gap-2 rounded-lg border border-[var(--overdue-red)]/35 px-3.5 py-2 text-xs font-medium text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                      Delete account
                    </button>
                  </div>

                  {deleteDialogOpen && (
                    <div className="space-y-2.5 rounded-xl border border-[var(--overdue-red)]/40 bg-[var(--overdue-red)]/5 p-4 text-xs">
                      <p className="font-semibold text-[var(--text-primary)]">Delete your account?</p>
                      <p className="text-[var(--text-secondary)]">
                        This deletes the following from the Septena server:
                      </p>
                      <ul className="list-disc space-y-0.5 pl-4 text-[var(--text-secondary)]">
                        <li>Your tasks, areas and projects</li>
                        <li>Your attachments</li>
                        <li>Your task conversations</li>
                        <li>Your synced settings</li>
                      </ul>
                      <p className="text-[var(--text-secondary)]">
                        It also removes your tasks from this device and signs you out. You can&apos;t undo this.
                      </p>
                      <div className="flex items-center gap-2 pt-1">
                        <input
                          type="text"
                          value={deleteConfirmText}
                          onChange={(e) => setDeleteConfirmText(e.target.value)}
                          placeholder='Type "DELETE" to confirm'
                          className="font-mono-tabular min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-2.5 py-1.5 text-xs outline-none"
                        />
                        <button
                          type="button"
                          onClick={() => {
                            setDeleteDialogOpen(false);
                            setDeleteConfirmText("");
                          }}
                          className="rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 font-medium text-[var(--text-primary)]"
                        >
                          Cancel
                        </button>
                        <button
                          type="button"
                          disabled={deleteConfirmText.trim().toUpperCase() !== "DELETE" || deletingAccount}
                          onClick={() => void handleDeleteAccount()}
                          className="rounded-lg bg-[var(--overdue-red)] px-3 py-1.5 font-medium text-white disabled:opacity-40"
                        >
                          {deletingAccount ? "Deleting…" : "Delete account"}
                        </button>
                      </div>
                      {deleteError && <p className="text-[var(--overdue-red)]">{deleteError}</p>}
                    </div>
                  )}
                </section>
              </>
            )}

            {/* GENERAL TAB (Lists + Smart Lists + Appearance + Header Textures + Text Size + Language) */}
            {tab === "general" && (
              <>
                <section>
                  <div className="mb-2 flex items-center justify-between">
                    <h3 className="text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                      Lists
                    </h3>
                    <button
                      type="button"
                      onClick={() => setShowSmartListEditor((v) => !v)}
                      className="rounded-md bg-[var(--bg-hover)] px-2.5 py-1 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
                    >
                      {showSmartListEditor ? "Hide Smart Lists" : "Customize Smart Lists…"}
                    </button>
                  </div>

                  {showSmartListEditor && (
                    <div className="mb-4 space-y-3 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3.5 text-xs">
                      {(["top", "bottom"] as const).map((sec) => {
                        const ids = orderedSmartListIds.filter((id) => sectionFor(id) === sec);
                        return (
                          <div key={sec}>
                            <p className="mb-1.5 text-[11px] font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                              {sec === "top" ? "Above Areas & Projects" : "Below Areas & Projects"}
                            </p>
                            {ids.length === 0 ? (
                              <p className="py-1 text-[var(--text-muted)]">No smart lists in this section</p>
                            ) : (
                              <div className="space-y-1">
                                {ids.map((id, idx) => {
                                  const reg = destinationInfo(id);
                                  const isHidden = hiddenSet.has(id);
                                  const locked = id === "today";
                                  return (
                                    <div
                                      key={id}
                                      className="flex items-center gap-2 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-2.5 py-1.5"
                                    >
                                      <span
                                        className={`min-w-0 flex-1 truncate font-medium ${
                                          isHidden ? "text-[var(--text-muted)] line-through" : "text-[var(--text-primary)]"
                                        }`}
                                      >
                                        {registryText(reg?.title ?? id, lang)}
                                      </span>
                                      <span className="text-[10px] text-[var(--text-muted)]">
                                        {reg?.visibility === "whenNonEmpty" ? "When non-empty" : "Always"}
                                      </span>
                                      <button
                                        type="button"
                                        disabled={idx === 0}
                                        onClick={() => void moveSmartListOrder(id, -1)}
                                        className="rounded p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] disabled:opacity-30"
                                        title="Move up"
                                      >
                                        <ArrowUp className="h-3.5 w-3.5" />
                                      </button>
                                      <button
                                        type="button"
                                        disabled={idx === ids.length - 1}
                                        onClick={() => void moveSmartListOrder(id, 1)}
                                        className="rounded p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] disabled:opacity-30"
                                        title="Move down"
                                      >
                                        <ArrowDown className="h-3.5 w-3.5" />
                                      </button>
                                      {!locked && (
                                        <>
                                          {destinationInfo(id)?.canMoveSection && (
                                          <button
                                            type="button"
                                            onClick={() => void toggleSmartListSection(id)}
                                            className="rounded bg-[var(--bg-hover)] px-1.5 py-0.5 text-[10px] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                                            title={sec === "top" ? "Move below Areas & Projects" : "Move above Areas & Projects"}
                                          >
                                            {sec === "top" ? "↓ Below" : "↑ Above"}
                                          </button>
                                          )}
                                          <button
                                            type="button"
                                            onClick={() => void toggleSmartListHidden(id)}
                                            className="rounded p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
                                            title={isHidden ? "Show in sidebar" : "Hide from sidebar"}
                                          >
                                            {isHidden ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}
                                          </button>
                                        </>
                                      )}
                                    </div>
                                  );
                                })}
                              </div>
                            )}
                          </div>
                        );
                      })}
                      <div className="flex items-center justify-between pt-1">
                        <span className="text-[11px] text-[var(--text-muted)]">
                          Changes sync across all your devices.
                        </span>
                        <button
                          type="button"
                          onClick={() => void resetSmartLists()}
                          className="inline-flex items-center gap-1 rounded px-2 py-1 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                        >
                          <RotateCcw className="h-3 w-3" />
                          Reset to Defaults
                        </button>
                      </div>
                    </div>
                  )}

                  <div className="divide-y divide-[var(--border-subtle)] rounded-xl border border-[var(--border-subtle)] px-3.5">
                    <ToggleRow
                      label="Group Today by list"
                      detail="When off, tasks appear in one list with their project or area underneath."
                      checked={prefs.todayGroupByList}
                      onChange={(v) => onChangePref("todayGroupByList", v)}
                    />
                    <ToggleRow
                      label="Show completed tasks"
                      detail="Show tasks completed today at the bottom of Today."
                      checked={prefs.todayShowCompleted}
                      onChange={(v) => onChangePref("todayShowCompleted", v)}
                    />
                    <ToggleRow
                      label={registryText(FADE_SETTING_ROW?.label ?? "", lang)}
                      detail={registryText(FADE_SETTING_ROW?.detail ?? "", lang)}
                      checked={fadeSettings(snapshot.settings).enabled}
                      onChange={(v) => void engine.setSetting("tasksShowAging", v)}
                    />
                    <ToggleRow
                      label="Show faded tasks"
                      detail="Show faded tasks in projects and areas."
                      checked={prefs.tasksShowFaded}
                      onChange={(v) => onChangePref("tasksShowFaded", v)}
                    />
                    <ToggleRow
                      label="Show sidebar counts"
                      checked={prefs.sidebarCounts}
                      onChange={(v) => onChangePref("sidebarCounts", v)}
                    />
                    <ToggleRow
                      label="Completion animations"
                      checked={prefs.loggingAnimationsEnabled}
                      onChange={(v) => onChangePref("loggingAnimationsEnabled", v)}
                    />
                  </div>
                </section>

                <section>
                  <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Appearance
                  </h3>
                  <div className="grid grid-cols-3 gap-2">
                    {(["system", "light", "dark"] as const).map((m) => (
                      <button
                        key={m}
                        type="button"
                        onClick={() => onChangePref("appearanceMode", m)}
                        className={`rounded-lg border px-3 py-2 text-xs font-medium capitalize transition-colors ${
                          prefs.appearanceMode === m
                            ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                            : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                        }`}
                      >
                        {m}
                      </button>
                    ))}
                  </div>
                </section>

                <section>
                  <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Accent color (synced)
                  </h3>
                  <div className="grid grid-cols-3 gap-2">
                    {DESIGN_TOKENS.fruitAccents.map((fruit) => {
                      const selected = currentAccent === fruit.id;
                      const swatch = isDark ? fruit.dark : fruit.light;
                      return (
                        <button
                          key={fruit.id}
                          type="button"
                          onClick={() => void engine.setSetting("accentColor", fruit.id)}
                          className={`flex items-center gap-2 rounded-lg border px-2.5 py-2 text-left text-xs transition-colors ${
                            selected
                              ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                              : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                          }`}
                        >
                          <span
                            className="h-3.5 w-3.5 shrink-0 rounded-full"
                            style={{ backgroundColor: swatch }}
                          />
                          <span className="truncate font-medium">{fruit.name}</span>
                          {selected && <Check className="ml-auto h-3.5 w-3.5 shrink-0" />}
                        </button>
                      );
                    })}
                  </div>
                </section>

                <section>
                  <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Header Texture (synced)
                  </h3>
                  <div className="grid grid-cols-3 gap-2">
                    {DESIGN_TOKENS.textures.map((tex) => {
                      const selected = currentTexture === tex.id;
                      return (
                        <button
                          key={tex.id}
                          type="button"
                          onClick={() => void engine.setSetting("canvasTexture", tex.id)}
                          className={`flex flex-col overflow-hidden rounded-xl border p-2 text-left transition-colors ${
                            selected
                              ? "border-[var(--accent)] bg-[var(--bg-selected)]"
                              : "border-[var(--border-subtle)] hover:bg-[var(--bg-hover)]"
                          }`}
                        >
                          <div className="mb-1.5 h-11 w-full overflow-hidden rounded-md bg-[var(--bg-canvas)]">
                            <HeaderWashPreview
                              style={tex.id as HeaderTextureStyle}
                              isDark={isDark}
                              accentHex={accentHex}
                              intensity={textureIntensity}
                              dayISO={dayISO}
                            />
                          </div>
                          <span className="text-xs font-medium text-[var(--text-primary)]">{tex.name}</span>
                          <span className="text-[10px] text-[var(--text-muted)]">{tex.tag}</span>
                        </button>
                      );
                    })}
                  </div>

                  {currentTexture !== "none" && (
                    <div className="mt-3 space-y-2 rounded-xl border border-[var(--border-subtle)] p-3 text-xs">
                      <div className="flex items-center justify-between gap-3">
                        <span className="font-medium text-[var(--text-primary)]">Intensity</span>
                        <input
                          type="range"
                          min={15}
                          max={100}
                          value={textureIntensity}
                          onChange={(e) =>
                            void engine.setSetting("textureIntensity", Number(e.target.value))
                          }
                          className="w-40 accent-[var(--accent)]"
                        />
                        <span className="font-mono-tabular w-9 text-right text-[var(--text-muted)]">
                          {textureIntensity}%
                        </span>
                      </div>
                      <ToggleRow
                        label="Slow drift"
                        detail="Refreshes daily · pauses under Reduce Motion."
                        checked={textureMotion === "slowDrift"}
                        onChange={(v) =>
                          void engine.setSetting("textureMotion", v ? "slowDrift" : "still")
                        }
                      />
                    </div>
                  )}
                </section>

                <section>
                  <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Text size
                  </h3>
                  <div className="grid grid-cols-5 gap-1.5">
                    {DESIGN_TOKENS.textScale.steps.map((s) => (
                      <button
                        key={s.id}
                        type="button"
                        onClick={() => onChangePref("textSizeStep", s.step)}
                        className={`rounded-lg border px-2 py-1.5 text-xs transition-colors ${
                          prefs.textSizeStep === s.step
                            ? "border-[var(--accent)] bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                            : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                        }`}
                      >
                        {s.label}
                      </button>
                    ))}
                  </div>
                </section>

                <section>
                  <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Language
                  </h3>
                  <div className="flex flex-wrap gap-1.5">
                    {REGISTRY_LANGUAGES.map((l) => (
                      <button
                        key={l}
                        type="button"
                        onClick={() => onChangePref("language", l)}
                        className={`rounded-lg border px-3 py-1.5 text-xs font-medium transition-colors ${
                          prefs.language === l
                            ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                            : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                        }`}
                      >
                        {l}
                      </button>
                    ))}
                  </div>
                </section>
              </>
            )}

            {/* AI & AGENTS TAB */}
            {tab === "ai_agents" && (
              <>
                <section className="flex items-center justify-between rounded-xl border border-[var(--border-subtle)] p-3.5">
                  <div>
                    <p className="text-xs font-medium text-[var(--text-primary)]">Pause all agents</p>
                    <p className="text-[11px] text-[var(--text-muted)]">
                      While paused, no agent can start or work on a task.
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => void engine.setSetting("agentsPaused", !agentsPaused)}
                    className={`inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium ${
                      agentsPaused
                        ? "bg-amber-500/15 text-amber-600 dark:text-amber-400"
                        : "bg-[var(--bg-hover)] text-[var(--text-primary)]"
                    }`}
                  >
                    {agentsPaused ? <PlayCircle className="h-3.5 w-3.5" /> : <PauseCircle className="h-3.5 w-3.5" />}
                    {agentsPaused ? "Paused — Resume" : "Pause all"}
                  </button>
                </section>

                <section className="space-y-3 rounded-xl border border-[var(--border-subtle)] p-4 text-xs">
                  <h3 className="flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    <Bot className="h-3.5 w-3.5" />
                    Connect Claude (Official MCP Connector)
                  </h3>
                  <div className="space-y-2">
                    <div className="flex items-center justify-between gap-2 rounded-lg bg-[var(--bg-sidebar)] px-3 py-2">
                      <div className="min-w-0">
                        <p className="text-[10px] font-medium text-[var(--text-muted)] uppercase">Connector URL</p>
                        <p className="font-mono-tabular truncate text-[var(--text-primary)]">
                          https://api.septena.app/mcp
                        </p>
                      </div>
                      <button
                        type="button"
                        onClick={() => void copyText("mcp_url", "https://api.septena.app/mcp")}
                        className="inline-flex shrink-0 items-center gap-1 rounded-md bg-[var(--bg-elevated)] px-2.5 py-1 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
                      >
                        {copiedId === "mcp_url" ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
                        {copiedId === "mcp_url" ? "Copied" : "Copy"}
                      </button>
                    </div>

                    <div className="flex flex-wrap gap-2">
                      <button
                        type="button"
                        onClick={() => void copyText("setup_prompt", FIRST_RUN.prompts.setup)}
                        className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
                      >
                        {copiedId === "setup_prompt" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                        {copiedId === "setup_prompt" ? "Copied" : "Copy Setup prompt"}
                      </button>
                      <button
                        type="button"
                        onClick={() => void copyText("first_prompt", FIRST_RUN.prompts.first)}
                        className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
                      >
                        {copiedId === "first_prompt" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                        {copiedId === "first_prompt" ? "Copied" : "Copy First prompt"}
                      </button>
                      <button
                        type="button"
                        onClick={() => void handleToggleSkillBrief()}
                        className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                      >
                        <BookOpen className="h-3.5 w-3.5" />
                        MCP Skills
                      </button>
                    </div>
                  </div>

                  {showSkill && (
                    <div className="space-y-2 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3">
                      <div className="flex items-center justify-between">
                        <span className="font-medium text-[var(--text-primary)]">Agent skill brief (skill.md)</span>
                        {skillText && (
                          <button
                            type="button"
                            onClick={() => void copyText("skill_md", skillText)}
                            className="inline-flex items-center gap-1 rounded bg-[var(--bg-elevated)] px-2 py-0.5 font-medium"
                          >
                            {copiedId === "skill_md" ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
                            {copiedId === "skill_md" ? "Copied" : "Copy Skill"}
                          </button>
                        )}
                      </div>
                      <pre className="max-h-44 overflow-auto whitespace-pre-wrap text-[11px] text-[var(--text-secondary)]">
                        {skillText ?? "Loading…"}
                      </pre>
                    </div>
                  )}

                  <p className="text-[11px] text-[var(--text-muted)]">
                    Paste the setup prompt into Claude, or add the connector URL to Claude as a custom connector. When your browser shows a code, enter it under Account ▸ Approve a sign-in.
                  </p>
                </section>

                <section>
                  <h3 className="mb-2 flex items-center gap-1.5 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    <Users className="h-3.5 w-3.5" />
                    Connected agents ({access?.connections.length ?? 0})
                  </h3>
                  {!access || access.connections.length === 0 ? (
                    <p className="text-xs text-[var(--text-muted)]">No agents connected.</p>
                  ) : (
                    <div className="space-y-1.5">
                      {access.connections.map((conn) => {
                        const displayName = conn.name || conn.clientName || conn.clientId || "Agent";
                        const isRenaming = renamingAgentId === conn.id;
                        return (
                          <div
                            key={conn.id}
                            className="flex items-center justify-between gap-2 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs"
                          >
                            {isRenaming ? (
                              <form
                                onSubmit={async (e) => {
                                  e.preventDefault();
                                  await api.renameAgent(conn.id, renameDraft.trim() || null);
                                  setRenamingAgentId(null);
                                  void loadAccess();
                                }}
                                className="flex flex-1 items-center gap-2"
                              >
                                <input
                                  type="text"
                                  autoFocus
                                  value={renameDraft}
                                  onChange={(e) => setRenameDraft(e.target.value)}
                                  placeholder="Agent name"
                                  className="min-w-0 flex-1 rounded border border-[var(--accent)] bg-transparent px-2 py-0.5 text-xs outline-none"
                                />
                                <button
                                  type="submit"
                                  className="rounded bg-[var(--accent)] px-2 py-0.5 font-medium"
                                  style={{ color: "var(--accent-check)" }}
                                >
                                  Save
                                </button>
                                <button
                                  type="button"
                                  onClick={() => setRenamingAgentId(null)}
                                  className="rounded px-1.5 py-0.5 text-[var(--text-muted)]"
                                >
                                  Cancel
                                </button>
                              </form>
                            ) : (
                              <>
                                <div>
                                  <p className="font-medium text-[var(--text-primary)]">{displayName}</p>
                                  <p className="text-[11px] text-[var(--text-muted)]">
                                    {conn.lastUsedAt
                                      ? `Last used ${new Date(conn.lastUsedAt).toLocaleDateString()}`
                                      : "Connected"}
                                  </p>
                                </div>
                                <div className="flex items-center gap-1">
                                  <button
                                    type="button"
                                    onClick={() => {
                                      setRenamingAgentId(conn.id);
                                      setRenameDraft(conn.name ?? "");
                                    }}
                                    className="inline-flex items-center gap-1 rounded px-2 py-1 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                                  >
                                    <Pencil className="h-3 w-3" />
                                    Rename
                                  </button>
                                  <button
                                    type="button"
                                    onClick={async () => {
                                      await api.disconnectAgent(conn.id);
                                      void loadAccess();
                                    }}
                                    className="inline-flex items-center gap-1 rounded px-2 py-1 text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                                  >
                                    <Trash2 className="h-3 w-3" />
                                    Disconnect
                                  </button>
                                </div>
                              </>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                </section>

                <section className="space-y-2.5 rounded-xl border border-[var(--border-subtle)] p-4 text-xs">
                  <h3 className="text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Where AI runs
                  </h3>
                  <div className="grid grid-cols-3 gap-2">
                    {(
                      [
                        { id: "onDeviceOnly", label: "On-device only" },
                        { id: "auto", label: "Automatic" },
                        { id: "useMyClaude", label: "Use my Claude" },
                      ] as const
                    ).map((opt) => (
                      <button
                        key={opt.id}
                        type="button"
                        onClick={() => onChangePref("aiMode", opt.id)}
                        className={`rounded-lg border px-2.5 py-2 text-xs font-medium transition-colors ${
                          prefs.aiMode === opt.id
                            ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                            : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                        }`}
                      >
                        {opt.label}
                      </button>
                    ))}
                  </div>
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {prefs.aiMode === "onDeviceOnly"
                      ? "Discuss never leaves this device. Septena has no on-device model here, so Discuss is off."
                      : prefs.aiMode === "auto"
                        ? "Septena has no on-device model here, so Discuss hands the task to your own Claude. Recommended."
                        : "Prefer your connected Claude for reasoning (your account, your data). Septena still never runs AI on your tasks."}
                  </p>
                  <button
                    type="button"
                    onClick={() => setShowAiExplainer((v) => !v)}
                    className="font-medium text-[var(--accent)] hover:underline"
                  >
                    {showAiExplainer ? "Hide how AI helps" : "How AI helps with your tasks"}
                  </button>
                  {showAiExplainer && (
                    <div className="space-y-1.5 rounded-lg bg-[var(--bg-sidebar)] p-3 text-[11px] text-[var(--text-secondary)]">
                      <p>
                        Some tasks need thinking before you can act. Open Discuss on any task to talk it through with your connected agent.
                      </p>
                      <p>
                        Septena&apos;s servers never run AI on your tasks. Nothing important happens on its own: any real decision or action waits for your confirmation in Review or Discuss.
                      </p>
                    </div>
                  )}
                </section>
              </>
            )}

            {/* CONNECTIONS TAB (Private iCal Feed + Browser Reminders) */}
            {tab === "connections_data" && (
              <>
                <section className="space-y-3 rounded-xl border border-[var(--border-subtle)] p-4 text-xs">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <Calendar className="h-4 w-4 text-[var(--accent)]" />
                      <div>
                        <p className="font-semibold text-[var(--text-primary)]">
                          Calendar Feed (iCal)
                        </p>
                        <p className="text-[11px] text-[var(--text-muted)]">
                          Private read-only subscription feed for Apple Calendar, Google Calendar, or Outlook.
                        </p>
                      </div>
                    </div>
                    <button
                      type="button"
                      disabled={icalBusy || !ical}
                      onClick={() => void handleIcalUpdate({ enabled: !ical?.enabled })}
                      className={`relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors disabled:opacity-40 ${
                        ical?.enabled ? "bg-[var(--accent)]" : "bg-[var(--border-subtle)]"
                      }`}
                      role="switch"
                      aria-checked={Boolean(ical?.enabled)}
                    >
                      <span
                        className={`inline-block h-3.5 w-3.5 transform rounded-full bg-white shadow transition-transform ${
                          ical?.enabled ? "translate-x-4.5" : "translate-x-0.5"
                        }`}
                      />
                    </button>
                  </div>

                  {icalError && <p className="text-[var(--overdue-red)]">{icalError}</p>}

                  {ical?.enabled && ical.url && (
                    <div className="space-y-3 border-t border-[var(--border-subtle)] pt-3">
                      <div className="flex items-center gap-2">
                        <span className="text-[var(--text-muted)]">Include:</span>
                        {(["all", "timed"] as const).map((scope) => (
                          <button
                            key={scope}
                            type="button"
                            disabled={icalBusy}
                            onClick={() => void handleIcalUpdate({ enabled: true, scope })}
                            className={`rounded-lg border px-2.5 py-1 font-medium ${
                              ical.scope === scope
                                ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                                : "border-[var(--border-subtle)] text-[var(--text-secondary)]"
                            }`}
                          >
                            {scope === "all" ? "All dated tasks" : "Timed tasks only"}
                          </button>
                        ))}
                      </div>

                      <div className="font-mono-tabular truncate rounded-lg bg-[var(--bg-sidebar)] px-3 py-2 text-[11px] text-[var(--text-secondary)]">
                        {ical.url}
                      </div>

                      <div className="flex flex-wrap items-center gap-2">
                        <button
                          type="button"
                          onClick={() => void copyText("ical_url", ical.url!)}
                          className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--accent)] px-3 py-1.5 font-medium"
                          style={{ color: "var(--accent-check)" }}
                        >
                          {copiedId === "ical_url" ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                          {copiedId === "ical_url" ? "Copied" : "Copy URL"}
                        </button>
                        {ical.webcalUrl && (
                          <a
                            href={ical.webcalUrl}
                            className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                          >
                            <ExternalLink className="h-3.5 w-3.5" />
                            Open in Calendar
                          </a>
                        )}
                        <button
                          type="button"
                          onClick={() => setConfirmRotateIcal(true)}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                        >
                          <RefreshCw className="h-3.5 w-3.5" />
                          Rotate Link
                        </button>
                      </div>

                      {confirmRotateIcal && (
                        <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 p-3">
                          <p className="font-medium text-[var(--text-primary)]">Rotate Calendar Feed Link?</p>
                          <p className="mt-0.5 text-[11px] text-[var(--text-secondary)]">
                            Rotating replaces your private feed link immediately. Existing calendar subscriptions will stop updating until you re-subscribe with the new URL.
                          </p>
                          <div className="mt-2 flex gap-2">
                            <button
                              type="button"
                              onClick={() => setConfirmRotateIcal(false)}
                              className="rounded-md bg-[var(--bg-elevated)] px-2.5 py-1 font-medium"
                            >
                              Cancel
                            </button>
                            <button
                              type="button"
                              disabled={icalBusy}
                              onClick={() => void handleIcalUpdate({ enabled: true, rotate: true })}
                              className="rounded-md bg-amber-600 px-2.5 py-1 font-medium text-white"
                            >
                              Rotate Link
                            </button>
                          </div>
                        </div>
                      )}
                    </div>
                  )}

                  <p className="text-[11px] text-[var(--text-muted)]">
                    Anyone with the private URL can read titles and notes in the feed; rotate or disable it anytime.
                  </p>
                </section>

                <section className="flex items-center justify-between gap-3 rounded-xl border border-[var(--border-subtle)] p-4 text-xs">
                  <div className="flex items-center gap-2.5">
                    <Bell className="h-4 w-4 text-[var(--accent)]" />
                    <div>
                      <p className="font-semibold text-[var(--text-primary)]">Timed reminders</p>
                      <p className="text-[11px] text-[var(--text-muted)]">
                        {notifPerm === "granted"
                          ? "Browser notifications are enabled for due task reminders."
                          : notifPerm === "denied"
                            ? "Browser notifications are blocked; reminders still appear as in-app banners."
                            : notifPerm === "unsupported"
                              ? "Reminders appear as in-app banners while web.septena.app is open."
                              : "Allow browser notifications to alert you when a task reminder is due."}
                      </p>
                    </div>
                  </div>
                  {notifPerm === "default" && (
                    <button
                      type="button"
                      onClick={() => void handleRequestNotifications()}
                      className="shrink-0 rounded-lg bg-[var(--accent)] px-3 py-1.5 font-medium"
                      style={{ color: "var(--accent-check)" }}
                    >
                      Allow notifications
                    </button>
                  )}
                </section>
              </>
            )}

            {/* PRIVACY & DATA TAB (Export + JSON Backup Import with Preview) */}
            {tab === "privacy" && (
              <>
                <section className="rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-4 text-xs leading-relaxed text-[var(--text-secondary)]">
                  <p className="mb-1 font-semibold text-[var(--text-primary)]">Your data</p>
                  <p>
                    Your tasks, areas, projects, and conversations stay in your browser&apos;s IndexedDB and sync through Septena&apos;s private server at api.septena.app, encrypted at rest (not end-to-end, so connected agents can read them when you choose). Connect Claude under AI &amp; Agents.
                  </p>
                </section>

                <section>
                  <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    Export (always free)
                  </h3>
                  <div className="flex flex-wrap gap-2">
                    <button
                      type="button"
                      onClick={() => exportAsJson(snapshot)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      <Download className="h-3.5 w-3.5" />
                      Export JSON backup
                    </button>
                    <button
                      type="button"
                      onClick={() => exportAsMarkdown(snapshot)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      <Download className="h-3.5 w-3.5" />
                      Export Markdown
                    </button>
                    <button
                      type="button"
                      onClick={() => exportAsCsv(snapshot)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      <Download className="h-3.5 w-3.5" />
                      Export CSV
                    </button>
                  </div>
                </section>

                <section className="space-y-3 rounded-xl border border-[var(--border-subtle)] p-4 text-xs">
                  <div className="flex items-center justify-between gap-3">
                    <div>
                      <p className="font-semibold text-[var(--text-primary)]">Import JSON backup…</p>
                      <p className="text-[11px] text-[var(--text-muted)]">
                        Preview and import a Septena JSON export. Existing items with matching IDs are kept; new items are added and synced.
                      </p>
                    </div>
                    <input
                      ref={fileInputRef}
                      type="file"
                      accept="application/json,.json"
                      onChange={(e) => void handlePickImportFile(e)}
                      className="hidden"
                    />
                    <button
                      type="button"
                      onClick={() => fileInputRef.current?.click()}
                      className="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      <Upload className="h-3.5 w-3.5" />
                      Choose file
                    </button>
                  </div>

                  {importError && <p className="text-[var(--overdue-red)]">{importError}</p>}
                  {importStatus && <p className="font-medium text-emerald-600 dark:text-emerald-400">{importStatus}</p>}

                  {importPreview && (
                    <div className="space-y-2 rounded-lg bg-[var(--bg-sidebar)] p-3">
                      <p className="font-semibold text-[var(--text-primary)]">Import Septena backup</p>
                      <p className="text-[var(--text-secondary)]">
                        Found {importPreview.areas.length} areas, {importPreview.projects.length} projects, and{" "}
                        {importPreview.tasks.length} tasks
                        {importPreview.checklistItems.length > 0
                          ? ` (${importPreview.checklistItems.length} checklist items)`
                          : ""}
                        .
                      </p>
                      {importPreview.skippedNonTaskCount > 0 && (
                        <p className="text-[var(--text-muted)]">
                          {importPreview.skippedNonTaskCount} non-task records will be skipped.
                        </p>
                      )}
                      <p className="text-[11px] text-[var(--text-muted)]">
                        Existing items with matching IDs are kept; new items are added and synced.
                      </p>
                      <div className="flex items-center gap-2 pt-1">
                        <button
                          type="button"
                          onClick={() => setImportPreview(null)}
                          className="rounded-lg bg-[var(--bg-elevated)] px-3 py-1.5 font-medium text-[var(--text-secondary)]"
                        >
                          Cancel
                        </button>
                        <button
                          type="button"
                          disabled={importing}
                          onClick={() => void handleConfirmImport()}
                          className="rounded-lg bg-[var(--accent)] px-3.5 py-1.5 font-medium disabled:opacity-40"
                          style={{ color: "var(--accent-check)" }}
                        >
                          {importing ? "Importing…" : "Import"}
                        </button>
                      </div>
                    </div>
                  )}
                </section>
              </>
            )}

            {/* ABOUT TAB */}
            {tab === "about" && (
              <>
                <section className="flex items-center gap-3.5 rounded-xl border border-[var(--border-subtle)] p-4">
                  <img src="/icon.svg" alt="" className="h-11 w-11 rounded-xl" />
                  <div>
                    <p className="text-sm font-semibold text-[var(--text-primary)]">Septena Web</p>
                    <p className="text-xs text-[var(--text-secondary)]">Tasks that think with you</p>
                    <p className="font-mono-tabular mt-0.5 text-[11px] text-[var(--text-muted)]">
                      Shared Rust core WASM v{coreVersion} · Revision {snapshot.cursor}
                    </p>
                  </div>
                </section>

                <section className="divide-y divide-[var(--border-subtle)] rounded-xl border border-[var(--border-subtle)] text-xs">
                  <a
                    href={HELP_URL}
                    target="_blank"
                    rel="noreferrer"
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <BookOpen className="h-4 w-4 text-[var(--text-muted)]" />
                    <span>{registryText("Help", lang)}</span>
                    <ExternalLink className="ml-auto h-3.5 w-3.5 text-[var(--text-muted)]" />
                  </a>
                  <button
                    type="button"
                    onClick={() => {
                      onClose();
                      onOpenShortcuts();
                    }}
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Keyboard className="h-4 w-4 text-[var(--text-muted)]" />
                    <span>Keyboard Shortcuts</span>
                    <span className="font-mono-tabular ml-auto text-[11px] text-[var(--text-muted)]">⌘⇧/</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      onClose();
                      onShowWelcomeAgain();
                    }}
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Info className="h-4 w-4 text-[var(--text-muted)]" />
                    <span>Show Welcome Again</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => void engine.setSetting("getStartedDismissed", false)}
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <RotateCcw className="h-4 w-4 text-[var(--text-muted)]" />
                    <span>Show Get Started Again</span>
                  </button>
                  <a
                    href="https://github.com/michellzappa/septena"
                    target="_blank"
                    rel="noreferrer"
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Code className="h-4 w-4 text-[var(--text-muted)]" />
                    <span>Open source</span>
                    <span className="ml-auto text-[11px] text-[var(--text-muted)]">MIT License</span>
                  </a>
                  <a
                    href="https://github.com/michellzappa/septena/issues"
                    target="_blank"
                    rel="noreferrer"
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    <Send className="h-4 w-4 text-[var(--text-muted)]" />
                    <span>Send feedback</span>
                    <ExternalLink className="ml-auto h-3.5 w-3.5 text-[var(--text-muted)]" />
                  </a>
                </section>

                <section className="space-y-2 rounded-xl border border-[var(--border-subtle)] p-4 text-xs">
                  <div className="flex items-center justify-between">
                    <span className="inline-flex items-center gap-1.5 font-semibold text-[var(--text-primary)]">
                      <Activity className="h-3.5 w-3.5 text-[var(--text-muted)]" />
                      Sync &amp; storage diagnostics
                    </span>
                    {notSynced.length > 0 && (
                      <button
                        type="button"
                        onClick={onClearNotSynced}
                        className="text-[11px] text-[var(--accent)] hover:underline"
                      >
                        Clear sync issues
                      </button>
                    )}
                  </div>
                  <p className="font-mono-tabular text-[11px] text-[var(--text-muted)]">
                    Tasks: {snapshot.tasks.length} · Areas: {snapshot.areas.length} · Projects:{" "}
                    {snapshot.projects.length} · Tags: {snapshot.tags.length} · Checklists:{" "}
                    {snapshot.checklistItems.length} · Outbox: {snapshot.outbox.length}
                  </p>
                  {notSynced.length === 0 ? (
                    <p className="text-[11px] text-[var(--text-muted)]">No sync issues.</p>
                  ) : (
                    <div className="max-h-32 space-y-1 overflow-y-auto pt-1">
                      {notSynced.map((item) => (
                        <div
                          key={item.clientOpId}
                          className="font-mono-tabular rounded bg-[var(--overdue-red)]/10 px-2 py-1 text-[11px] text-[var(--overdue-red)]"
                        >
                          {item.entity} ({item.id}): {item.reason}
                        </div>
                      ))}
                    </div>
                  )}
                </section>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
