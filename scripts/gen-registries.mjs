#!/usr/bin/env node
// Validates all `registry/*.json` files (including cross-file referential
// integrity) and generates typed Swift + TypeScript bindings.
//
// Usage:
//   node scripts/gen-registries.mjs          # validate and write generated files
//   node scripts/gen-registries.mjs --check  # validate and fail if generated files drifted
//
// Zero external dependencies (Node >= 20). See ADR 0015 (`docs/adr/0015-*.md`).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, "..");
const CHECK = process.argv.includes("--check");

const readJSON = (rel) => {
  const full = path.join(REPO, rel);
  try {
    return JSON.parse(fs.readFileSync(full, "utf8"));
  } catch (err) {
    throw new Error(`Failed to parse ${rel}: ${err.message}`);
  }
};

function assert(cond, msg) {
  if (!cond) throw new Error(`registry validation failed: ${msg}`);
}

function validateEntities(entities) {
  assert(entities.version === 1, "entities.json: version must be 1");
  assert(entities.patterns && typeof entities.patterns === "object", "entities.json: missing patterns");
  for (const [k, pattern] of Object.entries(entities.patterns)) {
    assert(typeof pattern === "string" && pattern.length > 0, `entities.json: pattern ${k} must be non-empty string`);
    new RegExp(pattern);
  }
  assert(entities.limits && typeof entities.limits === "object", "entities.json: missing limits");
  for (const [k, v] of Object.entries(entities.limits)) {
    assert(typeof v === "number" && Number.isInteger(v) && v > 0, `entities.json: limit ${k} must be positive int`);
  }
  assert(entities.enums && typeof entities.enums === "object", "entities.json: missing enums");
  for (const [k, vals] of Object.entries(entities.enums)) {
    assert(Array.isArray(vals) && vals.length > 0, `entities.json: enum ${k} must be non-empty array`);
    const seen = new Set();
    for (const v of vals) {
      assert(typeof v === "string" && v.length > 0, `entities.json: enum ${k} contains invalid item`);
      assert(!seen.has(v), `entities.json: enum ${k} contains duplicate "${v}"`);
      seen.add(v);
    }
  }
  const validKinds = new Set(["text", "int", "real", "bool", "json"]);
  assert(entities.entities && typeof entities.entities === "object", "entities.json: missing entities");
  for (const [name, spec] of Object.entries(entities.entities)) {
    assert(typeof spec.table === "string" && spec.table.length > 0, `entity ${name}: missing table`);
    assert(typeof spec.deletable === "boolean", `entity ${name}: deletable must be boolean`);
    assert(Array.isArray(spec.requiredOnInsert), `entity ${name}: requiredOnInsert must be array`);
    assert(spec.columns && typeof spec.columns === "object", `entity ${name}: missing columns`);
    for (const req of spec.requiredOnInsert) {
      assert(req in spec.columns, `entity ${name}: requiredOnInsert "${req}" not in columns`);
    }
    if (spec.updatable !== undefined) {
      assert(Array.isArray(spec.updatable), `entity ${name}: updatable must be array`);
      for (const up of spec.updatable) {
        assert(up in spec.columns, `entity ${name}: updatable "${up}" not in columns`);
      }
    }
    for (const [colName, col] of Object.entries(spec.columns)) {
      assert(validKinds.has(col.kind), `entity ${name}.${colName}: invalid kind "${col.kind}"`);
      if (col.format !== undefined) {
        assert(col.format in entities.patterns, `entity ${name}.${colName}: unknown format "${col.format}"`);
      }
      if (col.enum !== undefined) {
        assert(col.enum in entities.enums, `entity ${name}.${colName}: unknown enum "${col.enum}"`);
      }
    }
  }
}

function validateRules(rules) {
  assert(rules.version === 1, "rules.json: version must be 1");
  const required = [
    "cueDecayDays",
    "fadeWindowDays",
    "fadeGraceDays",
    "fadeMinOpacity",
    "fadeSweepWeekday",
    "recentlyDeletedDays",
    "upcomingCalendarDays",
    "toastDurationSeconds",
    "agentRunBudget",
    "claimTtlDefaultSeconds",
    "claimTtlMaxSeconds",
    "tombstoneTtlDays",
    "clientOpTtlDays",
    "changeLogTtlDays",
  ];
  for (const k of required) {
    assert(typeof rules[k] === "number" && Number.isFinite(rules[k]) && rules[k] > 0, `rules.json: ${k} must be positive number`);
  }
  assert(rules.fadeMinOpacity > 0 && rules.fadeMinOpacity < 1, "rules.json: fadeMinOpacity must be in (0, 1)");
  assert(rules.fadeSweepWeekday >= 1 && rules.fadeSweepWeekday <= 7, "rules.json: fadeSweepWeekday must be 1..7");
  assert(rules.claimTtlMaxSeconds >= rules.claimTtlDefaultSeconds, "rules.json: claimTtlMaxSeconds must be >= claimTtlDefaultSeconds");
}

function validateIcons(icons) {
  assert(icons.version === 1, "icons.json: version must be 1");
  assert(icons.icons && typeof icons.icons === "object", "icons.json: missing icons");
  for (const [id, map] of Object.entries(icons.icons)) {
    for (const family of ["sfSymbol", "material", "lucide"]) {
      assert(typeof map[family] === "string" && map[family].length > 0, `icons.json: ${id}.${family} must be non-empty string`);
    }
  }
}

function validateTokens(tokens) {
  assert(tokens.version === 1, "tokens.json: version must be 1");
  assert(Array.isArray(tokens.accentPalette) && tokens.accentPalette.length >= 8, "tokens.json: accentPalette must have >= 8 hexes");
  for (const hex of tokens.accentPalette) {
    assert(/^#[0-9a-fA-F]{6}$/.test(hex), `tokens.json: invalid hex "${hex}"`);
  }
  assert(Array.isArray(tokens.textScale?.steps) && tokens.textScale.steps.length === 5, "tokens.json: textScale must have 5 steps");
}

function validateCapabilities(caps) {
  assert(caps.version === 1, "capabilities.json: version must be 1");
  assert(Array.isArray(caps.platforms) && caps.platforms.length > 0, "capabilities.json: missing platforms");
  const validStatuses = new Set(caps.statuses);
  assert(validStatuses.size > 0, "capabilities.json: missing statuses");
  for (const [id, entry] of Object.entries(caps.capabilities)) {
    assert(typeof entry.title === "string" && entry.title.length > 0, `capabilities.json: ${id} missing title`);
    for (const p of caps.platforms) {
      assert(validStatuses.has(entry[p]), `capabilities.json: ${id}.${p} has invalid status "${entry[p]}"`);
    }
  }
}

function validateSettings(settings, entities, icons, caps) {
  assert(settings.version === 1, "settings.json: version must be 1");
  const validTypes = new Set(["bool", "int", "enum", "string", "string[]"]);
  const validScopes = new Set(["synced", "device"]);
  const validPlatforms = new Set(caps.platforms);
  for (const [key, def] of Object.entries(settings.keys)) {
    assert(validScopes.has(def.scope), `settings.json: ${key} invalid scope "${def.scope}"`);
    assert(validTypes.has(def.type), `settings.json: ${key} invalid type "${def.type}"`);
    assert(def.featureId in caps.capabilities, `settings.json: ${key} unknown featureId "${def.featureId}"`);
    assert(Array.isArray(def.platforms) && def.platforms.length > 0, `settings.json: ${key} missing platforms`);
    for (const p of def.platforms) assert(validPlatforms.has(p), `settings.json: ${key} unknown platform "${p}"`);
    if (def.enum !== undefined) {
      assert(def.enum in entities.enums, `settings.json: ${key} unknown enum "${def.enum}"`);
    }
  }
  assert(Array.isArray(settings.pages) && settings.pages.length > 0, "settings.json: missing pages");
  for (const page of settings.pages) {
    assert(page.icon in icons.icons, `settings.json: page ${page.id} unknown icon "${page.icon}"`);
    assert(page.featureId in caps.capabilities, `settings.json: page ${page.id} unknown featureId "${page.featureId}"`);
    assert(Array.isArray(page.sections) && page.sections.length > 0, `settings.json: page ${page.id} must have >= 1 section`);
    for (const sec of page.sections) {
      assert(Array.isArray(sec.items) && sec.items.length > 0, `settings.json: section ${page.id}.${sec.id} must have >= 1 item`);
      for (const item of sec.items) {
        if (item.kind === "setting") {
          assert(item.key in settings.keys, `settings.json: section ${page.id}.${sec.id} references unknown setting "${item.key}"`);
        } else if (item.kind === "customSurface") {
          assert(typeof item.surface === "string" && item.surface.length > 0, `settings.json: customSurface missing surface`);
        } else {
          assert(false, `settings.json: unknown item kind "${item.kind}"`);
        }
        if (item.icon !== undefined) assert(item.icon in icons.icons, `settings.json: item unknown icon "${item.icon}"`);
        if (item.featureId !== undefined) assert(item.featureId in caps.capabilities, `settings.json: item unknown featureId "${item.featureId}"`);
      }
    }
  }
}

function validateDestinations(dests, icons, caps) {
  assert(dests.version === 1, "destinations.json: version must be 1");
  assert(Array.isArray(dests.destinations) && dests.destinations.length > 0, "destinations.json: missing destinations");
  const seenIds = new Set();
  let lastOrder = -1;
  for (const d of dests.destinations) {
    assert(!seenIds.has(d.id), `destinations.json: duplicate id "${d.id}"`);
    seenIds.add(d.id);
    assert(d.sidebarOrder > lastOrder, `destinations.json: sidebarOrder must strictly increase at "${d.id}"`);
    lastOrder = d.sidebarOrder;
    assert(d.icon in icons.icons, `destinations.json: ${d.id} unknown icon "${d.icon}"`);
    assert(d.featureId in caps.capabilities, `destinations.json: ${d.id} unknown featureId "${d.featureId}"`);
  }
  return seenIds;
}

function validateActions(actions, icons, caps, destIds) {
  assert(actions.version === 1, "actions.json: version must be 1");
  const validMods = new Set(["primary", "alt", "shift", "ctrl"]);
  const validRoles = new Set(["default", "destructive"]);
  const checkShortcut = (actionId, sc) => {
    assert(typeof sc.key === "string" && sc.key.length > 0, `actions.json: ${actionId} shortcut missing key`);
    assert(Array.isArray(sc.modifiers), `actions.json: ${actionId} shortcut modifiers must be array`);
    for (const m of sc.modifiers) assert(validMods.has(m), `actions.json: ${actionId} unknown modifier "${m}"`);
    if (sc.key === "space" && !sc.globalCapture) {
      assert(false, `actions.json: ${actionId} binds space without globalCapture (forbidden on task rows)`);
    }
  };

  for (const [id, a] of Object.entries(actions.actions)) {
    assert(typeof a.title === "string" && a.title.length > 0, `actions.json: ${id} missing title`);
    assert(a.icon in icons.icons, `actions.json: ${id} unknown icon "${a.icon}"`);
    assert(validRoles.has(a.role), `actions.json: ${id} invalid role "${a.role}"`);
    assert(a.featureId in caps.capabilities, `actions.json: ${id} unknown featureId "${a.featureId}"`);
    if (a.shortcut) {
      checkShortcut(id, a.shortcut);
      for (const alt of a.shortcut.alternates ?? []) checkShortcut(id, alt);
    }
    for (const dest of [...(a.availability?.excludeDestinations ?? []), ...(a.availability?.onlyDestinations ?? [])]) {
      assert(destIds.has(dest), `actions.json: ${id} references unknown destination "${dest}"`);
    }
  }

  const checkMenuItems = (menuName, items) => {
    assert(Array.isArray(items) && items.length > 0, `actions.json: menu ${menuName} must be non-empty`);
    for (const item of items) {
      if (item.kind === "action") {
        assert(item.id in actions.actions, `actions.json: menu ${menuName} references unknown action "${item.id}"`);
      } else if (item.kind === "submenu") {
        assert(item.icon in icons.icons, `actions.json: submenu ${menuName}.${item.id} unknown icon "${item.icon}"`);
        checkMenuItems(`${menuName}.${item.id}`, item.items);
      } else if (item.kind === "divider" || item.kind === "slot") {
        // ok
      } else {
        assert(false, `actions.json: menu ${menuName} unknown item kind "${item.kind}"`);
      }
    }
  };
  for (const [name, items] of Object.entries(actions.contextMenus)) checkMenuItems(name, items);

  assert(actions.swipeActions.featureId in caps.capabilities, "actions.json: swipeActions unknown featureId");
  for (const id of [...actions.swipeActions.leading, ...actions.swipeActions.trailing]) {
    assert(id in actions.actions, `actions.json: swipeActions references unknown action "${id}"`);
  }
  for (const grp of actions.shortcutsSheet) {
    for (const id of grp.actionIds) {
      assert(id in actions.actions, `actions.json: shortcutsSheet.${grp.id} references unknown action "${id}"`);
    }
  }
}

function validateSurfaces(surfaces, icons, caps) {
  assert(surfaces.version === 1, "surfaces.json: version must be 1");
  assert(surfaces.notices.maxConcurrentExplainers === 1, "surfaces.json: maxConcurrentExplainers must be 1");
  for (const n of surfaces.notices.items) {
    assert(n.icon in icons.icons, `surfaces.json: notice ${n.id} unknown icon "${n.icon}"`);
    assert(n.featureId in caps.capabilities, `surfaces.json: notice ${n.id} unknown featureId "${n.featureId}"`);
  }
  assert(surfaces.prompts.safetyContract.cancelIsDefaultButton === true, "surfaces.json: cancelIsDefaultButton must be true");
  for (const p of surfaces.prompts.items) {
    assert(p.featureId in caps.capabilities, `surfaces.json: prompt ${p.id} unknown featureId "${p.featureId}"`);
  }
  for (const attr of surfaces.taskAttributes) {
    assert(attr.icon in icons.icons, `surfaces.json: attribute ${attr.id} unknown icon "${attr.icon}"`);
    assert(attr.featureId in caps.capabilities, `surfaces.json: attribute ${attr.id} unknown featureId "${attr.featureId}"`);
  }
}

function validateConformance() {
  const dir = path.join(REPO, "registry/conformance");
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  assert(files.length > 0, "registry/conformance must contain at least one fixture file");
  for (const f of files) {
    const data = readJSON(`registry/conformance/${f}`);
    assert(data.version === 1, `registry/conformance/${f}: version must be 1`);
  }
}

const swiftStr = (s) => JSON.stringify(s);
const swiftOptStr = (s) => (s === undefined || s === null ? "nil" : JSON.stringify(s));
const camelId = (s) => s.replace(/[._-]+([a-zA-Z0-9])/g, (_, c) => c.toUpperCase());

function appleKeycaps(sc) {
  const caps = [];
  if (sc.modifiers.includes("ctrl")) caps.push("⌃");
  if (sc.modifiers.includes("alt")) caps.push("⌥");
  if (sc.modifiers.includes("shift")) caps.push("⇧");
  if (sc.modifiers.includes("primary")) caps.push("⌘");
  const keyMap = { delete: "⌫", escape: "esc", return: "return", space: "space", tab: "tab" };
  caps.push(keyMap[sc.key] ?? sc.key.toUpperCase());
  return caps;
}

function generateSwift({ entities, rules, icons, tokens, caps, settings, dests, actions, surfaces }) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces}.json");
  lines.push("// Regenerate: node scripts/gen-registries.mjs");
  lines.push("");
  lines.push("import Foundation");
  lines.push("");

  // 1. Entities & Limits
  lines.push("/// Wire schema size and count limits shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityLimits {");
  for (const [k, v] of Object.entries(entities.limits)) {
    const type = v > 2_000_000_000 || k.endsWith("Bytes") ? "Int64" : "Int";
    lines.push(`  static let ${k}: ${type} = ${v}`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Wire schema regex strings shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityPatterns {");
  for (const [k, v] of Object.entries(entities.patterns)) {
    lines.push(`  static let ${k} = ${swiftStr(v)}`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Canonical enum wire strings shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityEnums {");
  for (const [k, vals] of Object.entries(entities.enums)) {
    lines.push(`  static let ${k}: [String] = [${vals.map(swiftStr).join(", ")}]`);
  }
  const entityNames = Object.keys(entities.entities);
  const deletable = entityNames.filter((n) => entities.entities[n].deletable);
  lines.push(`  static let entityNames: [String] = [${entityNames.map(swiftStr).join(", ")}]`);
  lines.push(`  static let deletableEntities: [String] = [${deletable.map(swiftStr).join(", ")}]`);
  lines.push("}");
  lines.push("");

  // 2. Domain Rules
  lines.push("/// Domain thresholds and retention constants shared across platforms (`registry/rules.json`).");
  lines.push("enum RegistryRules {");
  for (const [k, v] of Object.entries(rules)) {
    if (k === "version") continue;
    const type = Number.isInteger(v) ? "Int" : "Double";
    lines.push(`  static let ${k}: ${type} = ${v}`);
  }
  lines.push("}");
  lines.push("");

  // 3. Semantic Icons
  lines.push("/// Semantic icon ID → SF Symbol lookup (`registry/icons.json`).");
  lines.push("enum RegistryIcons {");
  lines.push("  static let sfSymbols: [String: String] = [");
  for (const [id, map] of Object.entries(icons.icons)) {
    lines.push(`    ${swiftStr(id)}: ${swiftStr(map.sfSymbol)},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static func sfSymbol(for id: String) -> String {");
  lines.push('    sfSymbols[id] ?? "circle"');
  lines.push("  }");
  lines.push("}");
  lines.push("");

  // 4. Design Tokens
  lines.push("/// Shared numeric and palette design tokens (`registry/tokens.json`).");
  lines.push("enum RegistryTokens {");
  lines.push("  enum Selection {");
  lines.push(`    static let emphasizedAlphaLight: Double = ${tokens.selection.emphasizedAlphaLight}`);
  lines.push(`    static let emphasizedAlphaDark: Double = ${tokens.selection.emphasizedAlphaDark}`);
  lines.push(`    static let unemphasizedAlphaLight: Double = ${tokens.selection.unemphasizedAlphaLight}`);
  lines.push(`    static let unemphasizedAlphaDark: Double = ${tokens.selection.unemphasizedAlphaDark}`);
  lines.push(`    static let chipSelectedFillOpacity: Double = ${tokens.selection.chipSelectedFillOpacity}`);
  lines.push(`    static let pointerHoverOpacity: Double = ${tokens.selection.pointerHoverOpacity}`);
  lines.push("  }");
  lines.push("  enum Radii {");
  lines.push(`    static let card: Double = ${tokens.radii.card}`);
  lines.push(`    static let small: Double = ${tokens.radii.small}`);
  lines.push(`    static let transientSurface: Double = ${tokens.radii.transientSurface}`);
  lines.push("  }");
  lines.push("  enum Spacing {");
  lines.push(`    static let xs: Double = ${tokens.spacing.xs}`);
  lines.push(`    static let sm: Double = ${tokens.spacing.sm}`);
  lines.push(`    static let md: Double = ${tokens.spacing.md}`);
  lines.push(`    static let lg: Double = ${tokens.spacing.lg}`);
  lines.push(`    static let pageGutter: Double = ${tokens.spacing.pageGutter}`);
  lines.push(`    static let pageTop: Double = ${tokens.spacing.pageTop}`);
  lines.push("  }");
  lines.push("  enum DesktopColumn {");
  lines.push(`    static let marginFraction: Double = ${tokens.desktopColumn.marginFraction}`);
  lines.push(`    static let minInset: Double = ${tokens.desktopColumn.minInset}`);
  lines.push(`    static let maxInset: Double = ${tokens.desktopColumn.maxInset}`);
  lines.push(`    static let verticalInset: Double = ${tokens.desktopColumn.verticalInset}`);
  lines.push(`    static let titleBarGap: Double = ${tokens.desktopColumn.titleBarGap}`);
  lines.push("  }");
  lines.push(`  static let accentPalette: [String] = [${tokens.accentPalette.map(swiftStr).join(", ")}]`);
  lines.push("  static let textScaleFactors: [Int: Double] = [");
  for (const s of tokens.textScale.steps) {
    lines.push(`    ${s.step}: ${s.factor},`);
  }
  lines.push("  ]");
  lines.push("}");
  lines.push("");

  // 5. Settings
  const syncedKeys = Object.entries(settings.keys).filter(([, v]) => v.scope === "synced").map(([k]) => k);
  lines.push("/// Unified task-app settings keys, defaults, and synced-key list (`registry/settings.json`).");
  lines.push("enum RegistrySettings {");
  lines.push(`  static let syncedKeys: [String] = [${syncedKeys.map(swiftStr).join(", ")}]`);
  lines.push("");
  lines.push("  enum StorageKey {");
  for (const [k, def] of Object.entries(settings.keys)) {
    if (def.storageKey) lines.push(`    static let ${k} = ${swiftStr(def.storageKey)}`);
  }
  lines.push("  }");
  lines.push("");
  lines.push("  enum Defaults {");
  for (const [k, def] of Object.entries(settings.keys)) {
    if (def.type === "bool") lines.push(`    static let ${k}: Bool = ${def.default}`);
    else if (def.type === "int") lines.push(`    static let ${k}: Int = ${def.default}`);
    else if (def.type === "enum" && typeof def.default === "string") lines.push(`    static let ${k}: String = ${swiftStr(def.default)}`);
    else if (def.type === "string" && typeof def.default === "string") lines.push(`    static let ${k}: String = ${swiftStr(def.default)}`);
  }
  lines.push("  }");
  lines.push("}");
  lines.push("");

  // 6. Destinations
  lines.push("/// Canonical smart-list metadata (`registry/destinations.json`).");
  lines.push("struct RegistryDestination: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let navigationKey: String");
  lines.push("  let serverView: String");
  lines.push("  let title: String");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
  lines.push("  let visibility: String");
  lines.push("  let shortcutKeycaps: [String]?");
  lines.push("  let emptyTitle: String");
  lines.push("  let emptyDetail: String");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistryDestinations {");
  lines.push("  static let viewAliases: [String: String] = [");
  for (const [k, v] of Object.entries(dests.viewAliases)) {
    lines.push(`    ${swiftStr(k)}: ${swiftStr(v)},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let all: [RegistryDestination] = [");
  for (const d of dests.destinations) {
    const capsList = d.shortcut ? `[${appleKeycaps(d.shortcut).map(swiftStr).join(", ")}]` : "nil";
    lines.push(
      `    RegistryDestination(id: ${swiftStr(d.id)}, navigationKey: ${swiftStr(d.navigationKey)}, serverView: ${swiftStr(d.serverView)}, title: ${swiftStr(d.title)}, iconId: ${swiftStr(d.icon)}, sfSymbol: ${swiftStr(icons.icons[d.icon].sfSymbol)}, visibility: ${swiftStr(d.visibility)}, shortcutKeycaps: ${capsList}, emptyTitle: ${swiftStr(d.emptyState.title)}, emptyDetail: ${swiftStr(d.emptyState.detail)}),`
    );
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let byNavigationKey: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.navigationKey, $0) })");
  lines.push("}");
  lines.push("");

  // 7. Actions & Shortcuts Sheet
  lines.push("/// Generated shortcut-sheet entry (`registry/actions.json`).");
  lines.push("struct RegistryShortcutEntry: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let label: String");
  lines.push("  let keycaps: [String]");
  lines.push("  let excludePlatforms: [String]");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistryActions {");
  lines.push("  static let titles: [String: String] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    lines.push(`    ${swiftStr(id)}: ${swiftStr(a.title)},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let sfSymbols: [String: String] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    lines.push(`    ${swiftStr(id)}: ${swiftStr(icons.icons[a.icon].sfSymbol)},`);
  }
  lines.push("  ]");
  lines.push("");
  for (const grp of actions.shortcutsSheet) {
    lines.push(`  static let shortcuts${camelId("_" + grp.id)}: [RegistryShortcutEntry] = [`);
    for (const actionId of grp.actionIds) {
      const a = actions.actions[actionId];
      if (!a.shortcut) continue;
      const excl = (a.shortcut.excludePlatforms ?? []).map(swiftStr).join(", ");
      const primaryCaps = appleKeycaps(a.shortcut).map(swiftStr).join(", ");
      lines.push(`    RegistryShortcutEntry(id: ${swiftStr(actionId)}, label: ${swiftStr(a.title)}, keycaps: [${primaryCaps}], excludePlatforms: [${excl}]),`);
      for (const [idx, alt] of (a.shortcut.alternates ?? []).entries()) {
        const altCaps = appleKeycaps(alt).map(swiftStr).join(", ");
        lines.push(`    RegistryShortcutEntry(id: ${swiftStr(`${actionId}.alt${idx}`)}, label: ${swiftStr(a.title)}, keycaps: [${altCaps}], excludePlatforms: [${excl}]),`);
      }
    }
    lines.push("  ]");
  }
  lines.push("}");
  lines.push("");

  // 8. Surfaces (Notices, Prompts, Task Attributes)
  lines.push("/// Destructive and fork confirmation copy (`registry/surfaces.json`).");
  lines.push("struct RegistryPromptCopy: Sendable, Hashable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let message: String");
  lines.push("  let confirmTitle: String?");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistrySurfaces {");
  lines.push(`  static let maxConcurrentExplainers: Int = ${surfaces.notices.maxConcurrentExplainers}`);
  lines.push(`  static let toastDurationSeconds: Double = ${surfaces.toasts.durationSeconds}`);
  lines.push(`  static let taskAttributeOrder: [String] = [${surfaces.taskAttributes.map((a) => swiftStr(a.id)).join(", ")}]`);
  lines.push("  static let prompts: [String: RegistryPromptCopy] = [");
  for (const p of surfaces.prompts.items) {
    lines.push(`    ${swiftStr(p.id)}: RegistryPromptCopy(id: ${swiftStr(p.id)}, title: ${swiftStr(p.title)}, message: ${swiftStr(p.message)}, confirmTitle: ${swiftOptStr(p.confirmTitle)}),`);
  }
  lines.push("  ]");
  lines.push("}");
  lines.push("");

  // 9. Capabilities parity ledger
  lines.push("/// Canonical capability parity ledger (`registry/capabilities.json`, ADR 0013 / ADR 0015).");
  lines.push("enum RegistryCapabilities {");
  lines.push("  static let byPlatform: [String: [String: String]] = [");
  for (const p of caps.platforms) {
    const pairs = Object.entries(caps.capabilities).map(([id, entry]) => `${swiftStr(id)}: ${swiftStr(entry[p])}`);
    lines.push(`    ${swiftStr(p)}: [${pairs.join(", ")}],`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static func isShipped(_ featureId: String, on platform: String) -> Bool {");
  lines.push('    byPlatform[platform]?[featureId] == "ships"');
  lines.push("  }");
  lines.push("}");
  lines.push("");

  return lines.join("\n");
}

function generateTS({ entities, rules, icons, tokens, caps, settings, dests, actions, surfaces }) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces}.json");
  lines.push("// Regenerate: node scripts/gen-registries.mjs");
  lines.push("");
  lines.push("export const ENTITY_PATTERNS = {");
  for (const [k, v] of Object.entries(entities.patterns)) {
    lines.push(`  ${k}: ${JSON.stringify(v)},`);
  }
  lines.push("} as const;");
  lines.push("");
  lines.push("export const ENTITY_LIMITS = {");
  for (const [k, v] of Object.entries(entities.limits)) {
    lines.push(`  ${k}: ${v},`);
  }
  lines.push("} as const;");
  lines.push("");
  lines.push("export const ENTITY_ENUMS = {");
  for (const [k, vals] of Object.entries(entities.enums)) {
    lines.push(`  ${k}: ${JSON.stringify(vals)} as const,`);
  }
  lines.push("} as const;");
  lines.push("");
  const deletable = Object.keys(entities.entities).filter((n) => entities.entities[n].deletable);
  lines.push(`export const DELETABLE_ENTITIES = ${JSON.stringify(deletable)} as const;`);
  lines.push("");
  lines.push("export const DOMAIN_RULES = {");
  for (const [k, v] of Object.entries(rules)) {
    if (k === "version") continue;
    lines.push(`  ${k}: ${v},`);
  }
  lines.push("} as const;");
  lines.push("");
  const syncedKeys = Object.entries(settings.keys).filter(([, v]) => v.scope === "synced").map(([k]) => k);
  lines.push(`export const SYNCED_SETTING_KEYS = ${JSON.stringify(syncedKeys)} as const;`);
  lines.push(`export const VIEW_ALIASES = ${JSON.stringify(dests.viewAliases)} as const;`);
  lines.push(`export const DESTINATIONS = ${JSON.stringify(dests.destinations)} as const;`);
  lines.push(`export const ICONS = ${JSON.stringify(icons.icons)} as const;`);
  lines.push(`export const DESIGN_TOKENS = ${JSON.stringify({ accentPolicy: tokens.accentPolicy, selection: tokens.selection, colors: tokens.colors, accentPalette: tokens.accentPalette, radii: tokens.radii, spacing: tokens.spacing, desktopColumn: tokens.desktopColumn, textScale: tokens.textScale })} as const;`);
  lines.push(`export const CAPABILITIES = ${JSON.stringify(caps.capabilities)} as const;`);
  lines.push(`export const ACTIONS_CATALOG = ${JSON.stringify({ actions: actions.actions, contextMenus: actions.contextMenus, swipeActions: actions.swipeActions, shortcutsSheet: actions.shortcutsSheet })} as const;`);
  lines.push(`export const SURFACES_CATALOG = ${JSON.stringify({ notices: surfaces.notices, prompts: surfaces.prompts, toasts: surfaces.toasts, taskAttributes: surfaces.taskAttributes })} as const;`);
  lines.push("");
  return lines.join("\n");
}

function writeOrCheck(rel, content) {
  const full = path.join(REPO, rel);
  const existing = fs.existsSync(full) ? fs.readFileSync(full, "utf8") : null;
  if (CHECK) {
    if (existing !== content) {
      throw new Error(`generated file out of date: ${rel} (run: node scripts/gen-registries.mjs)`);
    }
    return false;
  }
  if (existing === content) return false;
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content, "utf8");
  return true;
}

const entities = readJSON("registry/entities.json");
const rules = readJSON("registry/rules.json");
const icons = readJSON("registry/icons.json");
const tokens = readJSON("registry/tokens.json");
const caps = readJSON("registry/capabilities.json");
const settings = readJSON("registry/settings.json");
const dests = readJSON("registry/destinations.json");
const actions = readJSON("registry/actions.json");
const surfaces = readJSON("registry/surfaces.json");

validateEntities(entities);
validateRules(rules);
validateIcons(icons);
validateTokens(tokens);
validateCapabilities(caps);
validateSettings(settings, entities, icons, caps);
const destIds = validateDestinations(dests, icons, caps);
validateActions(actions, icons, caps, destIds);
validateSurfaces(surfaces, icons, caps);
validateConformance();

const bundle = { entities, rules, icons, tokens, caps, settings, dests, actions, surfaces };
const outputs = [
  ["SeptenaCore/Generated/RegistryConstants.swift", generateSwift(bundle)],
  ["backend/src/generated/registries.ts", generateTS(bundle)],
];

let changed = 0;
for (const [rel, content] of outputs) {
  if (writeOrCheck(rel, content)) {
    console.log(`wrote ${rel}`);
    changed++;
  }
}

if (CHECK) {
  console.log("registries: ok (all 9 registries valid and generated files up to date)");
} else if (changed === 0) {
  console.log("registries: already up to date");
}
