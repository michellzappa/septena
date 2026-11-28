// Review > Tracked (ADR 0065, docs/REVIEW_SPEC.md §2): the link a tracked row
// shows. Which tasks are tracked is the core's rule (`isTracked`).

import type { TaskRefRow } from "./types.ts";

export interface TrackedLink {
  url: string;
  label: string;
}

/** The link of a tracked row: the newest issue reference, else the first reference with a URL. */
export function trackedLink(refs: readonly TaskRefRow[]): TrackedLink | null {
  const live = refs.filter((r) => !r.deletedAt);
  const issues = live
    .filter((r) => r.key.startsWith("issue:") && r.snapshot?.url)
    .sort((a, b) => String(b.createdAt ?? "").localeCompare(String(a.createdAt ?? "")));
  const ref = issues[0] ?? live.find((r) => r.snapshot?.url || r.key.startsWith("url:"));
  if (!ref) return null;
  const url = ref.snapshot?.url ?? ref.key.slice(4);
  const label = ref.key.startsWith("issue:") ? ref.key.slice("issue:".length) : ref.snapshot?.title || url;
  return { url, label };
}
