# Septena cross-platform registries

Canonical, language-neutral contracts for **Septena (the task app)** across
iOS, iPadOS, macOS, Backend/MCP, Web, Android, and Windows. See
[ADR 0015](../docs/adr/0015-shared-registries-for-cross-platform-clients.md).

## Layout

| Path | Owns | Issue |
|---|---|---|
| `registry/entities.json` | Sync wire schema: entity columns, required/updatable fields, regexes, size limits, canonical enums | R0 (`#141`) |
| `registry/rules.json` | Domain thresholds and retention/timing constants | R0 (`#141`) |
| `registry/conformance/*.json` | Language-neutral golden test vectors run by Swift, TypeScript, and Kotlin | R0 (`#141`) |
| `registry/settings.json` | Synced + device-local task settings schema, defaults, and flattened Settings taxonomy | R1 (`#142`) |
| `registry/actions.json` | Actions, context menus, menu bar, swipe slots, platform-neutral shortcuts, shortcuts sheet | R2 (`#143`) |
| `registry/destinations.json` | Smart lists, aliases, sidebar order, visibility, drop rules, empty states | R3 (`#144`) |
| `registry/surfaces.json` | Notices, destructive/fork prompts, toasts, task composer attributes | R3 (`#144`) |
| `registry/icons.json` | Semantic icon ID → SF Symbol / Material / Lucide map | R4 (`#145`) |
| `registry/tokens.json` | Semantic design tokens, selection washes, 16-color palette, 5-step text scale | R4 (`#145`) |
| `registry/capabilities.json` | Capability parity ledger keyed by Feature ID (ADR 0013) | R4 (`#145`) |

## Workflow

Edit the JSON source files here, then regenerate the typed native bindings:

```bash
node scripts/gen-registries.mjs
```

Verify that all 9 registries pass cross-file referential integrity checks and
generated files are up to date (also run automatically by `scripts/lint-design.sh`):

```bash
node scripts/gen-registries.mjs --check
```

Generated outputs (checked in, never hand-edited):

- `SeptenaCore/Generated/RegistryConstants.swift`
- `backend/src/generated/registries.ts`
