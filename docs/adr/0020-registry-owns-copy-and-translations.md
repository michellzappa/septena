# 0020. The registry owns shared copy and its translations; shells render it

- Status: accepted (2026-11-21), agent defaults — mz may overrule
- Date: 2026-11-21
- Deciders: mz

## Context

ADR 0015 moved structure into `registry/*.json`. The registry audit
(`docs/REGISTRY_AUDIT.md`, 2026-11-21) found what is still wrong:

- Registry copy is generated as plain English, so Settings and the first run
  show English to every user, while the Swift copy they replace is
  translated (669 pt-BR strings in `Septena/Localizable.xcstrings`). Moving
  more copy into the registry today removes translations.
- `RegistrySurfaces` and `RegistryCapabilities` are generated and read by no
  code.
- Some registry copy is older than the shipped Swift copy, and the registry
  lacks items the apps ship (Inbox destination, weekly sweep notice, Star,
  Reminder, Rename, View and Window menus, a menu bar layout).
- The iPhone/iPad and Mac shells word the same thing differently.

Septena will ship on web, Android and Windows (ADR 0013, #20, #21, #136).
Translations kept only in an Xcode catalog cannot reach those clients, and
copy that lives in each shell will drift once per shell.

mz (2026-11-21): all generated code should be used; stale and missing
registry items should be fixed; the shells must never disagree, because web,
Android and Windows are coming.

## Decision

1. **Shared copy and structure live only in the registry.** Any string or
   list that more than one shell shows (iPhone/iPad SwiftUI, Mac AppKit,
   later web, Android, Windows, the MCP backend) is defined in
   `registry/*.json` and rendered from the generated code. A shell may hold
   copy only for something no other shell has, and says so in a comment.
2. **Translations of registry copy live in the registry.**
   `registry/l10n/<lang>.json` maps a stable key to the translated text.
   English stays inline in the registry files and is exported to
   `registry/l10n/en.json`. The generator writes those translations into
   `Septena/Localizable.xcstrings` (Apple), and later into Android
   `strings.xml`, web JSON and the Windows resource format. *(default)*
   Swift-only strings keep living in the catalog until they move into the
   registry.
3. **Keys are the English text**, the catalog's existing convention, so the
   669 existing pt-BR translations carry over. An optional `l10nKey` covers
   English that means two things. Plurals and placeholders (`{count}`,
   `{name}`, `{date}`) are declared in the registry and generated as
   functions. *(default)*
4. **Generated code is used or deleted.** A generated enum or field with no
   reader is a build warning first and an error once phase P3 lands.
   `RegistryCapabilities` gates surfaces as ADR 0015 already requires.
5. **The build enforces it.** `scripts/lint-design.sh` gains a rule that
   fails on a user-facing literal in a shared shell file that the registry
   owns, and the generator `--check` fails when a registry key has no
   English text or a placeholder mismatch.
6. **Languages.** pt-BR is translated and stays. New languages are added by
   adding a `registry/l10n/<lang>.json` file. Which languages to add, and
   who reviews machine translations, is mz's call (open question 1).

## Consequences

- One translation reaches every client. A web or Android client starts with
  every language the Apple apps have.
- Moving copy into the registry no longer costs translations, so the L2 to
  L6 moves can proceed after L1.
- The catalog becomes partly generated. Editing a registry-owned entry in
  Xcode is overwritten on the next generation; the comment on each entry
  says so.
- The lint will flag existing literals in bulk at first. P3 carries an
  allowlist that shrinks to zero; the allowlist is the remaining work.
- Machine translations need a review step before they ship (open question 2).

## Open questions

| # | Question | Default |
|---|---|---|
| 1 | Which languages after pt-BR? | Spanish, German, French, Japanese, Simplified Chinese (largest App Store markets the app does not cover yet), added only after P1 lands. |
| 2 | Who reviews machine translations? | Claude drafts, marked `needs_review` in the catalog; a string ships when reviewed, else English. |
| 3 | Translations source: registry files or the Xcode catalog? | Registry files (decision 2). |

## Links

- ADR 0015 · `docs/REGISTRY_AUDIT.md` · `docs/REGISTRY_PLAN.md`
- Issues #214 (L1), #215 (L2), #216 (L3), #217 (L4), #218 (L5), #219 (L6), #177, #179
- `docs/LOCALIZATION_PLAN.md` (the pt-BR pilot)
