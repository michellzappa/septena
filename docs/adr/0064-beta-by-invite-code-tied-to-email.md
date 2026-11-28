# 0064. The beta is by invite code, and the thank-you follows the email

- Status: accepted (2026-11-28), amended 2026-11-28 (seeded project, measured use)
- Date: 2026-11-28
- Deciders: mz (product), agent (mechanism)
- Extends: [ADR 0043](0043-plus-links-and-a-counts-only-admin-page.md) (plan links, admin page),
  [ADR 0045](0045-pro-is-a-real-plan-that-is-only-given.md) (Pro is only given),
  [ADR 0047](0047-every-way-in-creates-an-account.md) (verified email at sign-in)
- Spec: [BETA_ONBOARDING_SPEC.md](../BETA_ONBOARDING_SPEC.md)

## Context

The TestFlight public link lets anyone in, and Codex's first `/beta` page
linked it. mz wants the beta to feel small and chosen, the way cmux runs its
beta: a person types their email and a code on a web page, and the TestFlight
invite arrives in their inbox. mz also wants the beta thank-you (a year of
Pro) to belong to that email, so the account that person makes later, on any
device and with any sign-in, gets it.

An account stores no readable email for Apple, Google or Microsoft sign-in
(ADR 0043): only an email-code identity keeps the address. Sign in with Apple
can also hand us a relay address (Hide My Email) that never matches what the
person typed on the page.

## Decision

1. **Code only.** `/beta` shows an email field and a code field. No page links
   the TestFlight public link, and mz turns that link off in App Store Connect.
2. **Named batch codes.** mz makes codes on the admin page (`/admin`) with a
   label (who it was for), a use limit and an optional end date. mz picks
   the word (at least 8 letters, case-insensitive). A code is an invitation,
   not a credential: it is stored readable so the admin page can show it, and
   a rate limit stops guessing. Close and take back work as for plan links.
3. **The backend runs the join.** `POST api.septena.app/v1/beta/join` checks
   the code, adds the email to the TestFlight group through the App Store
   Connect API (Apple sends its own invite mail), writes the beta row, makes
   the person's plan link, and sends our welcome mail. The site page only
   posts to it.
4. **The thank-you follows the email in two ways.**
   - An email grant: at every sign-in that carries a verified email (Apple,
     Google, Microsoft, email code), the backend looks the address up in the
     beta rows and writes the grant entitlement on that account. An email
     code identity that already exists gets the grant at join time.
   - A personal plan link (ADR 0043, one use) in the welcome mail. It covers a
     relay address, an account made before the join, and a different
     address. Whichever path runs first wins, and the other then does nothing.
5. **The grant is Pro, from the join until 12 months after the public
   launch.** Until mz sets the launch date the grant has no end. Setting it
   writes the end date on every beta grant.
6. **The app has no code field and no beta screen.** App Review 3.1.1 holds,
   as for plan links: the claim and the code run on the web only.

## Consequences

- The backend stores the email of each beta tester, readable, to match it at
  sign-in. The privacy page needs a "Beta" block before the first code goes
  out.
- The backend holds an App Store Connect key that can add testers. It is a
  Worker secret, with the App Manager role at most.
- The admin page shows counts per code (joined, signed in, granted), never an
  email in a list. mz finds one tester by typing their address.
- A tester who signs in with a relay address and never opens the welcome mail
  gets no Pro. The second mail (spec §5) reminds them.
- Turning the public link off strands nobody: people who already joined keep
  TestFlight access.

## Amendment (2026-11-28): a seeded project, and measured use

mz decided on 2026-11-28:

7. **The checklist is a project.** When a tester's Pro grant first lands on
   an account, the backend writes one normal project into that account,
   "Septena beta", with the registry notes and one open task per checklist
   item (`registry/beta.json`). It is not locked: the tester can edit, move,
   tick or delete it like any other project. It is written once; a deleted
   project does not come back. It replaces the Beta screen in Settings.
8. **Did it, not only ticked it.** The backend measures, from the account's
   own rows, whether the tester used each part and when they first did. It
   is content-free: a time per item, counts per week, never task text. It
   also measures repeat use (active days in weeks 1, 2 and 4), completed
   agent loops, a normal week's adds, completions and moves to Today, and
   asks one question on day 7 (how disappointed they would be without
   Septena).
9. **mz sees it per tester and in counts.** The Beta card on the admin Plans
   page shows counts per item (did it, ticked it), the activation funnel per
   code, repeat use, medians, and the day-7 answers. A lookup by one email
   (a POST, never a URL) shows one tester. There is still no list of emails.

Consequences of the amendment: the welcome mail says that the beta notes
which parts a tester used and when, never what they wrote. The app shows a
Today card that opens the project, and nothing else. The rules for each
measurement are in the spec, §7.

## Links

- Spec: `docs/BETA_ONBOARDING_SPEC.md`
- Site page: septena/site `app/beta/page.tsx`
- TestFlight upload and group: `scripts/testflight-distribute.mjs`
