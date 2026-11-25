import {
  zDeviceStartResponse,
  zPullResponse,
  zPushResponse,
  zSessionResponse,
  zWsTicketResponse,
  type DeviceStartResponse,
  type OutboxOp,
  type PullResponse,
  type PushResponse,
  type SessionResponse,
  type WsTicketResponse,
} from "../types";

// API client for api.septena.app (docs/WEB_CLIENT_SPEC.md §4–§5).
// - Access token stays in memory only (never localStorage/sessionStorage).
// - Refresh token stays in an HttpOnly cookie on api.septena.app (/v1/auth).
// - Single-flight refresh prevents concurrent 401s from double-rotating the cookie.

const DEFAULT_API_BASE = "https://api.septena.app";
const CLIENT_HEADER = "web 0.1.0";

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message?: string) {
    super(message ?? `${code} (${status})`);
    this.status = status;
    this.code = code;
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
    // Refresh slightly before the 1-hour expiry.
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
      const err = (await res.json().catch(() => ({}))) as { error?: string };
      throw new ApiError(res.status, err.error ?? "device_start_failed");
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
      const err = (await res.json().catch(() => ({}))) as { error?: string };
      return { status: err.error === "denied" ? "denied" : "expired" };
    }
    if (!res.ok) {
      const err = (await res.json().catch(() => ({}))) as { error?: string };
      throw new ApiError(res.status, err.error ?? "device_poll_failed");
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
      const err = (await res.json().catch(() => ({}))) as { error?: string; message?: string };
      throw new ApiError(res.status, err.error ?? "pull_failed", err.message);
    }
    return zPullResponse.parse(await res.json());
  }

  async push(ops: OutboxOp[]): Promise<PushResponse> {
    const wireOps = ops.map((o) =>
      o.op === "delete"
        ? { clientOpId: o.clientOpId, op: "delete", entity: o.entity, id: o.id }
        : { clientOpId: o.clientOpId, op: "upsert", entity: o.entity, id: o.id, fields: o.fields },
    );
    const res = await this.authedFetch("/v1/sync/push", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ops: wireOps }),
    });
    if (!res.ok) {
      const err = (await res.json().catch(() => ({}))) as { error?: string; message?: string };
      throw new ApiError(res.status, err.error ?? "push_failed", err.message);
    }
    return zPushResponse.parse(await res.json());
  }

  async wsTicket(): Promise<WsTicketResponse> {
    const res = await this.authedFetch("/v1/sync/ws-ticket", { method: "POST" });
    if (!res.ok) {
      const err = (await res.json().catch(() => ({}))) as { error?: string };
      throw new ApiError(res.status, err.error ?? "ws_ticket_failed");
    }
    return zWsTicketResponse.parse(await res.json());
  }

  wsUrl(ticket: string): string {
    const base = this.apiBase.replace(/^http/, "ws");
    return `${base}/v1/sync/ws?ticket=${encodeURIComponent(ticket)}`;
  }
}
