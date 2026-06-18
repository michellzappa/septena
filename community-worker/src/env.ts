import type { AttestEnv } from "./attest";

export interface Env extends AttestEnv {
  DB: D1Database;
  USER_HASH_SALT?: string;
  ATTEST_MODE?: string;
}

export interface CurrentUser {
  userHash: string;
  role: "user" | "maintainer" | "moderator";
  isBanned: boolean;
}
