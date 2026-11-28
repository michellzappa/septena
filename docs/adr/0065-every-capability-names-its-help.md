# 0065. Every capability names its help, and the site build checks it

- Status: accepted (2026-11-28)
- Date: 2026-11-28
- Deciders: mz (product), agent (mechanism)
- Extends: [ADR 0015](0015-shared-registries-for-cross-platform-clients.md) (shared registries, feature IDs),
  [ADR 0020](0020-registry-owns-copy-and-translations.md) (the registry owns copy),
  [ADR 0028](0028-registry-owns-vocabulary-platforms-own-interaction.md) (the registry owns vocabulary)
- Issues: #889 (Review groups explained in the app), septena/site#84 (Review guide)

## Context

mz wants help, docs and marketing to describe the app as it is, at all
times, and the complex parts (agents, Review) to be clear to a new user.

On 2026-11-28 they did not. Of 66 capabilities that ship on at least one
platform in `registry/capabilities.json`, 28 had no help guide on the site.
Two site guides named capability IDs that no longer exist. Two pages still
described the Agent list, which ADR 0046 removed. Nothing connected an
engineering change to the help that describes it, so the help drifted
silently.

The pieces already exist: every registry entry carries a capability ID,
site guides list the capability IDs they cover (`features: [...]` in
`lib/site-guides.ts` and `lib/help-articles.ts`), and the site copies the
registry and rebuilds when it changes.

## Decision

- **The capability registry is the contract.** Each capability in
  `registry/capabilities.json` has `docs`: the site guide slugs that explain
  it, or `{ "pending": "<septena/site issue URL>" }` while the help is not
  written. A capability with no platform at `ships` or `partial` needs no
  `docs`.
- **The app gate.** `node scripts/gen-registries.mjs --check` (CI) fails
  when a capability ships or is partial on any platform and has no `docs`.
  So the PR that ships a feature also names its help, or opens the site
  issue for it. Engineering cannot ship a capability that nobody plans to
  explain.
- **Retired words.** `registry/retired-terms.json` lists names the product
  no longer uses (for example "Agent list", "Septask"), each with the word
  to use instead. When a change removes or renames a concept, the same PR
  adds the old name there.
- **The site gate.** The site build fails when a `docs` slug does not
  exist, when a guide names a capability ID that does not exist, or when
  rendered copy uses a retired word. It prints the open `pending` entries
  with their age.
- **One definition per concept.** Words a user must understand (lists,
  Review groups, marks on a task) carry their one-sentence meaning in the
  registry (#889 starts with the Review groups). The app and the site's
  glossary render that text, so they cannot disagree.
- **Drift is visible.** Each factory run lists `pending` entries older
  than 7 days in its report and keeps one septena/site issue, "Help drift",
  up to date with them.
- **Marketing follows the same IDs.** A site claim that a feature exists
  (features page, compare pages, platform pages) names its capability ID,
  and the site build fails when that capability does not ship.

## Consequences

- A PR that ships a capability does a little more: it names a guide or
  links a site issue.
- The gate turns on green: the 28 capabilities without help get `pending`
  pointing at one backfill issue on septena/site, and the two unknown IDs
  get fixed.
- Help still needs a writer. The gate makes a gap visible and owned; it
  does not write the guide.
- Wording quality is not checked by a machine. Copy still goes through the
  humanizer skill.

## Links

`registry/capabilities.json`, `scripts/gen-registries.mjs`,
septena/site `lib/site-guides.ts`, `lib/help-articles.ts`,
`scripts/sync-registry.mjs`, `scripts/check-copy.mjs`.
