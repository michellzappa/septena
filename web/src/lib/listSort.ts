// Sort By on lists (docs/LIST_SORT_SPEC.md, #779). The one web home of the list sort:
// which lists take one, the synced `listSort` record, and the call into the shared core.
// The comparison lives in the core (`sortTasks`) only. Never re-implement it here.

import { sortTasks } from "./core/index.ts";
import { destinationInfo } from "./destinations.ts";
import { ENTITY_ENUMS, SETTINGS_REGISTRY, SURFACES_CATALOG, registryText } from "./generated/registries.ts";
import type { ActiveDestination, TaskRow } from "./types";

export type ListSort = (typeof ENTITY_ENUMS.listSort)[number];
export type ListSortMap = Record<string, Exclude<ListSort, "manual">>;

const SETTING = SETTINGS_REGISTRY.keys.listSort;
const VALUES: ReadonlySet<string> = new Set(ENTITY_ENUMS.listSort);

/** The Sort By choices, in registry order, with their registry titles. */
export const LIST_SORT_OPTIONS: ReadonlyArray<{ value: ListSort; title: string }> = SETTING.options;

/** The registry copy and icon token of the Sort By menu and the "Sorted by" line. */
export const LIST_SORT_SURFACE = SURFACES_CATALOG.listSort;

/**
 * The key a list stores its sort under, or null when the list takes no sort.
 * Smart lists take one when the registry says `supportsManualOrder`; every project and area does.
 */
export function listSortKey(destination: ActiveDestination): string | null {
  if (destination.kind === "project") return `project:${destination.id}`;
  if (destination.kind === "area") return `area:${destination.id}`;
  return destinationInfo(destination.id)?.supportsManualOrder === true ? destination.id : null;
}

/** The synced record, with every key that does not hold a valid non-manual choice left out. */
export function readListSortMap(raw: unknown): ListSortMap {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const out: ListSortMap = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (key.length === 0 || key.length > SETTING.keyMaxLength) continue;
    if (typeof value !== "string" || value === "manual" || !VALUES.has(value)) continue;
    out[key] = value as Exclude<ListSort, "manual">;
  }
  return out;
}

export function listSortFor(map: ListSortMap, key: string | null): ListSort {
  return (key && map[key]) || "manual";
}

/**
 * The record to write when the user picks `sort` for the list `key`. Manual removes the key.
 * Keys of projects and areas that no longer exist are dropped, and at most `maxEntries` stay
 * (the newest choice is kept).
 */
export function nextListSortMap(
  map: ListSortMap,
  key: string,
  sort: ListSort,
  live: { projectIds: ReadonlySet<string>; areaIds: ReadonlySet<string> },
): ListSortMap {
  const entries = Object.entries(map).filter(([k]) => {
    if (k === key) return false;
    if (k.startsWith("project:")) return live.projectIds.has(k.slice("project:".length));
    if (k.startsWith("area:")) return live.areaIds.has(k.slice("area:".length));
    return true;
  });
  if (sort !== "manual") entries.push([key, sort]);
  return Object.fromEntries(entries.slice(-SETTING.maxEntries)) as ListSortMap;
}

/** "Sorted by <choice>" for the list header, localized. */
export function sortedByLine(sort: ListSort, lang: string): string {
  const option = LIST_SORT_OPTIONS.find((o) => o.value === sort);
  return registryText(LIST_SORT_SURFACE.sortedBy, lang, { sort: registryText(option?.title ?? sort, lang) });
}

/**
 * `items` (in manual order) in the order of `sort`, sorted inside each group (`groupOf`).
 * Each group keeps the slots it held, so a later grouping by the same key sees the groups in
 * their own order. Items with `pinned` true keep their place (the Inbox band on Today).
 * Fails safe: on any core error the manual order comes back.
 */
export function sortListItems<T>(
  items: readonly T[],
  sort: ListSort,
  taskOf: (item: T) => TaskRow,
  groupOf: (item: T) => string = () => "",
  pinned: (item: T) => boolean = () => false,
): T[] {
  if (sort === "manual" || items.length < 2) return [...items];
  try {
    const slots = new Map<string, number[]>();
    items.forEach((item, index) => {
      if (pinned(item)) return;
      const group = groupOf(item);
      const list = slots.get(group) ?? [];
      list.push(index);
      slots.set(group, list);
    });
    const out = [...items];
    for (const indexes of slots.values()) {
      if (indexes.length < 2) continue;
      const byId = new Map(indexes.map((i) => [taskOf(items[i]).id, items[i]]));
      const ids = sortTasks(indexes.map((i) => taskOf(items[i])), sort);
      if (ids.length !== indexes.length || ids.some((id) => !byId.has(id)) || new Set(ids).size !== ids.length) {
        throw new Error("sortTasks returned other ids");
      }
      ids.forEach((id, n) => {
        out[indexes[n]] = byId.get(id)!;
      });
    }
    return out;
  } catch {
    return [...items];
  }
}
