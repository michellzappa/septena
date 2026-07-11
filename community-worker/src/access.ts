/**
 * Cloudflare Access JWT verification.
 *
 * Access injects `CF-Access-Authenticated-User-Email` as a PLAIN request
 * header — any client that reaches the worker without going through Access
 * (workers.dev, a direct route, or simply a curl that sets the header) can
 * spoof it. The only trustworthy identity signal is the
 * `CF-Access-Jwt-Assertion` JWT, verified against the team's public keys
 * (https://<team-domain>/cdn-cgi/access/certs). The email is read from the
 * verified JWT payload, never from the header.
 *
 * Both vars must be set for this path to work; unset = the Access path is
 * disabled (fail closed) and only the dashboard token authorizes /admin.
 */

export interface AccessEnv {
  /** Access team domain, e.g. "myteam.cloudflareaccess.com". */
  ACCESS_TEAM_DOMAIN?: string;
  /** The Access application's audience (AUD) tag. */
  ACCESS_AUD?: string;
}

interface AccessJwk {
  kid?: string;
  kty: string;
  e: string;
  n: string;
}

// Module-level JWKS cache; isolates are recycled often enough that a plain
// timestamped cache (no invalidation beyond kid-miss refetch) is sufficient.
let jwksCache: { keys: AccessJwk[]; fetchedAt: number } | null = null;
const JWKS_TTL_MS = 60 * 60 * 1000;
const CLOCK_SKEW_SEC = 60;

export async function verifyAccessJwt(
  env: AccessEnv,
  jwt: string,
): Promise<{ ok: true; email: string } | { ok: false; reason: string }> {
  const teamDomain = env.ACCESS_TEAM_DOMAIN?.trim();
  const aud = env.ACCESS_AUD?.trim();
  if (!teamDomain || !aud) return { ok: false, reason: "access not configured" };

  try {
    const parts = jwt.split(".");
    if (parts.length !== 3) return { ok: false, reason: "malformed" };
    const header = JSON.parse(decodeSegment(parts[0])) as { alg?: string; kid?: string };
    if (header.alg !== "RS256") return { ok: false, reason: "alg" };

    const payload = JSON.parse(decodeSegment(parts[1])) as {
      aud?: string | string[];
      iss?: string;
      exp?: number;
      nbf?: number;
      email?: string;
    };
    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.exp !== "number" || payload.exp < now - CLOCK_SKEW_SEC) {
      return { ok: false, reason: "expired" };
    }
    if (typeof payload.nbf === "number" && payload.nbf > now + CLOCK_SKEW_SEC) {
      return { ok: false, reason: "not yet valid" };
    }
    if (payload.iss !== `https://${teamDomain}`) return { ok: false, reason: "iss" };
    const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!audiences.includes(aud)) return { ok: false, reason: "aud" };
    const email = payload.email?.trim().toLowerCase();
    if (!email) return { ok: false, reason: "no email claim" };

    const key = await signingKey(teamDomain, header.kid);
    if (!key) return { ok: false, reason: "unknown kid" };
    const data = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", key, b64urlToBytes(parts[2]), data,
    );
    if (!valid) return { ok: false, reason: "sig" };

    return { ok: true, email };
  } catch (e) {
    return { ok: false, reason: `err:${(e as Error).message}` };
  }
}

async function signingKey(teamDomain: string, kid?: string): Promise<CryptoKey | null> {
  const fresh = jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS;
  let jwk = fresh ? findKey(jwksCache!.keys, kid) : null;
  if (!jwk) {
    // Stale cache or unknown kid (key rotation) → refetch once.
    const res = await fetch(`https://${teamDomain}/cdn-cgi/access/certs`);
    if (!res.ok) return null;
    const body = (await res.json()) as { keys?: AccessJwk[] };
    jwksCache = { keys: body.keys ?? [], fetchedAt: Date.now() };
    jwk = findKey(jwksCache.keys, kid);
  }
  if (!jwk) return null;
  return crypto.subtle.importKey(
    "jwk",
    { kty: "RSA", e: jwk.e, n: jwk.n },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
}

function findKey(keys: AccessJwk[], kid?: string): AccessJwk | null {
  return keys.find((k) => k.kty === "RSA" && (!kid || k.kid === kid)) ?? null;
}

function decodeSegment(b64url: string): string {
  return new TextDecoder().decode(b64urlToBytes(b64url));
}

function b64urlToBytes(s: string): Uint8Array {
  const norm = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(norm);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
