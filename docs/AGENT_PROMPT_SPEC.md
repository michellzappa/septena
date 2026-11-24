# Agent prompt: one pattern for every agent exchange

Status: building (2026-11-24). Shipped on iPhone, iPad and Mac (#396). Android has
the agent prompt and the review page; its Review list rows are open (#412).

## Problem

An agent asks the user for something in three places, and each place drew its
own controls:

- an open question (option pills, then an "Other…" field),
- a Review hand-off (`needs_verify`: a small "Needs review" label with a yellow
  eye, then Accept and Send back, then a one-line "What needs another pass?"
  field),
- a follow-up reply ("Reply…", then a one-line field).

The text was small, the one-line fields cut off what the user typed, the
button order changed between the Review row and the task page, and the touch
targets were below 44pt.

## The pattern

Model: the Claude Code permission prompt. A clear question, the choices as a
short vertical list, and a last choice that lets the user type what to do
instead.

One **agent prompt** has four parts, top to bottom:

1. **Kicker**: one small line, secondary ink. Who asks and when:
   "Review requested · 2h ago" or "Your agent asks". No icon. No agent name:
   several agents can hand off.
2. **Question**: the thing to answer, at body size or larger, primary ink,
   never truncated. For Review this is the agent's `endStateNote` (what to
   check). For an open question it is the turn's `question`.
3. **Choices**: a vertical list of full-width buttons, at most one primary.
   Touch targets are 44pt (`ControlSize.taskAction` = `.large` on touch,
   `.small` on the Mac).
4. **Tell the agent instead**: the last choice. A tap turns it, in place, into
   a multi-line field (grows to about 6 lines) with the registry prompt's
   placeholder, a primary button with the prompt's `confirmTitle`, and Cancel.
   The field takes focus. Mac: ⌘Return sends, Escape cancels. The draft stays
   while the user switches away inside the session.

The free-text copy comes from `registry/surfaces.json` `prompts.text`:
`sendBackReview`, `conversationOther`, `conversationReply`. The kickers and
fallbacks come from the `conversation` block in the same file (`askKicker`,
`reviewKicker`, `reviewFallback`, `acceptedLabel`).

## The three uses

| Use | Kicker | Question | Choices | Free text |
| --- | --- | --- | --- | --- |
| Review (`needs_verify`) | "Review requested · {ago}" | `endStateNote`, or "Ready for review" | Accept (primary) | `sendBackReview` ("Send back…") |
| Open question | "Your agent asks" | turn `question` | each option | `conversationOther` ("Other…") |
| Follow-up | none | none | none | `conversationReply` ("Reply…"), field only |

Order is the same on every surface: **Accept first, Send back second**, on the
Review row, in the task page and in the Mac inspector.

## Review row

The row shows the title, the list (area › project), the full review note,
"asked {ago}", then Accept and Send back on their own line. Send back on the
row does not open a field in the row: it opens the task page with the Send
back field already open and focused. A tap anywhere else opens the task page.

## Review page

A task in Review opens at the registry `review` depth (`surfaces.json`
`taskPage`): title, notes, the conversation (with the agent prompt) and Added
by. The list (area › project) shows as one read-only line under the title.

## Data

`convos.endStateAt` (registry `entities.json`, server-owned): the backend
stamps it each time `endState` changes. The apps read it, never write it.
"{ago}" is a relative time from it. A task handed to Review before this field
existed has no stamp and shows no "{ago}".
