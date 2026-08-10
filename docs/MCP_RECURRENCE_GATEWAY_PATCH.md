# MCP recurrence — lockstep record

**Status: LANDED on both servers.**

- App / in-app MCP server: `septena@46e3845`
- Hosted gateway: `septena-mcp-gateway@86af246`

Kept as a record because the two repos have no shared history and the gateway
has no remote, so this is the only place the pairing is written down. If you
touch task recurrence again, both commits move together.

**Not yet deployed.** The gateway commit is on disk on `mz-mbp`; the running
Worker still serves the previous build. Consumer chat cannot set a repeat rule
until `npm run deploy` runs from that repo — and, more urgently, until then the
*deployed* recurrence math still disagrees with the app's (see below).

## Why the math half was urgent

`src/recurrence.ts` was a literal port of the app's `RecurrenceDateCalculator`.
Both surfaces derive a generated occurrence's record name from
`(source task id + next scheduled date)`, and that deterministic id is the only
thing making a phone completion and a chat completion of the same task converge
on one record instead of two.

So changing the Swift date math alone silently broke convergence. Any change to
one implementation is a change to both, always.

The specific fix: month-end preservation on a **fixed** schedule. Clamping alone
made a monthly rule decay — Jan 31 clamps to Feb 28, the next occurrence
re-anchors on that stored date, and the series walks Mar 28 → Apr 28 and never
returns to month-end. Gated on `!afterCompletion`, because an after-completion
rule anchors on whatever day the box was ticked, where snapping would invent a
month-end intent the user never expressed.

Verified equal across both languages, not assumed:

| case | result |
|---|---|
| `2026-01-31` fixed monthly, 4 steps | `02-28, 03-31, 04-30, 05-31` |
| `2026-01-15` fixed monthly | `02-15` (ordinary day untouched) |
| `2026-02-28` after-completion monthly | `03-28` (no snap) |
| scheduled `08-03`, completed `08-22`, weekly fixed | `08-24` (weekday kept) |
| `occurrenceID("task-1", "2026-08-05")` | `recur-d8ec483a6cf756f9` (TS == FNV-1a reference) |

## Wire shape

Identical on both servers, mirroring the app's own `Recurrence` JSON so a rule
set from chat is byte-identical to one set in the repeat picker.

```jsonc
"recurrence": {
  "unit": "day" | "week" | "month",   // required
  "interval": 1,                       // optional, >= 1, default 1
  "after_completion": true             // optional, default true
}
```

- `tasks_create`: optional, echoed back in the result when set.
- `tasks_update`: object sets, **null clears**, absent leaves untouched.
- `tasks_get` / `tasks_list`: emitted in the shape the writes accept, so a read
  round-trips into a write.
- `afterCompletion` is accepted as an input alias on both sides. A model
  guessing the camelCase spelling would otherwise get the opposite anchor
  silently.

## The validation that matters

`after_completion: false` anchors on the task's **scheduled date**. With no
scheduled date the anchor falls back to the completion day — the rule degrades
into `after_completion: true` while still claiming to be fixed. Both servers
reject it:

> `recurrence.after_completion=false anchors on the task's scheduled date, so
> the task needs one. Set 'scheduled' in this same call, or use
> after_completion=true to count from the completion day instead.`

On update, both validate against the schedule set in the **same call** — the app
re-reads via `scheduledOf(id)`, the gateway does a lookup only when the rule
needs an anchor the call didn't supply.

"Every Monday" and "every week after I finish it" are different rules that
diverge the moment the user is late. An agent that can only express the default
silently converts every named-weekday request into a drifting one.
