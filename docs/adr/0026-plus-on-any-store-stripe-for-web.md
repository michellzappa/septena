# 0026. Sell Plus on any store, one account entitlement, Stripe for web

- Status: accepted (2026-11-22)
- Date: 2026-11-22
- Deciders: mz
- Builds on: [ADR 0010](0010-free-server-tier-with-limits.md),
  [ADR 0023](0023-sync-across-devices-is-plus.md)

## Context

Septena Plus (ADR 0023) sells sync on every device. The apps run on
iPhone, iPad, Mac and Apple Watch now. A web client, Windows and Android
are planned on the same account and backend. Each platform has its own
payment rules:

- Apple requires in-app purchase for a digital subscription sold inside an
  App Store app (App Review Guideline 3.1.1). A multiplatform service may
  let users use a subscription bought elsewhere (3.1.3(b)), as long as the
  app also sells it through in-app purchase.
- Google Play requires Play Billing for a digital subscription sold inside
  a Play Store app. An app may honor a subscription bought elsewhere.
- The Microsoft Store lets non-game apps use their own payment system. A
  Windows build outside the Store has no rule.
- The web has no store.

The backend already stores one entitlement row per source of access
(`apple`, `stripe`, `grant`) and puts the account on Plus when any row is
active (`docs/SYNC_SUBSCRIPTION_SPEC.md` §6). The plan is the account's,
not the device's.

The spec named Stripe for the web. The alternative was a merchant of record
(Paddle, Lemon Squeezy), which is the legal seller and files VAT and sales
tax in every country for about 5% a sale. mz chose Stripe on 2026-11-22:
lower fees, one provider for every non-store sale, and a direct customer
relationship.

## Decision

**One account, one Plus, bought on any store, valid on every device.**

| Where the user is | How they pay | Entitlement source |
|---|---|---|
| iPhone, iPad | Apple in-app purchase (StoreKit 2) | `apple` |
| Mac (Developer ID build, Sparkle updates) | Stripe Checkout in the browser once P3 ships. Until then the Mac sheet sends the user to the iPhone or iPad app. | `stripe` |
| Apple Watch | Nothing. The watch syncs through the paired phone. | none |
| Android (Play Store build) | Google Play Billing | `google` (new) |
| Web client | Stripe Checkout | `stripe` |
| Windows | Stripe Checkout, opened in the browser | `stripe` |
| mz, testers, press | Grant | `grant` |

Rules that apply on every platform:

- **Same price everywhere:** €7 a month or €60 a year (ADR 0023). Outside
  the euro area each store uses its matching local price. Stripe charges in
  EUR at launch.
- **No double payment.** When the account is on Plus from any source, no
  app shows a buy button. The app says where the subscription lives and how
  to manage it: the App Store, Google Play, or the Stripe customer portal on
  septena.app.
- **No checkout link out of a store app at launch.** The iOS and Android
  apps sell only through their own store. They honor a subscription bought
  elsewhere, and they never point to it. A storefront that allows outside
  links (Apple's US storefront, for example) can get one later in its own
  change.
- **The trial is the server's.** Every new account starts the 14-day reverse
  trial (ADR 0010) on any platform. No store gets an introductory offer.
- **Web and Windows share one Stripe setup.** Stripe Checkout in
  subscription mode starts the purchase, the Stripe customer portal manages
  it, and Stripe webhooks write the `stripe` row. The checkout carries the
  backend user id, so a purchase always lands on the signed-in account.
- **Windows ships outside the Store first.** It signs in to the same
  account and opens the Stripe checkout in the browser. A later Microsoft
  Store listing keeps Stripe (allowed for non-game apps) and adds no new
  source.
- **Android sells through Play Billing in the Play Store build.** A user who
  already bought on the web or on an Apple device is on Plus on Android with
  no second purchase.

## Consequences

- The backend gains two new paths: Stripe webhooks (spec phase P3) and the
  Google Play Developer API plus real-time developer notifications (P4).
  Both write the same entitlement table, and the gates do not change.
- mz carries tax work for Stripe sales. Stripe Tax calculates VAT at
  checkout. Envisioning Technology registers for the EU VAT One Stop Shop
  and files it every quarter with the existing bookkeeping. Countries
  outside the EU need their own registration only above their thresholds.
  Apple and Google stay the seller for their own sales and handle tax there.
- A Stripe sale keeps about 97% of the price before VAT. An App Store or Play
  sale keeps 85%. A web purchase is better for us, but no store app may
  steer to it.
- Refunds and chargebacks on Stripe sales come to us. The `stripe` row moves
  to `revoked` on a refund or a lost dispute, like an Apple refund.
- The Mac app ships outside the Mac App Store (`docs/RELEASING-MAC.md`), and
  StoreKit sells nothing outside it. A Mac-only user cannot buy Plus until
  the Stripe checkout (P3) ships. A Mac App Store build would add `apple`
  there, with no change at the gates.
- The app shows "manage" text by source. A user who paid on the web and
  opens the iOS app sees where to manage it, and no Apple button.
- A user can still pay twice by buying on two stores while signed in to two
  different accounts. Support grants a refund. The account link through the
  backend user id prevents it inside one account.

## Links

- `docs/SYNC_SUBSCRIPTION_SPEC.md` §3.3 (funnel), §7.1 (the paywall), §9,
  §10
- ADR 0010, ADR 0023
- Pricing reasoning: Starlings Septena workspace, `/strategy/free-and-paid-plans`
