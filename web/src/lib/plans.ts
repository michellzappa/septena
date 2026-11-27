// The account's plan and the plan sheet's choices, the web side of Apple
// `PlanStatus` / `PlanTier` (docs/PREMIUM_LANGUAGE.md, spec §7.1). The server
// decides access; this only reads its answer.

import { DESIGN_TOKENS, PLAN_UI } from "@/lib/generated/registries";
import type { Entitlement } from "@/lib/types";

export type PlanTier = "plus" | "pro";
export const PLAN_TIERS: readonly PlanTier[] = ["plus", "pro"];

/** The plan as the account has it (Apple `PlanStatus.Plan`). */
export type AccountPlan =
  | { kind: "device" }
  | { kind: "free"; lapsed: boolean }
  | { kind: "trial"; endsAt: number }
  | { kind: "plus"; source: string; through: number | null; pro: boolean };

export function accountPlan(answer: Entitlement | null, signedIn: boolean): AccountPlan | null {
  if (!signedIn) return { kind: "device" };
  if (!answer) return null;
  const live = answer.entitlements.filter((r) => r.active);
  if (!answer.active || live.length === 0) {
    return { kind: "free", lapsed: answer.entitlements.some((r) => r.source !== "trial") };
  }
  const pro = answer.plan === "pro";
  const paid = live.filter((r) => (pro ? r.plan === "pro" : r.source !== "trial"));
  if (paid.length === 0) {
    const end = answer.trialEndsAt ?? Math.max(0, ...live.map((r) => r.expiresAt ?? 0));
    return { kind: "trial", endsAt: end };
  }
  const forever = paid.find((r) => r.expiresAt == null);
  if (forever) return { kind: "plus", source: forever.source, through: null, pro };
  const latest = paid.reduce((a, b) => ((b.expiresAt ?? 0) > (a.expiresAt ?? 0) ? b : a));
  return { kind: "plus", source: latest.source, through: latest.expiresAt ?? null, pro };
}

/** The account's paid plan: Pro, Plus (bought, given or the trial), else null. */
export function currentTier(plan: AccountPlan | null): PlanTier | null {
  if (!plan) return null;
  if (plan.kind === "plus") return plan.pro ? "pro" : "plus";
  if (plan.kind === "trial") return "plus";
  return null;
}

/** The plans above the account's: none on Pro, Pro on Plus, else both. */
export function tiersAbove(plan: AccountPlan | null): PlanTier[] {
  if (plan?.kind === "plus") return plan.pro ? [] : ["pro"];
  return [...PLAN_TIERS];
}

/** The plan a sheet opens on: Pro for a Plus account, else the moment's plan, else Plus. */
export function recommendedTier(upsellId: string | null, plan: AccountPlan | null): PlanTier {
  if (plan?.kind === "plus" && !plan.pro) return "pro";
  const moment = upsellId ? PLAN_UI.upsells.find((u) => u.id === upsellId) : undefined;
  return moment?.plan === "pro" ? "pro" : "plus";
}

export const tierName = (tier: PlanTier): string => (tier === "pro" ? PLAN_UI.proName : PLAN_UI.shortName);
export const tierCard = (tier: PlanTier) => PLAN_UI.cards.find((c) => c.id === tier);
export const tierPrices = (tier: PlanTier) => (tier === "pro" ? PLAN_UI.proPrices : PLAN_UI.prices);
export const tierBenefits = (tier: PlanTier) => PLAN_UI.benefits[tier];
export const upsellMoment = (id: string | null) => (id ? PLAN_UI.upsells.find((u) => u.id === id) ?? null : null);

/** The status line for the account's plan (plans.json `status`), English; localize with registryText. */
export function statusLine(plan: AccountPlan | null): { text: string; vars?: Record<string, string> } | null {
  if (!plan) return null;
  const day = (ms: number) => new Date(ms).toLocaleDateString(undefined, { dateStyle: "medium" });
  switch (plan.kind) {
    case "device":
      return { text: PLAN_UI.status.device };
    case "free":
      return { text: PLAN_UI.status.free };
    case "trial":
      return { text: PLAN_UI.status.trialEnds, vars: { date: day(plan.endsAt) } };
    case "plus":
      if (plan.through != null) {
        return { text: plan.pro ? PLAN_UI.status.proThrough : PLAN_UI.status.paidThrough, vars: { date: day(plan.through) } };
      }
      return null;
  }
}

type Fruit = (typeof DESIGN_TOKENS.fruitAccents)[number];

/**
 * The premium language's colors (docs/PREMIUM_LANGUAGE.md): the brand is the
 * Magic Plus color (Persimmon under Colorful, the fruit otherwise); a benefit
 * tile keeps its semantic color under Colorful and takes the accent otherwise.
 */
export function planColors(fruit: Fruit, isDark: boolean): Record<string, string> {
  const persimmon = DESIGN_TOKENS.fruitAccents.find((f) => f.id === "persimmon");
  const brand = fruit.multicolor && persimmon ? persimmon : fruit;
  const accent = isDark ? fruit.dark : fruit.light;
  const glyphs: Record<string, string> = DESIGN_TOKENS.multicolorGlyphs;
  const colors: Record<string, string> = DESIGN_TOKENS.colors;
  const tile = (icon: string) => (fruit.multicolor && glyphs[icon] ? colors[glyphs[icon]] ?? accent : accent);
  return {
    "--brand": isDark ? brand.dark : brand.light,
    "--brand-ink": isDark ? brand.checkDark : brand.checkLight,
    "--plan-devices": tile("plans.devices"),
    "--plan-agents": tile("plans.agents"),
    "--plan-files": tile("plans.files"),
    "--plan-history": tile("plans.history"),
    "--plan-plus": isDark ? brand.dark : brand.light,
  };
}
