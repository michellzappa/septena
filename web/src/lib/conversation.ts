// A task's conversation as the shared core sees it: one adapter for the rows,
// the Review and Agent lists, and the fade pass.

import {
  conversationState,
  deriveConversation,
  type CoreConversation,
  type CoreConversationState,
  type CoreProjection,
} from "./core/index.ts";
import type { ConvoRow, TurnRow } from "./types";

export interface EvaluatedConversation {
  projection: CoreProjection;
  state: CoreConversationState;
}

/** Null when the task has no conversation and no turns. */
export function evaluateConversation(
  convo: ConvoRow | null,
  turns: TurnRow[],
  now: string,
): EvaluatedConversation | null {
  if (!convo && turns.length === 0) return null;
  const core: CoreConversation = {
    confirmedIntent: convo?.confirmedIntent ?? null,
    thread: turns.map((t) => ({
      seq: t.seq,
      role: t.role,
      step: t.step,
      provider: t.provider ?? null,
      options: t.options ?? null,
      confidence: t.confidence ?? null,
    })),
    artifactExists: Boolean(convo?.artifact),
    handoffExists: Boolean(convo?.handoff),
    endState: convo?.endState ?? null,
    endStateNote: convo?.endStateNote ?? null,
    assignee: convo?.assignee ?? null,
    stoppedAt: convo?.stoppedAt ?? null,
    claimUntil: convo?.claimUntil ?? null,
  };
  return { projection: deriveConversation(core, now), state: conversationState(core, now) };
}

export function groupTurnsByTask(turns: TurnRow[]): Map<string, TurnRow[]> {
  const byTask = new Map<string, TurnRow[]>();
  for (const turn of turns) {
    const list = byTask.get(turn.taskId);
    if (list) list.push(turn);
    else byTask.set(turn.taskId, [turn]);
  }
  for (const list of byTask.values()) list.sort((a, b) => a.seq - b.seq);
  return byTask;
}
