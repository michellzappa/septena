// Idempotency keys on writes (ADR 0050 §4, docs/AGENT_SURFACE_SPEC.md AS3).
//
// Every MCP write tool and every /v1/tasks write takes an optional
// `idempotency_key`. The TaskStore keeps the key, a hash of the call's body
// and the first result for 24 hours per account. A repeat with the same key
// and body returns that result and does not write again. The same key with
// another body is refused as `idempotency_conflict`. A refused or failed call
// keeps nothing, so its retry runs.

import { z } from "zod";
import { Refusal } from "./errors.js";

/// Printable ASCII, no spaces: a UUID, a ULID or any caller-made string.
export const zIdempotencyKey = z.string().regex(/^[\x21-\x7E]{1,255}$/, "expected 1–255 printable ASCII characters, no spaces");

export const IDEMPOTENCY_KEY_FIELD = "idempotency_key";

/// The JSON Schema property the write tools list.
export const IDEMPOTENCY_KEY_SCHEMA = {
  type: "string",
  minLength: 1,
  maxLength: 255,
  description:
    "Optional. A key you make for this write (a UUID). Send the same key when you retry the same call: Septena returns the first result and does not write again. Keys live 24 hours. The same key with a different body is refused as idempotency_conflict.",
} as const;

/// The store methods this needs; both the MCP connector and /v1 pass their
/// TaskStore stub.
export interface IdempotencyStore {
  idempotencyBegin(key: string, hash: string): Promise<
    { state: "new" } | { state: "replay"; result: string } | { state: "conflict" } | { state: "in_progress" }
  >;
  idempotencyFinish(key: string, hash: string, result: string): Promise<void>;
  idempotencyAbandon(key: string, hash: string): Promise<void>;
}

/// JSON with object keys sorted, so the same body always hashes the same.
export function canonicalJson(v: unknown): string {
  if (v === null || typeof v !== "object") return JSON.stringify(v) ?? "null";
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(",")}]`;
  const o = v as Record<string, unknown>;
  return `{${Object.keys(o).filter((k) => o[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`).join(",")}}`;
}

/// SHA-256 (hex) of the call: where it went and what it carried.
export async function bodyHash(scope: string, body: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(`${scope}\n${canonicalJson(body)}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export type Outcome<T> = { keep: true; value: T } | { keep: false; value: T };

/// Run `run` once per key. Without a key, it just runs. `run` says whether
/// its value is a result to keep (a write that landed) or not (a refusal).
/// A replay returns the kept value with `replayed: true`. A conflict or a
/// call still running throws a Refusal with the envelope code.
export async function withIdempotency<T>(
  store: IdempotencyStore,
  key: string | undefined,
  scope: string,
  body: unknown,
  run: () => Promise<Outcome<T>>,
): Promise<{ value: T; replayed: boolean }> {
  if (key === undefined) return { value: (await run()).value, replayed: false };
  const hash = await bodyHash(scope, body);
  const start = await store.idempotencyBegin(key, hash);
  if (start.state === "replay") return { value: JSON.parse(start.result) as T, replayed: true };
  if (start.state === "conflict") {
    throw new Refusal("idempotency_conflict", `The idempotency_key ${key} was used in the last 24 hours with a different body. Nothing was written.`);
  }
  if (start.state === "in_progress") {
    throw new Refusal("idempotency_in_progress", `A call with the idempotency_key ${key} is still running. Nothing was written.`);
  }
  let outcome: Outcome<T>;
  try {
    outcome = await run();
  } catch (err) {
    await store.idempotencyAbandon(key, hash).catch(() => {});
    throw err;
  }
  if (outcome.keep) await store.idempotencyFinish(key, hash, JSON.stringify(outcome.value));
  else await store.idempotencyAbandon(key, hash);
  return { value: outcome.value, replayed: false };
}
