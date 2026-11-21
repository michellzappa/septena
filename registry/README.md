# Septena cross-platform registries

Canonical, language-neutral contracts for **Septena (the task app)** across
iOS, iPadOS, macOS, Backend/MCP, Web, Android, and Windows. See
[ADR 0015](../docs/adr/0015-shared-registries-for-cross-platform-clients.md).

## Layout

| Path | Owns | Status |
|---|---|---|
| `registry/entities.json` | Sync wire schema: entity columns, required/updatable fields, regexes, size limits, canonical enums | Phase R0 (`#141`) |
| `registry/rules.json` | Domain thresholds and retention/timing constants | Phase R0 (`#141`) |
| `registry/conformance/*.json` | Language-neutral golden test vectors run by Swift, TypeScript, and Kotlin | Phase R0 (`#141`) |
| `registry/settings.json` | Synced + device-local task settings schema, defaults, and taxonomy | Planned R1 (`#142`) |
| `registry/actions.json` | Actions, context menus, menu bar, swipe slots, platform-neutral shortcuts | Planned R2 (`#143`) |
| `registry/destinations.json` | Smart lists, aliases, sidebar order, visibility, drop rules, empty states | Planned R3 (`#144`) |
| `registry/surfaces.json` | Notices, destructive/fork prompts, toasts, task composer attributes | Planned R3 (`#144`) |
| `registry/icons.json`, `tokens.json`, `capabilities.json` | Semantic icons, design tokens, capability parity ledger | Planned R4 (`#145`) |

## Workflow

Edit the JSON source files here, then regenerate the typed native bindings:

```bash
node scripts/gen-registries.mjs
```

Verify that registries are valid and checked-in generated files are up to date
(also run automatically by `scripts/lint-design.sh`):

```bash
node scripts/gen-registries.mjs --check
```

Generated outputs (checked in, never hand-edited):

- `SeptenaCore/Generated/RegistryConstants.swift`
- `backend/src/generated/registries.ts`
