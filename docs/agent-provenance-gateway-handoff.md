# Handoff: Provenance stamping in the Septena MCP gateway

> **Landed — historical.** Both halves ship: the gateway stamps provenance and
> the app reads it. Kept as the wire contract, cited by
> `docs/agent-provenance-spec.md`.

**For:** an agent working in `../septena-mcp-gateway` (Cloudflare Worker, TypeScript).
**Goal:** When Claude creates a task via MCP, stamp the CloudKit `Task` record so the iOS app can mark it as agent-created. This is the gateway half of [agent-provenance-spec.md](agent-provenance-spec.md); the iOS half is already implemented in this repo.

## Context you need

- The gateway writes CloudKit records **directly** via CloudKit Web Services (`records/modify`) using the per-user `ckWebAuthToken`. There is no app round-trip.
- The iOS app reads three new fields off the `Task` record: `source` (string), `sourceClient` (string), `createdAt` (timestamp). It renders a "created by Claude, unacknowledged" cue when `source == "mcp"`.
- The reference implementation already in this repo is `logNutritionEntry` in `src/tools/nutrition.ts` — it sets `source: { value: "mcp" }` and uses `createWithFieldFallback`. Mirror it.

## Changes

### 1. `src/tools/writeTasks.ts` — `createTask` (around line 75; the `fields` object is at line 77 — NOT line 124, which is `updateTask`)

Add three fields to the `fields` object:

```typescript
const fields: Record<string, { value: unknown }> = {
  title:        { value: input.title },
  status:       { value: "open" },
  created:      { value: todayYMD() },   // KEEP — legacy YYYY-MM-DD string
  createdAt:    { value: Date.now() },   // NEW — epoch ms → CloudKit TIMESTAMP (NSDate)
  source:       { value: "mcp" },        // NEW
  sourceClient: { value: "Claude" },     // NEW — hardcoded for now (see note 3)
  today:        { value: input.today ? 1 : 0 },
};
// ...existing optional fields (todaySetOn, scheduled, deadline, area, project) unchanged.
// Do NOT set acknowledgedAt — leaving it absent is what keeps the cue "on".
```

- `createdAt` **must be epoch milliseconds** (`Date.now()`), not an ISO string. CloudKit Web Services infers `TIMESTAMP` from a numeric value, which lands as the `NSDate` the iOS app reads as a `Date` — identical to how this repo already writes `loggedAt` in `nutrition.ts`.
- Keep writing the legacy `created` YYYY-MM-DD string; the app still uses it during the transition.

### 2. `src/tools/writeTasks.ts` — switch `createTask` to `createWithFieldFallback` (the important one)

`createTask` currently calls raw `modifyRecords(...)`, which **fails the entire create** if the CloudKit schema doesn't yet know a field. `logNutritionEntry` instead uses `client.createWithFieldFallback(...)`, which drops unknown fields and retries. Adopt it so this change is safe to deploy **before** the CloudKit prod schema learns the new fields:

```typescript
const { droppedFields } = await client.createWithFieldFallback({
  recordType: "Task",
  recordName: id,
  fields,
  protectedFields: ["title", "status", "created"],  // the 3 NEW fields are intentionally NOT protected
});
return droppedFields.length > 0 ? { id, title: input.title, droppedFields }
                                : { id, title: input.title };
```

Because `source` / `sourceClient` / `createdAt` are **not** in `protectedFields`, creates keep succeeding (fields silently dropped) until the schema catches up — then provenance starts sticking automatically. No deploy-ordering dependency with the iOS/schema side. Surfacing `droppedFields` in the result is optional but good for observability.

### 3. `sourceClient` — hardcode `"Claude"` for v1

The bound OAuth `clientId` lives in the access-token record but `getCkTokenForAccessToken()` (`src/storage.ts`) doesn't return it. Plumbing it through (return the full `AccessTokenRecord`, map `clientId` → friendly name) is a clean follow-up, but only Claude connects to `mcp.septena.app` today, so a literal `"Claude"` is correct now.

## Scope / do NOT do

- **Creates only.** Do **not** stamp `tasks_update` / `tasks_complete` / `tasks_defer`. Agent edits/completes are the higher-stakes "triage" posture, deliberately deferred past v1.
- Do not set `acknowledgedAt` anywhere in the gateway — it's a user-engagement field owned by the app.

## How to verify

1. Deploy. From Claude, create a task via MCP.
2. In the iOS app, the new task shows the agent cue (a leading accent dot) in the task list.
3. Engaging with it (open/complete/swipe "Mark seen") clears the cue, and it stays cleared across devices.
4. Before the prod schema deploy: confirm `droppedFields` includes `source`/`sourceClient`/`createdAt` (create still succeeds). After: `droppedFields` empty and the cue appears.
