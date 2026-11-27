"use client";

// The premium language on the web (docs/PREMIUM_LANGUAGE.md), the same pieces
// as Apple `PlanLanguage.swift` and Android `PlanLanguage.kt`: the plan mark,
// the wordmark, the plan head, the benefit row, and the plan sheet that says
// why the reader sees it before it names a price. Colors come from the CSS
// variables `planColors` sets (--brand, --plan-*).

import { useEffect, useState } from "react";
import { X } from "lucide-react";
import { PLAN_UI, registryText } from "@/lib/generated/registries";
import {
  type AccountPlan,
  type PlanTier,
  recommendedTier,
  tierBenefits,
  tierCard,
  tierName,
  tierPrices,
  tiersAbove,
  upsellMoment,
} from "@/lib/plans";
import { RegistryIcon } from "./RegistryIcon";

const TILE_COLOR: Record<string, string> = {
  "plans.devices": "var(--plan-devices)",
  "plans.agents": "var(--plan-agents)",
  "plans.files": "var(--plan-files)",
  "plans.history": "var(--plan-history)",
  "plans.plus": "var(--plan-plus)",
};

/** The plan's tile: Plus a brand tile with an ink glyph, Pro an ink tile with a brand glyph. */
export function PlanMark({ tier, size = 44 }: { tier: PlanTier; size?: number }) {
  const pro = tier === "pro";
  return (
    <span
      aria-hidden="true"
      className="inline-flex shrink-0 items-center justify-center"
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.27,
        background: pro ? "var(--text-primary)" : "linear-gradient(180deg, var(--brand), color-mix(in srgb, var(--brand) 82%, black))",
        color: pro ? "var(--brand)" : "var(--brand-ink)",
      }}
    >
      <RegistryIcon token={pro ? "plans.pro" : "plans.plus"} strokeWidth={2.75} style={{ width: size * 0.52, height: size * 0.52 }} />
    </span>
  );
}

/** "Septena Plus" / "Septena Pro": the product in the text color, the plan name in the brand color. */
export function PlanWordmark({ tier, lang, className = "text-xl" }: { tier: PlanTier; lang: string; className?: string }) {
  const name = registryText(tierName(tier), lang);
  const full = registryText(tierCard(tier)?.title ?? tierName(tier), lang);
  const product = full.replace(name, "").trim();
  return (
    <span className={`font-bold tracking-tight text-[var(--text-primary)] ${className}`}>
      {product ? `${product} ` : ""}
      <span style={{ color: "var(--brand)" }}>{name}</span>
    </span>
  );
}

/** Mark, wordmark and one line under it. */
export function PlanHead({ tier, line, lang, markSize = 56 }: { tier: PlanTier; line?: string | null; lang: string; markSize?: number }) {
  return (
    <div className="flex items-center gap-3.5">
      <PlanMark tier={tier} size={markSize} />
      <div className="min-w-0">
        <PlanWordmark tier={tier} lang={lang} />
        {line ? <p className="mt-0.5 text-sm text-[var(--text-secondary)]">{line}</p> : null}
      </div>
    </div>
  );
}

/** One benefit: a tile in its color, a title, one line of detail. Text wraps. */
export function PlanBenefitRow({ benefit, lang }: { benefit: { icon: string; title: string; detail: string }; lang: string }) {
  return (
    <div className="flex items-start gap-3">
      <span
        aria-hidden="true"
        className="inline-flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-[8px] text-white"
        style={{ background: TILE_COLOR[benefit.icon] ?? "var(--accent)" }}
      >
        <RegistryIcon token={benefit.icon} className="h-4 w-4" strokeWidth={2.25} />
      </span>
      <div className="min-w-0">
        <p className="text-sm font-semibold text-[var(--text-primary)]">{registryText(benefit.title, lang)}</p>
        <p className="text-[13px] text-[var(--text-secondary)]">{registryText(benefit.detail, lang)}</p>
      </div>
    </div>
  );
}

/** The plan's price: the highlighted one strong, the other after it, and the 7-Year Pass under Plus (ADR 0061). */
export function PlanPriceLine({ tier, lang }: { tier: PlanTier; lang: string }) {
  const prices = tierPrices(tier);
  const main = prices.find((p) => p.highlighted) ?? prices[0];
  return (
    <div>
      <p className="text-base font-semibold text-[var(--text-primary)]">{registryText(main.label, lang)}</p>
      <p className="text-[13px] text-[var(--text-secondary)]">{registryText(main.detail, lang)}</p>
      {prices
        .filter((p) => p.id !== main.id)
        .map((p) => (
          <p key={p.id} className="text-[13px] text-[var(--text-secondary)]">
            {registryText(p.label, lang)}
          </p>
        ))}
      {tier === "plus" ? (
        <div className="mt-2">
          <p className="text-[13px] font-medium text-[var(--text-primary)]">{registryText(PLAN_UI.pass.label, lang)}</p>
          <p className="text-xs text-[var(--text-secondary)]">{registryText(PLAN_UI.pass.rateDetail, lang)}</p>
        </div>
      ) : null}
    </div>
  );
}

/**
 * The plan sheet (spec §7.1): why it opened, which plan, what that plan gives,
 * then the price. The web does not sell yet (web checkout is #43), so under
 * the price it says where to buy, or that checkout opens at launch.
 */
export function PlanSheet({
  open,
  onClose,
  plan,
  upsellId,
  initialTier,
  lang,
}: {
  open: boolean;
  onClose: () => void;
  plan: AccountPlan | null;
  upsellId: string | null;
  initialTier?: PlanTier | null;
  lang: string;
}) {
  const tiers = tiersAbove(plan);
  const fallback = initialTier ?? recommendedTier(upsellId, plan);
  const [picked, setPicked] = useState<PlanTier | null>(null);
  useEffect(() => {
    if (open) setPicked(null);
  }, [open, upsellId, initialTier]);
  if (!open || tiers.length === 0) return null;
  const chosen = picked ?? fallback;
  const tier = tiers.includes(chosen) ? chosen : tiers[0];
  const moment = upsellMoment(upsellId);
  const notice = PLAN_UI.checkout.open ? PLAN_UI.paywall.buyElsewhere : PLAN_UI.checkout.notice;
  const cancel = PLAN_UI.promises.find((p) => p.id === "cancel");
  const hostage = PLAN_UI.promises.find((p) => p.id === "no_hostage");

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      onClick={(e) => {
        // The sheet can open over Settings: a click outside closes only the sheet.
        e.stopPropagation();
        onClose();
      }}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label={registryText(tierCard(tier)?.title ?? PLAN_UI.name, lang)}
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key === "Escape") onClose();
        }}
      >
        <div className="flex justify-end px-3 pt-3">
          <button
            type="button"
            onClick={onClose}
            aria-label={registryText("Not Now", lang)}
            className="rounded-lg p-1.5 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="space-y-5 px-6 pb-6">
          {moment ? (
            <div>
              <p className="text-lg font-semibold text-[var(--text-primary)]">{registryText(moment.title, lang)}</p>
              <p className="mt-1 text-sm text-[var(--text-secondary)]">{registryText(moment.detail, lang)}</p>
            </div>
          ) : (
            <div>
              <p className="text-xl font-bold text-[var(--text-primary)]">{registryText(PLAN_UI.name, lang)}</p>
              <p className="mt-1 text-sm text-[var(--text-secondary)]">{registryText(PLAN_UI.headline, lang)}</p>
            </div>
          )}

          {tiers.length > 1 ? (
            <div
              role="radiogroup"
              aria-label={registryText(PLAN_UI.paywall.choosePlan, lang)}
              className="grid grid-cols-2 rounded-lg bg-[var(--bg-hover)] p-0.5"
            >
              {tiers.map((t) => (
                <button
                  key={t}
                  type="button"
                  role="radio"
                  aria-checked={t === tier}
                  onClick={() => setPicked(t)}
                  className={`rounded-md py-1.5 text-sm font-medium ${
                    t === tier ? "bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-sm" : "text-[var(--text-secondary)]"
                  }`}
                >
                  {registryText(tierName(t), lang)}
                </button>
              ))}
            </div>
          ) : null}

          <PlanHead tier={tier} line={registryText(tierCard(tier)?.detail ?? "", lang)} lang={lang} markSize={44} />
          <div className="space-y-3">
            {tierBenefits(tier).map((b) => (
              <PlanBenefitRow key={b.id} benefit={b} lang={lang} />
            ))}
          </div>

          <div className="rounded-xl border border-[var(--border-subtle)] p-4">
            <PlanPriceLine tier={tier} lang={lang} />
            <p className="mt-3 text-[13px] text-[var(--text-secondary)]">{registryText(notice, lang)}</p>
          </div>

          <div className="space-y-0.5 text-center text-xs text-[var(--text-muted)]">
            {cancel ? <p>{registryText(cancel.title, lang)}</p> : null}
            {hostage ? <p>{registryText(hostage.title, lang)}</p> : null}
            <a href={PLAN_UI.compareURL} target="_blank" rel="noreferrer" className="inline-block pt-1 text-[var(--accent)] hover:underline">
              {registryText(PLAN_UI.paywall.compareAll, lang)}
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}
