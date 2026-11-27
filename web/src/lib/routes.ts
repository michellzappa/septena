// Client-side URL routing for web.septena.app.
//
// Cloudflare Workers static assets (`wrangler.jsonc` `not_found_handling:
// "single-page-application"`) and the offline Service Worker (`public/sw.js`)
// serve `index.html` for every non-asset path, so every list, area, project,
// task page, and settings tab gets a clean, bookmarkable URL without server
// rendering task data (docs/WEB_CLIENT_SPEC.md §2).

import type { ActiveDestination, SmartDestination } from "./types";

export type LogbookTab = "completed" | "deleted";

export type SettingsTabId =
  | "account"
  | "general"
  | "appearance"
  | "agents"
  | "connections"
  | "privacy"
  | "about";

export interface ParsedWebRoute {
  /** Destination to show, or null on a standalone `/task/:id` or `/settings/...` URL. */
  destination: ActiveDestination | null;
  logbookTab: LogbookTab;
  tagFilterId: string | null;
  taskPageId: string | null;
  settingsOpen: boolean;
  settingsTab: SettingsTabId | undefined;
  /** True when `/faded` was visited so Review opens with Faded expanded. */
  expandFaded: boolean;
  /** True when the URL was `/` or an alias/unknown path and should be canonicalized via replaceState. */
  canonicalize: boolean;
}

export interface WebRouteState {
  destination: ActiveDestination;
  logbookTab: LogbookTab;
  tagFilterId: string | null;
  taskPageId: string | null;
  settingsOpen: boolean;
  settingsTab: SettingsTabId;
}

const SMART_CANONICAL_PATH: Record<SmartDestination, string> = {
  today: "/today",
  review: "/review",
  agent: "/review",
  faded: "/review",
  upcoming: "/upcoming",
  repeating: "/repeating",
  anytime: "/anytime",
  starred: "/favorites",
  logbook: "/logbook",
};

const SETTINGS_TAB_TO_SLUG: Record<SettingsTabId, string> = {
  account: "account",
  general: "general",
  appearance: "appearance",
  agents: "agents",
  connections: "connections",
  privacy: "privacy",
  about: "about",
};

const SETTINGS_SLUG_TO_TAB: Record<string, SettingsTabId> = {
  account: "account",
  general: "general",
  appearance: "appearance",
  agents: "agents",
  // Older links: the Agents tab was "AI & Agents" (/settings/ai-agents).
  "ai-agents": "agents",
  ai_agents: "agents",
  ai: "agents",
  connections: "connections",
  connections_data: "connections",
  data: "connections",
  privacy: "privacy",
  about: "about",
};

const TRANSIENT_CALLBACK_PARAMS = [
  "oidc_code",
  "oidc_error",
  "oidc_link",
  "share_title",
  "share_text",
  "share_url",
] as const;

function safeDecode(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

export function settingsTabToSlug(tab: SettingsTabId): string {
  return SETTINGS_TAB_TO_SLUG[tab] ?? "general";
}

export function destinationPath(
  destination: ActiveDestination,
  logbookTab: LogbookTab = "completed",
): string {
  if (destination.kind === "area") {
    return `/area/${encodeURIComponent(destination.id)}`;
  }
  if (destination.kind === "project") {
    return `/project/${encodeURIComponent(destination.id)}`;
  }
  if (destination.id === "logbook" && logbookTab === "deleted") {
    return "/logbook/deleted";
  }
  return SMART_CANONICAL_PATH[destination.id] ?? "/today";
}

export function taskPagePath(taskId: string): string {
  return `/task/${encodeURIComponent(taskId)}`;
}

export function settingsPath(tab: SettingsTabId = "general"): string {
  return `/settings/${settingsTabToSlug(tab)}`;
}

export function buildWebUrl(state: WebRouteState): string {
  if (state.settingsOpen) {
    return settingsPath(state.settingsTab);
  }
  if (state.taskPageId) {
    return taskPagePath(state.taskPageId);
  }
  const base = destinationPath(state.destination, state.logbookTab);
  if (state.tagFilterId) {
    const params = new URLSearchParams();
    params.set("tag", state.tagFilterId);
    return `${base}?${params.toString()}`;
  }
  return base;
}

export function hasPendingAuthOrShareParams(search: string): boolean {
  if (!search) return false;
  const params = new URLSearchParams(search);
  return TRANSIENT_CALLBACK_PARAMS.some((k) => params.has(k));
}

export function parseWebRoute(pathname: string, search = ""): ParsedWebRoute {
  const params = new URLSearchParams(search);
  const tag = params.get("tag")?.trim() || null;

  const trimmed = pathname.replace(/\/+$/, "");
  const segments = trimmed.split("/").filter(Boolean);

  const base: ParsedWebRoute = {
    destination: { kind: "smart", id: "today" },
    logbookTab: "completed",
    tagFilterId: tag,
    taskPageId: null,
    settingsOpen: false,
    settingsTab: undefined,
    expandFaded: false,
    canonicalize: false,
  };

  if (segments.length === 0) {
    return { ...base, canonicalize: true };
  }

  const head = segments[0].toLowerCase();
  const hasTrailingSlash = pathname.length > 1 && pathname.endsWith("/");

  switch (head) {
    case "today":
      return {
        ...base,
        destination: { kind: "smart", id: "today" },
        canonicalize: segments.length > 1 || segments[0] !== "today" || hasTrailingSlash,
      };
    case "inbox":
    case "triage":
      return {
        ...base,
        destination: { kind: "smart", id: "today" },
        canonicalize: true,
      };
    case "review":
      return {
        ...base,
        destination: { kind: "smart", id: "review" },
        canonicalize: segments.length > 1 || segments[0] !== "review" || hasTrailingSlash,
      };
    case "agent":
      return {
        ...base,
        destination: { kind: "smart", id: "review" },
        canonicalize: true,
      };
    case "faded":
      return {
        ...base,
        destination: { kind: "smart", id: "review" },
        expandFaded: true,
        canonicalize: true,
      };
    case "upcoming":
      return {
        ...base,
        destination: { kind: "smart", id: "upcoming" },
        canonicalize: segments.length > 1 || segments[0] !== "upcoming" || hasTrailingSlash,
      };
    case "repeating":
      return {
        ...base,
        destination: { kind: "smart", id: "repeating" },
        canonicalize: segments.length > 1 || segments[0] !== "repeating" || hasTrailingSlash,
      };
    case "anytime":
      return {
        ...base,
        destination: { kind: "smart", id: "anytime" },
        canonicalize: segments.length > 1 || segments[0] !== "anytime" || hasTrailingSlash,
      };
    case "someday":
    case "unscheduled":
      return {
        ...base,
        destination: { kind: "smart", id: "anytime" },
        canonicalize: true,
      };
    case "favorites":
      return {
        ...base,
        destination: { kind: "smart", id: "starred" },
        canonicalize: segments.length > 1 || segments[0] !== "favorites" || hasTrailingSlash,
      };
    case "starred":
      return {
        ...base,
        destination: { kind: "smart", id: "starred" },
        canonicalize: true,
      };
    case "logbook": {
      const sub = segments[1]?.toLowerCase();
      if (sub === "deleted") {
        return {
          ...base,
          destination: { kind: "smart", id: "logbook" },
          logbookTab: "deleted",
          canonicalize:
            segments.length > 2 ||
            segments[0] !== "logbook" ||
            segments[1] !== "deleted" ||
            hasTrailingSlash,
        };
      }
      return {
        ...base,
        destination: { kind: "smart", id: "logbook" },
        logbookTab: "completed",
        canonicalize: segments.length > 1 || segments[0] !== "logbook" || hasTrailingSlash,
      };
    }
    case "deleted":
    case "recently-deleted":
    case "recentlydeleted":
    case "trash":
      return {
        ...base,
        destination: { kind: "smart", id: "logbook" },
        logbookTab: "deleted",
        canonicalize: true,
      };
    case "area":
    case "areas": {
      const rawId = segments[1];
      if (!rawId) return { ...base, canonicalize: true };
      const id = safeDecode(rawId);
      return {
        ...base,
        destination: { kind: "area", id },
        canonicalize: segments[0] !== "area" || segments.length > 2 || hasTrailingSlash,
      };
    }
    case "project":
    case "projects": {
      const rawId = segments[1];
      if (!rawId) return { ...base, canonicalize: true };
      const id = safeDecode(rawId);
      return {
        ...base,
        destination: { kind: "project", id },
        canonicalize: segments[0] !== "project" || segments.length > 2 || hasTrailingSlash,
      };
    }
    case "task":
    case "tasks": {
      const rawId = segments[1];
      if (!rawId) return { ...base, canonicalize: true };
      const id = safeDecode(rawId);
      return {
        ...base,
        destination: null,
        tagFilterId: null,
        taskPageId: id,
        canonicalize: segments[0] !== "task" || segments.length > 2 || hasTrailingSlash,
      };
    }
    case "settings": {
      const rawTab = segments[1]?.toLowerCase();
      const matchedTab = rawTab ? SETTINGS_SLUG_TO_TAB[rawTab] : undefined;
      const tab: SettingsTabId = matchedTab ?? "general";
      const canonicalSlug = settingsTabToSlug(tab);
      return {
        ...base,
        destination: null,
        tagFilterId: null,
        settingsOpen: true,
        settingsTab: tab,
        canonicalize:
          !rawTab ||
          !matchedTab ||
          segments[0] !== "settings" ||
          segments[1] !== canonicalSlug ||
          segments.length > 2 ||
          hasTrailingSlash,
      };
    }
    default:
      return { ...base, canonicalize: true };
  }
}

export function isPlainLeftClick(e: {
  button: number;
  metaKey: boolean;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
}): boolean {
  return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey;
}
