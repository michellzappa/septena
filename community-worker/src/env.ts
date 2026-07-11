import type { AccessEnv } from "./access";
import type { AttestEnv } from "./attest";

export interface Env extends AttestEnv, AccessEnv {
  DB: D1Database;
  USER_HASH_SALT?: string;
  TELEMETRY_HASH_SALT?: string;
  ADMIN_DASHBOARD_TOKEN?: string;
  ADMIN_EMAILS?: string;
  ATTEST_MODE?: string;
  // Sign in with Apple — the App-Attest substitute for native macOS (see apple.ts).
  // Secret used to HMAC-sign session tokens; falls back to USER_HASH_SALT if unset.
  SESSION_SIGNING_KEY?: string;
  // Override for accepted identity-token `aud` values; defaults to APP_ATTEST_APP_ID
  // with the team prefix stripped.
  SIWA_BUNDLE_IDS?: string;
}

export interface CurrentUser {
  userHash: string;
  role: "user" | "maintainer" | "moderator";
  isBanned: boolean;
}
