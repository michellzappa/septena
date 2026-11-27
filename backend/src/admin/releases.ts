import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";

// Mac downloads for the admin page: the download counts of the Mac releases
// on GitHub (docs/RELEASING-MAC.md). The repo is public, but GitHub limits
// calls without a token per IP, and Workers share their IPs, so the call can
// fail with 403. With the optional GITHUB_TOKEN secret (read-only) it does
// not. Cached in KV for an hour; the last good answer is kept without expiry
// and shown when GitHub does not answer.

const URL_RELEASES = "https://api.github.com/repos/michellzappa/septena/releases?per_page=30";
const CACHE_KEY = "admin:mac-releases:v1";
const CACHE_SECONDS = 3600;
const LAST_GOOD_KEY = "admin:mac-releases:last-good";

const zReleases = z.array(z.object({
  tag_name: z.string(),
  published_at: z.string().nullable(),
  assets: z.array(z.object({ name: z.string(), download_count: z.number() })),
}));

export interface MacRelease {
  tag: string;
  published: string | null;
  /// Downloads of the disk image and the zip: people.
  installs: number;
  /// Downloads of appcast.xml: update checks seen by GitHub, not people.
  appcast: number;
}

export async function macReleases(env: Env): Promise<MacRelease[] | null> {
  const cached = await env.STATE.get(CACHE_KEY);
  if (cached) {
    try { return JSON.parse(cached) as MacRelease[]; } catch { /* reload */ }
  }
  try {
    const res = await fetch(URL_RELEASES, {
      headers: {
        Accept: "application/vnd.github+json", "User-Agent": "septena-admin",
        ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
      },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`github ${res.status}`);
    const list = zReleases.parse(await res.json())
      .filter((r) => /^v\d/.test(r.tag_name))
      .map((r) => ({
        tag: r.tag_name,
        published: r.published_at,
        installs: r.assets.filter((a) => /\.(dmg|zip)$/i.test(a.name)).reduce((n, a) => n + a.download_count, 0),
        appcast: r.assets.filter((a) => a.name === "appcast.xml").reduce((n, a) => n + a.download_count, 0),
      }));
    await Promise.all([
      env.STATE.put(CACHE_KEY, JSON.stringify(list), { expirationTtl: CACHE_SECONDS }),
      env.STATE.put(LAST_GOOD_KEY, JSON.stringify(list)),
    ]);
    return list;
  } catch (e) {
    logEvent("admin_releases_failed", { error: String(e) });
    const last = await env.STATE.get(LAST_GOOD_KEY);
    try { return last ? JSON.parse(last) as MacRelease[] : null; } catch { return null; }
  }
}
