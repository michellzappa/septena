# 0047. Every way into Septena creates an account and offers every sign-in method it can

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz (product), agent (mechanism)
- Amends: [ADR 0016](0016-sign-in-beyond-apple.md) (decision 4, "not now"
  for Google and web Sign in with Apple)
- Spec: [SIGN_IN_SURFACES_SPEC.md](../SIGN_IN_SURFACES_SPEC.md)

## Context

- Septena has many ways in: the iPhone, iPad and Mac apps (App Store and
  Developer ID), Android, the web app at `web.septena.app`, the Claude
  connector's authorize page, and later Windows. The watch signs in through
  the phone.
- Today only Sign in with Apple creates an account, and only in the builds
  that carry the Apple entitlement. Android, the web app, the Developer ID Mac
  app and the connector page offer device approval only. A person who arrives
  there first cannot start (#551).
- On 2026-11-21 mz chose Google, Microsoft and email next to Apple (#137).
  ADR 0016 then put Google and web Sign in with Apple under "not now".
- On 2026-11-26 mz asked that every way in also be a way to create an account,
  and that each one offer every sign-in method its platform allows.

## Decision

1. **Every sign-in screen is also the create-account screen.** There is one
   button per method ("Continue with …"). The first sign-in with a method that
   matches no account creates one. There is no separate sign-up flow.
2. **Every surface offers every method it can.** The methods are Apple,
   Google, Microsoft, an email code (ADR 0016) and device approval (ADR 0016).
   Apple, Google and Microsoft use the platform's native flow where one
   exists, else a web redirect through `api.septena.app`. Web Sign in with
   Apple (a Services ID) is now in scope: it is the only way to offer Apple on
   the Developer ID Mac app, Android, the web and Windows.
3. **One list, in the registry.** `registry/sign-in.json` holds the methods,
   their order per platform and their copy. Every client renders it. The
   platform's own provider comes first, then the other providers, then email,
   then "I use Septena on another device".
4. **Every method ends in `issueSession()`** and an `AccountStore` identity row
   (`provider:subject`, hashed per ADR 0043; email stays readable). Sync,
   entitlements and per-user routing do not change.
5. **No silent linking by email.** A provider sign-in whose email belongs to
   another account does not join that account. It shows "This email already
   has a Septena account" and offers an email code to that address. A correct
   code signs in to the existing account and adds the provider to it. Linking
   two accounts that both hold tasks stays out of scope.
6. **A signed-in user manages methods** in Settings ▸ Account ▸ Sign-in
   methods: add any method, remove any but the last.
7. **Passkeys come later** as one more row, with no new ADR.

## Consequences

- A new person can start on any surface, including the connector page with
  no app installed (an agent-first account).
- #551 closes: the Developer ID Mac app signs in with Apple through the web
  flow.
- The backend gains one OIDC module for three providers, a redirect callback
  and the link-by-code step. App Store rule 4.8 holds, because Apple is on
  every Apple screen.
- mz owns three provider dashboards: an Apple Services ID with a key, a Google
  Cloud OAuth client, and a Microsoft Entra app registration. mz also sets up
  email sending for `septena.app` (#169).
- Septena stores email addresses. The privacy page, the support page, the App
  Store and Play privacy answers and Terms of Use (#564) change before the
  first new method opens.
- A self-hosted server (ADR 0011) offers email and device approval without
  Septena's keys, and providers only with its own OAuth clients.

## Links

- ADR 0016, ADR 0043, ADR 0011
- Issues: #137 (providers), #169 (email code), #171 (email on Apple
  accounts), #551 (Mac download), #564 (Terms), #21 web, #20 Android,
  #136 Windows
