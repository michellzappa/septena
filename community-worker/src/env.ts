import type { AttestEnv } from "./attest";

export interface Env extends AttestEnv {
  DB: D1Database;
  USER_HASH_SALT?: string;
  TELEMETRY_HASH_SALT?: string;
  ADMIN_DASHBOARD_TOKEN?: string;
  ADMIN_EMAILS?: string;
  ATTEST_MODE?: string;
}

export interface CurrentUser {
  userHash: string;
  role: "user" | "maintainer" | "moderator";
  isBanned: boolean;
}
