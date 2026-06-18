/**
 * Apple App Attest — shared verifier (GENERIC, reusable).
 *
 * No reports-specific logic lives here: the Feedback worker imports this same
 * module to gate its writes. It proves a request came from the genuine,
 * unmodified app on a real Apple device — anonymous, and without any API key in
 * the (open-source) client.
 *
 * ⚠️ SECURITY STATUS: implemented per Apple's "Validating Apps That Connect to
 * Your Server" spec, but NOT yet validated against a real device's attestation.
 * Validate behind ATTEST_MODE="audit" (verify + log, never reject) on a private
 * staging worker until a real iPhone/iPad/Mac round-trips and the logs show
 * clean passes; production should run with ATTEST_MODE="enforce". The signature
 * encoding details (DER↔P1363) and the dev/prod aaguid are the most likely
 * things to tweak on first device — audit mode surfaces them without breaking
 * writes.
 *
 * Bindings expected on Env: KV `ATTEST` (keyId → {publicKeyRawB64, counter}),
 * KV `CHALLENGES` (challenge → "1", short TTL), KV `RL` (rate-limit buckets).
 * Vars: APP_ATTEST_APP_ID ("TEAMID.bundle.id"), APP_ATTEST_ENV ("development"|"production").
 */

import * as x509 from "@peculiar/x509";
import { decode as cborDecode } from "cbor-x";

export interface AttestEnv {
  ATTEST: KVNamespace;
  CHALLENGES: KVNamespace;
  RL: KVNamespace;
  APP_ATTEST_APP_ID: string;
  APP_ATTEST_ENV?: string;
}

// Apple App Attest Root CA — pinned (https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem)
const APPLE_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const APP_ATTEST_OID = "1.2.840.113635.100.8.2";

// MARK: - Challenges (one-time, short-lived)

export async function issueChallenge(env: AttestEnv): Promise<string> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const challenge = b64url(bytes);
  await env.CHALLENGES.put(challenge, "1", { expirationTtl: 300 });
  return challenge;
}

async function consumeChallenge(env: AttestEnv, challenge: string): Promise<boolean> {
  if (!challenge) return false;
  const hit = await env.CHALLENGES.get(challenge);
  if (!hit) return false;
  await env.CHALLENGES.delete(challenge); // one-time use (replay protection)
  return true;
}

// MARK: - Rate limit (per key; falls back to a caller-supplied id e.g. IP)

export async function rateLimited(env: AttestEnv, id: string, limit = 30, windowSec = 60): Promise<boolean> {
  const bucket = `${id}:${Math.floor(Date.now() / 1000 / windowSec)}`;
  const n = parseInt((await env.RL.get(bucket)) ?? "0", 10) + 1;
  await env.RL.put(bucket, String(n), { expirationTtl: windowSec * 2 });
  return n > limit;
}

// MARK: - Registration (verify attestation, store the public key)

export interface AttestResult { ok: boolean; reason?: string; }

export async function verifyAttestation(
  env: AttestEnv,
  args: { keyId: string; attestationB64: string; challenge: string }
): Promise<AttestResult> {
  try {
    if (!(await consumeChallenge(env, args.challenge))) return { ok: false, reason: "bad challenge" };

    const att = cborDecode(b64ToBytes(args.attestationB64)) as {
      fmt: string; attStmt: { x5c: Uint8Array[] }; authData: Uint8Array;
    };
    if (att.fmt !== "apple-appattest") return { ok: false, reason: "fmt" };

    const [credCertDer, caCertDer] = att.attStmt.x5c;
    const credCert = new x509.X509Certificate(credCertDer);
    const caCert = new x509.X509Certificate(caCertDer);
    const root = new x509.X509Certificate(APPLE_ROOT_CA_PEM);

    // Chain: credCert ← caCert ← Apple root (each signs the next).
    const chainOK =
      (await credCert.verify({ publicKey: await caCert.publicKey.export() })) &&
      (await caCert.verify({ publicKey: await root.publicKey.export() }));
    if (!chainOK) return { ok: false, reason: "chain" };

    // nonce = SHA256(authData ‖ SHA256(challenge)) must equal the cert's
    // App Attest extension value.
    const clientDataHash = await sha256(new TextEncoder().encode(args.challenge));
    const nonce = await sha256(concat(att.authData, clientDataHash));
    const ext = credCert.getExtension(APP_ATTEST_OID);
    if (!ext) return { ok: false, reason: "no ext" };
    if (!bytesEndWith(new Uint8Array(ext.value), nonce)) return { ok: false, reason: "nonce" };

    // authData: rpIdHash == SHA256(appId) for one of the configured app ids
    // (iOS + Mac have different bundle ids → different attestations).
    const rpIdHash = att.authData.slice(0, 32);
    const appIds = env.APP_ATTEST_APP_ID.split(",").map((s) => s.trim()).filter(Boolean);
    const appIdHashes = await Promise.all(appIds.map((a) => sha256(new TextEncoder().encode(a))));
    if (!appIdHashes.some((h) => bytesEqual(rpIdHash, h))) return { ok: false, reason: "rpId" };

    // Extract + store the credential public key (P-256, raw uncompressed point).
    const raw = new Uint8Array((await credCert.publicKey.rawData) as ArrayBuffer); // SPKI
    const pub = await crypto.subtle.importKey("spki", raw,
      { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
    const rawPoint = new Uint8Array((await crypto.subtle.exportKey("raw", pub)) as ArrayBuffer);
    await env.ATTEST.put(args.keyId, JSON.stringify({ k: b64(rawPoint), c: 0 }));
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: `err:${(e as Error).message}` };
  }
}

// MARK: - Assertion (verify a write came from a registered key)

export async function verifyAssertion(
  env: AttestEnv,
  args: { keyId: string; assertionB64: string; challenge: string; body: Uint8Array }
): Promise<AttestResult> {
  try {
    if (!(await consumeChallenge(env, args.challenge))) return { ok: false, reason: "bad challenge" };
    const stored = await env.ATTEST.get(args.keyId);
    if (!stored) return { ok: false, reason: "unknown key" };
    const { k, c } = JSON.parse(stored) as { k: string; c: number };

    const assertion = cborDecode(b64ToBytes(args.assertionB64)) as {
      signature: Uint8Array; authenticatorData: Uint8Array;
    };

    // clientDataHash = SHA256(body ‖ challenge); nonce = SHA256(authData ‖ clientDataHash).
    const clientDataHash = await sha256(concat(args.body, new TextEncoder().encode(args.challenge)));
    const nonce = await sha256(concat(assertion.authenticatorData, clientDataHash));

    const pub = await crypto.subtle.importKey("raw", b64ToBytes(k),
      { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const sigRaw = derToP1363(assertion.signature);
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sigRaw, nonce);
    if (!valid) return { ok: false, reason: "sig" };

    // Counter must strictly increase (replay/clone protection).
    const counter = readUint32(assertion.authenticatorData, 33);
    if (counter <= c) return { ok: false, reason: "counter" };
    await env.ATTEST.put(args.keyId, JSON.stringify({ k, c: counter }));
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: `err:${(e as Error).message}` };
  }
}

// MARK: - helpers

async function sha256(b: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", b));
}
function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length); out.set(a); out.set(b, a.length); return out;
}
function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i]; return d === 0;
}
function bytesEndWith(hay: Uint8Array, needle: Uint8Array): boolean {
  if (hay.length < needle.length) return false;
  return bytesEqual(hay.slice(hay.length - needle.length), needle);
}
function readUint32(b: Uint8Array, off: number): number {
  return (b[off] << 24 | b[off + 1] << 16 | b[off + 2] << 8 | b[off + 3]) >>> 0;
}
function b64(b: Uint8Array): string { return btoa(String.fromCharCode(...b)); }
function b64url(b: Uint8Array): string { return b64(b).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
function b64ToBytes(s: string): Uint8Array {
  const norm = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(norm); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out;
}
/** DER-encoded ECDSA signature → fixed 64-byte r‖s (P1363) for WebCrypto. */
function derToP1363(der: Uint8Array): Uint8Array {
  let i = 2; // skip SEQUENCE header
  if (der[1] & 0x80) i += der[1] & 0x7f; // long-form length
  function readInt(): Uint8Array {
    // der[i] === 0x02 (INTEGER)
    let len = der[i + 1]; let start = i + 2;
    while (der[start] === 0x00 && len > 1) { start++; len--; } // strip leading zero
    const v = der.slice(start, start + len); i = start + len; return v;
  }
  const r = readInt(); const s = readInt();
  const out = new Uint8Array(64);
  out.set(r, 32 - r.length); out.set(s, 64 - s.length);
  return out;
}
