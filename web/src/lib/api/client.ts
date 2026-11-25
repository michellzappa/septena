import {
  zAccessSummary,
  zChangesResponse,
  zDeviceStartResponse,
  zIcalFeedSettings,
  zPullResponse,
  zPushResponse,
  zSessionResponse,
  zWsTicketResponse,
  type AccessSummary,
  type ChangeEntry,
  type DeviceStartResponse,
  type IcalFeedSettings,
  type OutboxOp,
  type PullResponse,
  type PushResponse,
  type SessionResponse,
  type WsTicketResponse,
} from "../types";

// API client for api.septena.app (docs/WEB_CLIENT_SPEC.md §4–§5).
// - Access token stays in memory only (never localStorage/sessionStorage).
// - Refresh token stays in an HttpOnly cookie on api.septena.app (/v1/auth).
// - Single-flight refresh prevents concurrent 401s from racing cookie rotation.

const DEFAULT_API_BASE = "https://api.septena.app";
const CLIENT_HEADER = "web 0.2.0";

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly rawBody: string;
  constructor(status: number, code: string, message?: string, rawBody = "") {
    super(message ?? `${code} (${status})`);
    this.status = status;
    this.code = code;
    this.rawBody = rawBody;
  }
}

export class SeptenaApiClient {
  readonly apiBase: string;
  private accessToken: string | null = null;
  private userId: string | null = null;
  private accessExpiresAt = 0;
  private refreshInFlight: Promise<SessionResponse | null> | null = null;

  constructor(apiBase = process.env.NEXT_PUBLIC_API_URL ?? DEFAULT_API_BASE) {
    this.apiBase = apiBase.replace(/\/$/, "");
  }

  get currentUserId(): string | null {
    return this.userId;
  }

  get isAuthenticated(): boolean {
    return this.accessToken !== null;
  }

  private setSession(session: SessionResponse): void {
    this.accessToken = session.accessToken;
    this.userId = session.userId;
    this.accessExpiresAt = Date.now() + Math.max(30, session.expiresIn - 120) * 1000;
  }

  clearInMemorySession(): void {
    this.accessToken = null;
    this.userId = null;
    this.accessExpiresAt = 0;
  }

  async restoreSession(): Promise<SessionResponse | null> {
    return this.refreshWithCookie();
  }

  async refreshWithCookie(): Promise<SessionResponse | null> {
    if (this.refreshInFlight) return this.refreshInFlight;
    this.refreshInFlight = (async () => {
      const res = await fetch(`${this.apiBase}/v1/auth/refresh`, {
        method: "POST",
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
          "X-Septena-Client": CLIENT_HEADER,
        },
        body: "{}",
      });
      if (!res.ok) {
        if (res.status === 401 || res.status === 403) {
          this.clearInMemorySession();
        }
        return null;
      }
      const parsed = zSessionResponse.parse(await res.json());
      this.setSession(parsed);
      return parsed;
    })();
    try {
      return await this.refreshInFlight;
    } finally {
      this.refreshInFlight = null;
    }
  }

  async startDeviceSignIn(clientName: string): Promise<DeviceStartResponse> {
    const res = await fetch(`${this.apiBase}/v1/auth/device/start`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Septena-Client": CLIENT_HEADER,
      },
      body: JSON.stringify({ clientName }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "device_start_failed", err.message, raw);
    }
    return zDeviceStartResponse.parse(await res.json());
  }

  async pollDeviceSignIn(
    code: string,
    pollSecret: string,
  ): Promise<{ status: "pending" } | { status: "approved"; session: SessionResponse } | { status: "denied" | "expired" }> {
    const res = await fetch(`${this.apiBase}/v1/auth/device/poll`, {
      method: "POST",
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        "X-Septena-Client": CLIENT_HEADER,
      },
      body: JSON.stringify({ code, pollSecret, sessionMode: "cookie" }),
    });
    if (res.status === 202) return { status: "pending" };
    if (res.status === 410) {
      const err = parseErr(await res.text().catch(() => ""));
      return { status: err.error === "denied" ? "denied" : "expired" };
    }
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "device_poll_failed", err.message, raw);
    }
    const session = zSessionResponse.parse(await res.json());
    this.setSession(session);
    return { status: "approved", session };
  }

  async signOut(): Promise<void> {
    try {
      await fetch(`${this.apiBase}/v1/auth/signout`, {
        method: "POST",
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
          "X-Septena-Client": CLIENT_HEADER,
        },
        body: "{}",
      });
    } finally {
      this.clearInMemorySession();
    }
  }

  private async ensureAccessToken(): Promise<string> {
    if (this.accessToken && Date.now() < this.accessExpiresAt) {
      return this.accessToken;
    }
    const refreshed = await this.refreshWithCookie();
    if (!refreshed) throw new ApiError(401, "unauthorized");
    return refreshed.accessToken;
  }

  private async authedFetch(path: string, init: RequestInit = {}): Promise<Response> {
    const token = await this.ensureAccessToken();
    const doReq = (bearer: string) =>
      fetch(`${this.apiBase}${path}`, {
        ...init,
        headers: {
          ...(init.headers ?? {}),
          Authorization: `Bearer ${bearer}`,
          "X-Septena-Client": CLIENT_HEADER,
        },
      });

    let res = await doReq(token);
    if (res.status === 401) {
      const refreshed = await this.refreshWithCookie();
      if (!refreshed) throw new ApiError(401, "unauthorized");
      res = await doReq(refreshed.accessToken);
    }
    return res;
  }

  async pull(since: number): Promise<PullResponse> {
    const qs = new URLSearchParams({
      since: String(since),
      limit: "500",
      settings: "1",
      checklists: "1",
      tags: "1",
      refs: "1",
    });
    const res = await this.authedFetch(`/v1/sync/pull?${qs.toString()}`, { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "pull_failed", err.message, raw);
    }
    return zPullResponse.parse(await res.json());
  }

  async push(ops: OutboxOp[]): Promise<PushResponse> {
    const wireOps = ops.map((o) => {
      if (o.op === "delete") {
        return { clientOpId: o.clientOpId, op: "delete", entity: o.entity, id: o.id };
      }
      if (o.op === "appendTurn") {
        return { clientOpId: o.clientOpId, op: "appendTurn", taskId: o.taskId, turn: o.turn };
      }
      return { clientOpId: o.clientOpId, op: "upsert", entity: o.entity, id: o.id, fields: o.fields };
    });
    const res = await this.authedFetch("/v1/sync/push", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ops: wireOps }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "push_failed", err.message, raw);
    }
    return zPushResponse.parse(await res.json());
  }

  async wsTicket(): Promise<WsTicketResponse> {
    const res = await this.authedFetch("/v1/sync/ws-ticket", { method: "POST" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "ws_ticket_failed", err.message, raw);
    }
    return zWsTicketResponse.parse(await res.json());
  }

  wsUrl(ticket: string): string {
    const base = this.apiBase.replace(/^http/, "ws");
    return `${base}/v1/sync/ws?ticket=${encodeURIComponent(ticket)}`;
  }

  async getAccessSummary(): Promise<AccessSummary> {
    const res = await this.authedFetch("/v1/access", { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "access_failed", err.message, raw);
    }
    return zAccessSummary.parse(await res.json());
  }

  async revokeDevice(sid: string): Promise<void> {
    const res = await this.authedFetch(`/v1/access/devices/${encodeURIComponent(sid)}`, { method: "DELETE" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "revoke_device_failed", err.message, raw);
    }
  }

  async disconnectAgent(id: string): Promise<void> {
    const res = await this.authedFetch(`/v1/access/connections/${encodeURIComponent(id)}`, { method: "DELETE" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "disconnect_agent_failed", err.message, raw);
    }
  }

  async renameAgent(id: string, name: string | null): Promise<void> {
    const res = await this.authedFetch(`/v1/access/connections/${encodeURIComponent(id)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "rename_agent_failed", err.message, raw);
    }
  }

  async inspectPairingCode(code: string): Promise<{ kind: "connector" | "device"; client: string; expiresIn: number }> {
    const res = await this.authedFetch("/v1/pair/inspect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "inspect_failed", err.message, raw);
    }
    return (await res.json()) as { kind: "connector" | "device"; client: string; expiresIn: number };
  }

  async approvePairingCode(code: string, kind: "connector" | "device", name?: string): Promise<void> {
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const body: Record<string, unknown> = { code, kind, timeZone };
    if (kind === "connector" && name?.trim()) body.name = name.trim();
    const res = await this.authedFetch("/v1/pair/approve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "approve_failed", err.message, raw);
    }
  }

  async getChanges(entity: string, id: string, limit = 50): Promise<ChangeEntry[]> {
    const qs = new URLSearchParams({ entity, id, limit: String(limit) });
    const res = await this.authedFetch(`/v1/changes?${qs.toString()}`, { method: "GET" });
    if (!res.ok) return [];
    const parsed = zChangesResponse.safeParse(await res.json());
    return parsed.success ? parsed.data.changes : [];
  }

  async downloadAttachment(id: string, filename: string): Promise<void> {
    const res = await this.authedFetch(`/v1/attachments/${encodeURIComponent(id)}`, { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "download_failed", err.message, raw);
    }
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }

  async uploadAttachmentBytes(id: string, file: File): Promise<{ rev: number }> {
    const buf = await file.arrayBuffer();
    const res = await this.authedFetch(`/v1/attachments/${encodeURIComponent(id)}`, {
      method: "PUT",
      headers: {
        "Content-Type": file.type || "application/octet-stream",
      },
      body: buf,
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "upload_failed", err.message, raw);
    }
    return (await res.json()) as { rev: number };
  }

  async getIcalSettings(): Promise<IcalFeedSettings> {
    const res = await this.authedFetch("/v1/ical/settings", { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "ical_settings_failed", err.message, raw);
    }
    return zIcalFeedSettings.parse(await res.json());
  }

  async updateIcalSettings(body: {
    enabled?: boolean;
    scope?: "all" | "timed";
    rotate?: boolean;
  }): Promise<IcalFeedSettings> {
    const res = await this.authedFetch("/v1/ical/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "ical_update_failed", err.message, raw);
    }
    return zIcalFeedSettings.parse(await res.json());
  }

  async deleteAccount(): Promise<void> {
    const res = await this.authedFetch("/v1/account", { method: "DELETE" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "delete_account_failed", err.message, raw);
    }
    this.clearInMemorySession();
  }

  async fetchSkillMarkdown(): Promise<string> {
    const res = await fetch(`${this.apiBase}/skill.md`, { method: "GET" });
    if (!res.ok) {
      throw new ApiError(res.status, "skill_fetch_failed");
    }
    return res.text();
  }
}

function parseErr(raw: string): { error?: string; message?: string } {
  try {
    return JSON.parse(raw) as { error?: string; message?: string };
  } catch {
    return {};
  }
}
