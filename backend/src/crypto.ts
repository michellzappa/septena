// AES-GCM envelope encryption for ckWebAuthTokens stored in KV.
//
// Workers KV is already encrypted at rest by Cloudflare, but adding an
// application-layer key means a KV leak alone isn't enough — the attacker
// would also need TOKEN_ENC_KEY (a Worker secret). Rotating TOKEN_ENC_KEY
// invalidates all stored tokens at once; users re-auth.

const ALGO = "AES-GCM";
const IV_BYTES = 12;

async function importKey(rawBase64: string): Promise<CryptoKey> {
  const raw = Uint8Array.from(atob(rawBase64), (c) => c.charCodeAt(0));
  if (raw.length !== 32) {
    throw new Error(`TOKEN_ENC_KEY must decode to 32 bytes, got ${raw.length}`);
  }
  return crypto.subtle.importKey("raw", raw, ALGO, false, ["encrypt", "decrypt"]);
}

export async function encrypt(plaintext: string, keyB64: string): Promise<string> {
  const key = await importKey(keyB64);
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: ALGO, iv },
      key,
      new TextEncoder().encode(plaintext),
    ),
  );
  const combined = new Uint8Array(iv.length + ct.length);
  combined.set(iv, 0);
  combined.set(ct, iv.length);
  return btoa(String.fromCharCode(...combined));
}

export async function decrypt(envelopeB64: string, keyB64: string): Promise<string> {
  const key = await importKey(keyB64);
  const combined = Uint8Array.from(atob(envelopeB64), (c) => c.charCodeAt(0));
  const iv = combined.slice(0, IV_BYTES);
  const ct = combined.slice(IV_BYTES);
  const pt = await crypto.subtle.decrypt({ name: ALGO, iv }, key, ct);
  return new TextDecoder().decode(pt);
}
