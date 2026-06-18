export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
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
