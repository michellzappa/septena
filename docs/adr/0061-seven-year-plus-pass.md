# 0061. Offer a 7-year one-time Plus pass at half the annual rate

- Status: accepted (2026-11-27)
- Date: 2026-11-27
- Deciders: mz
- Amends: [ADR 0023](0023-sync-across-devices-is-plus.md) (adds a one-time Plus option), [ADR 0060](0060-revenuecat-subscriptions-and-pinned-currencies.md) (adds the 7-year Plus product and pinned prices)
- Builds on: [ADR 0011](0011-self-hostable-backend.md), [ADR 0026](0026-plus-on-any-store-stripe-for-web.md), [ADR 0059](0059-pro-sells-like-plus.md), [ADR 0060](0060-revenuecat-subscriptions-and-pinned-currencies.md)

## Context

Subscription fatigue is one of the strongest objections among task-app switchers (especially people coming from Things 3 and OmniFocus). Earlier specs ruled out a "lifetime" product because selling open-ended server access for a single payment creates unbounded long-term liability (`docs/SYNC_SUBSCRIPTION_SPEC.md` §4).

Septena's actual unit economics leave room for a time-boxed upfront pass:

- Hosted sync on Cloudflare Workers + Durable Objects costs an estimated ~$0.015/month per active user (~$1.25 over 7 years).
- Worst-case 10 GB of R2 attachments filled for the entire 7 years costs ~$12.60 (typical users store far less).
- Users bring their own AI provider, so inference costs Septena $0.
- The backend is already MIT-licensed and self-hostable on a user's own Cloudflare account (ADR 0011), giving users a real, permanent no-lock-in exit path alongside export.

Seven years matches the product name (*Septena*), spans more than a full hardware lifecycle, bounds server liability, and avoids misleading "lifetime" claims. Against the **€70/year ($70/year)** Plus plan, **€210 ($210)** is exact **3× annual** (pay for 3 years, get 7 — €30/$30 a year), keeping every Septena price a clean multiple of 7 (`7 / 70 / 210` for Plus; `14 / 140` for Pro).

## Decision

1. **Offer a 7-Year Plus Pass as a one-time purchase — Plus only.**
   - **Septena Plus 7-Year Pass** grants 7 years of Plus across every platform (iOS, iPadOS, macOS, Watch, Android, Windows, Web) for the price of 3 annual years (**€210 / $210**):

     | Plan | EUR (base, incl. VAT) | USD (1:1 parity, + applicable sales tax) | Other storefronts |
     |---|---|---|---|
     | **Plus (7-Year Pass)** | **€210** (€30/yr) | **$210** ($30/yr) | Auto-equalized from EUR |

   - **No one-time Pro pass.** Pro (€14/month · €140/year; $14/month · $140/year) stays subscription-only while multi-agent MCP traffic and 50 GB attachment loads remain unmeasured.
   - **Naming:** Always call it a **"7-Year Pass"** (or "7 years of Plus"). Never market it as "lifetime".

2. **Store product types and RevenueCat / backend handling.**
   - **Apple App Store (iOS, iPadOS, Mac App Store):** **Non-Renewing Subscription** (`com.septena.tasks.sync.plus.7year`). Do *not* use a Non-Consumable, because App Review prohibits expiring Non-Consumables.
   - **Google Play:** Re-purchasable one-time product (`com.septena.tasks.sync.plus.7year`).
   - **Web & Windows (Stripe / RevenueCat Web Billing):** One-time Checkout (`mode: "payment"`) in fixed EUR, USD, GBP or BRL.
   - **Entitlement storage:** RevenueCat `NON_RENEWING_PURCHASE` webhooks map `app_user_id` (`u_…`) into the user's `TaskStore` Durable Object `entitlements` table with `expiresAt = max(now, currentPlusExpiresAt) + 7 years` (stackable if extended early; set to `revoked` on refund). Existing server gates (`resolvePlan`, `PLAN_TABLE`) stay unchanged.
   - **Upgrading from 7-Year Plus to Pro:** Because Apple Non-Renewing Subscriptions live outside the auto-renewing subscription group, Apple does not auto-prorate upgrades to Pro. A 7-Year Plus buyer who subscribes to Pro receives Pro while active (`resolvePlan` prefers `pro`) and falls back cleanly to their remaining 7-Year Plus window if they cancel Pro. The paywall discloses plainly that subscribing to Pro does not auto-refund a 7-Year Pass.

3. **Pair with free self-hosting (ADR 0011) as the permanence guarantee.**
   - Keep self-hosting on the user's own Cloudflare account free and unsupported (ADR 0011), and surface it on `/pricing` as the no-lock-in escape hatch alongside JSON export.
   - At Year 7 expiry, no data is deleted. The user can buy another 7-Year Pass, switch to monthly or annual Plus, drop to the free 1-device account, or move to their own self-hosted Cloudflare Worker.
   - Future optional fan revenue (such as *The Instrument* book or merch) stays separate from core task and sync pricing.

## Consequences

- **Stronger positioning against Things 3 and subscription fatigue:** Buyers who refuse recurring subscriptions get an honest upfront option across every OS plus an open-source self-hosting exit, without breaking the free-on-one-device + 14-day reverse-trial funnel.
- **Healthy upfront unit economics:** On EU App Store sales, €210 nets ~€147 after VAT (~21%) and Apple's 15% cut (~€169 on Stripe web) against ~$1.25–$14 of estimated 7-year Cloudflare costs.
- **No proration between 7-Year Plus and Pro on Apple:** Requires one clear line on the paywall when a 7-Year Plus holder views Pro.
- **Deferred revenue accounting:** VAT is due at sale, while the revenue is recognized over 7 years under EU corporate accounting; Envisioning Technology bookkeeping must confirm deferred-revenue treatment before checkout opens.
- **Follow-up implementation work:** Add the 7-year Plus product to `registry/plans.json` (plus `gen-registries.mjs`), configure `com.septena.tasks.sync.plus.7year` as a Non-Renewing Subscription in App Store Connect, a one-time product in Google Play, and a one-time price in Stripe / RevenueCat, handle `NON_RENEWING_PURCHASE` expiry calculation in the RevenueCat webhook, and complete the ADR 0011 self-hosting checklist before advertising self-hosting publicly.

## Links

- [ADR 0011](0011-self-hostable-backend.md)
- [ADR 0023](0023-sync-across-devices-is-plus.md)
- [ADR 0026](0026-plus-on-any-store-stripe-for-web.md)
- [ADR 0059](0059-pro-sells-like-plus.md)
- [ADR 0060](0060-revenuecat-subscriptions-and-pinned-currencies.md)
- `docs/SYNC_SUBSCRIPTION_SPEC.md`
- Starlings Septena workspace: `/strategy/pricing-strategy`, `/strategy/free-and-paid-plans`
