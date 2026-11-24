import { z } from "zod";
import { CoreInputError, parseRef, type CoreRef } from "../core/index.js";
import { ENTITY_ENUMS, ENTITY_LIMITS } from "../generated/registries.js";
import { MAX_REFS_PER_TASK, snapshotFits, zRefSnapshotFields, type RefSnapshot } from "../store/columns.js";
import type { Row } from "../store/TaskStore.js";
import type { StoreRpc } from "./writes.js";

// Task references at the MCP and REST boundary (docs/TASK_REFERENCES_SPEC.md
// §7). The core normalises every key here; an invalid key is an error. An
// error never names the key: errors reach the logs, and a key is user content
// (§10).

/// A key, a URL or a `message://` link before normalisation. A link can be
/// longer than the key it becomes.
export const MAX_REF_INPUT = 4 * ENTITY_LIMITS.refKeyMax;

export const zRefInput = z.object({
  key: z.string().min(1).max(MAX_REF_INPUT),
  role: z.enum(ENTITY_ENUMS.taskRefRole).optional(),
  snapshot: zRefSnapshotFields.optional(),
}).strict();
export type RefInput = z.infer<typeof zRefInput>;
export const zRefs = z.array(zRefInput).max(MAX_REFS_PER_TASK);
export const zRefKeys = z.array(z.string().min(1).max(MAX_REF_INPUT)).max(MAX_REFS_PER_TASK);

export interface ResolvedRef {
  ref: CoreRef;
  role?: RefInput["role"];
  snapshot?: RefSnapshot;
}

export function parseRefArg(input: string, where: string): CoreRef {
  try {
    return parseRef(input);
  } catch (e) {
    if (e instanceof CoreInputError) throw new Error(`${where} is not a valid reference: ${e.reason}`);
    throw e;
  }
}

/// The references of one call, one per key. A key named twice: the last wins.
export function resolveRefs(inputs: RefInput[], field = "refs"): ResolvedRef[] {
  const out = new Map<string, ResolvedRef>();
  inputs.forEach((input, i) => {
    const ref = parseRefArg(input.key, `${field}[${i}].key`);
    out.set(ref.key, { ref, role: input.role, snapshot: input.snapshot });
  });
  return [...out.values()];
}

/// The snapshot to store: the caller's fields, plus the id before
/// normalisation and the web address that the link itself gave. A `url` key
/// is its own address. Over the cap, title and subtitle are shortened (§4.1).
export function snapshotFor(r: ResolvedRef): RefSnapshot | null {
  const s: RefSnapshot = { ...r.snapshot };
  if (s.rawId === undefined && r.ref.rawId !== r.ref.id && r.ref.kind !== "url") s.rawId = r.ref.rawId;
  if (s.url === undefined && r.ref.url && r.ref.kind !== "url") s.url = r.ref.url;
  for (const field of ["subtitle", "title"] as const) {
    while (!snapshotFits(s) && s[field]) {
      // By code point, so a cut never splits a character.
      const chars = [...s[field]];
      s[field] = chars.slice(0, Math.floor(chars.length / 2)).join("");
      if (!s[field]) delete s[field];
    }
  }
  return Object.keys(s).length > 0 ? s : null;
}

/// References as `tasks_get` shows them.
export function refsOut(rows: Row[]) {
  return rows.map((r) => ({
    key: r.key as string, kind: r.kind as string, role: r.role as string,
    ...(r.snapshot ? { snapshot: r.snapshot as RefSnapshot } : {}),
  }));
}

/// `tasks_find_by_ref`: the tasks that point at a key, active first.
export async function findByRef(store: StoreRpc, input: string, limit = 50) {
  const ref = parseRefArg(input, "key");
  const { tasks, total } = await store.findByRef(ref.key, limit);
  return {
    key: ref.key,
    kind: ref.kind,
    tasks: tasks.map((t) => ({
      id: t.id, title: t.title, status: t.status,
      ...(t.area ? { area: t.area } : {}),
      ...(t.project ? { project: t.project } : {}),
      ...(t.faded ? { faded: true } : {}),
      role: t.role,
    })),
    total,
  };
}
