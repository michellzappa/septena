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

  /// Binds a user to the pending authorization. A code approves once: a
  /// second approval (by anyone) is refused so a code cannot be re-pointed.
  async approve(a: PairApproval): Promise<{ outcome: ApproveOutcome; clientName?: string }> {
    const p = await this.live();
    if (!p) return { outcome: "not_found" };
    if (await this.ctx.storage.get<PairApproval>("approved")) return { outcome: "already_used" };
    await this.ctx.storage.put("approved", a);
    return { outcome: "ok", clientName: p.clientName };
  }

  async status(pendingId: string): Promise<{ status: PairStatus; clientName?: string; redirectUri?: string }> {
    const p = await this.live();
    if (!p || p.pendingId !== pendingId) return { status: "gone" };
    const approved = !!(await this.ctx.storage.get<PairApproval>("approved"));
    return { status: approved ? "approved" : "pending", clientName: p.clientName, redirectUri: p.redirectUri };
  }

  /// One-shot: returns the approved authorization and wipes the object.
  async take(pendingId: string): Promise<{ pending: PendingAuth; approval: PairApproval } | null> {
    const p = await this.live();
    if (!p || p.pendingId !== pendingId) return null;
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
