import {
  zAccessSummary,
  zBetaState,
  type BetaProgress,
  type BetaState,
  zEntitlement,
  type Entitlement,
  zAuthMethodsResponse,
  zCreatedAgentKey,
  zEmailStartResponse,
  zLinkedIdentitiesResponse,
  zChangesResponse,
  zDeviceStartResponse,
  zIcalFeedSettings,
  zPullResponse,
  zPushResponse,
  zSessionResponse,
  zWsTicketResponse,
  type AccessSummary,
  type AuthMethodEntry,
  type ChangeEntry,
  type DeviceStartResponse,
  type EmailStartResponse,
  type IcalFeedSettings,
  type LinkedIdentitiesResponse,
  type OidcRedeemSignInResult,
  type OutboxOp,
  type PullResponse,
  type PushResponse,
  type SessionResponse,
  type WsTicketResponse,
  type Avatar,
} from "../types";
import { normalizeAvatar } from "../avatar";

// API client for api.septena.app (docs/WEB_CLIENT_SPEC.md §4–§5).
// - Access token stays in memory only (never localStorage/sessionStorage).
// - Refresh token stays in an HttpOnly cookie on api.septena.app (/v1/auth).
// - Single-flight refresh prevents concurrent 401s from racing cookie rotation.

const DEFAULT_API_BASE = "https://api.septena.app";

/** `/v1/support/*` wire (backend/src/support/routes.ts). */
export interface SupportDiagnostics {
  platform: "web";
  osVersion?: string;
  deviceModel?: string;
  appVersion?: string;
  signedIn?: boolean;
}
export interface SupportOutgoing {
  message_id: string;
  text: string;
  email?: string;
  diagnostics?: SupportDiagnostics;
}
export interface SupportMessage {
  id: string;
  direction: "in" | "out";
  text: string;
  authorName: string | null;
  createdAt: number;
  readAt: number | null;
}
export interface SupportConversation {
  messages: SupportMessage[];
  unread: number;
}
/// `X-Septena-Client` and `X-Septena-Version` (docs/ADMIN_CONSOLE_SPEC.md §4).
/// The version is "<package.json version> (<git commit count>)", set at build
/// time in next.config.ts, the same form as the other clients.
export const CLIENT_HEADER = "septena-web";
export const CLIENT_VERSION = process.env.NEXT_PUBLIC_SEPTENA_VERSION ?? "0.0.0 (0)";
export const CLIENT_HEADERS = { "X-Septena-Client": CLIENT_HEADER, "X-Septena-Version": CLIENT_VERSION } as const;

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
    this.clearAvatarPhotos();
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
          ...CLIENT_HEADERS,
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

  async startDeviceSignIn(clientName: string, signal?: AbortSignal): Promise<DeviceStartResponse> {
    const res = await fetch(`${this.apiBase}/v1/auth/device/start`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...CLIENT_HEADERS,
      },
      body: JSON.stringify({ clientName }),
      signal,
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
        ...CLIENT_HEADERS,
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

  /** The sign-in methods this server has turned on (with web/native capability flags). */
  async authMethodEntries(signal?: AbortSignal): Promise<AuthMethodEntry[]> {
    const res = await fetch(`${this.apiBase}/v1/auth/methods`, {
      headers: { ...CLIENT_HEADERS },
      signal,
    });
    if (!res.ok) throw new ApiError(res.status, "auth_methods_failed");
    return zAuthMethodsResponse.parse(await res.json()).methods;
  }

  /** The sign-in method ids this server has turned on. Throws on any failure: the caller fails closed. */
  async authMethods(signal?: AbortSignal): Promise<string[]> {
    return (await this.authMethodEntries(signal)).map((m) => m.id);
  }

  /** Top-level OIDC redirect URL for Google, Microsoft, or Web Sign in with Apple (ADR 0047). */
  oidcStartUrl(provider: "apple" | "google" | "microsoft", returnTo: string): string {
    const u = new URL(`${this.apiBase}/v1/auth/oidc/${provider}/start`);
    u.searchParams.set("return_to", returnTo);
    return u.toString();
  }

  /** Trades the one-time `oidc_code` from the callback URL for a cookie session or collision-link step. */
  async redeemOidcSignIn(code: string, signal?: AbortSignal): Promise<OidcRedeemSignInResult> {
    const res = await fetch(`${this.apiBase}/v1/auth/oidc/redeem`, {
      method: "POST",
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        ...CLIENT_HEADERS,
      },
      body: JSON.stringify({ code, sessionMode: "cookie" }),
      signal,
    });
    if (res.status === 409) {
      const body = (await res.json().catch(() => ({}))) as {
        error?: string;
        email?: string;
        provider?: string;
        linkToken?: string;
        codeSent?: boolean;
      };
      if (body.error === "account_exists" && body.email && body.provider) {
        return {
          status: "account_exists",
          email: body.email,
          provider: body.provider,
          linkToken: body.linkToken,
          codeSent: body.codeSent,
        };
      }
    }
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "oidc_redeem_failed", err.message, raw);
    }
    const session = zSessionResponse.parse(await res.json());
    this.setSession(session);
    return { status: "signed_in", session };
  }

  /** Finishes the no-silent-linking collision step with the emailed 6-digit code. */
  async completeCollisionLink(linkToken: string, code: string, signal?: AbortSignal): Promise<SessionResponse> {
    const res = await fetch(`${this.apiBase}/v1/auth/link/complete`, {
      method: "POST",
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        ...CLIENT_HEADERS,
      },
      body: JSON.stringify({ linkToken, code, sessionMode: "cookie" }),
      signal,
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "link_complete_failed", err.message, raw);
    }
    const session = zSessionResponse.parse(await res.json());
    this.setSession(session);
    return session;
  }

  /** Lists sign-in methods linked to the signed-in account (Settings ▸ Account, #643). */
  async listIdentities(): Promise<LinkedIdentitiesResponse> {
    const res = await this.authedFetch("/v1/auth/identities");
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "identities_failed", err.message, raw);
    }
    return zLinkedIdentitiesResponse.parse(await res.json());
  }

  /** Removes a linked sign-in method; backend refuses removing the last one with 409 last_method. */
  async unlinkIdentity(id: string): Promise<LinkedIdentitiesResponse> {
    const res = await this.authedFetch(`/v1/auth/identities/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "unlink_failed", err.message, raw);
    }
    return zLinkedIdentitiesResponse.parse(await res.json());
  }

  /** Sends a 6-digit verification code to add an email address to the signed-in account. */
  async startLinkEmail(email: string): Promise<EmailStartResponse> {
    const res = await this.authedFetch("/v1/auth/link/email/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "link_email_start_failed", err.message, raw);
    }
    return zEmailStartResponse.parse(await res.json());
  }

  /** Verifies the emailed code and attaches the email to the signed-in account. */
  async verifyLinkEmail(email: string, code: string): Promise<LinkedIdentitiesResponse> {
    const res = await this.authedFetch("/v1/auth/link/email/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, code }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "link_email_verify_failed", err.message, raw);
    }
    return zLinkedIdentitiesResponse.parse(await res.json());
  }

  /** Starts an OIDC redirect flow to link Apple, Google, or Microsoft to the signed-in account. */
  async startLinkOidc(provider: "apple" | "google" | "microsoft", returnTo: string): Promise<string> {
    const res = await this.authedFetch("/v1/auth/link/oidc/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ provider, returnTo }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "link_oidc_start_failed", err.message, raw);
    }
    const data = (await res.json()) as { url: string };
    return data.url;
  }

  /** Completes an OIDC link flow after redirect back with `?oidc_code=`. */
  async redeemOidcLink(code: string): Promise<LinkedIdentitiesResponse> {
    const res = await this.authedFetch("/v1/auth/oidc/redeem", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "link_oidc_redeem_failed", err.message, raw);
    }
    return zLinkedIdentitiesResponse.parse(await res.json());
  }

  /** Sends a sign-in code to `email` (POST /v1/auth/email/start). */
  async startEmailSignIn(email: string, signal?: AbortSignal): Promise<EmailStartResponse> {
    const res = await fetch(`${this.apiBase}/v1/auth/email/start`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...CLIENT_HEADERS,
      },
      body: JSON.stringify({ email }),
      signal,
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "email_start_failed", err.message, raw);
    }
    return zEmailStartResponse.parse(await res.json());
  }

  /**
   * Trades the emailed code for a session (POST /v1/auth/email/verify). The
   * refresh token arrives in the HttpOnly cookie, as for device approval.
   */
  async verifyEmailSignIn(email: string, code: string, signal?: AbortSignal): Promise<SessionResponse> {
    const res = await fetch(`${this.apiBase}/v1/auth/email/verify`, {
      method: "POST",
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        ...CLIENT_HEADERS,
      },
      body: JSON.stringify({ email, code, sessionMode: "cookie" }),
      signal,
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "email_verify_failed", err.message, raw);
    }
    const session = zSessionResponse.parse(await res.json());
    this.setSession(session);
    return session;
  }

  async signOut(): Promise<void> {
    try {
      await fetch(`${this.apiBase}/v1/auth/signout`, {
        method: "POST",
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
          ...CLIENT_HEADERS,
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
          ...CLIENT_HEADERS,
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

  // Contact Support (ADR 0054, docs/IDENTIFIERS.md "Support wire"). Signed
  // in: the session plus the support key, so a signed-out conversation moves
  // to the account. Signed out: the support key alone.
  private async supportFetch(path: string, supportKey: string, init: RequestInit = {}): Promise<Response> {
    const headers = { ...(init.headers ?? {}), "X-Septena-Support-Key": supportKey };
    if (this.isAuthenticated) return this.authedFetch(path, { ...init, headers });
    return fetch(`${this.apiBase}${path}`, {
      ...init,
      headers: { ...headers, ...CLIENT_HEADERS },
    });
  }

  async sendSupportMessage(message: SupportOutgoing, supportKey: string): Promise<SupportMessage> {
    const res = await this.supportFetch("/v1/support/messages", supportKey, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(message),
    });
    if (res.status !== 202) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "support_failed", err.message, raw);
    }
    return ((await res.json()) as { message: SupportMessage }).message;
  }

  async supportConversation(supportKey: string): Promise<SupportConversation> {
    const res = await this.supportFetch("/v1/support/messages", supportKey, { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      throw new ApiError(res.status, parseErr(raw).error ?? "support_failed", undefined, raw);
    }
    return (await res.json()) as SupportConversation;
  }

  async markSupportRead(supportKey: string): Promise<void> {
    const res = await this.supportFetch("/v1/support/read", supportKey, { method: "POST" });
    if (!res.ok && res.status !== 204) throw new ApiError(res.status, "support_failed");
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

  /** The account's plan (GET /v1/entitlement). */
  async getEntitlement(): Promise<Entitlement> {
    const res = await this.authedFetch("/v1/entitlement", { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "entitlement_failed", err.message, raw);
    }
    return zEntitlement.parse(await res.json());
  }

  /** The beta checklist (GET /v1/beta, docs/BETA_ONBOARDING_SPEC.md §7). */
  async getBeta(): Promise<BetaState> {
    const res = await this.authedFetch("/v1/beta?platform=web", { method: "GET" });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "beta_failed", err.message, raw);
    }
    return zBetaState.parse(await res.json());
  }

  /** One checklist change (POST /v1/beta/progress). 404: not a tester. */
  async postBetaProgress(body: BetaProgress): Promise<void> {
    const res = await this.authedFetch("/v1/beta/progress", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.status !== 204 && !res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "beta_progress_failed", err.message, raw);
    }
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

  // A new agent key (#86). The key is in this reply only.
  async createAgentKey(name: string): Promise<{ id: string; key: string; name: string; scope: string }> {
    const res = await this.authedFetch("/v1/access/keys", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, access: "write" }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => "");
      const err = parseErr(raw);
      throw new ApiError(res.status, err.error ?? "create_agent_key_failed", err.message, raw);
    }
    return zCreatedAgentKey.parse(await res.json());
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

  // The account and its avatar (#857, backend/src/api/avatar.ts).

  /** GET /v1/account. */
  async getAccount(): Promise<{ userId: string; avatar: Avatar }> {
    const res = await this.authedFetch("/v1/account", { method: "GET" });
    if (!res.ok) throw await apiError(res, "account_failed");
    const body = (await res.json()) as { userId?: unknown; avatar?: unknown };
    const avatar = normalizeAvatar(body.avatar);
    if (typeof body.userId !== "string" || !avatar) throw new ApiError(502, "account_invalid");
    return { userId: body.userId, avatar };
  }

  /**
   * PATCH /v1/account/avatar: initials or one emoji. `applied: false` means a
   * newer edit is on the server; the reply carries that avatar.
   */
  async patchAvatar(body: AvatarPatch): Promise<{ avatar: Avatar; applied: boolean }> {
    const res = await this.authedFetch("/v1/account/avatar", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw await apiError(res, "avatar_failed");
    return parseAvatarReply(await res.json());
  }

  /** PUT /v1/account/avatar: the cropped JPEG. 413: too large. 415: wrong type. */
  async putAvatarPhoto(jpeg: Blob): Promise<{ avatar: Avatar; applied: boolean }> {
    const res = await this.authedFetch("/v1/account/avatar", {
      method: "PUT",
      headers: { "Content-Type": "image/jpeg" },
      body: await jpeg.arrayBuffer(),
    });
    if (!res.ok) throw await apiError(res, "avatar_photo_failed");
    return parseAvatarReply(await res.json());
  }

  /** DELETE /v1/account/avatar: back to initials, the color and typed initials stay. */
  async deleteAvatar(): Promise<Avatar> {
    const res = await this.authedFetch("/v1/account/avatar", { method: "DELETE" });
    if (!res.ok) throw await apiError(res, "avatar_delete_failed");
    return parseAvatarReply(await res.json()).avatar;
  }

  private avatarPhotos = new Map<string, Promise<string>>();

  /** The owner's photo as an object URL, cached by photo id. */
  accountAvatarPhotoUrl(photoId: string): Promise<string> {
    return this.avatarPhoto(`me:${photoId}`, `/v1/account/avatar/photo?v=${encodeURIComponent(photoId)}`);
  }

  /** A shared-project member's photo as an object URL, cached by photo id. */
  memberAvatarPhotoUrl(shareId: string, memberId: string, photoId: string): Promise<string> {
    return this.avatarPhoto(
      `${shareId}/${memberId}:${photoId}`,
      `/v1/shares/${encodeURIComponent(shareId)}/members/${encodeURIComponent(memberId)}/avatar?v=${encodeURIComponent(photoId)}`,
    );
  }

  private avatarPhoto(key: string, path: string): Promise<string> {
    const cached = this.avatarPhotos.get(key);
    if (cached) return cached;
    const load = (async () => {
      const res = await this.authedFetch(path, { method: "GET" });
      if (!res.ok) throw await apiError(res, "avatar_photo_failed");
      return URL.createObjectURL(await res.blob());
    })();
    // A failed load is tried again on the next render that asks for it.
    load.catch(() => this.avatarPhotos.delete(key));
    this.avatarPhotos.set(key, load);
    return load;
  }

  private clearAvatarPhotos(): void {
    for (const p of this.avatarPhotos.values()) {
      p.then((url) => URL.revokeObjectURL(url)).catch(() => {});
    }
    this.avatarPhotos.clear();
  }

  async fetchSkillMarkdown(): Promise<string> {
    const res = await fetch(`${this.apiBase}/skill.md`, { method: "GET" });
    if (!res.ok) {
      throw new ApiError(res.status, "skill_fetch_failed");
    }
    return res.text();
  }
}

/** The PATCH body of `/v1/account/avatar` (backend zAvatarPatchBody). */
export type AvatarPatch =
  | { kind: "initials"; color?: string; initials?: string; updatedAt?: number }
  | { kind: "emoji"; emoji: string; color?: string; initials?: string; updatedAt?: number };

function parseAvatarReply(body: unknown): { avatar: Avatar; applied: boolean } {
  const obj = (body ?? {}) as { avatar?: unknown; applied?: unknown };
  const avatar = normalizeAvatar(obj.avatar);
  if (!avatar) throw new ApiError(502, "avatar_invalid");
  return { avatar, applied: obj.applied !== false };
}

async function apiError(res: Response, fallback: string): Promise<ApiError> {
  const raw = await res.text().catch(() => "");
  const err = parseErr(raw);
  return new ApiError(res.status, err.error ?? fallback, err.message, raw);
}

function parseErr(raw: string): { error?: string; message?: string } {
  try {
    return JSON.parse(raw) as { error?: string; message?: string };
  } catch {
    return {};
  }
}
