import { fromBase64Url, sha256Base64Url } from "../util.js";

// Verifies a native Sign in with Apple identity token (a JWT signed by Apple)
// and returns the stable user id (`sub`). `sub` is per developer team, so
// Septena and Septask on every platform see the same value for one person.
//
// Replay guard: the app sends Apple the SHA-256 of a one-time raw nonce and
// sends us the raw nonce; the token's `nonce` claim must match its hash.

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
const KEYS_TTL_MS = 60 * 60 * 1000;
const CLOCK_SKEW_S = 60;

interface AppleJwk extends JsonWebKey {
  kid: string;
}

let keyCache: { at: number; keys: AppleJwk[] } | null = null;

async function appleKeys(forceRefresh: boolean): Promise<AppleJwk[]> {
  if (!forceRefresh && keyCache && Date.now() - keyCache.at < KEYS_TTL_MS) return keyCache.keys;
  const res = await fetch(APPLE_KEYS_URL);
  if (!res.ok) throw new Error(`apple keys fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys: AppleJwk[] };
  keyCache = { at: Date.now(), keys: body.keys };
  return body.keys;
}

function decodePart<T>(part: string): T {
  return JSON.parse(new TextDecoder().decode(fromBase64Url(part))) as T;
}

export class AppleIdentityError extends Error {}

export async function verifyAppleIdentityToken(
  token: string,
  rawNonce: string,
  audiences: string[],
): Promise<{ sub: string }> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new AppleIdentityError("malformed token");
  const [h, p, s] = parts;
  const header = decodePart<{ alg: string; kid: string }>(h);
  if (header.alg !== "RS256") throw new AppleIdentityError("unexpected alg");

  let jwk = (await appleKeys(false)).find((k) => k.kid === header.kid);
  // Apple rotates keys; a kid we have not seen means our cache is stale.
  if (!jwk) jwk = (await appleKeys(true)).find((k) => k.kid === header.kid);
  if (!jwk) throw new AppleIdentityError("unknown signing key");

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    fromBase64Url(s),
    new TextEncoder().encode(`${h}.${p}`),
  );
  if (!ok) throw new AppleIdentityError("bad signature");

  const claims = decodePart<{ iss: string; aud: string; exp: number; iat: number; sub: string; nonce?: string }>(p);
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== APPLE_ISSUER) throw new AppleIdentityError("bad issuer");
  if (!audiences.includes(claims.aud)) throw new AppleIdentityError("bad audience");
  if (claims.exp < now - CLOCK_SKEW_S) throw new AppleIdentityError("expired");
  if (claims.iat > now + CLOCK_SKEW_S) throw new AppleIdentityError("issued in the future");
  if (!claims.sub) throw new AppleIdentityError("no subject");
  // Apple echoes the nonce the app passed, which is the hex SHA-256 of the
  // raw nonce (Apple's sample code), so compare against hex.
  if (!claims.nonce || claims.nonce !== (await sha256Hex(rawNonce))) {
    throw new AppleIdentityError("nonce mismatch");
  }
  return { sub: claims.sub };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Our user id. Derived, not Apple's raw `sub`, so the id namespace can take
/// another sign-in provider later without a collision.
export async function userIdForAppleSub(sub: string): Promise<string> {
  return `u_${await sha256Base64Url(`apple:${sub}`)}`;
}
