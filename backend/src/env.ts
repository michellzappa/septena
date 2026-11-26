// Worker bindings — keep in sync with wrangler.toml.

import type { TaskStore } from "./store/TaskStore.js";
import type { ProjectStore } from "./store/ProjectStore.js";
import type { AccountStore } from "./store/AccountStore.js";
import type { PairingStore } from "./shadow/PairingStore.js";

export interface Env {
  // Vars (public-ish, set in wrangler.toml)
  API_PUBLIC_URL: string; // task backend origin (api.septena.app); also serves the task MCP connector
  APPLE_AUDIENCES: string; // comma-separated bundle ids allowed as SIWA `aud`
  // Sync subscription (docs/SYNC_SUBSCRIPTION_SPEC.md §6). "true" blocks
  // unentitled sync with 402; anything else only logs what it would block.
  ENTITLEMENT_ENFORCE: string;
  APPLE_IAP_BUNDLE_IDS: string;    // comma-separated bundle ids whose purchases count
  APPLE_IAP_ENVIRONMENTS: string;  // comma-separated: Production, Sandbox
  /// Comma-separated browser origins allowed to call /v1/* with credentials
  /// (docs/WEB_CLIENT_SPEC.md §4–§5), e.g. "https://web.septena.app".
  WEB_ALLOWED_ORIGINS?: string;
  /// Optional. "true" answers every request except /health and /v1/admin/*
  /// with 503, for the account move's copy window (docs/CLOUDFLARE_ACCOUNT_MOVE.md).
  /// The apps keep their changes in the outbox and retry.
  MAINTENANCE?: string;

  // Secrets (set via `wrangler secret put`)
  SESSION_SIGNING_KEY: string; // 32-byte base64; signs access and refresh tokens
  /// Optional. The key before the current one. Set it while the key changes,
  /// so live sessions keep working (backend/README.md).
  SESSION_SIGNING_KEY_PREVIOUS?: string;
  /// Optional. Unset = the /v1/admin routes answer 404. Grants entitlements.
  ADMIN_TOKEN?: string;
  /// The admin page at /admin (src/admin/). It answers 404 until all three are
  /// set: the Cloudflare Access team domain, the Access application's audience
  /// tag, and the comma-separated emails that may open it.
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  ADMIN_EMAILS?: string;
  /// "true" issues the signed tokens of ADR 0040 (src/api/session.ts). Anything
  /// else still issues the KV tokens, and accepts both.
  SIGNED_SESSIONS?: string;
  /// Optional APNs provider key (.p8 PEM) and identifiers for agent question pushes (F1b #213).
  /// When any of APNS_KEY / APNS_KEY_ID / APNS_TEAM_ID is unset, pushes no-op cleanly.
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  /// Optional bundle id override for `apns-topic` (defaults to `com.septena.tasks`).
  APNS_BUNDLE_ID?: string;
  /// Optional global APNs host override ("true" = sandbox, "false" = prod; unset = per-token).
  APNS_SANDBOX?: string;

  /// Email sign-in (ADR 0016, #169). "true" turns it on; it stays off until
  /// Terms of Use and the privacy copy ship (#564). Needs the EMAIL binding.
  EMAIL_SIGNIN?: string;
  /// Cloudflare Email Service send binding (septena.app is onboarded).
  EMAIL?: SendEmail;

  /// Directory reviewer access (ADR 0055, src/shadow/reviewer.ts). The pairing
  /// page offers the demo account REVIEWER_ACCOUNT_ID to whoever types
  /// REVIEWER_CODE, until REVIEWER_MODE_UNTIL (optional ISO date). Any one
  /// unset or malformed turns it off. All three are secrets.
  REVIEWER_CODE?: string;
  REVIEWER_ACCOUNT_ID?: string;
  REVIEWER_MODE_UNTIL?: string;
  /// The OpenAI apps directory's domain verification token, served as plain
  /// text at /.well-known/openai-apps-challenge. Unset: that path is 404.
  OPENAI_APPS_CHALLENGE?: string;

  // KV namespaces
  STATE: KVNamespace;    // short-lived OAuth state (src/shadow/oauth.ts)
  TOKENS: KVNamespace;   // MCP grants: access and refresh tokens (src/shadow/tokens.ts)
  CLIENTS: KVNamespace;  // DCR client registrations

  // Task backend (docs/SEPTASK_BACKEND.md in the app repo)
  TASK_STORE: DurableObjectNamespace<TaskStore>; // one object per user
  /// Global identity table (`provider:subject` -> `userId`, ADR 0016 #168).
  /// Bound in wrangler.toml; optional on Env so isolated unit tests need not wire it.
  ACCOUNT_STORE?: DurableObjectNamespace<AccountStore>;
  /// One object per shared project (ADR 0004). Optional so isolated unit tests
  /// need not wire it.
  PROJECT_STORE?: DurableObjectNamespace<ProjectStore>;
  /// Website signups (septena-site). The admin page reads it; nothing here writes.
  SIGNUPS?: D1Database;
  ATTACHMENTS: R2Bucket;                         // attachment bytes, u/{userId}/att/{id}
  PAIRING: DurableObjectNamespace<PairingStore>; // one object per pending app-pairing code (src/shadow/)
}
