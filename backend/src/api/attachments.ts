import type { Env } from "../env.js";
import { attachmentQuotaBytes, decide, type LimitBreach, type PlanState } from "../entitlement/entitlement.js";

// What an app upload (`PUT /v1/attachments/:id`) and an agent upload
// (src/shadow/attachments.ts) share: where the bytes live, and the plan gate.

export function attachmentKey(userId: string, id: string): string {
  return `u/${userId}/att/${id}`;
}

export interface AttachmentRefusal {
  error: "attachments_not_in_plan" | "attachment_quota";
  breach: LimitBreach;
}

/// Server attachments are a plan limit: none on the free account (files stay
/// on the device that added them), a quota on Plus. null = the bytes fit.
export async function attachmentRefusal(
  env: Env, userId: string, plan: PlanState | null, length: number, storedBytes: () => Promise<number>,
): Promise<AttachmentRefusal | null> {
  const quota = plan ? attachmentQuotaBytes(plan.limits) : null;
  if (!plan || quota === null || (quota > 0 && (await storedBytes()) + length <= quota)) return null;
  const breach: LimitBreach = { limit: "attachmentsGB", upsell: "file_elsewhere" };
  if (decide(env, userId, "attachment_upload", plan, breach) !== "block") return null;
  return { error: quota === 0 ? "attachments_not_in_plan" : "attachment_quota", breach };
}
