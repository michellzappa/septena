// Worker bindings — keep in sync with wrangler.toml.

import type { TaskStore } from "./store/TaskStore.js";
import type { PairingStore } from "./shadow/PairingStore.js";

export interface Env {
  // Vars (public-ish, set in wrangler.toml)
  CK_CONTAINER: string;
  CK_ENVIRONMENT: "development" | "production";
  CK_ZONE: string;
  PUBLIC_URL: string;     // live connector origin (mcp.septena.app)
  API_PUBLIC_URL: string; // task backend origin (api.septena.app); also hosts the read-only MCP preview
  APPLE_AUDIENCES: string; // comma-separated bundle ids allowed as SIWA `aud`

  // Secrets (set via `wrangler secret put`)
  CK_API_TOKEN: string;
  TOKEN_ENC_KEY: string;
  SESSION_SIGNING_KEY: string; // 32-byte base64; signs task-backend access tokens

  // KV namespaces
  STATE: KVNamespace;    // mid-OAuth state, short TTL
  TOKENS: KVNamespace;   // access_token → encrypted ckWebAuthToken, long-lived
  CLIENTS: KVNamespace;  // DCR client registrations

  // Task backend (docs/SEPTASK_BACKEND.md in the app repo)
  TASK_STORE: DurableObjectNamespace<TaskStore>; // one object per user
  ATTACHMENTS: R2Bucket;                         // attachment bytes, u/{userId}/att/{id}
  PAIRING: DurableObjectNamespace<PairingStore>; // one object per pending app-pairing code (src/shadow/)
}
