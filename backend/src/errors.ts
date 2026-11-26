// The one error envelope (ADR 0050 §3, docs/AGENT_SURFACE_SPEC.md AS3).
//
// A refused MCP tool call and a refused /v1 call carry
// `{ error: { code, message, hint, retryable } }`. `code` is the refusal's
// existing name (`paused`, `held`, `human_accepts`, ...), never renamed.
// `retryable` answers one question: can the SAME request succeed later with
// no action by the user? `held` can (the lease ends), `paused` cannot (only
// the user unpauses), `stale` cannot (the agent must read and send a new
// body).
//
// REFUSALS is the one table from code to retryable and hint. The `rule`
// strings in older result fields (AGENT_WRITE_RULES in the TaskStore, the
// claim refusals in shadow/agent.ts) are read from it, so a hint is written
// once.

import { DOMAIN_RULES } from "./generated/registries.js";

export interface ErrorEnvelope {
  code: string;
  message: string;
  hint: string;
  retryable: boolean;
}

interface RefusalInfo {
  retryable: boolean;
  hint: string;
}

const RUN_BUDGET = DOMAIN_RULES.agentRunBudget;

export const REFUSALS = {
  // ---- the agent rules (ADR 0008), enforced in the TaskStore ----
  paused: {
    retryable: false,
    hint: "The user paused all agents. Do not write; only the user can unpause. tasks_agent_events reports unpaused.",
  },
  stopped: {
    retryable: false,
    hint: "The user stopped agent work on this task. Do not write to it; only the user can resume it.",
  },
  your_turn: { retryable: false, hint: "A question waits for the user. Wait for a user_turn event on this task." },
  held: {
    retryable: true,
    hint: "Another agent holds this task until claimUntil. Pick another task, or claim this one after claimUntil.",
  },
  doing: { retryable: false, hint: "The user does this task now. Do not work on it until a do_ended event on this task." },
  budget: {
    retryable: false,
    hint: `${RUN_BUDGET} runs since the user last wrote on this task. Ask the user (a provider turn with options) before you continue.`,
  },
  terminal: { retryable: false, hint: "The conversation has an end state. Only the user reopens it." },
  closed: { retryable: false, hint: "The task is done or cancelled. Only the user reopens it." },
  not_found: { retryable: false, hint: "No such item. Search or list again to find the right id." },
  human_accepts: {
    retryable: false,
    hint: "Only the user ends an agent-worked task: not done, not cancelled, not deleted by you. Call tasks_set_endstate with endState \"needs_verify\" and a note describing what to check, or why you suggest to cancel it.",
  },
  human_ends: {
    retryable: false,
    hint: "You may set \"needs_verify\" (hand over to Review) or \"decomposed\" (the work goes on as an issue or smaller tasks). Every other end state follows from what the user does.",
  },
  in_review: {
    retryable: false,
    hint: "This task is in the user's Review. You may hand it over again with \"needs_verify\" and a new note. Only the user takes it out of Review.",
  },
  note_required: { retryable: false, hint: "A hand-off needs a note that says what to check. Send it in the same call." },
  "human_only:assignee": {
    retryable: false,
    hint: "Only the user takes a task back from you. Ask in the conversation, or hand it over with \"needs_verify\".",
  },
  "human_only:stoppedAt": { retryable: false, hint: "Only the user stops or resumes agent work on a task." },
  "human_only:agentsPaused": { retryable: false, hint: "Only the user pauses or unpauses agents." },
  human_only_do: { retryable: false, hint: "Only the user starts, changes or ends a Do." },
  stale: {
    retryable: false,
    hint: "The notes changed since you read them. Read `current`, then write again on top of it with its noteRev as baseNoteRev.",
  },
  brief_is_users: {
    retryable: false,
    hint: "The text above `## Log` is the user's brief. Append a dated entry under `## Log`, or propose a new brief for the user to accept.",
  },
  "retired:context": { retryable: false, hint: "Project context is retired (ADR 0012). Write the project's notes instead." },

  // ---- store checks on the fields of a write ----
  missing_required: { retryable: false, hint: "A required field is missing. Send it in the same call." },
  required: { retryable: false, hint: "A required field cannot be cleared." },
  immutable: { retryable: false, hint: "This field cannot change after the item exists." },
  invalid_key: { retryable: false, hint: "The reference key is not valid. Use a link or a key such as issue:owner/repo#1." },
  duplicate_ref: { retryable: false, hint: "The task already has this reference." },
  duplicate_tag_name: { retryable: false, hint: "A tag with this name exists. Use that tag." },
  ref_limit_exceeded: { retryable: false, hint: "The task has the most references it can hold. Remove one first." },
  checklist_limit_exceeded: { retryable: false, hint: "The task has the most checklist items it can hold." },
  tag_limit_exceeded: { retryable: false, hint: "The account has the most tags it can hold." },
  quota_exceeded: { retryable: false, hint: "The account's attachment storage is full." },
  shared_project: { retryable: false, hint: "This project is shared. Only its owner deletes it or moves its tasks out." },
  shared_move_out: { retryable: false, hint: "Only the owner of a shared project moves its tasks out." },

  // ---- the connector and the plan ----
  read_only: {
    retryable: false,
    hint: "This connection can only read. The user removes the connector and adds it again to let it write.",
  },
  plan_limit: { retryable: false, hint: "The account's plan does not allow this now. Reading tasks still works." },
  plan_check_failed: { retryable: true, hint: "Septena could not check the account's plan. Try again in a minute." },
  rate_limited: { retryable: true, hint: "Too many attempts. Wait, then try again." },
  unavailable: { retryable: true, hint: "Septena could not finish the call. Try again; with an idempotency_key a retry is safe." },
  maintenance: { retryable: true, hint: "Septena is in maintenance. Try again in a few minutes." },

  // ---- the request itself ----
  invalid_arguments: { retryable: false, hint: "Fix the arguments the message names, then call again." },
  invalid_request: { retryable: false, hint: "Fix the request the message describes, then send it again." },
  unknown_tool: { retryable: false, hint: "Call tools/list for the tools this server has." },
  unauthorized: { retryable: false, hint: "Sign in or connect again: the token is missing, expired or revoked." },

  // ---- idempotency keys (ADR 0050 §4) ----
  idempotency_conflict: {
    retryable: false,
    hint: "This idempotency_key was used in the last 24 hours with a different body. Use a new key for a new write.",
  },
  idempotency_in_progress: {
    retryable: true,
    hint: "A call with this idempotency_key is still running. Wait a few seconds, then send the same call again.",
  },
} as const satisfies Record<string, RefusalInfo>;

export type RefusalCode = keyof typeof REFUSALS;

const FALLBACK: RefusalInfo = { retryable: false, hint: "The call was refused. Read the message before you try again." };

/// Store reasons that are another code under an older name.
const ALIASES: Record<string, RefusalCode> = { unknown_task: "not_found", deleted: "not_found" };

/// The code an older reason string means: `unknown_task` is `not_found`;
/// a reason with a detail suffix (`missing_required:title`) keeps its full
/// name as the code unless the table names the full string.
export function canonicalCode(reason: string): string {
  return ALIASES[reason] ?? reason;
}

/// Retryable and hint for a code: the exact code, then the part before `:`
/// (`immutable:title` → `immutable`), then a refusal that is not retryable.
export function refusalInfo(code: string): RefusalInfo {
  const table = REFUSALS as Record<string, RefusalInfo>;
  const exact = table[canonicalCode(code)];
  if (exact) return exact;
  const base = code.split(":")[0];
  return table[base] ?? FALLBACK;
}

/// Whether the table knows this code (or its prefix).
export function isKnownCode(code: string): boolean {
  return refusalInfo(code) !== FALLBACK;
}

export function errorEnvelope(code: string, message?: string, opts: { hint?: string; retryable?: boolean } = {}): ErrorEnvelope {
  const c = canonicalCode(code);
  const info = refusalInfo(c);
  return {
    code: c,
    message: message ?? info.hint,
    hint: opts.hint ?? info.hint,
    retryable: opts.retryable ?? info.retryable,
  };
}

/// A refusal with a code. Thrown by the write tools so the connector can
/// answer with the envelope; the message stays what it always said, so text
/// that agents and tests match keeps working.
export class Refusal extends Error {
  readonly code: string;
  constructor(code: string, message?: string) {
    super(message ?? refusalInfo(code).hint);
    this.name = "Refusal";
    this.code = canonicalCode(code);
  }
}

/// The envelope for anything a tool call threw. A Refusal keeps its code. A
/// Durable Object error Cloudflare marks `retryable` (an overloaded or reset
/// object) is `unavailable`. Any other throw is a request the tool would not
/// run as sent.
export function envelopeFor(err: unknown): ErrorEnvelope {
  if (err instanceof Refusal) return errorEnvelope(err.code, err.message);
  const message = err instanceof Error ? err.message : String(err);
  if (err && typeof err === "object" && (err as { retryable?: unknown }).retryable === true) {
    return errorEnvelope("unavailable", message);
  }
  if (/\bnot found\b/i.test(message)) return errorEnvelope("not_found", message);
  return errorEnvelope("invalid_request", message);
}

/// A tool result that reports a refusal in its own fields (a claim with
/// `claimed: false`, a complete with `completed: false`, a notes write with
/// `written: false`): the result plus the envelope. Every other result comes
/// back unchanged. The old fields stay, so clients that read them still work.
export function withRefusalEnvelope<T>(result: T): T {
  if (!result || typeof result !== "object" || Array.isArray(result)) return result;
  const r = result as Record<string, unknown>;
  if (typeof r.reason !== "string" || "error" in r) return result;
  const refused = r.claimed === false || r.completed === false || r.written === false;
  if (!refused) return result;
  return { ...r, error: errorEnvelope(r.reason, typeof r.rule === "string" ? r.rule : undefined) } as T;
}

/// The code for an HTTP refusal that names no code of its own.
export function codeForStatus(status: number): RefusalCode {
  if (status === 401) return "unauthorized";
  if (status === 402) return "plan_limit";
  if (status === 404 || status === 410) return "not_found";
  if (status === 429) return "rate_limited";
  if (status === 503) return "unavailable";
  if (status >= 500) return "unavailable";
  return "invalid_request";
}

// ---- /v1 ----
//
// The /v1 API has always answered `{ error: "<code>", ... }`, and every app
// client decodes `error` as a string (BackendErrorBody, the watch, Android,
// the web client). The envelope needs `error` to be an object, so on /v1 a
// caller asks for it: `X-Septena-Errors: envelope`. Without the header the
// body is what it always was. With it, `error` is the envelope and every
// other old field stays.

export const ERROR_FORMAT_HEADER = "X-Septena-Errors";

const CODE_SHAPE = /^[a-z][a-z0-9_]*(:[A-Za-z0-9_,]+)?$/;

/// A refused /v1 response with the envelope in place of the old `error`
/// string. A success, or a body that already carries the envelope, passes.
export async function envelopeResponse(res: Response): Promise<Response> {
  if (res.status < 400) return res;
  const text = await res.clone().text();
  let old: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(text) as unknown;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) old = parsed as Record<string, unknown>;
  } catch {
    // A text body ("Unauthorized"): the status names the code.
  }
  if (old.error && typeof old.error === "object") return res;
  const oldError = typeof old.error === "string" ? old.error : undefined;
  const code = typeof old.reason === "string" && CODE_SHAPE.test(old.reason) ? old.reason
    : oldError && CODE_SHAPE.test(oldError) && oldError !== "rejected" ? oldError
    : codeForStatus(res.status);
  const message = typeof old.message === "string" ? old.message
    : oldError && !CODE_SHAPE.test(oldError) ? oldError
    : undefined;
  const transient = res.status >= 500 || res.status === 429;
  const error = errorEnvelope(code, message, isKnownCode(code) ? {} : { retryable: transient });
  const headers = new Headers(res.headers);
  headers.set("Content-Type", "application/json");
  headers.delete("Content-Length");
  return new Response(JSON.stringify({ ...old, error }), { status: res.status, headers });
}
