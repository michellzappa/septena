import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { attachmentKey, attachmentRefusal } from "../api/attachments.js";
import { signClaims, verifyClaims } from "../api/session.js";
import { planCheckFailed, planFor, upsellLine, type PlanState } from "../entitlement/entitlement.js";
import type { Tool } from "../rpc.js";
import { zId } from "../store/columns.js";
import type { Row } from "../store/TaskStore.js";
import { randomId } from "../util.js";
import { type StoreRpc, pushAs, requireApplied, rpcStoreFor } from "./writes.js";

// Files an agent puts on a task. Two ways in, one write:
//   - small content in the tool call (`text` or `base64`);
//   - a one-time upload token, for a file on the agent's machine: a model
//     cannot write a PDF out as base64.
// An agent cannot read a file's bytes or delete a file. The server never
// fetches an address an agent names: a web page is a `url` reference.

/// Below the apps' own limit (MAX_ATTACHMENT_BYTES): the Worker holds the
/// bytes in memory here.
export const MAX_AGENT_FILE_BYTES = 10 * 1024 * 1024;
const TOKEN_PREFIX = "su1";
const TOKEN_TTL_S = 15 * 60;

/// A display name only: no path, no control characters, and no bidirectional
/// marks, which can hide a real extension.
const zFilename = z.string().trim().min(1).max(255)
  .refine((n) => !/[\u0000-\u001f\u007f/\\‎‏‪-‮⁦-⁩]/.test(n) && n !== "." && n !== "..",
    "a plain file name, no path");
/// Parameters (`; charset=utf-8`) are dropped.
const zContentType = z.string().max(200).transform((t) => t.split(";")[0].trim().toLowerCase())
  .refine((t) => /^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/.test(t), "a MIME type, e.g. application/pdf");
const zFile = z.object({ taskId: zId, filename: zFilename, contentType: zContentType });
type FileInfo = z.infer<typeof zFile>;

export const zAttachmentArgs = {
  tasks_attachment_add: z.object({
    task_id: zId,
    filename: zFilename,
    content_type: zContentType,
    text: z.string().max(MAX_AGENT_FILE_BYTES).optional(),
    base64: z.string().max(Math.ceil(MAX_AGENT_FILE_BYTES / 3) * 4 + 4).optional(),
  }).refine((a) => a.text === undefined || a.base64 === undefined, "Pass text or base64, not both."),
};
export type AttachmentToolName = keyof typeof zAttachmentArgs;
export type AttachmentAddInput = z.infer<typeof zAttachmentArgs.tasks_attachment_add>;

export const ATTACHMENT_TOOLS: Tool[] = [
  {
    name: "tasks_attachment_add",
    title: "Attach a file",
    description:
      "Attach a file of up to 10 MB to a task. For text you wrote (Markdown, CSV, JSON), pass it in `text`. For a tiny binary, pass " +
      "`base64`. For a file on disk, pass neither: the reply has an upload URL and a one-time token, valid for 15 " +
      "minutes, and a curl command to send the file. Nothing is attached until that upload answers. Attach only what the user asked for " +
      "or what the task needs. For a web page or an email, use `refs` on tasks_update instead. Only the user can remove a file.",
    inputSchema: {
      type: "object",
      required: ["task_id", "filename", "content_type"],
      properties: {
        task_id: { type: "string", description: "Task id." },
        filename: { type: "string", minLength: 1, maxLength: 255, description: "Name with extension, e.g. quote.pdf. No path." },
        content_type: { type: "string", description: "MIME type, e.g. application/pdf, image/png, text/markdown." },
        text: { type: "string", description: "The whole file as text (UTF-8)." },
        base64: { type: "string", description: "The whole file as standard base64. Only for small files." },
      },
    },
    annotations: { title: "Attach a file", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
];

/// A task's files as `tasks_get` shows them. Never the bytes.
export function attachmentsOut(rows: Row[]) {
  return rows.map((r) => ({
    id: r.id as string, filename: r.filename as string, contentType: r.contentType as string,
    byteCount: r.byteCount as number,
    // false: the bytes are only on the device that added the file.
    uploaded: typeof r.uploadedAt === "string",
  }));
}

type AttachmentStatus = 400 | 402 | 404 | 409 | 410 | 411 | 413 | 503;

/// A refusal in words, with the HTTP status the upload route answers.
export class AttachmentError extends Error {
  readonly status: AttachmentStatus;
  constructor(message: string, status: AttachmentStatus = 400) {
    super(message);
    this.status = status;
  }
}

function decodeBase64(s: string): Uint8Array<ArrayBuffer> {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  } catch {
    throw new AttachmentError("base64 is not valid base64.");
  }
}

async function requireTask(store: StoreRpc, taskId: string): Promise<void> {
  const r = await store.readTask(taskId);
  if (!r || r.task.kind === "heading") throw new AttachmentError(`Task not found: ${taskId}`, 404);
}

async function requireRoom(env: Env, store: StoreRpc, userId: string, length: number): Promise<void> {
  let plan: PlanState | null = null;
  try {
    plan = await planFor(env, userId);
  } catch (e) {
    if (planCheckFailed(env, userId, "attachment_upload", e, "closed") === "block") {
      throw new AttachmentError("Septena could not check this account's plan. Try again in a minute.", 503);
    }
  }
  const refused = await attachmentRefusal(env, userId, plan, length, () => store.attachmentBytes());
  if (refused) throw new AttachmentError(refused.breach.upsell ? upsellLine(refused.breach.upsell) : refused.error, 402);
}

/// Adds the row, then the bytes. The row goes first, so the store's rules
/// (stopped, paused, quota) refuse before anything is kept.
export async function storeFile(
  env: Env, store: StoreRpc, userId: string, actor: string, file: FileInfo, bytes: Uint8Array<ArrayBuffer>, id: string,
) {
  if (bytes.length === 0) throw new AttachmentError("The file is empty.");
  if (bytes.length > MAX_AGENT_FILE_BYTES) throw new AttachmentError("The file is over 10 MB.", 413);
  await requireTask(store, file.taskId);
  await requireRoom(env, store, userId, bytes.length);
  const existing = await store.readAttachments(file.taskId);
  const position = existing.reduce((max, r) => Math.max(max, typeof r.position === "number" ? r.position : 0), -1) + 1;
  const [pushed] = await pushAs(store, actor, [{
    op: "upsert", entity: "attachment", id,
    fields: {
      taskId: file.taskId, filename: file.filename, contentType: file.contentType, byteCount: bytes.length,
      position, createdAt: new Date().toISOString(),
    },
  }]);
  requireApplied(pushed, file.taskId);
  const key = attachmentKey(userId, id);
  let rev: number | null;
  try {
    await env.ATTACHMENTS.put(key, bytes);
    rev = await store.finishUpload(id, actor);
  } catch (e) {
    // No row without bytes.
    await pushAs(store, actor, [{ op: "delete", entity: "attachment", id }]).catch(() => {});
    await env.ATTACHMENTS.delete(key).catch(() => {});
    throw e;
  }
  if (rev === null) {
    await env.ATTACHMENTS.delete(key);
    throw new AttachmentError("The file was deleted while it was uploading.", 410);
  }
  return { attached: true, id, task_id: file.taskId, filename: file.filename, byteCount: bytes.length };
}

export async function addAttachment(env: Env, store: StoreRpc, userId: string, actor: string, a: AttachmentAddInput) {
  const file: FileInfo = { taskId: a.task_id, filename: a.filename, contentType: a.content_type };
  const id = `att-${randomId(12)}`;
  if (a.text !== undefined) return storeFile(env, store, userId, actor, file, new TextEncoder().encode(a.text), id);
  if (a.base64 !== undefined) return storeFile(env, store, userId, actor, file, decodeBase64(a.base64), id);
  await requireTask(store, file.taskId);
  await requireRoom(env, store, userId, 0);
  const token = await signClaims(env, TOKEN_PREFIX, { sub: userId, act: actor, id, ...file, exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_S });
  const url = `${env.API_PUBLIC_URL}/v1/agent/upload`;
  return {
    attached: false,
    upload: { method: "PUT", url, token, expiresInSeconds: TOKEN_TTL_S, maxBytes: MAX_AGENT_FILE_BYTES },
    command: `curl -sS -T <path> -H 'Authorization: Bearer ${token}' ${url}`,
  };
}

const zClaims = zFile.extend({ sub: z.string().min(1), act: z.string().startsWith("mcp:"), id: zId });

/// `PUT /v1/agent/upload`. The token rides in the header, never in the URL:
/// URLs reach the logs. It names the attachment id, so it works once: a used
/// id has a row, live or deleted.
export async function agentUpload(c: Context<{ Bindings: Env }>): Promise<Response> {
  const header = c.req.header("Authorization") ?? "";
  const raw = header.startsWith("Bearer ") ? await verifyClaims(c.env, TOKEN_PREFIX, header.slice(7)) : null;
  const claims = zClaims.safeParse(raw);
  if (!claims.success) return c.json({ error: "The upload token is not valid or has expired. Call tasks_attachment_add again." }, 401);
  const { sub, act, id, ...file } = claims.data;
  try {
    const length = Number(c.req.header("Content-Length") ?? NaN);
    if (!Number.isInteger(length) || length < 0) throw new AttachmentError("Send a Content-Length.", 411);
    if (length > MAX_AGENT_FILE_BYTES) throw new AttachmentError("The file is over 10 MB.", 413);
    const store = rpcStoreFor(c.env, sub);
    if (await store.hasAttachment(id)) throw new AttachmentError("This upload token is used.", 409);
    return c.json(await storeFile(c.env, store, sub, act, file, new Uint8Array(await c.req.arrayBuffer()), id));
  } catch (e) {
    if (e instanceof AttachmentError) return c.json({ error: e.message }, e.status);
    // A store rule refused the agent (stopped, paused, quota).
    return c.json({ error: e instanceof Error ? e.message : String(e) }, 403);
  }
}
