import { Hono } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { zId } from "../store/columns.js";
import { storeFor } from "./session.js";

// Project & area notes history REST surface (docs/PROJECT_NOTES_SPEC.md §6, #123).
// Mounted at /v1/notes behind `requireUser`.

type Vars = { userId: string; actor: string };

export const notesHistoryRest = new Hono<{ Bindings: Env; Variables: Vars }>();

export const zHistoryQuery = z.object({
  container: z.enum(["project", "area"]),
  id: zId,
  before: z.coerce.number().int().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  includeBody: z.enum(["0", "1"]).default("1"),
});

notesHistoryRest.get("/history", async (c) => {
  const q = zHistoryQuery.safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  const store = storeFor(c.env, c.get("userId"));
  const note = await store.readNote(q.data.container, q.data.id);
  if (!note) return c.json({ error: "not_found" }, 404);
  const revisions = await store.noteRevisions(
    q.data.container,
    q.data.id,
    q.data.before ?? null,
    q.data.limit,
    q.data.includeBody === "1",
  );
  return c.json(
    { container: q.data.container, id: q.data.id, noteRev: note.noteRev, revisions },
    200,
    { "Cache-Control": "no-store" },
  );
});
