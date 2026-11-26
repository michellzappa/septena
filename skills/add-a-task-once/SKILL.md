---
name: add-a-task-once
description: Create a Septena task exactly once. Search first, link the item the task comes from as a `from` reference, respect the `existing` and `dismissed` results, and retry with the same idempotency key. Use before every tasks_create, and always when the task comes from an email, an issue, an event or a web page.
---

# Add a task once

A person who finds the same task twice stops trusting the list. Septena helps
you avoid that: it matches the item a task comes from, it remembers proposals
the person turned down, and it replays a retried write.

## Procedure

1. **Check the item.** When the task comes from an email, a thread, an event,
   an issue or a page, call `tasks_find_by_ref` with its link or key. An open
   task that points at it already exists: tell the person, and do not create
   another. `dismissed: true` means the person turned down a proposal from this
   item: do not propose it again, and do not reword it.
2. **Search.** Call `tasks_search` with the words of the title. When a task
   with the same meaning exists, tell the person, or change that task with
   `tasks_update`.
3. **Resolve names.** Get area and project ids from `tasks_list_areas` and
   `tasks_list_projects`. Call `tasks_list_tags` and reuse the person's tag
   names.
4. **Declare who asked.** `origin: "user_request"` when the person asked for
   this task: it lands where you put it. `origin: "agent_suggestion"` (the
   default) when you found it yourself: it lands as a proposal in the Inbox.
5. **Create.** Call `tasks_create` with:
   - `refs: [{ "key": "<link or key>", "role": "from", "snapshot": { "title": "<its title>" } }]`
     for the item the task comes from. Never put message text in a snapshot.
   - `idempotency_key`: a new UUID for this one create.
6. **Read `placement`** and tell the person what happened:

   | placement | What it means | What you say |
   | --- | --- | --- |
   | `committed` | The task is in its list. | You added it. |
   | `inbox_proposal` | The task waits in the Inbox for the person's tap. | You proposed it. Never say "added to Today". |
   | `existing` | An active task has this `from` key. Nothing was created. `matched_keys` names the key. | It exists already. |
   | `dismissed` | The person turned down a proposal from this item. Nothing was created. | Nothing. Do not propose it again. |

   When only a closed task (done, cancelled or faded) has the key, Septena
   creates the task and adds a `follow_up` reference to the old one.
   Pass `allow_duplicate: true` only when the person wants a second task.

## Retry

- After a lost reply or a host error (for example "too many calls already
  running"), send the same call with the same `idempotency_key`. Septena
  returns the first result and does not write again.
- A refusal carries `{ error: { code, message, hint, retryable } }`. Send the
  call again only when `retryable` is `true`.
- `idempotency_conflict` means you sent a key again with a different body. A
  new write needs a new key.
- For many tasks, create them one after another or in small groups.

## Reference keys

`email:<Message-ID>`, `thread:<root Message-ID>`, `event:<iCal UID>`,
`issue:<owner>/<repo>#<n>`, `task:<task id>`, `url:<web URL>`, a web URL or a
`message://` link. Septena stores one normal form, so every spelling of one
item is one key. A task holds up to 20 references.

Full brief: https://api.septena.app/skill.md.
