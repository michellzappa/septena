export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

// Public, cacheable GET responses (the website roadmap board). Permissive CORS
// so it can be fetched from the browser too; edge-cached briefly to stay cheap.
export function publicJson(value: unknown, maxAgeSeconds = 300): Response {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": `public, max-age=${maxAgeSeconds}, s-maxage=${maxAgeSeconds}`,
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, OPTIONS",
    },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204 });
}

export function notFound(): Response {
  return json({ error: "not_found" }, 404);
}

export async function readJson<T>(req: Request, maxBytes = 16_384): Promise<{ data?: T; bytes: Uint8Array; error?: Response }> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.byteLength > maxBytes) return { bytes, error: json({ error: "body_too_large" }, 413) };
  try {
    const text = new TextDecoder().decode(bytes);
    return { bytes, data: text.length ? JSON.parse(text) as T : {} as T };
  } catch {
    return { bytes, error: json({ error: "bad_json" }, 400) };
  }
}
