import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { accountStoreFor } from "../store/AccountStore.js";

// The beta grant at sign-in (ADR 0064). Its own module, because the sign-in
// code imports it: a static import of the plan-link code from here closes an
// import loop through the pairing code back into sign-in.

/// Claims the tester's plan link for this account when the signed-in email
/// is a tester's. The link's one use makes the first account win. Never
/// throws: a sign-in must not fail on this.
export async function grantBetaAtSignIn(env: Env, userId: string, email: string | undefined, verified: boolean | undefined): Promise<void> {
  if (!email || !verified) return;
  try {
    const accounts = accountStoreFor(env);
    const tester = accounts ? await accounts.betaTester(email.trim().toLowerCase()) : null;
    if (!tester || tester.ascState !== "invited" || tester.grantedUserId || !tester.planLinkHash) return;
    const { claimPlusLink } = await import("./plusLinks.js");
    const claim = await claimPlusLink(env, tester.planLinkHash, userId, { atSignIn: true });
    if (claim) logEvent("beta_granted", { userId, via: "email" });
  } catch (e) {
    logEvent("beta_grant_failed", { error: String(e) });
  }
}
