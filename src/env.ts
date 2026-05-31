// Worker bindings — keep in sync with wrangler.toml.

export interface Env {
  // Vars (public-ish, set in wrangler.toml)
  CK_CONTAINER: string;
  CK_ENVIRONMENT: "development" | "production";
  CK_ZONE: string;
  PUBLIC_URL: string;

  // Secrets (set via `wrangler secret put`)
  CK_API_TOKEN: string;
  TOKEN_ENC_KEY: string;
  // Shared secret the iOS app presents when pushing a freshly-minted
  // ckWebAuthToken to POST /internal/ck-token. The app holds durable native
  // CloudKit auth, so it re-mints web tokens (CKFetchWebAuthTokenOperation)
  // and keeps the gateway supplied — making expiry invisible to the user.
  APP_INGEST_SECRET: string;

  // KV namespaces
  STATE: KVNamespace;    // mid-OAuth state, short TTL
  TOKENS: KVNamespace;   // access_token → encrypted ckWebAuthToken, long-lived
  CLIENTS: KVNamespace;  // DCR client registrations
}
