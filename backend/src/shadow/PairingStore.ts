import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";

// PairingStore — one Durable Object per pending pairing code, for the
// read-only MCP preview on api.septena.app (see src/shadow/oauth.ts).
//
// The browser's authorize page holds a pending authorization and shows a
// short code. The user enters that code in Septask, which calls
// POST /v1/pair/approve with its own bearer token; that binds the user id to
// the pending authorization. The page polls until it sees the approval, then
// finishes the OAuth redirect. A Durable Object gives the poll and the approve
// one strongly consistent view; the alarm wipes the object at expiry.

export interface PendingAuth {
  /// "connector" (absent on records written before 2026-11-22) finishes the
  /// MCP OAuth redirect; "device" mints an app session for a new device
  /// (ADR 0016, issue #170). Each finish path refuses the other purpose, so a
  /// connector code never mints an app session and a device code never mints
  /// MCP tokens.
  purpose?: "connector" | "device";
  /// Random secret held only in the browser's cookie. Polling and finishing
  /// need it, so knowing the short code alone cannot complete the flow.
  pendingId: string;
  clientId: string;
  clientName?: string;
  redirectUri: string;
  oauthState: string;
  codeChallenge: string;
  expiresAt: number; // ms epoch
}

export interface PairApproval {
  userId: string;
  timeZone?: string;
  /// Connector codes only: the name the user gave the agent, and the agent
  /// (token family id) it replaces. Both land at the token exchange.
  label?: string;
  replaces?: string;
}

export type ApproveOutcome = "ok" | "not_found" | "already_used";
export type PairStatus = "pending" | "approved" | "gone";

export class PairingStore extends DurableObject<Env> {
  private async live(): Promise<PendingAuth | null> {
    const p = await this.ctx.storage.get<PendingAuth>("pending");
    if (!p) return null;
    if (Date.now() > p.expiresAt) {
      await this.ctx.storage.deleteAll();
      return null;
    }
    return p;
  }

  /// False when the code is already held by another live authorization; the
  /// Worker then draws a new code.
  async create(p: PendingAuth): Promise<boolean> {
    if (await this.live()) return false;
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.put("pending", p);
    await this.ctx.storage.setAlarm(p.expiresAt);
    return true;
  }

  /// What the code asks for, without approving it, so the approving app can
  /// show "Sign in on <device>?" or "Connect <client>?" before the user agrees.
  async peek(): Promise<
    | { outcome: "ok"; purpose: "connector" | "device"; clientName?: string; expiresAt: number }
    | { outcome: "not_found" | "already_used" }
  > {
    const p = await this.live();
    if (!p) return { outcome: "not_found" };
    if (await this.ctx.storage.get<PairApproval>("approved")) return { outcome: "already_used" };
    return { outcome: "ok", purpose: p.purpose ?? "connector", clientName: p.clientName, expiresAt: p.expiresAt };
  }

  /// Binds a user to the pending authorization. A code approves once: a
  /// second approval (by anyone) is refused so a code cannot be re-pointed.
  /// `expectedPurpose` is what the user confirmed; a mismatch approves nothing.
  async approve(
    a: PairApproval,
    expectedPurpose?: "connector" | "device",
  ): Promise<{ outcome: ApproveOutcome; clientName?: string; purpose?: "connector" | "device" }> {
    const p = await this.live();
    if (!p) return { outcome: "not_found" };
    const purpose = p.purpose ?? "connector";
    if (expectedPurpose && expectedPurpose !== purpose) return { outcome: "not_found" };
    if (await this.ctx.storage.get<PairApproval>("approved")) return { outcome: "already_used" };
    await this.ctx.storage.put("approved", a);
    return { outcome: "ok", clientName: p.clientName, purpose };
  }

  async status(
    pendingId: string,
    purpose: "connector" | "device" = "connector",
  ): Promise<{ status: PairStatus; clientName?: string; redirectUri?: string }> {
    const p = await this.live();
    if (!p || p.pendingId !== pendingId || (p.purpose ?? "connector") !== purpose) return { status: "gone" };
    const approved = !!(await this.ctx.storage.get<PairApproval>("approved"));
    return { status: approved ? "approved" : "pending", clientName: p.clientName, redirectUri: p.redirectUri };
  }

  /// One-shot: returns the approved authorization and wipes the object.
  async take(
    pendingId: string,
    purpose: "connector" | "device" = "connector",
  ): Promise<{ pending: PendingAuth; approval: PairApproval } | null> {
    const p = await this.live();
    if (!p || p.pendingId !== pendingId || (p.purpose ?? "connector") !== purpose) return null;
    const approval = await this.ctx.storage.get<PairApproval>("approved");
    if (!approval) return null;
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    return { pending: p, approval };
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
