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
2. **Thematic EUR = USD 1:1 parity; auto-equalize everything else from EUR (amended by mz, 2026-11-27).** EUR is the canonical baseline in `registry/plans.json` (**€7/month · €70/year · €210 / 7 years** for Plus; **€14/month · €140/year** for Pro), and **USD matches 1:1 numerically** (**$7/month · $70/year · $210 / 7 years** for Plus; **$14/month · $140/year** for Pro) because EU prices include ~21% VAT while US prices exclude local sales tax — keeping the thematic multiples of 7 (`7 / 70 / 210`, `14 / 140`) intact in both EUR and USD without hurting net proceeds.
   - **App Store & Google Play:** Set the EUR baseline (`€7 / €70 / €210`, `€14 / €140`), pin USD 1:1 (`$7 / $70 / $210`, `$14 / $140`), and let each store auto-equalize every other storefront from the EUR base.
   - **Web & Windows checkout:** Anchor EUR (`€7 / €70 / €210`, `€14 / €140`) and USD 1:1 (`$7 / $70 / $210`, `$14 / $140`) via RevenueCat / Stripe, letting Stripe/RevenueCat handle local currency presentation elsewhere.
   - **Website (`/pricing` and home plan cards):** Show a minimal inline currency dropdown directly above the plan cards (not in the footer) with only `EUR` and `USD`, plus the visitor's own local currency auto-detected via `/api/geo` (`CF-IPCountry` + daily edge-cached EUR FX rates) whenever they visit from outside EUR/USD. `EUR` shows exact VAT-inclusive numbers; `USD` shows exact 1:1 numbers with a "+ applicable local sales tax" footnote; any other local currency shows an approximate live-FX conversion from EUR with an estimate footnote.
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
