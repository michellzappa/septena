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

  // KV namespaces
  STATE: KVNamespace;    // mid-OAuth state, short TTL
  TOKENS: KVNamespace;   // access_token → encrypted ckWebAuthToken, long-lived
  CLIENTS: KVNamespace;  // DCR client registrations
}
