# Septena cross-platform registries

Canonical, language-neutral contracts for **Septena (the task app)** across
iOS, iPadOS, macOS, Backend/MCP, Web, Android, and Windows. See
[ADR 0015](../docs/adr/0015-shared-registries-for-cross-platform-clients.md).

## Layout

| Path | Owns | Issue |
|---|---|---|
| `registry/entities.json` | Sync wire schema: entity columns, required/updatable fields, regexes, size limits, canonical enums | R0 (`#141`) |
| `registry/rules.json` | Domain thresholds and retention/timing constants | R0 (`#141`) |
| `registry/conformance/*.json` | Language-neutral golden test vectors run by Swift, TypeScript, Kotlin and the Rust core (`sync-engine.json` is run by the Rust core first, ADR 0025) | R0 (`#141`) |
| `registry/settings.json` | Synced + device-local task settings schema, defaults, and flattened Settings taxonomy | R1 (`#142`) |
| `registry/actions.json` | Actions, context menus, menu bar, swipe slots, platform-neutral shortcuts, shortcuts sheet | R2 (`#143`) |
| `registry/destinations.json` | Smart lists, aliases, sidebar order, visibility, drop rules, empty states | R3 (`#144`) |
| `registry/surfaces.json` | Notices, destructive/fork prompts, toasts, task composer attributes | R3 (`#144`) |
| `registry/icons.json` | Semantic icon ID → SF Symbol / Material / Lucide map | R4 (`#145`) |
| `registry/tokens.json` | Semantic design tokens, selection washes, 16-color palette, 5-step text scale | R4 (`#145`) |
| `registry/plans.json` | Plans and pricing: prices, plan limits (the server plan table), pricing-page cards and comparison rows, promises, upsell copy (ADR 0010, ADR 0023). The site's /pricing page and the app's Septena Plus page render it | — |
| `registry/capabilities.json` | Capability parity ledger keyed by Feature ID (ADR 0013) | R4 (`#145`) |
| `registry/device-frames.json` | Canonical iPhone and Android shapes for marketing visuals (website scenes, App Store panels) | — |
| `registry/l10n/en.json` | Generated: every user-facing registry string, its placeholders and source paths | L1 (`#214`) |
| `registry/l10n/<lang>.json` | Translations of registry copy, keyed by the English text | L1 (`#214`) |

## Workflow

Edit the JSON source files here, then regenerate the typed native bindings:

```bash
node scripts/gen-registries.mjs
```

Verify that all 10 registries pass cross-file referential integrity checks and
generated files are up to date (also run automatically by `scripts/lint-design.sh`):

```bash
node scripts/gen-registries.mjs --check
```

Generated outputs (checked in, never hand-edited):

- `SeptenaCore/Generated/RegistryConstants.swift`
- `backend/src/generated/registries.ts`
- `android/core/src/main/kotlin/app/septena/core/generated/RegistryConstants.kt`
- `core/crates/septena-core/src/generated/registry.rs` (the shared Rust core, ADR 0025)
- `registry/l10n/en.json`
- the registry entries in `Septena/Localizable.xcstrings` (their comment
  starts "Generated from registry")

## Enforcement (ADR 0020 P3)

- **Capability gating (ADR 0015).** A surface shows on a platform only when
  its `featureId` is `ships` or `partial` there in `capabilities.json`
  (`RegistryCapabilities.isAvailable`). The generated `applies(to:)` on
  settings tabs, pages and items, destinations and task attributes includes
  that check; menus check it in `RegistryActions.isAvailableOnPlatform`;
  notices filter in `TaskNotices.today`. Flip a feature to `planned`, run the
  generator, and its settings, menu items, smart list, pill and notice go away
  on that platform. A settings item without its own `featureId` takes its
  setting key's, then the page it opens, then the page it sits on.
- **Readers.** `--check` fails when a generated Swift member or TS export has
  no reader (`scripts/registry-readers.mjs`). Read it, stop generating it (the
  server-only rules in `SERVER_ONLY` are left out of Swift), or list it in
  `registry/readers-allowlist.json` with a reason and an issue. An allowlist
  entry that gains a reader fails too.
- **Literals.** `scripts/lint-design.sh` runs `scripts/lint-registry-literals.py`
  (`registry-owned-literal`): a Swift string literal in `Septena/Shell/` or
  `Septask/` that equals a registry string fails the build. Read the
  generated value instead (`RegistryActions.title(id, .add)`,
  `TaskFilter.today.title`, `RegistryPrompts.textPrompt(id).title`, ...). Known
  leftovers are in `scripts/registry-literal-allowlist.json`, each with the
  issue that removes it.

## Localized copy (ADR 0020)

- English stays inline in the registry files. The key of a string is its
  English text, so the catalog's existing translations apply. When one
  English text needs two translations, add `"l10nKeys": { "<field>": "<key>" }`
  to the object that holds it.
- Placeholders are named: `{count}`, `{name}`, `{date}`. `{count}` is an
  integer (`%lld` on Apple); every other name is text (`%@`).
- A plural string is an object: `{ "one": "1 task", "other": "{count} tasks" }`.
- Translate in `registry/l10n/<lang>.json` (key → text, or plural forms), then
  run the generator. It writes the translations into the Xcode catalog and the
  TS tables (`REGISTRY_L10N`, `registryText()`). Never edit registry entries in
  Xcode: the next generation overwrites them.
- `--check` fails on empty English, a placeholder mismatch, or two keys that
  collapse to one catalog key. It reports missing translations without failing.
- Swift reads localized copy through the generated values (`RegistryL10n`);
  templates are functions (`RegistryNotices.rolledInTitle(count:)`,
  `RegistryToasts.movedBulk(count:destination:)`, `RegistryPrompts.deleteArea(…)`).
- `node scripts/gen-registries.mjs --seed-l10n <lang>` copies catalog
  translations for registry keys into `registry/l10n/<lang>.json` (existing
  entries win).
