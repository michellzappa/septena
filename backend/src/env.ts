// Worker bindings — keep in sync with wrangler.toml.

import type { TaskStore } from "./store/TaskStore.js";
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
  /// Optional. "true" answers every request except /health and /v1/admin/*
  /// with 503, for the account move's copy window (docs/CLOUDFLARE_ACCOUNT_MOVE.md).
  /// The apps keep their changes in the outbox and retry.
  MAINTENANCE?: string;

  // Secrets (set via `wrangler secret put`)
  SESSION_SIGNING_KEY: string; // 32-byte base64; signs task-backend access tokens
  /// Optional. Unset = the /v1/admin routes answer 404. Grants entitlements.
  ADMIN_TOKEN?: string;

  // KV namespaces
  STATE: KVNamespace;    // short-lived OAuth state (src/shadow/oauth.ts)
  TOKENS: KVNamespace;   // MCP grants: access and refresh tokens (src/shadow/tokens.ts)
  CLIENTS: KVNamespace;  // DCR client registrations

  // Task backend (docs/SEPTASK_BACKEND.md in the app repo)
  TASK_STORE: DurableObjectNamespace<TaskStore>; // one object per user
  /// Global identity table (`provider:subject` -> `userId`, ADR 0016 #168).
  /// Bound in wrangler.toml; optional on Env so isolated unit tests need not wire it.
  ACCOUNT_STORE?: DurableObjectNamespace<AccountStore>;
  ATTACHMENTS: R2Bucket;                         // attachment bytes, u/{userId}/att/{id}
  PAIRING: DurableObjectNamespace<PairingStore>; // one object per pending app-pairing code (src/shadow/)
}
