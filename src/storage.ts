import type { Env } from "./env.js";
import { decrypt, encrypt } from "./crypto.js";

// KV-backed records. All keys are random IDs (not deterministic from user
// data) so a KV listing leak doesn't reveal anything about who has signed up.

// ---- Mid-OAuth state ----
// Saved when we redirect the user to Apple sign-in. Recovered via a cookie
// when Apple redirects back. TTL short — a real user finishes in <2 min.

export interface OAuthState {
  oauthState: string;          // claude.ai's state, returned verbatim
  codeChallenge: string;       // PKCE
  codeChallengeMethod: "S256"; // we only accept S256
  clientId: string;
  redirectUri: string;
  createdAt: number;
}

const STATE_TTL_SECONDS = 600;

export async function putState(env: Env, id: string, s: OAuthState): Promise<void> {
  await env.STATE.put(`state:${id}`, JSON.stringify(s), { expirationTtl: STATE_TTL_SECONDS });
}

export async function takeState(env: Env, id: string): Promise<OAuthState | null> {
  const raw = await env.STATE.get(`state:${id}`);
  if (!raw) return null;
  await env.STATE.delete(`state:${id}`);
  return JSON.parse(raw) as OAuthState;
}

/// Non-destructive read — used by /oauth/continue, which only checks
/// the in-flight state exists before bouncing to Apple. The Apple
/// callback handler later does the destructive `takeState`.
export async function peekState(env: Env, id: string): Promise<OAuthState | null> {
  const raw = await env.STATE.get(`state:${id}`);
  return raw ? (JSON.parse(raw) as OAuthState) : null;
}

// ---- Auth codes ----
// Issued on Apple callback, exchanged at /oauth/token. Short TTL.

export interface AuthCode {
  ckWebAuthToken: string;      // plaintext here; encrypted on promotion to access token
  codeChallenge: string;
  clientId: string;
  redirectUri: string;
}

const CODE_TTL_SECONDS = 300;

export async function putCode(env: Env, code: string, c: AuthCode): Promise<void> {
  await env.STATE.put(`code:${code}`, JSON.stringify(c), { expirationTtl: CODE_TTL_SECONDS });
}

export async function takeCode(env: Env, code: string): Promise<AuthCode | null> {
  const raw = await env.STATE.get(`code:${code}`);
  if (!raw) return null;
  await env.STATE.delete(`code:${code}`);
  return JSON.parse(raw) as AuthCode;
}

// ---- Access tokens ----
// Long-lived. CKWebAuthToken is encrypted with TOKEN_ENC_KEY.

export interface AccessTokenRecord {
  ckWebAuthTokenEnc: string;   // AES-GCM envelope
  clientId: string;
  createdAt: number;
  lastUsedAt: number;
}

export async function putAccessToken(
  env: Env,
  accessToken: string,
  ckWebAuthToken: string,
  clientId: string,
): Promise<void> {
  const enc = await encrypt(ckWebAuthToken, env.TOKEN_ENC_KEY);
  const rec: AccessTokenRecord = {
    ckWebAuthTokenEnc: enc,
    clientId,
    createdAt: Date.now(),
    lastUsedAt: Date.now(),
  };
  await env.TOKENS.put(`token:${accessToken}`, JSON.stringify(rec));
}

export async function getCkTokenForAccessToken(
  env: Env,
  accessToken: string,
): Promise<string | null> {
  const raw = await env.TOKENS.get(`token:${accessToken}`);
  if (!raw) return null;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  return decrypt(rec.ckWebAuthTokenEnc, env.TOKEN_ENC_KEY);
}

// ---- Dynamic client registrations ----
// Per MCP spec, clients (e.g. claude.ai) self-register before OAuth.

export interface ClientRecord {
  clientId: string;
  redirectUris: string[];
  name?: string;
  createdAt: number;
}

export async function putClient(env: Env, c: ClientRecord): Promise<void> {
  await env.CLIENTS.put(`client:${c.clientId}`, JSON.stringify(c));
}

export async function getClient(env: Env, clientId: string): Promise<ClientRecord | null> {
  const raw = await env.CLIENTS.get(`client:${clientId}`);
  return raw ? (JSON.parse(raw) as ClientRecord) : null;
}
