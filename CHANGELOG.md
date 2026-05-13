# CHANGELOG

Backend (Septena) changes requested by the iOS Engage client. These can't
be made from the iOS side — they live in `~/Dev/septena-app/api/` and need
to be applied to the Python backend.

Items are listed in priority order. Each one names the file, the symptom,
and the suggested fix.

---

## 1. Path-traversal in DELETE endpoints (security, P0)

**Files:** `api/routers/tasks.py:995–1022`

`tasks_delete()` and `projects_delete()` accept `task_id` / `project_id`
straight from the URL path and pass them into filesystem operations
without validating the shape. `_project_path(pid)` constructs
`TASKS_PROJECTS_DIR / f"{pid}.json"`; `_task_path_for_id(tid)` falls back
to `TASKS_ITEMS_DIR / "{tid}.json"`. Neither call checks containment.

A request that bypasses URL normalization (raw `httpx`, Python `requests`,
or a custom client) carrying e.g. `project_id = "../tasks-config"` would
resolve to `Tasks/tasks-config.json` (the areas config) and `path.unlink()`
would delete it.

`ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")` already exists at the top of
the router and is enforced on `areas_replace` and `projects_create` — it's
just inconsistently applied to the lookup paths.

**Fix:** add a guard at the top of every endpoint that takes `task_id` or
`project_id` from the URL or request body:

```python
if not ID_RE.match(tid):
    raise HTTPException(status_code=400, detail="invalid id")
```

Affected endpoints (every site that calls `_find_task_path` or
`_project_path` with a user-supplied id):

- `DELETE /api/tasks/{task_id}` — `tasks_delete`
- `DELETE /api/tasks/projects/{project_id}` — `projects_delete`
- `PUT /api/tasks/projects/{project_id}` — `projects_update`
- `POST /api/tasks/update` — `tasks_update`
- `POST /api/tasks/complete` — `tasks_complete`
- `POST /api/tasks/uncomplete` — `tasks_uncomplete`
- `POST /api/tasks/cancel` — `tasks_cancel`
- `POST /api/tasks/move-to-today` — `tasks_move_to_today`
- `POST /api/tasks/schedule` — `tasks_schedule`
- `POST /api/tasks/set-due` — `tasks_set_due`
- `POST /api/tasks/someday` — `tasks_someday`

The non-DELETE ones don't unlink, but they do `_write_task` which writes to
the resolved path. A malicious id could overwrite arbitrary `.json` files
inside any reachable directory.

---

## 2. Token authentication (security, P1)

**Status today:** no auth. The server is reachable to anyone on the
tailnet.

**Suggested:** single-bearer-token model. Server reads the expected token
from an env var (e.g. `SEPTENA_API_TOKEN`); requests must carry
`Authorization: Bearer <token>`. iOS already has the plumbing pattern from
the old `AtaskClient` — would store the token in Keychain.

Implementation sketch:

```python
# api/auth.py
import os
from fastapi import Header, HTTPException

EXPECTED = os.environ.get("SEPTENA_API_TOKEN")

async def require_token(authorization: str = Header(None)):
    if not EXPECTED:                          # auth disabled if env unset
        return
    if authorization != f"Bearer {EXPECTED}":
        raise HTTPException(status_code=401, detail="unauthorized")
```

Apply via `Depends(require_token)` on each router — or globally via
`app.include_router(..., dependencies=[Depends(require_token)])`.

Setting `SEPTENA_API_TOKEN` empty/unset keeps current behavior (no auth)
so the change is safe to deploy without coordinating clients.

---

## 3. List endpoint scales linearly (performance, P2)

**Files:** `api/routers/tasks.py:222`

```python
def _load_tasks():
    for path in TASKS_ITEMS_DIR.rglob("*.json"):
        parsed = _parse_task(path)
```

Every call to `/api/tasks/list`, `/counts`, or `/history` walks the entire
`Tasks/Items/` tree, opens each file, and parses the JSON. Today this is
~60 tasks → invisible. After a year of usage with hundreds of completed
tasks in the logbook, it becomes the dominant cost on every page load.

**Suggested fix:**

- Maintain `Tasks/_index.json` with `{id, title, status, area, project,
  scheduled, due, today, today_set_on, completed_at}` for every task —
  enough to satisfy `/list` and `/counts` without opening individual files.
- Rebuild on missing or stale (timestamp older than newest task file).
- Update incrementally on every write path (`_write_task`, `_log_event`).

Alternative: in-memory LRU cache invalidated on writes. Simpler, but lost
on every `uvicorn` restart.

---

## 4. Conditional GETs / ETag on /list (performance, P3)

iOS calls `/api/tasks/list` on every `.onAppear` (tab switch, sheet
dismiss, etc.). The full payload comes back even when nothing has changed.

**Suggested:** emit `ETag` on `/list` derived from the maximum mtime under
`TASKS_ITEMS_DIR` (and project/area dirs). Honour `If-None-Match` and
return `304 Not Modified` when the etag still matches.

iOS already has the plumbing to handle 304s if the client adds the header
on subsequent requests.

---

## 5. Document `/update` vs verb endpoints (docs only, P3)

There's overlap between `POST /api/tasks/update` (which can set any field)
and the dedicated verb endpoints (`/move-to-today`, `/schedule`, `/set-due`,
`/someday`, `/complete`, `/cancel`).

The verb endpoints exist mainly so the events log captures intent
(`{"reason": "rescheduled"}`, `{"reason": "someday"}`). The general
`/update` endpoint writes silently with no event log entry.

**Suggested:** add a comment block at the top of the router that states
the rule explicitly:

> Use `/update` for silent edits (typo fix, notes change). Use the verb
> endpoints when the change is a meaningful state transition that should
> show up in `/history`.

That's it for code; just makes the implicit contract explicit so future
clients pick the right endpoint.

---

## Out of scope (handled in iOS)

- Project status enum (was string on the wire, made an enum on the iOS
  side; wire format unchanged).
- Robust decoders for missing/null fields on iOS.
- Dead-code cleanup, font alias migration.
