# 0023. Make sync across devices the paid line

- Status: accepted (2026-11-22)
- Date: 2026-11-22
- Deciders: mz
- Amends: [ADR 0010](0010-free-server-tier-with-limits.md) (the device
  count of the free account only; the rest of 0010 stands)

## Context

ADR 0010 gave the free account server sync on 2 devices. A review of the
pricing page, the app and competitor pricing pages on 2026-11-22 found:

- Phone and Mac is the most common pair. With 2 free devices, most users
  never meet the main paid feature.
- The paid features that ship today are sync, synced files, history and the
  hosted connector. Overnight agent runs (#5), the planned headline, are not
  shipped, so the public pages cannot sell them yet.
- With 2 free devices, Plus sells "faster sync and more history". That is
  the weakest paid offer in the category and hard to say in one line.
- The site's /pricing page already says "free on one device, sync is paid".
  The spec and the site disagree.
- Nothing has launched. No user has free 2-device sync today, so this change
  takes nothing away from anyone.

## Decision

The one-line rule is: **free on one device, Plus on all of them.**

- **Free, no account:** unchanged. The full task app on one device.
- **Free account:** the server holds a copy of **one** device. That device
  syncs to the server, which gives a backup and lets the user join shared
  projects and use the connector within the 0010 caps.
- **Moving to a new device is free.** When a free account signs in on a new
  device, that device takes the one slot and the old device stops syncing.
  It keeps its local data. Replacing a phone never needs Plus.
- **Plus (€7 a month / €60 a year):** sync on every device, as in 0010.
  The price was €5 / €40 until 2026-11-22, when MZ raised it.
- The paid plan is named **Septena Plus** on every surface: site, app,
  App Store product, receipts. "Support Septena" and "Supporter" leave the
  task app.

All other free-account limits in ADR 0010 and the spec stand: history
windows, no server attachments, connector and agent caps, join shared
projects, reverse trial, upsell rules.

## Consequences

- The plan table's free device count changes from 2 to 1. Gates still read
  limits, never the plan name, so the change is a value, not code.
- The first upsell moment moves from the third device to the second device.
  The second device works locally and one line says Plus syncs every device.
- The site, the app paywall and the App Store text can say the same short
  rule.
- Fewer free accounts reach multi-device sync, so fewer users see it before
  they pay. The 14-day reverse trial covers this: every new account gets
  Plus first, then the free account.
- If conversion is high and churn is high, the device count is still the
  first knob, now in the other direction. Raising it to 2 later only adds a
  free thing and needs no new ADR.

## Links

- ADR 0010, `docs/SYNC_SUBSCRIPTION_SPEC.md` §3
- Pricing reasoning: Starlings Septena workspace, `/strategy/free-and-paid-plans`
