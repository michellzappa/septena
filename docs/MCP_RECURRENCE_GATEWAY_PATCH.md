# MCP recurrence — pending gateway mirror

**Status: HALF-LANDED.** The in-app MCP server (`SeptenaCore/MCP/`) now exposes
task recurrence. The hosted gateway (`../septena-mcp-gateway`) does **not** yet,
because that repo was not available on the machine where this landed.

This violates the lockstep rule in CLAUDE.md ("any MCP tool change must land in
BOTH, plus the docs/skills, in the same change"). It is written down here so the
divergence is visible rather than silent. **Close it before treating recurrence
as available to consumer chat** — until then, `tasks_create` / `tasks_update`
over the gateway silently ignore a `recurrence` argument, which is exactly the
failure mode the rule exists to prevent.

## What landed in the app

| File | Change |
|---|---|
| `SeptenaCore/MCP/MCPToolCatalog.swift` | `recurrenceSchema` fragment; added to `tasks_create` + `tasks_update` properties |
| `SeptenaCore/MCP/MCPDispatch.swift` | `recurrenceArg(_:scheduled:)` parse + validate; `recurrenceJSON(_:)` emit; wired into `tasksCreate`, `tasksUpdate`, `tasksGet`, `taskJSON` |
| `Septena/Shell/Tasks/TasksSkill.swift` | tool input lines + an "every Monday" worked example |

No tool **names** changed, so `MCPToolCatalog.expectedNames` (the drift
tripwire) is unaffected.

## Wire shape

Mirrors the app's own `Recurrence` Codable keys, so an agent-set rule is
byte-identical to one set in the repeat picker.

```jsonc
"recurrence": {
  "unit": "day" | "week" | "month",   // required
  "interval": 1,                       // optional, >= 1, default 1
  "after_completion": true             // optional, default true
}
```

- `tasks_create`: optional. Echoed back in the result when set.
- `tasks_update`: present-with-object sets, **present-with-null clears**, absent
  leaves untouched (same convention as `notes` / `scheduled`).
- `tasks_get` and every `taskJSON` row emit `recurrence` when the task has one,
  in the same shape they accept — a read round-trips into a write unchanged.

## The one validation that matters

`after_completion: false` anchors on the task's **scheduled date**. With no
scheduled date the anchor silently falls back to the completion day, i.e. the
rule degrades into `after_completion: true` while still claiming to be fixed.

So the gateway must reject it, as the app does:

> `recurrence.after_completion=false anchors on the task's scheduled date, so
> the task needs one. Set 'scheduled' in this same call, or use
> after_completion=true to count from the completion day instead.`

On `tasks_update`, validate against the schedule **after** any `scheduled` in
the same call — the app applies recurrence last and re-reads the stored value
(`scheduledOf(id)`) for exactly this reason.

Also accept `afterCompletion` as an alias for `after_completion` on input. A
model guessing the camelCase spelling otherwise gets the opposite anchor
silently, which is the same class of bug.

## Gateway files to touch

Per the mirror comment at the top of `MCPToolCatalog.swift`:

- `../septena-mcp-gateway/src/mcp.ts` — `GLOBAL_TOOLS` / `SECTION_TOOLS`
- `../septena-mcp-gateway/src/tools/*.ts` — the `*JsonSchema` literals
- `skill.md` — generated from `SectionRegistry.fullSkillMarkdown()`, so
  regenerate after the app-side skill change above

## Why `after_completion` is not cosmetic

"Every Monday" and "every week after I finish it" are different rules that
diverge the moment the user is late. Fixed keeps the weekday; after-completion
walks it forward. An agent that can only express the default silently converts
every named-weekday request into a drifting one.
