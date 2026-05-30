export function randomId(bytes = 32): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return base64url(buf);
}

export function base64url(buf: Uint8Array): string {
  return btoa(String.fromCharCode(...buf))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

export async function sha256Base64Url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return base64url(new Uint8Array(digest));
}

// Structured single-line log. One JSON object per event so `wrangler tail`
// (and any log drain) can be grep'd/filtered by `evt`. Kept deliberately
// terse — never log token values, only their shape/age.
export function logEvent(evt: string, fields: Record<string, unknown> = {}): void {
  try {
    console.log(JSON.stringify({ evt, ...fields }));
  } catch {
    console.log(JSON.stringify({ evt, logError: "unserializable fields" }));
  }
}

export function readCookie(req: Request, name: string): string | null {
  const header = req.headers.get("Cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, ...rest] = part.trim().split("=");
    if (k === name) return decodeURIComponent(rest.join("="));
  }
  return null;
}
