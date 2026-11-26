import type { StoreSnapshot } from "../types";

// Signing in with another account (#575). The tasks on this device belong to
// the account stored with them. When a new session is for a different user,
// the device asks before it removes them — unless there is nothing to remove.
// Same rule as Apple's `TaskSyncEngine.signIn` (`accountSwitchSummary`).

/** What a sign-in with another account would remove from this device. */
export interface AccountSwitchSummary {
  /** Tasks on this device, finished and deleted ones included. */
  tasks: number;
  /** Changes in the outbox that the previous account never received. */
  unsent: number;
}

export type AccountSwitchDecision =
  /** No stored account, or the same account: keep the local data. */
  | { kind: "keep" }
  /** Another account, and nothing local to lose: wipe without asking. */
  | { kind: "wipe" }
  /** Another account with local data: ask the user first. */
  | { kind: "ask"; summary: AccountSwitchSummary };

export function decideAccountSwitch(
  existing: Pick<StoreSnapshot, "userId" | "tasks" | "outbox">,
  userId: string,
): AccountSwitchDecision {
  // No stored id (the first sign-in on this device): keep the local data.
  if (!existing.userId || existing.userId === userId) return { kind: "keep" };
  const summary: AccountSwitchSummary = {
    tasks: existing.tasks.filter((t) => t.kind !== "heading").length,
    unsent: existing.outbox.length,
  };
  if (summary.tasks === 0 && summary.unsent === 0) return { kind: "wipe" };
  return { kind: "ask", summary };
}

/**
 * Thrown by `WebSyncEngine.start` when the session is for another account and
 * the device holds that account's data, but the caller did not confirm the
 * replace. It fails closed: nothing is removed.
 */
export class AccountSwitchRequiredError extends Error {
  readonly summary: AccountSwitchSummary;
  constructor(summary: AccountSwitchSummary) {
    super("Another account signed in; confirm before replacing this device's tasks.");
    this.name = "AccountSwitchRequiredError";
    this.summary = summary;
  }
}
