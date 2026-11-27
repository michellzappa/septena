"use client";

import { useCallback, useEffect, useRef, useState, type ComponentType } from "react";
import {
  Activity,
  ArrowDown,
  ArrowUp,
  ArrowUpDown,
  Bell,
  BookOpen,
  Bot,
  Calendar,
  Check,
  ChevronLeft,
  ChevronRight,
  CircleHelp,
  CirclePlus,
  Code,
  Copy,
  Cpu,
  Download,
  ExternalLink,
  Eye,
  EyeOff,
  Globe,
  Info,
  KeyRound,
  Keyboard,
  Link2,
  LogOut,
  MonitorSmartphone,
  Palette,
  Pencil,
  RefreshCw,
  RotateCcw,
  Send,
  Shield,
  SlidersHorizontal,
  Sun,
  Trash2,
  Upload,
  UserCircle,
  Users,
  Wrench,
  X,
} from "lucide-react";
import {
  DESIGN_TOKENS,
  FIRST_RUN,
  HELP_URL,
  ICONS,
  PLAN_UI,
  REGISTRY_LANGUAGES,
  SETTINGS_REGISTRY,
  SURFACES_CATALOG,
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
import { accountPlan, currentTier, statusLine, tierCard, tiersAbove, type PlanTier } from "@/lib/plans";
import type { WebSyncEngine } from "@/lib/sync/engine";
import type {
  AccessSummary,
  Entitlement,
  IcalFeedSettings,
  NotSyncedItem,
  SmartDestination,
  StoreSnapshot,
} from "@/lib/types";
import { HeaderWashPreview } from "./HeaderWash";
import { PlanBenefitRow, PlanHead, PlanMark, PlanPriceLine, PlanSheet } from "./PlanLanguage";
import { SignInMethodsSection } from "./SignInMethodsSection";

export type SettingsTab = (typeof SETTINGS_REGISTRY.desktopTabs)[number]["id"];

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
  /** Opens Contact Support (ADR 0054). */
  onOpenSupport: () => void;
  /** Unread support replies: a dot on the Contact Support row. */
  supportUnread: number;
  /** The tab to show when the modal opens. Without it, the last tab stays. */
  initialTab?: SettingsTab;
}

interface RegistryItem {
  kind: "pageLink" | "setting" | "customSurface";
  key?: string;
  page?: string;
  surface?: string;
  label?: string;
  detail?: string;
  icon?: string;
  statusKey?: string;
  visibility?: string;
  platforms?: readonly string[];
  featureId?: string;
}

interface RegistrySection {
  id: string;
  header?: string;
  footer?: string;
  platforms?: readonly string[];
  items: readonly RegistryItem[];
}

interface RegistryPage {
  id: string;
  title: string;
  icon: string;
  depth: number;
  platforms?: readonly string[];
  featureId: string;
  sections: readonly RegistrySection[];
}

interface RegistryRootGroup {
  id: string;
  header?: string;
  mobilePresentation: string;
  desktopTab: string | null;
  items: readonly RegistryItem[];
}

const DESKTOP_TABS = SETTINGS_REGISTRY.desktopTabs;
const ROOT_GROUPS = SETTINGS_REGISTRY.rootGroups as readonly RegistryRootGroup[];
const PAGES = SETTINGS_REGISTRY.pages as readonly RegistryPage[];
const PAGE_BY_ID = new Map<string, RegistryPage>(PAGES.map((p) => [p.id, p]));
const TAB_BY_ID = new Map<string, (typeof DESKTOP_TABS)[number]>(DESKTOP_TABS.map((t) => [t.id, t]));
const TAB_DIRECT_PAGES = new Set<string>(["account", "appearance", "privacy", "about"]);

const NEW_KEY_PROMPT = SURFACES_CATALOG.prompts.text.find((p) => p.id === "newAgentKey");
const KEY_CREATED_PROMPT = SURFACES_CATALOG.prompts.items.find((p) => p.id === "agentKeyCreated");
const SUPPORT_UNREAD_LABEL =
  SURFACES_CATALOG.support.copy.find((c) => c.id === "unreadReply")?.label ?? SURFACES_CATALOG.support.title;
const CUSTOMIZABLE_SMART_LISTS: SmartDestination[] = SIDEBAR_DESTINATIONS.map((d) => d.id);
const CONNECTOR_URL = "https://api.septena.app/mcp";

const LUCIDE_BY_NAME: Record<string, ComponentType<{ className?: string }>> = {
  "user-circle": UserCircle,
  "sliders-horizontal": SlidersHorizontal,
  palette: Palette,
  cpu: Cpu,
  link: Link2,
  shield: Shield,
  info: Info,
  "monitor-smartphone": MonitorSmartphone,
  "key-round": KeyRound,
  users: Users,
  bot: Bot,
  "book-open": BookOpen,
  calendar: Calendar,
  sun: Sun,
  bell: Bell,
  globe: Globe,
  keyboard: Keyboard,
  "arrow-up-down": ArrowUpDown,
  "circle-plus": CirclePlus,
  "circle-help": CircleHelp,
  code: Code,
  send: Send,
  wrench: Wrench,
  activity: Activity,
};

function iconFor(iconId?: string): ComponentType<{ className?: string }> {
  if (!iconId) return Info;
  const lucide = (ICONS as Record<string, { lucide?: string }>)[iconId]?.lucide;
  return (lucide && LUCIDE_BY_NAME[lucide]) || Info;
}

function appliesToWeb(platforms?: readonly string[]): boolean {
  return !platforms || platforms.length === 0 || platforms.includes("web");
}

function settingsCopy(
  owner: keyof typeof SETTINGS_REGISTRY.copy,
  id: string,
  lang: string,
  replacements?: Record<string, string>,
): string {
  const list = SETTINGS_REGISTRY.copy[owner] as ReadonlyArray<{ id: string; label: string }>;
  const raw = list.find((e) => e.id === id)?.label ?? id;
  let text = registryText(raw, lang);
  if (replacements) {
    for (const [k, v] of Object.entries(replacements)) {
      text = text.replace(`{${k}}`, v);
    }
  }
  return text;
}

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
    <label className="flex cursor-pointer items-center justify-between gap-3 py-2.5">
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
  onOpenSupport,
  supportUnread,
  initialTab,
}: SettingsModalProps) {
  const [tab, setTab] = useState<SettingsTab>("general");
  const [pageStack, setPageStack] = useState<string[]>([]);
  const [access, setAccess] = useState<AccessSummary | null>(null);
  const [accessError, setAccessError] = useState<string | null>(null);
  const [entitlement, setEntitlement] = useState<Entitlement | null>(null);
  const [planSheet, setPlanSheet] = useState<{ upsellId: string | null; tier: PlanTier | null } | null>(null);
  const [pairCode, setPairCode] = useState("");
  const [pairPreview, setPairPreview] = useState<{ kind: "connector" | "device"; client: string } | null>(null);
  const [pairStatus, setPairStatus] = useState<string | null>(null);
  const [renamingAgentId, setRenamingAgentId] = useState<string | null>(null);
  const [keyNameDraft, setKeyNameDraft] = useState<string | null>(null);
  const [createdKey, setCreatedKey] = useState<string | null>(null);
  const [keyError, setKeyError] = useState<string | null>(null);
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

  const [importPreview, setImportPreview] = useState<ParsedBackupPreview | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [importStatus, setImportStatus] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [notifPerm, setNotifPerm] = useState<NotificationPermission | "unsupported">(() => {
    if (typeof window === "undefined" || !("Notification" in window)) return "unsupported";
    return Notification.permission;
  });

  const selectTab = useCallback((next: SettingsTab) => {
    setTab(next);
    setPageStack([]);
    setPairCode("");
    setPairPreview(null);
    setPairStatus(null);
  }, []);

  const pushPage = useCallback((pageId: string) => {
    if (!PAGE_BY_ID.has(pageId)) return;
    setPageStack((prev) => [...prev, pageId]);
    setPairCode("");
    setPairPreview(null);
    setPairStatus(null);
  }, []);

  const popPage = useCallback(() => {
    setPageStack((prev) => prev.slice(0, -1));
  }, []);

  useEffect(() => {
    if (open && initialTab) {
      selectTab(initialTab);
    }
  }, [initialTab, open, selectTab]);

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

  const loadEntitlement = useCallback(async () => {
    try {
      setEntitlement(await api.getEntitlement());
    } catch {
      // Keep last known entitlement if offline.
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

  const activePageId = pageStack[pageStack.length - 1] ?? null;

  useEffect(() => {
    if (!open) return;
    void loadEntitlement();
    if (tab === "account" || tab === "ai_agents" || activePageId === "devices_access" || activePageId === "agents") {
      void loadAccess();
    }
    if (tab === "connections_data" || activePageId === "calendar") {
      void loadIcal();
    }
  }, [activePageId, loadAccess, loadEntitlement, loadIcal, open, tab]);

  if (!open) return null;

  const lang = prefs.language;
  const signedIn = Boolean(snapshot.userId);
  const welcomeName =
    typeof snapshot.settings.welcomeName === "string" ? snapshot.settings.welcomeName.trim() : "";
  const plan = accountPlan(entitlement, signedIn);
  const planCurrent = currentTier(plan);
  const planAbove = tiersAbove(plan);
  const planStatus = statusLine(plan);
  const planStatusText = planStatus ? registryText(planStatus.text, lang, planStatus.vars ?? {}) : null;
  const planBadge =
    planCurrent === "pro"
      ? registryText(PLAN_UI.proName, lang)
      : planCurrent === "plus"
        ? registryText(PLAN_UI.shortName, lang)
        : signedIn
          ? registryText(PLAN_UI.status.free, lang)
          : null;
  const isPro = planCurrent === "pro";
  const agentLimit = access?.agents?.limit ?? null;
  const agentsFull =
    access && agentLimit != null && (access.agents?.count ?? access.connections.length) >= agentLimit && planCurrent !== "pro"
      ? PLAN_UI.upsells.find((u) => u.id === (planCurrent === "plus" ? "agents_full_plus" : "agents_full")) ?? null
      : null;
  const currentAccent =
    typeof snapshot.settings.accentColor === "string" ? snapshot.settings.accentColor : "colorful";
  const currentTexture = (
    typeof snapshot.settings.canvasTexture === "string" ? snapshot.settings.canvasTexture : "none"
  ) as HeaderTextureStyle;
  const textureIntensity =
    typeof snapshot.settings.textureIntensity === "number" ? snapshot.settings.textureIntensity : 55;
  const textureMotion = snapshot.settings.textureMotion === "slowDrift" ? "slowDrift" : "still";
  const agentsPaused = Boolean(snapshot.settings.agentsPaused);

  // Synced smart list sidebar customization.
  const rawOrder = Array.isArray(snapshot.settings.smartListOrder)
    ? (snapshot.settings.smartListOrder as string[])
    : [];
  const hiddenSet = new Set<string>(
    Array.isArray(snapshot.settings.smartListHidden) ? (snapshot.settings.smartListHidden as string[]) : [],
  );
  const placementMap =
    snapshot.settings.smartListPlacement && typeof snapshot.settings.smartListPlacement === "object"
      ? (snapshot.settings.smartListPlacement as Record<string, "top" | "bottom">)
      : {};

  const orderedSmartListIds: SmartDestination[] = [
    ...rawOrder.filter((id): id is SmartDestination => CUSTOMIZABLE_SMART_LISTS.includes(id as SmartDestination)),
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
      setPairStatus(err instanceof Error ? err.message : settingsCopy("sign_in_approval", "invalidCode", lang));
    }
  };

  const handleApproveCode = async () => {
    if (!pairPreview) return;
    try {
      await api.approvePairingCode(pairCode.trim(), pairPreview.kind);
      setPairStatus(
        pairPreview.kind === "connector"
          ? settingsCopy("sign_in_approval", "doneConnector", lang)
          : settingsCopy("sign_in_approval", "doneDevice", lang, { client: pairPreview.client }),
      );
      setPairPreview(null);
      setPairCode("");
      void loadAccess();
    } catch (err) {
      setPairStatus(err instanceof Error ? err.message : "Approval failed");
    }
  };

  const handleIcalUpdate = async (body: { enabled?: boolean; scope?: "all" | "timed"; rotate?: boolean }) => {
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
      setImportError(err instanceof Error ? err.message : settingsCopy("import_export", "importFailed", lang));
    }
  };

  const handleConfirmImport = async () => {
    if (!importPreview || importing) return;
    setImporting(true);
    setImportError(null);
    try {
      const imported = await engine.importBackup(importPreview);
      setImportStatus(settingsCopy("import_export", "importedCount", lang, { count: String(imported) }));
      setImportPreview(null);
    } catch (err) {
      setImportError(err instanceof Error ? err.message : settingsCopy("import_export", "importFailed", lang));
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
        setSkillText(settingsCopy("mcp_skills", "loadFailed", lang));
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
      setDeleteError(err instanceof Error ? err.message : settingsCopy("delete_account", "failed", lang));
    } finally {
      setDeletingAccount(false);
    }
  };

  const isItemVisible = (item: RegistryItem): boolean => {
    if (!appliesToWeb(item.platforms)) return false;
    if (item.visibility === "signedIn") return signedIn;
    if (item.visibility === "signedOut") return !signedIn;
    if (item.visibility === "debugOnly" || item.visibility === "minAppleOS27") return false;
    return true;
  };

  const statusText = (statusKey?: string): string | null => {
    if (!statusKey) return null;
    switch (statusKey) {
      case "planStatus":
        return planStatusText;
      case "agentsStatus": {
        const paused = settingsCopy("access_agents", "paused", lang);
        const count = access ? `${access.connections.length}` : null;
        if (agentsPaused) return count ? `${count} · ${paused}` : paused;
        return count;
      }
      case "claudeStatus":
        return access && access.connections.length > 0 ? registryText("Connected", lang) : registryText("Set up", lang);
      case "aiMode": {
        const opts = SETTINGS_REGISTRY.keys.aiMode.options;
        const match = opts.find((o) => o.value === prefs.aiMode);
        return match ? registryText(match.title, lang) : null;
      }
      case "calendarStatus":
        if (!ical) return null;
        return ical.enabled ? registryText("On", lang) : registryText("Off", lang);
      default:
        return null;
    }
  };

  // Profile card alert: only show sync state if this device is not syncing.
  const profileSyncAlert =
    signedIn && entitlement?.device && entitlement.device.syncing === false
      ? registryText(PLAN_UI.status.device, lang)
      : null;

  const renderApproveCodeBox = (placeholder: string, footer: string) => (
    <div className="space-y-2.5">
      <form onSubmit={(e) => void handleInspectCode(e)} className="flex gap-2">
        <input
          type="text"
          value={pairCode}
          onChange={(e) => setPairCode(e.target.value)}
          placeholder={placeholder}
          className="font-mono-tabular min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
        />
        <button
          type="submit"
          disabled={!pairCode.trim()}
          className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium hover:opacity-90 disabled:opacity-40"
          style={{ color: "var(--accent-check)" }}
        >
          {settingsCopy("sign_in_approval", "continue", lang)}
        </button>
      </form>
      {pairPreview && (
        <div className="flex items-center justify-between gap-2 rounded-lg bg-[var(--bg-hover)] p-2.5 text-xs">
          <span>
            {pairPreview.kind === "connector"
              ? settingsCopy("sign_in_approval", "confirmConnector", lang, { client: pairPreview.client })
              : settingsCopy("sign_in_approval", "confirmDevice", lang, { client: pairPreview.client })}
          </span>
          <div className="flex items-center gap-1.5">
            <button
              type="button"
              onClick={() => setPairPreview(null)}
              className="rounded-md px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-elevated)]"
            >
              {settingsCopy("sign_in_approval", "dontApprove", lang)}
            </button>
            <button
              type="button"
              onClick={() => void handleApproveCode()}
              className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium"
              style={{ color: "var(--accent-check)" }}
            >
              {settingsCopy("sign_in_approval", "approve", lang)}
            </button>
          </div>
        </div>
      )}
      {pairStatus && <p className="text-xs text-[var(--text-secondary)]">{pairStatus}</p>}
      <p className="text-[11px] text-[var(--text-muted)]">{footer}</p>
    </div>
  );

  const renderSettingItem = (item: RegistryItem) => {
    const key = item.key;
    if (!key) return null;
    const label = registryText(item.label ?? key, lang);
    const detail = item.detail ? registryText(item.detail, lang) : undefined;
    switch (key) {
      case "todayGroupByList":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={prefs.todayGroupByList}
            onChange={(v) => onChangePref("todayGroupByList", v)}
          />
        );
      case "todayShowCompleted":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={prefs.todayShowCompleted}
            onChange={(v) => onChangePref("todayShowCompleted", v)}
          />
        );
      case "tasksShowAging":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={fadeSettings(snapshot.settings).enabled}
            onChange={(v) => void engine.setSetting("tasksShowAging", v)}
          />
        );
      case "tasksShowFaded":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={prefs.tasksShowFaded}
            onChange={(v) => onChangePref("tasksShowFaded", v)}
          />
        );
      case "sidebarCounts":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={prefs.sidebarCounts}
            onChange={(v) => onChangePref("sidebarCounts", v)}
          />
        );
      case "loggingAnimationsEnabled":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={prefs.loggingAnimationsEnabled}
            onChange={(v) => onChangePref("loggingAnimationsEnabled", v)}
          />
        );
      case "agentsPaused":
        return (
          <ToggleRow
            label={label}
            detail={detail}
            checked={agentsPaused}
            onChange={(v) => void engine.setSetting("agentsPaused", v)}
          />
        );
      case "textSizeStep":
        return (
          <div className="py-2.5">
            <p className="mb-2 text-xs font-medium text-[var(--text-primary)]">{label}</p>
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
                  {registryText(s.label, lang)}
                </button>
              ))}
            </div>
          </div>
        );
      case "aiMode": {
        const opts = SETTINGS_REGISTRY.keys.aiMode.options;
        const desc =
          prefs.aiMode === "onDeviceOnly"
            ? settingsCopy("aiMode", "onDeviceOnlyNoModel", lang)
            : prefs.aiMode === "auto"
              ? settingsCopy("aiMode", "autoNoModel", lang)
              : settingsCopy("aiMode", "useMyClaude", lang, { app: "Septena" });
        return (
          <div className="space-y-2.5 py-2">
            <div className="grid grid-cols-3 gap-2">
              {opts.map((opt) => (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => onChangePref("aiMode", opt.value as WebDisplayPrefs["aiMode"])}
                  className={`rounded-lg border px-2.5 py-2 text-xs font-medium transition-colors ${
                    prefs.aiMode === opt.value
                      ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                  }`}
                >
                  {registryText(opt.title, lang)}
                </button>
              ))}
            </div>
            <p className="text-[11px] text-[var(--text-muted)]">{desc}</p>
          </div>
        );
      }
      default:
        return null;
    }
  };

  const renderSurface = (item: RegistryItem) => {
    const surface = item.surface;
    if (!surface) return null;
    switch (surface) {
      case "account_profile_editor":
        return (
          <div className="py-2">
            <label className="block text-xs font-medium text-[var(--text-primary)]">
              {registryText(item.label ?? "Your name", lang)}
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
              placeholder={registryText(item.label ?? "Your name", lang)}
              className="mt-1.5 w-full rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-sm text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </div>
        );

      case "sync_account_status":
        return (
          <div className="space-y-3 py-2">
            {snapshot.userId && (
              <div>
                <div className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-xs font-medium text-[var(--text-primary)]">
                      {settingsCopy("sync_account_status", "accountIdLabel", lang)}
                    </p>
                    <p className="font-mono-tabular mt-0.5 truncate text-xs text-[var(--text-secondary)]">
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
                        <span>{settingsCopy("sync_account_status", "copied", lang)}</span>
                      </>
                    ) : (
                      <>
                        <Copy className="h-3.5 w-3.5" />
                        <span>{settingsCopy("sync_account_status", "copy", lang)}</span>
                      </>
                    )}
                  </button>
                </div>
                <p className="mt-1 text-[11px] text-[var(--text-muted)]">
                  {settingsCopy("sync_account_status", "accountIdFooter", lang)}
                </p>
              </div>
            )}
            <div className="border-t border-[var(--border-subtle)] pt-2.5">
              <button
                type="button"
                onClick={() => {
                  onClose();
                  onSignOut();
                }}
                className="inline-flex items-center gap-2 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
              >
                <LogOut className="h-3.5 w-3.5" />
                Sign out and clear local browser data
              </button>
            </div>
          </div>
        );

      case "delete_account":
        return (
          <div className="space-y-3 py-2">
            <button
              type="button"
              onClick={() => setDeleteDialogOpen(true)}
              className="inline-flex items-center gap-2 rounded-lg border border-[var(--overdue-red)]/35 px-3 py-1.5 text-xs font-medium text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
            >
              <Trash2 className="h-3.5 w-3.5" />
              {settingsCopy("delete_account", "button", lang)}
            </button>
            <p className="text-[11px] text-[var(--text-muted)]">
              {settingsCopy("delete_account", "footer", lang)}
            </p>
            {deleteDialogOpen && (
              <div className="space-y-2.5 rounded-xl border border-[var(--overdue-red)]/40 bg-[var(--overdue-red)]/5 p-3.5 text-xs">
                <p className="font-semibold text-[var(--text-primary)]">
                  {settingsCopy("delete_account", "title", lang)}
                </p>
                <p className="text-[var(--text-secondary)]">
                  {settingsCopy("delete_account", "intro", lang)}
                </p>
                <ul className="list-disc space-y-0.5 pl-4 text-[var(--text-secondary)]">
                  <li>{settingsCopy("delete_account", "tasks", lang)}</li>
                  <li>{settingsCopy("delete_account", "attachments", lang)}</li>
                  <li>{settingsCopy("delete_account", "conversations", lang)}</li>
                  <li>{settingsCopy("delete_account", "settings", lang)}</li>
                </ul>
                <p className="text-[var(--text-secondary)]">
                  {settingsCopy("delete_account", "consequence", lang)}
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
                    {registryText(SURFACES_CATALOG.prompts.cancelTitle, lang)}
                  </button>
                  <button
                    type="button"
                    disabled={deleteConfirmText.trim().toUpperCase() !== "DELETE" || deletingAccount}
                    onClick={() => void handleDeleteAccount()}
                    className="rounded-lg bg-[var(--overdue-red)] px-3 py-1.5 font-medium text-white disabled:opacity-40"
                  >
                    {deletingAccount ? "Deleting…" : settingsCopy("delete_account", "button", lang)}
                  </button>
                </div>
                {deleteError && <p className="text-[var(--overdue-red)]">{deleteError}</p>}
              </div>
            )}
          </div>
        );

      case "access_devices":
        return (
          <div className="space-y-1.5 py-2">
            {accessError && <p className="text-xs text-[var(--overdue-red)]">{accessError}</p>}
            {(access?.devices ?? []).map((dev) => (
              <div
                key={dev.sid}
                className="flex items-center justify-between rounded-lg border border-[var(--border-subtle)] px-3 py-2 text-xs"
              >
                <div>
                  <p className="font-medium text-[var(--text-primary)]">
                    {dev.client || settingsCopy("access_devices", "deviceUnknown", lang)}
                    {dev.current && (
                      <span className="ml-2 rounded bg-[var(--bg-selected)] px-1.5 py-0.5 text-[10px]">
                        {settingsCopy("access_devices", "currentDevice", lang)}
                      </span>
                    )}
                  </p>
                  {dev.lastUsedAt && (
                    <p className="text-[11px] text-[var(--text-muted)]">
                      {settingsCopy(
                        "access_devices",
                        dev.syncing === false ? "activeNotSyncing" : "active",
                        lang,
                        { time: new Date(dev.lastUsedAt).toLocaleDateString() },
                      )}
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
        );

      case "sign_in_approval":
        return (
          <div className="py-2">
            <p className="mb-2 text-xs font-medium text-[var(--text-primary)]">
              {settingsCopy("sign_in_approval", "title", lang)}
            </p>
            {renderApproveCodeBox(
              settingsCopy("sign_in_approval", "codePlaceholder", lang),
              settingsCopy("sign_in_approval", "footer", lang),
            )}
          </div>
        );

      case "plus_offer":
        return (
          <div className="space-y-4 py-2 text-xs">
            {planCurrent ? (
              <PlanHead
                tier={planCurrent}
                lang={lang}
                line={
                  planStatusText ?? registryText(tierCard(planCurrent)?.detail ?? "", lang)
                }
              />
            ) : (
              <div>
                <p className="text-base font-bold text-[var(--text-primary)]">{registryText(PLAN_UI.headline, lang)}</p>
                <p className="mt-1 text-[13px] text-[var(--text-secondary)]">{registryText(PLAN_UI.subhead, lang)}</p>
                {planStatusText ? (
                  <p className="mt-2 text-xs text-[var(--text-muted)]">{planStatusText}</p>
                ) : null}
              </div>
            )}
            {planCurrent ? (
              <div className="space-y-3">
                <p className="text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  {registryText(PLAN_UI.paywall.yourPlanIncludes, lang)}
                </p>
                {(planCurrent === "pro" ? PLAN_UI.benefits.pro : PLAN_UI.benefits.plus).map((b) => (
                  <PlanBenefitRow key={b.id} benefit={b} lang={lang} />
                ))}
              </div>
            ) : null}
            {planAbove.map((t) => (
              <div key={t} className="space-y-3 border-t border-[var(--border-subtle)] pt-4">
                <PlanHead tier={t} lang={lang} markSize={40} line={registryText(tierCard(t)?.detail ?? "", lang)} />
                {(t === "pro" ? PLAN_UI.benefits.pro : PLAN_UI.benefits.plus).map((b) => (
                  <PlanBenefitRow key={b.id} benefit={b} lang={lang} />
                ))}
                <PlanPriceLine tier={t} lang={lang} />
                <button
                  type="button"
                  onClick={() => setPlanSheet({ upsellId: null, tier: t })}
                  className="rounded-lg px-3 py-1.5 text-sm font-semibold"
                  style={{ background: "var(--brand)", color: "var(--brand-ink)" }}
                >
                  {registryText(t === "pro" ? PLAN_UI.paywall.seePro : PLAN_UI.paywall.seePlus, lang)}
                </button>
              </div>
            ))}
            {planAbove.length > 0 ? (
              <p className="text-[11px] text-[var(--text-muted)]">
                {registryText(PLAN_UI.checkout.open ? PLAN_UI.priceFootnote : PLAN_UI.checkout.notice, lang)}
              </p>
            ) : null}
            <a
              href={PLAN_UI.compareURL}
              target="_blank"
              rel="noreferrer"
              className="inline-block text-xs text-[var(--accent)] hover:underline"
            >
              {registryText(PLAN_UI.paywall.compareAll, lang)}
            </a>
          </div>
        );

      case "smart_lists_editor":
        return (
          <div className="space-y-4 py-2 text-xs">
            {(["top", "bottom"] as const).map((sec) => {
              const ids = orderedSmartListIds.filter((id) => sectionFor(id) === sec);
              return (
                <div key={sec}>
                  <p className="mb-1.5 text-[11px] font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                    {settingsCopy("smart_lists_editor", sec === "top" ? "topHeader" : "bottomHeader", lang)}
                  </p>
                  {ids.length === 0 ? (
                    <p className="py-1 text-[var(--text-muted)]">
                      {settingsCopy("smart_lists_editor", "empty", lang)}
                    </p>
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
                              {settingsCopy(
                                "smart_lists_editor",
                                reg?.visibility === "whenNonEmpty" ? "whenNonEmpty" : "alwaysShown",
                                lang,
                              )}
                            </span>
                            <button
                              type="button"
                              disabled={idx === 0}
                              onClick={() => void moveSmartListOrder(id, -1)}
                              className="rounded p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] disabled:opacity-30"
                              title={settingsCopy("smart_lists_editor", "moveUp", lang)}
                            >
                              <ArrowUp className="h-3.5 w-3.5" />
                            </button>
                            <button
                              type="button"
                              disabled={idx === ids.length - 1}
                              onClick={() => void moveSmartListOrder(id, 1)}
                              className="rounded p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] disabled:opacity-30"
                              title={settingsCopy("smart_lists_editor", "moveDown", lang)}
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
                                    title={settingsCopy(
                                      "smart_lists_editor",
                                      sec === "top" ? "moveBelow" : "moveAbove",
                                      lang,
                                    )}
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
                {settingsCopy("smart_lists_editor", "bottomFooterButtons", lang)}
              </span>
              <button
                type="button"
                onClick={() => void resetSmartLists()}
                className="inline-flex shrink-0 items-center gap-1 rounded px-2 py-1 text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
              >
                <RotateCcw className="h-3 w-3" />
                {settingsCopy("smart_lists_editor", "reset", lang)}
              </button>
            </div>
          </div>
        );

      case "browser_notifications":
        return (
          <div className="flex items-center justify-between gap-3 py-2 text-xs">
            <div className="flex items-center gap-2.5">
              <Bell className="h-4 w-4 text-[var(--accent)]" />
              <div>
                <p className="font-medium text-[var(--text-primary)]">
                  {registryText(item.label ?? "Timed reminders", lang)}
                </p>
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
          </div>
        );

      case "web_language":
        return (
          <div className="flex flex-wrap gap-1.5 py-2">
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
        );

      case "accent_color":
        return (
          <div className="space-y-5 py-2">
            <div>
              <p className="mb-2 text-xs font-medium text-[var(--text-primary)]">
                {registryText("Appearance", lang)}
              </p>
              <div className="grid grid-cols-3 gap-2">
                {SETTINGS_REGISTRY.keys.appearanceMode.options.map((m) => (
                  <button
                    key={m.value}
                    type="button"
                    onClick={() => onChangePref("appearanceMode", m.value as WebDisplayPrefs["appearanceMode"])}
                    className={`rounded-lg border px-3 py-2 text-xs font-medium transition-colors ${
                      prefs.appearanceMode === m.value
                        ? "border-[var(--accent)] bg-[var(--bg-selected)] text-[var(--text-primary)]"
                        : "border-[var(--border-subtle)] text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                    }`}
                  >
                    {registryText(m.title, lang)}
                  </button>
                ))}
              </div>
            </div>

            <div>
              <p className="mb-2 text-xs font-medium text-[var(--text-primary)]">
                {registryText(item.label ?? "Accent", lang)}
              </p>
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
            </div>

            <div>
              <p className="mb-2 text-xs font-medium text-[var(--text-primary)]">
                {registryText("Header Texture", lang)}
              </p>
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
                      onChange={(e) => void engine.setSetting("textureIntensity", Number(e.target.value))}
                      className="w-40 accent-[var(--accent)]"
                    />
                    <span className="font-mono-tabular w-9 text-right text-[var(--text-muted)]">
                      {textureIntensity}%
                    </span>
                  </div>
                  <ToggleRow
                    label={registryText("Slow drift", lang)}
                    detail="Refreshes daily · pauses under Reduce Motion."
                    checked={textureMotion === "slowDrift"}
                    onChange={(v) => void engine.setSetting("textureMotion", v ? "slowDrift" : "still")}
                  />
                </div>
              )}
            </div>
          </div>
        );

      case "access_agents":
        return (
          <div className="space-y-2 py-2 text-xs">
            {agentsFull ? (
              <div className="flex items-start gap-3 rounded-xl border border-[var(--border-subtle)] p-3">
                <PlanMark tier={agentsFull.plan === "pro" ? "pro" : "plus"} size={30} />
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold text-[var(--text-primary)]">{registryText(agentsFull.title, lang)}</p>
                  <p className="text-[12px] text-[var(--text-secondary)]">{registryText(agentsFull.detail, lang)}</p>
                  <button
                    type="button"
                    onClick={() => setPlanSheet({ upsellId: agentsFull.id, tier: null })}
                    className="mt-1.5 text-xs font-semibold text-[var(--accent)] hover:underline"
                  >
                    {registryText(agentsFull.plan === "pro" ? PLAN_UI.paywall.seePro : PLAN_UI.paywall.seePlus, lang)}
                  </button>
                </div>
              </div>
            ) : null}
            {!access || access.connections.length === 0 ? (
              <p className="text-[var(--text-muted)]">No agents connected.</p>
            ) : (
              <div className="space-y-1.5">
                {access.connections.map((conn) => {
                  const displayName = conn.name || conn.clientName || conn.clientId || "Agent";
                  const isRenaming = renamingAgentId === conn.id;
                  return (
                    <div
                      key={conn.id}
                      className="flex items-center justify-between gap-2 rounded-lg border border-[var(--border-subtle)] px-3 py-2"
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
                            {registryText(SURFACES_CATALOG.prompts.cancelTitle, lang)}
                          </button>
                        </form>
                      ) : (
                        <>
                          <div>
                            <p className="font-medium text-[var(--text-primary)]">{displayName}</p>
                            <p className="text-[11px] text-[var(--text-muted)]">
                              {conn.lastUsedAt
                                ? settingsCopy("access_agents", "lastUsed", lang, {
                                    time: new Date(conn.lastUsedAt).toLocaleDateString(),
                                  })
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

            <div className="pt-1">
              {createdKey ? (
                <div className="space-y-2 rounded-lg border border-[var(--accent)] p-3">
                  <p className="font-medium text-[var(--text-primary)]">
                    {registryText(KEY_CREATED_PROMPT?.title ?? "", lang)}
                  </p>
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {registryText(KEY_CREATED_PROMPT?.message ?? "", lang)}
                  </p>
                  <code className="block break-all rounded bg-[var(--bg-hover)] px-2 py-1 font-mono text-[11px] select-all">
                    {createdKey}
                  </code>
                  <button
                    type="button"
                    onClick={async () => {
                      await navigator.clipboard.writeText(createdKey).catch(() => {});
                      setCreatedKey(null);
                    }}
                    className="rounded bg-[var(--accent)] px-2 py-0.5 font-medium"
                    style={{ color: "var(--accent-check)" }}
                  >
                    {registryText(KEY_CREATED_PROMPT?.confirmTitle ?? "", lang)}
                  </button>
                </div>
              ) : keyNameDraft !== null ? (
                <form
                  onSubmit={async (e) => {
                    e.preventDefault();
                    const name = keyNameDraft.trim();
                    if (!name) return;
                    try {
                      const created = await api.createAgentKey(name);
                      setKeyError(null);
                      setKeyNameDraft(null);
                      setCreatedKey(created.key);
                    } catch (err) {
                      setKeyError(err instanceof Error ? err.message : String(err));
                    }
                    void loadAccess();
                  }}
                  className="flex items-center gap-2 rounded-lg border border-[var(--border-subtle)] px-3 py-2"
                >
                  <input
                    type="text"
                    autoFocus
                    maxLength={40}
                    value={keyNameDraft}
                    onChange={(e) => setKeyNameDraft(e.target.value)}
                    placeholder={registryText(NEW_KEY_PROMPT?.placeholder ?? "", lang)}
                    className="min-w-0 flex-1 rounded border border-[var(--accent)] bg-transparent px-2 py-0.5 text-xs outline-none"
                  />
                  <button
                    type="submit"
                    disabled={!keyNameDraft.trim()}
                    className="rounded bg-[var(--accent)] px-2 py-0.5 font-medium disabled:opacity-50"
                    style={{ color: "var(--accent-check)" }}
                  >
                    {registryText(NEW_KEY_PROMPT?.confirmTitle ?? "", lang)}
                  </button>
                  <button
                    type="button"
                    onClick={() => setKeyNameDraft(null)}
                    className="rounded px-1.5 py-0.5 text-[var(--text-muted)]"
                  >
                    {registryText(SURFACES_CATALOG.prompts.cancelTitle, lang)}
                  </button>
                </form>
              ) : (
                <button
                  type="button"
                  onClick={() => setKeyNameDraft("")}
                  className="inline-flex items-center gap-1 rounded px-2 py-1 text-[var(--accent)] hover:bg-[var(--bg-hover)]"
                >
                  {registryText(NEW_KEY_PROMPT?.title ?? "", lang)}
                </button>
              )}
              {keyError && <p className="mt-1 text-[11px] text-[var(--overdue-red)]">{keyError}</p>}
            </div>
          </div>
        );

      case "claude_connector":
        return (
          <div className="space-y-4 py-2 text-xs">
            <div className="divide-y divide-[var(--border-subtle)]">
              <div className="flex items-center justify-between gap-3 py-2 first:pt-0">
                <div className="min-w-0">
                  <p className="font-medium text-[var(--text-primary)]">
                    {settingsCopy("claude_connector", "connectorUrl", lang)}
                  </p>
                  <p className="font-mono-tabular truncate text-[11px] text-[var(--text-muted)]">
                    {CONNECTOR_URL}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => void copyText("mcp_url", CONNECTOR_URL)}
                  className="inline-flex shrink-0 items-center gap-1 rounded-md border border-[var(--border-subtle)] px-2.5 py-1 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  {copiedId === "mcp_url" ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
                  {settingsCopy("claude_connector", copiedId === "mcp_url" ? "copied" : "copy", lang)}
                </button>
              </div>

              <div className="flex items-center justify-between gap-3 py-2">
                <div className="min-w-0">
                  <p className="font-medium text-[var(--text-primary)]">
                    {settingsCopy("claude_connector", "setupPrompt", lang)}
                  </p>
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {settingsCopy("claude_connector", "setupPromptDetail", lang)}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => void copyText("setup_prompt", FIRST_RUN.prompts.setup)}
                  className="inline-flex shrink-0 items-center gap-1 rounded-md border border-[var(--border-subtle)] px-2.5 py-1 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  {copiedId === "setup_prompt" ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
                  {settingsCopy("claude_connector", copiedId === "setup_prompt" ? "copied" : "copy", lang)}
                </button>
              </div>

              <div className="flex items-center justify-between gap-3 py-2 last:pb-0">
                <div className="min-w-0">
                  <p className="font-medium text-[var(--text-primary)]">
                    {settingsCopy("claude_connector", "firstPrompt", lang)}
                  </p>
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {settingsCopy("claude_connector", "firstPromptDetail", lang)}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => void copyText("first_prompt", FIRST_RUN.prompts.first)}
                  className="inline-flex shrink-0 items-center gap-1 rounded-md border border-[var(--border-subtle)] px-2.5 py-1 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  {copiedId === "first_prompt" ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
                  {settingsCopy("claude_connector", copiedId === "first_prompt" ? "copied" : "copy", lang)}
                </button>
              </div>
            </div>

            <div className="border-t border-[var(--border-subtle)] pt-3">
              <p className="mb-2 font-medium text-[var(--text-primary)]">
                {settingsCopy("claude_connector", "approveHeader", lang)}
              </p>
              {renderApproveCodeBox(
                settingsCopy("claude_connector", "codePlaceholder", lang),
                settingsCopy("claude_connector", "footer", lang),
              )}
            </div>
          </div>
        );

      case "mcp_skills":
        return (
          <div className="space-y-2 py-2 text-xs">
            <button
              type="button"
              onClick={() => void handleToggleSkillBrief()}
              className="flex w-full items-center justify-between text-left font-medium text-[var(--text-primary)]"
            >
              <span className="inline-flex items-center gap-2">
                <BookOpen className="h-4 w-4 text-[var(--text-muted)]" />
                {registryText(item.label ?? "MCP Skills", lang)}
              </span>
              <span className="text-[var(--text-muted)]">{showSkill ? "Hide" : "Show"}</span>
            </button>
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
                      {copiedId === "skill_md"
                        ? settingsCopy("claude_connector", "copied", lang)
                        : settingsCopy("mcp_skills", "copySkill", lang)}
                    </button>
                  )}
                </div>
                <pre className="max-h-48 overflow-auto whitespace-pre-wrap text-[11px] text-[var(--text-secondary)]">
                  {skillText ?? "Loading…"}
                </pre>
              </div>
            )}
          </div>
        );

      case "ai_explainer":
        return (
          <div className="space-y-2 py-2 text-xs">
            <button
              type="button"
              onClick={() => setShowAiExplainer((v) => !v)}
              className="flex w-full items-center justify-between text-left font-medium text-[var(--accent)] hover:underline"
            >
              <span>{registryText(item.label ?? "How AI helps with your tasks", lang)}</span>
              <span>{showAiExplainer ? "Hide" : "Read"}</span>
            </button>
            {showAiExplainer && (
              <div className="space-y-2 rounded-lg bg-[var(--bg-sidebar)] p-3 text-[11px] text-[var(--text-secondary)]">
                <p className="font-medium text-[var(--text-primary)]">
                  {settingsCopy("ai_explainer", "intro", lang)}
                </p>
                <p>{settingsCopy("ai_explainer", "privateBody", lang, { app: "Septena" })}</p>
                <p>{settingsCopy("ai_explainer", "closing", lang)}</p>
              </div>
            )}
          </div>
        );

      case "calendar_detail":
        return (
          <div className="space-y-3 py-2 text-xs">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Calendar className="h-4 w-4 text-[var(--accent)]" />
                <div>
                  <p className="font-semibold text-[var(--text-primary)]">
                    {settingsCopy("calendar_detail", "feedHeader", lang)}
                  </p>
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {settingsCopy("calendar_detail", "feedToggle", lang)}
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
                  <span className="text-[var(--text-muted)]">
                    {settingsCopy("calendar_detail", "include", lang)}:
                  </span>
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
                      {settingsCopy("calendar_detail", scope === "all" ? "scopeAll" : "scopeTimed", lang)}
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
                    {copiedId === "ical_url"
                      ? settingsCopy("claude_connector", "copied", lang)
                      : settingsCopy("calendar_detail", "copyUrl", lang)}
                  </button>
                  {ical.webcalUrl && (
                    <a
                      href={ical.webcalUrl}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      <ExternalLink className="h-3.5 w-3.5" />
                      {settingsCopy("calendar_detail", "openInCalendar", lang)}
                    </a>
                  )}
                  <button
                    type="button"
                    onClick={() => setConfirmRotateIcal(true)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                  >
                    <RefreshCw className="h-3.5 w-3.5" />
                    {settingsCopy("calendar_detail", "rotate", lang)}
                  </button>
                </div>

                {confirmRotateIcal && (
                  <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 p-3">
                    <p className="font-medium text-[var(--text-primary)]">
                      {settingsCopy("calendar_detail", "rotateTitle", lang)}
                    </p>
                    <p className="mt-0.5 text-[11px] text-[var(--text-secondary)]">
                      {settingsCopy("calendar_detail", "rotateMessage", lang)}
                    </p>
                    <div className="mt-2 flex gap-2">
                      <button
                        type="button"
                        onClick={() => setConfirmRotateIcal(false)}
                        className="rounded-md bg-[var(--bg-elevated)] px-2.5 py-1 font-medium"
                      >
                        {registryText(SURFACES_CATALOG.prompts.cancelTitle, lang)}
                      </button>
                      <button
                        type="button"
                        disabled={icalBusy}
                        onClick={() => void handleIcalUpdate({ enabled: true, rotate: true })}
                        className="rounded-md bg-amber-600 px-2.5 py-1 font-medium text-white"
                      >
                        {settingsCopy("calendar_detail", "rotate", lang)}
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}

            <p className="text-[11px] text-[var(--text-muted)]">
              {settingsCopy("calendar_detail", "feedFooter", lang)}
            </p>
          </div>
        );

      case "privacy_explainer":
        return (
          <p className="py-2 text-xs leading-relaxed text-[var(--text-secondary)]">
            {registryText(item.detail ?? "", lang)}
          </p>
        );

      case "import_export":
        return (
          <div className="space-y-4 py-2 text-xs">
            <div>
              <p className="mb-2 font-medium text-[var(--text-primary)]">Export</p>
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => exportAsJson(snapshot)}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  <Download className="h-3.5 w-3.5" />
                  {settingsCopy("import_export", "exportJsonTitle", lang)}
                </button>
                <button
                  type="button"
                  onClick={() => exportAsMarkdown(snapshot)}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  <Download className="h-3.5 w-3.5" />
                  {settingsCopy("import_export", "exportMarkdownTitle", lang)}
                </button>
                <button
                  type="button"
                  onClick={() => exportAsCsv(snapshot)}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--border-subtle)] px-3 py-2 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                >
                  <Download className="h-3.5 w-3.5" />
                  {settingsCopy("import_export", "exportCsvTitle", lang)}
                </button>
              </div>
            </div>

            <div className="space-y-3 border-t border-[var(--border-subtle)] pt-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="font-medium text-[var(--text-primary)]">
                    {settingsCopy("import_export", "importJsonTitle", lang)}
                  </p>
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {settingsCopy("import_export", "importJsonDetail", lang)}
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
                  <p className="font-semibold text-[var(--text-primary)]">
                    {settingsCopy("import_export", "importDialogTitle", lang)}
                  </p>
                  <p className="text-[var(--text-secondary)]">
                    {settingsCopy("import_export", "importSummary", lang, {
                      areas: String(importPreview.areas.length),
                      projects: String(importPreview.projects.length),
                      tasks: String(importPreview.tasks.length),
                    })}
                  </p>
                  {importPreview.skippedNonTaskCount > 0 && (
                    <p className="text-[var(--text-muted)]">
                      {settingsCopy("import_export", "importSkipped", lang, {
                        count: String(importPreview.skippedNonTaskCount),
                      })}
                    </p>
                  )}
                  <p className="text-[11px] text-[var(--text-muted)]">
                    {settingsCopy("import_export", "importNote", lang)}
                  </p>
                  <div className="flex items-center gap-2 pt-1">
                    <button
                      type="button"
                      onClick={() => setImportPreview(null)}
                      className="rounded-lg bg-[var(--bg-elevated)] px-3 py-1.5 font-medium text-[var(--text-secondary)]"
                    >
                      {registryText(SURFACES_CATALOG.prompts.cancelTitle, lang)}
                    </button>
                    <button
                      type="button"
                      disabled={importing}
                      onClick={() => void handleConfirmImport()}
                      className="rounded-lg bg-[var(--accent)] px-3.5 py-1.5 font-medium disabled:opacity-40"
                      style={{ color: "var(--accent-check)" }}
                    >
                      {importing ? "Importing…" : settingsCopy("import_export", "importConfirm", lang)}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
        );

      case "about_header":
        return (
          <div className="flex items-center gap-3.5 py-2">
            <img src="/icon.svg" alt="" className="h-11 w-11 rounded-xl" />
            <div>
              <p className="text-sm font-semibold text-[var(--text-primary)]">Septena</p>
              <p className="text-xs text-[var(--text-secondary)]">
                {registryText(item.label ?? "Tasks that think with you", lang)}
              </p>
              <p className="font-mono-tabular mt-0.5 text-[11px] text-[var(--text-muted)]">
                {registryText(item.detail ?? "Version {version}", lang).replace("{version}", coreVersion)}
              </p>
            </div>
          </div>
        );

      case "open_source":
        return (
          <a
            href="https://github.com/michellzappa/septena"
            target="_blank"
            rel="noreferrer"
            className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
          >
            <Code className="h-4 w-4 text-[var(--text-muted)]" />
            <span>{registryText(item.label ?? "Open source", lang)}</span>
            {item.detail && (
              <span className="ml-auto text-[11px] text-[var(--text-muted)]">{registryText(item.detail, lang)}</span>
            )}
            <ExternalLink className="h-3.5 w-3.5 text-[var(--text-muted)]" />
          </a>
        );

      case "open_help":
        return (
          <a
            href={HELP_URL}
            target="_blank"
            rel="noreferrer"
            className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
          >
            <CircleHelp className="h-4 w-4 text-[var(--text-muted)]" />
            <span>{registryText(item.label ?? "Help", lang)}</span>
            <ExternalLink className="ml-auto h-3.5 w-3.5 text-[var(--text-muted)]" />
          </a>
        );

      case "keyboard_shortcuts":
        return (
          <button
            type="button"
            onClick={() => {
              onClose();
              onOpenShortcuts();
            }}
            className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
          >
            <Keyboard className="h-4 w-4 text-[var(--text-muted)]" />
            <span>{registryText(item.label ?? "Keyboard Shortcuts", lang)}</span>
            <span className="font-mono-tabular ml-auto text-[11px] text-[var(--text-muted)]">⌘⇧/</span>
          </button>
        );

      case "reset_get_started":
        return (
          <button
            type="button"
            onClick={() => void engine.setSetting("getStartedDismissed", false)}
            className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
          >
            <RotateCcw className="h-4 w-4 text-[var(--text-muted)]" />
            <span>{registryText(item.label ?? "Show Get Started Again", lang)}</span>
          </button>
        );

      case "reset_first_run":
        return (
          <button
            type="button"
            onClick={() => {
              onClose();
              onShowWelcomeAgain();
            }}
            className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
          >
            <Info className="h-4 w-4 text-[var(--text-muted)]" />
            <span>{registryText(item.label ?? "Show Welcome Again", lang)}</span>
          </button>
        );

      case "contact_support":
        return (
          <button
            type="button"
            onClick={() => {
              onClose();
              onOpenSupport();
            }}
            className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
          >
            <Send className="h-4 w-4 text-[var(--text-muted)]" />
            <span>{registryText(item.label ?? SURFACES_CATALOG.support.title, lang)}</span>
            {supportUnread > 0 && (
              <span
                className="ml-auto h-2 w-2 rounded-full bg-[var(--accent)]"
                role="status"
                aria-label={registryText(SUPPORT_UNREAD_LABEL, lang)}
              />
            )}
          </button>
        );

      case "sync_diagnostics":
        return (
          <div className="space-y-2 py-2 text-xs">
            <div className="flex items-center justify-between">
              <span className="inline-flex items-center gap-1.5 font-medium text-[var(--text-primary)]">
                <Activity className="h-3.5 w-3.5 text-[var(--text-muted)]" />
                {registryText(item.label ?? "Sync & storage diagnostics", lang)}
              </span>
              {notSynced.length > 0 && (
                <button
                  type="button"
                  onClick={onClearNotSynced}
                  className="text-[11px] text-[var(--accent)] hover:underline"
                >
                  {settingsCopy("sync_diagnostics", "clear", lang)}
                </button>
              )}
            </div>
            <p className="font-mono-tabular text-[11px] text-[var(--text-muted)]">
              Core WASM v{coreVersion} · Revision {snapshot.cursor}
            </p>
            <p className="font-mono-tabular text-[11px] text-[var(--text-muted)]">
              Tasks: {snapshot.tasks.length} · Areas: {snapshot.areas.length} · Projects: {snapshot.projects.length} ·
              Tags: {snapshot.tags.length} · Checklists: {snapshot.checklistItems.length} · Outbox:{" "}
              {snapshot.outbox.length}
            </p>
            {notSynced.length === 0 ? (
              <p className="text-[11px] text-[var(--text-muted)]">No sync issues.</p>
            ) : (
              <div className="max-h-36 space-y-1 overflow-y-auto pt-1">
                {notSynced.map((entry) => (
                  <div
                    key={entry.clientOpId}
                    className="font-mono-tabular rounded bg-[var(--overdue-red)]/10 px-2 py-1 text-[11px] text-[var(--overdue-red)]"
                  >
                    {entry.entity} ({entry.id}): {entry.reason}
                  </div>
                ))}
              </div>
            )}
            {item.detail && <p className="text-[11px] text-[var(--text-muted)]">{registryText(item.detail, lang)}</p>}
          </div>
        );

      default:
        return null;
    }
  };

  const renderItem = (item: RegistryItem) => {
    if (item.kind === "pageLink" && item.page) {
      const targetPage = PAGE_BY_ID.get(item.page);
      const Icon = iconFor(item.icon ?? targetPage?.icon);
      const label =
        item.statusKey === "planStatus" && isPro
          ? registryText(tierCard("pro")?.title ?? PLAN_UI.proName, lang)
          : registryText(item.label ?? targetPage?.title ?? item.page, lang);
      const badge = statusText(item.statusKey);
      return (
        <button
          type="button"
          onClick={() => pushPage(item.page!)}
          className="flex w-full items-center gap-2.5 py-2.5 text-left text-xs text-[var(--text-primary)] hover:opacity-80"
        >
          <Icon className="h-4 w-4 shrink-0 text-[var(--accent)]" />
          <span className="min-w-0 flex-1 truncate font-medium">{label}</span>
          {badge && <span className="shrink-0 text-[11px] text-[var(--text-muted)]">{badge}</span>}
          <ChevronRight className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
        </button>
      );
    }
    if (item.kind === "setting") return renderSettingItem(item);
    if (item.kind === "customSurface") return renderSurface(item);
    return null;
  };

  const renderPageContent = (pageId: string) => {
    const page = PAGE_BY_ID.get(pageId);
    if (!page) return null;
    return (
      <div className="space-y-5">
        {page.sections
          .filter((sec) => appliesToWeb(sec.platforms))
          .map((sec) => {
            const visibleItems = sec.items.filter(isItemVisible);
            if (visibleItems.length === 0) return null;
            return (
              <div key={sec.id} className="space-y-5">
                <section>
                  {sec.header && (
                    <h3 className="mb-1.5 text-[11px] font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                      {registryText(sec.header, lang)}
                    </h3>
                  )}
                  <div className="divide-y divide-[var(--border-subtle)] rounded-xl border border-[var(--border-subtle)] px-3.5">
                    {visibleItems.map((item, idx) => (
                      <div key={item.key ?? item.page ?? item.surface ?? idx}>{renderItem(item)}</div>
                    ))}
                  </div>
                  {sec.footer && (
                    <p className="mt-1.5 text-[11px] text-[var(--text-muted)]">{registryText(sec.footer, lang)}</p>
                  )}
                </section>
                {pageId === "account" && sec.id === "sync" && signedIn && (
                  <SignInMethodsSection api={api} language={lang} />
                )}
              </div>
            );
          })}
      </div>
    );
  };

  const renderTabContent = (tabId: SettingsTab) => {
    if (TAB_DIRECT_PAGES.has(tabId)) {
      return renderPageContent(tabId);
    }
    const tabTitle = TAB_BY_ID.get(tabId)?.title;
    const groups = ROOT_GROUPS.filter((g) => g.desktopTab === tabId);
    return (
      <div className="space-y-5">
        {groups.map((grp) => {
          const visibleItems = grp.items.filter(isItemVisible);
          if (visibleItems.length === 0) return null;
          const showHeader = grp.header && grp.header !== tabTitle;
          return (
            <section key={grp.id}>
              {showHeader && (
                <h3 className="mb-1.5 text-[11px] font-semibold tracking-wide text-[var(--text-muted)] uppercase">
                  {registryText(grp.header!, lang)}
                </h3>
              )}
              <div className="divide-y divide-[var(--border-subtle)] rounded-xl border border-[var(--border-subtle)] px-3.5">
                {visibleItems.map((item, idx) => (
                  <div key={item.key ?? item.page ?? item.surface ?? idx}>{renderItem(item)}</div>
                ))}
              </div>
            </section>
          );
        })}
      </div>
    );
  };

  const identityTabs = DESKTOP_TABS.filter((t) => t.group === "identity");
  const mainTabs = DESKTOP_TABS.filter((t) => t.group === "main");
  const aboutTabs = DESKTOP_TABS.filter((t) => t.group === "about");

  const currentTabTitle = registryText(TAB_BY_ID.get(tab)?.title ?? "Settings", lang);
  const currentHeaderTitle = activePageId
    ? activePageId === "plus" && isPro
      ? registryText(tierCard("pro")?.title ?? PLAN_UI.proName, lang)
      : registryText(PAGE_BY_ID.get(activePageId)?.title ?? activePageId, lang)
    : currentTabTitle;
  const backLabel =
    pageStack.length > 1
      ? registryText(PAGE_BY_ID.get(pageStack[pageStack.length - 2])?.title ?? currentTabTitle, lang)
      : currentTabTitle;

  const initials = (welcomeName || "S")
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() ?? "")
    .join("");

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-4"
      onClick={onClose}
    >
      <div
        className="flex h-[84vh] max-h-[680px] w-full max-w-3xl overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Left Settings Sidebar generated from registry/settings.json desktopTabs */}
        <aside className="hidden w-52 shrink-0 flex-col border-r border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-2.5 sm:flex">
          {identityTabs.map((t) => {
            const active = tab === t.id;
            return (
              <button
                key={t.id}
                type="button"
                onClick={() => selectTab(t.id)}
                className={`mb-2.5 flex w-full items-center gap-2.5 rounded-xl px-2.5 py-2 text-left transition-colors ${
                  active
                    ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                    : "hover:bg-[var(--bg-hover)]"
                }`}
              >
                <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-[var(--border-subtle)] bg-[var(--bg-elevated)] text-xs font-semibold text-[var(--text-primary)]">
                  {initials}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-xs font-semibold text-[var(--text-primary)]">
                    {welcomeName || settingsCopy("account_profile_card", "yourProfile", lang)}
                  </p>
                  <div className="mt-0.5 flex items-center gap-1 text-[10px] text-[var(--text-muted)]">
                    {planBadge && (
                      <span className="rounded-full bg-[var(--bg-elevated)] px-1.5 py-0.25 font-medium text-[var(--text-secondary)]">
                        {planBadge}
                      </span>
                    )}
                    {profileSyncAlert && <span>· {profileSyncAlert}</span>}
                  </div>
                </div>
              </button>
            );
          })}

          <nav className="space-y-0.5">
            {mainTabs.map((t) => {
              const Icon = iconFor(t.icon);
              const active = tab === t.id;
              return (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => selectTab(t.id)}
                  className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left text-xs font-medium transition-colors ${
                    active
                      ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                  }`}
                >
                  <Icon className="h-4 w-4 shrink-0 text-[var(--accent)]" />
                  <span className="truncate">{registryText(t.title, lang)}</span>
                </button>
              );
            })}
          </nav>

          {aboutTabs.length > 0 && (
            <nav className="mt-3 border-t border-[var(--border-subtle)] pt-3 space-y-0.5">
              {aboutTabs.map((t) => {
                const Icon = iconFor(t.icon);
                const active = tab === t.id;
                return (
                  <button
                    key={t.id}
                    type="button"
                    onClick={() => selectTab(t.id)}
                    className={`flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left text-xs font-medium transition-colors ${
                      active
                        ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                        : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                    }`}
                  >
                    <Icon className="h-4 w-4 shrink-0 text-[var(--accent)]" />
                    <span className="truncate">{registryText(t.title, lang)}</span>
                  </button>
                );
              })}
            </nav>
          )}
        </aside>

        {/* Right content column with subpage stack */}
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex items-center justify-between gap-2 border-b border-[var(--border-subtle)] px-5 py-3.5">
            <div className="flex min-w-0 items-center gap-2">
              {pageStack.length > 0 && (
                <button
                  type="button"
                  onClick={popPage}
                  className="inline-flex shrink-0 items-center gap-0.5 rounded-md px-1.5 py-1 text-xs font-medium text-[var(--accent)] hover:bg-[var(--bg-hover)]"
                >
                  <ChevronLeft className="h-3.5 w-3.5" />
                  <span>{backLabel}</span>
                </button>
              )}
              <h2 className="truncate text-base font-semibold text-[var(--text-primary)]">
                {currentHeaderTitle}
              </h2>
            </div>
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
            {DESKTOP_TABS.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => selectTab(t.id)}
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

          <div className="flex-1 overflow-y-auto p-5 text-sm">
            {activePageId ? renderPageContent(activePageId) : renderTabContent(tab)}
          </div>
        </div>
      </div>
      <PlanSheet
        open={planSheet !== null}
        onClose={() => setPlanSheet(null)}
        plan={plan}
        upsellId={planSheet?.upsellId ?? null}
        initialTier={planSheet?.tier ?? null}
        lang={lang}
      />
    </div>
  );
}
