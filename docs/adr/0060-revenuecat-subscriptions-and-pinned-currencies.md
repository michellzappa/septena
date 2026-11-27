# 0060. Standardize on RevenueCat and pin EUR, USD and GBP currencies

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0026](0026-plus-on-any-store-stripe-for-web.md) (per-store webhook integration and EUR-only web checkout)
- Builds on: [ADR 0023](0023-sync-across-devices-is-plus.md), [ADR 0059](0059-pro-sells-like-plus.md)

## Context

Septena sells Plus and Pro across three payment rails: Apple App Store (iPhone, iPad, Mac), Google Play (Android) and Stripe (Web and Windows). Maintaining separate receipt verifiers, server-to-server notifications, grace-period state machines, renewal analytics and refund handlers for three stores duplicates work that a subscription backend already solves.

At the same time, Septena uses a EUR baseline (€7 / €60 for Plus; €14 / €120 for Pro). Letting stores auto-equalize from a VAT-inclusive EU base produces awkward US/UK prices (because EU prices include ~21% VAT while US prices exclude sales tax) and leaves web/Windows buyers in USD/GBP facing foreign-currency card fees or dynamic FX drift that conflicts with the annual signup price guarantee.

## Decision

1. **Standardize on RevenueCat across all stores.** RevenueCat (free up to $2,500 USD Monthly Tracked Revenue, 1% above) manages subscriptions across Apple App Store, Google Play and Web/Windows (Stripe / RevenueCat Web Billing). Every purchase binds to the Septena backend user id (`u_…`) as RevenueCat's `app_user_id`. RevenueCat webhooks sync entitlement state (`plus` / `pro`, status, expiry, source) into the user's Durable Object `entitlements` table, so the server plan table and every limit gate remain unchanged.
2. **Pin EUR, USD, GBP and BRL; auto-equalize the rest from EUR.** Clean `.00` price points apply on Apple App Store, Google Play and Web/Windows checkout (BRL uses Brazil PPP pricing, added 2026-11-27):

   | Plan | EUR (base, incl. VAT) | USD (+ applicable tax) | GBP (incl. VAT) | BRL (PPP, incl. taxes) | Other storefronts |
   |---|---|---|---|---|---|
   | **Plus** | €7/month · €60/year | $7/month · $60/year | £6/month · £50/year | R$ 29/month · R$ 240/year | Auto-equalized from EUR |
   | **Pro** | €14/month · €120/year | $14/month · $120/year | £12/month · £100/year | R$ 58/month · R$ 480/year | Auto-equalized from EUR |

   - **App Store & Google Play:** Pin EUR, USD, GBP and BRL to the table above; let the store auto-equalize all other storefronts from the EUR base. Additional regional PPP tiers are deferred until post-launch.
   - **Web & Windows checkout:** Charge fixed EUR, USD, GBP or BRL prices matching the table above. Do not use dynamic FX conversion (such as Stripe Adaptive Pricing) on subscriptions.
   - **Website (`/pricing` and home plan cards):** Geo-default to EUR, USD, GBP or BRL via Cloudflare `CF-IPCountry` (`/api/geo`) with a quiet inline currency switcher directly above the plan cards (not in the footer) and currency-aware tax footnotes (VAT/tax included in EUR/GBP/BRL; plus applicable local sales tax in USD).
3. **Annual signup price guarantee currency and tax rule.** A subscriber's protected annual renewal price is locked in the **purchase currency within the same store** (never re-converted to EUR at renewal). The guarantee protects Septena's subscription price tier; statutory VAT or sales tax changes are excluded and disclosed plainly. Switching store or storefront currency starts a new subscription at current public pricing.

## Consequences

- **One subscription integration instead of three.** The Cloudflare Worker receives RevenueCat webhooks (and keeps admin `grant` and `trial` rows locally in the Durable Object) instead of maintaining separate Apple JWS, Google Play Developer API / RTDN and Stripe webhook state machines. The existing direct Apple JWS path (`backend/src/entitlement/appleJws.ts`) can be retired once RevenueCat is wired up.
- **Cost & privacy trade-off.** RevenueCat costs 0% up to $2,500 USD MTR and 1% above that threshold (measured and billed in USD). It introduces a subscription processor in the purchase path (amending the "no third-party SDK" wording in `docs/SYNC_SUBSCRIPTION_SPEC.md` §3.3 for billing state only; task data and sync traffic never touch RevenueCat).
- **Clean US/UK pricing and natural FX hedge.** USD `$7 / $60` (tax-exclusive) nets slightly more than EUR `€7 / €60` (VAT-inclusive) while keeping clean numbers, and GBP `£6 / £50` matches EU net proceeds. USD payouts naturally offset USD infrastructure costs (Cloudflare, RevenueCat, Apple).
- **Follow-up implementation work:** wire RevenueCat SDK + webhook handler into Apple/Android/Web/backend, extend `registry/plans.json` with pinned EUR/USD/GBP prices and tax footnotes across all three shells and `septena-site`, and configure pinned tiers in App Store Connect, Google Play and Stripe.

## Links

- [ADR 0026](0026-plus-on-any-store-stripe-for-web.md)
- [ADR 0059](0059-pro-sells-like-plus.md)
- `docs/SYNC_SUBSCRIPTION_SPEC.md`
- Pricing strategy: Starlings Septena workspace, `/strategy/pricing-strategy`
