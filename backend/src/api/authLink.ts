import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent, sha256Base64Url } from "../util.js";
import { accountStoreFor, type IdentityRow } from "../store/AccountStore.js";
import { hasUsedTrial, markTrialUsed, startTrialOnce } from "../entitlement/entitlement.js";
import { emailSignInEnabled, startEmailSignIn, verifyEmailCodeOnly, zEmailAddress, type EmailFailure } from "./emailSignIn.js";
import { signClaims, verifyClaims } from "./session.js";

// Account identity management, linking, and "no silent linking" collision catch
// (ADR 0047 decisions 5 & 6, issues #171, #637, #643).
//
// - Signed-in users list, add and remove sign-in methods on their account
//   (Settings ▸ Account ▸ Sign-in methods). Removing the last method is refused.
// - When a new provider sign-in (Apple, Google, Microsoft) carries a verified
//   email that already belongs to an existing account, Septena refuses to
//   create a duplicate account. Instead it returns `409 account_exists` with a
//   short-lived signed `linkToken` and emails a 6-digit code to that address.
//   Submitting `{ linkToken, code }` to POST /v1/auth/link/complete attaches
//   the provider to the existing account and signs the user in.

export type FederatedProvider = "apple" | "google" | "microsoft";

const COLLISION_LINK_PREFIX = "sl1";
const OIDC_LINK_START_PREFIX = "sl2";
const LINK_TOKEN_TTL_S = 10 * 60;

const PROVIDER_LABELS: Record<string, string> = {
  apple: "Apple",
  google: "Google",
  microsoft: "Microsoft",
};

export interface LinkedIdentityView {
  /// Opaque stable identifier (the AccountStore key: `email:<addr>` or `<provider>:h_<hash>`).
  id: string;
  provider: string;
  label: string;
  createdAt: number;
}

export interface LinkedIdentitiesPayload {
  identities: LinkedIdentityView[];
  canRemove: boolean;
}

export function formatIdentities(rows: IdentityRow[]): LinkedIdentitiesPayload {
  return {
    identities: rows.map((r) => ({
      id: r.key,
      provider: r.provider,
      label: r.provider === "email" ? r.subject : (PROVIDER_LABELS[r.provider] ?? r.provider),
      createdAt: r.createdAt,
    })),
    canRemove: rows.length > 1,
  };
}

export async function listUserIdentities(env: Env, userId: string): Promise<LinkedIdentitiesPayload> {
  const accounts = accountStoreFor(env);
  if (!accounts) return { identities: [], canRemove: false };
  const rows = await accounts.listIdentitiesForUser(userId);
  return formatIdentities(rows);
}

// ---- shared provider login with no-silent-linking collision catch ----

export interface ProviderLoginInput {
  provider: FederatedProvider;
  subject: string;
  /// Preserves legacy derived `u_` ids for native Apple accounts (ADR 0016).
  preferredUserId?: string;
  email?: string;
  emailVerified?: boolean;
  clientIp?: string | null;
}

export type ProviderLoginOutcome =
  | { outcome: "signed_in"; userId: string; created: boolean }
  | { outcome: "needs_link"; email: string; provider: FederatedProvider; linkToken: string; codeSent: boolean }
  | { outcome: "needs_link_email_off"; email: string; provider: FederatedProvider };

export async function resolveProviderLogin(
  env: Env,
  input: ProviderLoginInput,
): Promise<ProviderLoginOutcome> {
  const accounts = accountStoreFor(env);
  if (!accounts) {
    if (!input.preferredUserId) throw new Error("ACCOUNT_STORE binding missing");
    const trialStarted = await startTrialOnce(env, input.preferredUserId);
    if (trialStarted) logEvent("trial_started", { userId: input.preferredUserId });
    return { outcome: "signed_in", userId: input.preferredUserId, created: trialStarted };
  }

  // 1. Existing identity for this provider subject -> sign right in.
  const existing = await accounts.resolveIdentity(input.provider, input.subject);
  if (existing) {
    await accounts.resolveOrCreateIdentity(input.provider, input.subject, input.preferredUserId);
    return { outcome: "signed_in", userId: existing.userId, created: false };
  }

  // 2. New provider subject: check for email collision (ADR 0047 decision 5).
  const normalizedEmail = input.email?.trim().toLowerCase();
  if (normalizedEmail && input.emailVerified) {
    const emailOwner = await accounts.resolveIdentity("email", normalizedEmail);
    if (emailOwner) {
      if (!emailSignInEnabled(env)) {
        logEvent("auth_collision_blocked", { provider: input.provider, emailSignIn: false });
        return { outcome: "needs_link_email_off", email: normalizedEmail, provider: input.provider };
      }
      const sent = await startEmailSignIn(env, { email: normalizedEmail }, input.clientIp);
      const linkToken = await signClaims(env, COLLISION_LINK_PREFIX, {
        provider: input.provider,
        subject: input.subject,
        email: normalizedEmail,
        userId: emailOwner.userId,
        exp: Math.floor(Date.now() / 1000) + LINK_TOKEN_TTL_S,
      });
      logEvent("auth_collision_link_required", { provider: input.provider, codeSent: sent.ok });
      return {
        outcome: "needs_link",
        email: normalizedEmail,
        provider: input.provider,
        linkToken,
        codeSent: sent.ok,
      };
    }
  }

  // 3. No collision: create the account and grant its one-time 14-day trial.
  const { userId, created } = await accounts.resolveOrCreateIdentity(
    input.provider,
    input.subject,
    input.preferredUserId,
  );
  if (created || input.provider === "apple") {
    const markers: string[] = [];
    if (input.provider === "apple" && input.preferredUserId) {
      markers.push(input.preferredUserId);
    } else {
      markers.push(`p_${await sha256Base64Url(`${input.provider}:${input.subject}`)}`);
    }
    if (normalizedEmail && input.emailVerified) {
      markers.push(`e_${await sha256Base64Url(`email:${normalizedEmail}`)}`);
    }
    let usedBefore = false;
    for (const m of markers) {
      if (await hasUsedTrial(env, m)) { usedBefore = true; break; }
    }
    if (!usedBefore) {
      if (await startTrialOnce(env, userId)) logEvent("trial_started", { userId });
      for (const m of markers) await markTrialUsed(env, m);
    }
  }
  return { outcome: "signed_in", userId, created };
}

// ---- complete collision linking (POST /v1/auth/link/complete) ----

export const zLinkCompleteBody = z.object({
  linkToken: z.string().min(20).max(4_000),
  code: z.string().trim().regex(/^\d{6}$/),
  sessionMode: z.enum(["body", "cookie"]).optional(),
}).strict();

export type CompleteCollisionOutcome =
  | { ok: true; userId: string; provider: string }
  | { ok: false; status: 401 | 409 | 410 | 429 | 503; error: string; attemptsLeft?: number };

export async function completeCollisionLink(
  env: Env,
  body: { linkToken: string; code: string },
  clientIp?: string | null,
): Promise<CompleteCollisionOutcome> {
  const accounts = accountStoreFor(env);
  if (!accounts) return { ok: false, status: 503, error: "unavailable" };

  const claims = await verifyClaims(env, COLLISION_LINK_PREFIX, body.linkToken);
  if (
    !claims ||
    typeof claims.provider !== "string" ||
    typeof claims.subject !== "string" ||
    typeof claims.email !== "string" ||
    typeof claims.userId !== "string"
  ) {
    return { ok: false, status: 410, error: "expired_or_unknown" };
  }

  const checked = await verifyEmailCodeOnly(env, { email: claims.email, code: body.code }, clientIp);
  if (!checked.ok) return checked;

  // Verify the target email identity still belongs to the same account.
  const owner = await accounts.resolveIdentity("email", claims.email);
  if (!owner || owner.userId !== claims.userId) {
    return { ok: false, status: 410, error: "expired_or_unknown" };
  }

  const linked = await accounts.linkIdentity(claims.provider, claims.subject, claims.userId);
  if (!linked.ok) {
    return { ok: false, status: 409, error: "already_linked" };
  }
  logEvent("auth_collision_linked", { ok: true, provider: claims.provider });
  return { ok: true, userId: claims.userId, provider: claims.provider };
}

// ---- signed-in identity linking & removal ----

export const zLinkEmailVerifyBody = z.object({
  email: zEmailAddress,
  code: z.string().trim().regex(/^\d{6}$/),
}).strict();

export type LinkMutationOutcome =
  | { ok: true; created: boolean; identities: LinkedIdentityView[]; canRemove: boolean }
  | EmailFailure
  | { ok: false; status: 404 | 409 | 503; error: string; attemptsLeft?: number };

export async function linkEmailToAccount(
  env: Env,
  userId: string,
  body: { email: string; code: string },
  clientIp?: string | null,
): Promise<LinkMutationOutcome> {
  const accounts = accountStoreFor(env);
  if (!accounts) return { ok: false, status: 503, error: "unavailable" };
  const checked = await verifyEmailCodeOnly(env, body, clientIp);
  if (!checked.ok) return checked;
  return linkProviderToAccount(env, userId, "email", body.email);
}

export async function linkProviderToAccount(
  env: Env,
  userId: string,
  provider: string,
  subject: string,
): Promise<LinkMutationOutcome> {
  const accounts = accountStoreFor(env);
  if (!accounts) return { ok: false, status: 503, error: "unavailable" };
  const res = await accounts.linkIdentity(provider, subject, userId);
  if (!res.ok) {
    logEvent("auth_identity_link", { ok: false, provider, reason: res.reason });
    return { ok: false, status: 409, error: "already_linked" };
  }
  const list = await listUserIdentities(env, userId);
  logEvent("auth_identity_link", { ok: true, provider, created: res.created });
  return { ok: true, created: res.created, ...list };
}

export async function unlinkIdentityFromAccount(
  env: Env,
  userId: string,
  id: string,
): Promise<
  | { ok: true; identities: LinkedIdentityView[]; canRemove: boolean }
  | { ok: false; status: 404 | 409 | 503; error: string }
> {
  const accounts = accountStoreFor(env);
  if (!accounts) return { ok: false, status: 503, error: "unavailable" };
  const res = await accounts.unlinkIdentity(userId, id);
  if (!res.ok) {
    logEvent("auth_identity_unlink", { ok: false, reason: res.reason });
    return res.reason === "last_identity"
      ? { ok: false, status: 409, error: "last_method" }
      : { ok: false, status: 404, error: "not_found" };
  }
  logEvent("auth_identity_unlink", { ok: true });
  return { ok: true, ...formatIdentities(res.remaining) };
}

// ---- signed short-lived token for starting an OIDC link from Settings ----

export async function mintOidcLinkToken(env: Env, userId: string): Promise<string> {
  return signClaims(env, OIDC_LINK_START_PREFIX, {
    userId,
    exp: Math.floor(Date.now() / 1000) + LINK_TOKEN_TTL_S,
  });
}

export async function verifyOidcLinkToken(env: Env, token: string): Promise<string | null> {
  const claims = await verifyClaims(env, OIDC_LINK_START_PREFIX, token);
  return claims && typeof claims.userId === "string" ? claims.userId : null;
}
