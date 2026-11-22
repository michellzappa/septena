#!/usr/bin/env node
// Validates all `registry/*.json` files (including cross-file referential
// integrity) and generates typed Swift, TypeScript, Kotlin and Rust bindings.
//
// Usage:
//   node scripts/gen-registries.mjs          # validate and write generated files
//   node scripts/gen-registries.mjs --check  # validate and fail if generated files drifted
//
// Zero external dependencies (Node >= 20). See ADR 0015 (`docs/adr/0015-*.md`).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as L10N from "./registry-l10n.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, "..");
const CHECK = process.argv.includes("--check");
// `--seed-l10n <lang>`: one-time import of <lang> translations for registry
// keys out of `Septena/Localizable.xcstrings` into `registry/l10n/<lang>.json`.
const SEED_LANG = (() => {
  const i = process.argv.indexOf("--seed-l10n");
  return i === -1 ? null : process.argv[i + 1];
})();

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
  assert(Array.isArray(entities.turnFields) && entities.turnFields.length > 0, "entities.json: missing turnFields");
  assert(entities.turnFields.every((field) => typeof field === "string" && field.length > 0), "entities.json: turnFields must contain non-empty strings");
  assert(new Set(entities.turnFields).size === entities.turnFields.length, "entities.json: turnFields contains duplicates");
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
    "deleteGraceSeconds",
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
  if (tokens.fruitAccents !== undefined) {
    assert(Array.isArray(tokens.fruitAccents) && tokens.fruitAccents.length > 0, "tokens.json: fruitAccents must be non-empty array");
    for (const a of tokens.fruitAccents) {
      assert(typeof a.id === "string" && a.id.length > 0, "tokens.json: fruitAccent missing id");
      for (const h of [a.light, a.dark, a.checkLight, a.checkDark]) {
        assert(/^#[0-9a-fA-F]{6}$/.test(h), `tokens.json: fruitAccent ${a.id} invalid hex "${h}"`);
      }
    }
  }
  if (tokens.textures !== undefined) {
    assert(Array.isArray(tokens.textures) && tokens.textures.length > 0, "tokens.json: textures must be non-empty array");
    for (const t of tokens.textures) {
      assert(typeof t.id === "string" && t.id.length > 0, "tokens.json: texture missing id");
      assert(typeof t.name === "string" && t.name.length > 0, `tokens.json: texture ${t.id} missing name`);
    }
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
  assert(settings.version === 2, "settings.json: version must be 2");
  const validTypes = new Set(["bool", "int", "enum", "string", "string[]"]);
  const validScopes = new Set(["synced", "device"]);
  const validPlatforms = new Set(caps.platforms);
  const validPresentations = new Set(["card", "inline"]);
  const validVisibilities = new Set(["always", "signedIn", "signedOut", "whenNonEmpty", "minAppleOS27", "debugOnly"]);

  for (const [key, def] of Object.entries(settings.keys)) {
    assert(validScopes.has(def.scope), `settings.json: ${key} invalid scope "${def.scope}"`);
    assert(validTypes.has(def.type), `settings.json: ${key} invalid type "${def.type}"`);
    assert(def.featureId in caps.capabilities, `settings.json: ${key} unknown featureId "${def.featureId}"`);
    assert(Array.isArray(def.platforms) && def.platforms.length > 0, `settings.json: ${key} missing platforms`);
    for (const p of def.platforms) assert(validPlatforms.has(p), `settings.json: ${key} unknown platform "${p}"`);
    if (def.enum !== undefined) {
      assert(def.enum in entities.enums, `settings.json: ${key} unknown enum "${def.enum}"`);
    }
    if (def.format !== undefined) {
      assert(def.format in entities.patterns, `settings.json: ${key} unknown format "${def.format}"`);
    }
    if (def.options !== undefined) {
      assert(Array.isArray(def.options) && def.options.length > 0, `settings.json: ${key} options must be non-empty array`);
      for (const opt of def.options) {
        assert(typeof opt.value === "string" && opt.value.length > 0, `settings.json: ${key} option missing value`);
        assert(typeof opt.title === "string" && opt.title.length > 0, `settings.json: ${key} option missing title`);
      }
    }
  }

  assert(Array.isArray(settings.desktopTabs) && settings.desktopTabs.length > 0, "settings.json: missing desktopTabs");
  const tabIds = new Set();
  for (const tab of settings.desktopTabs) {
    assert(!tabIds.has(tab.id), `settings.json: duplicate desktopTab "${tab.id}"`);
    tabIds.add(tab.id);
    assert(tab.icon in icons.icons, `settings.json: desktopTab ${tab.id} unknown icon "${tab.icon}"`);
    assert(tab.featureId in caps.capabilities, `settings.json: desktopTab ${tab.id} unknown featureId "${tab.featureId}"`);
  }

  assert(Array.isArray(settings.pages) && settings.pages.length > 0, "settings.json: missing pages");
  const pagesById = new Map();
  for (const page of settings.pages) {
    assert(!pagesById.has(page.id), `settings.json: duplicate page "${page.id}"`);
    assert(page.depth === 1 || page.depth === 2, `settings.json: page ${page.id} depth must be 1 or 2`);
    assert(page.icon in icons.icons, `settings.json: page ${page.id} unknown icon "${page.icon}"`);
    assert(page.featureId in caps.capabilities, `settings.json: page ${page.id} unknown featureId "${page.featureId}"`);
    if (page.platforms !== undefined) {
      for (const p of page.platforms) assert(validPlatforms.has(p), `settings.json: page ${page.id} unknown platform "${p}"`);
    }
    assert(Array.isArray(page.sections) && page.sections.length > 0, `settings.json: page ${page.id} must have >= 1 section`);
    pagesById.set(page.id, page);
  }

  const seenSettingKeys = new Set();
  const seenSurfaces = new Set();
  const linkedPages = new Set();

  const validateItem = (ctx, item, allowPageDepths) => {
    if (item.icon !== undefined) assert(item.icon in icons.icons, `settings.json: ${ctx} unknown icon "${item.icon}"`);
    if (item.featureId !== undefined) assert(item.featureId in caps.capabilities, `settings.json: ${ctx} unknown featureId "${item.featureId}"`);
    if (item.platforms !== undefined) {
      for (const p of item.platforms) assert(validPlatforms.has(p), `settings.json: ${ctx} unknown platform "${p}"`);
    }
    if (item.visibility !== undefined) {
      assert(validVisibilities.has(item.visibility), `settings.json: ${ctx} invalid visibility "${item.visibility}"`);
    }
    if (item.kind === "setting") {
      assert(item.key in settings.keys, `settings.json: ${ctx} references unknown setting "${item.key}"`);
      assert(settings.keys[item.key].ui !== false, `settings.json: ${ctx} references internal ui:false setting "${item.key}"`);
      assert(!seenSettingKeys.has(item.key), `settings.json: duplicate setting "${item.key}" at ${ctx}`);
      seenSettingKeys.add(item.key);
    } else if (item.kind === "customSurface") {
      assert(typeof item.surface === "string" && item.surface.length > 0, `settings.json: ${ctx} customSurface missing surface`);
      assert(!seenSurfaces.has(item.surface), `settings.json: duplicate customSurface "${item.surface}" at ${ctx}`);
      seenSurfaces.add(item.surface);
      if (item.ownsKeys !== undefined) {
        assert(Array.isArray(item.ownsKeys), `settings.json: ${ctx} ownsKeys must be array`);
        for (const k of item.ownsKeys) {
          assert(k in settings.keys, `settings.json: ${ctx} ownsKeys references unknown setting "${k}"`);
          assert(!seenSettingKeys.has(k), `settings.json: duplicate setting "${k}" (via ownsKeys) at ${ctx}`);
          seenSettingKeys.add(k);
        }
      }
    } else if (item.kind === "pageLink") {
      const target = pagesById.get(item.page);
      assert(target !== undefined, `settings.json: ${ctx} pageLink references unknown page "${item.page}"`);
      assert(allowPageDepths.has(target.depth), `settings.json: ${ctx} cannot link to depth-${target.depth} page "${item.page}"`);
      linkedPages.add(item.page);
      if (item.surface !== undefined) {
        assert(!seenSurfaces.has(item.surface), `settings.json: duplicate surface "${item.surface}" at ${ctx}`);
        seenSurfaces.add(item.surface);
      }
    } else {
      assert(false, `settings.json: ${ctx} unknown item kind "${item.kind}"`);
    }
  };

  assert(Array.isArray(settings.rootGroups) && settings.rootGroups.length > 0, "settings.json: missing rootGroups");
  const seenGroupIds = new Set();
  for (const grp of settings.rootGroups) {
    assert(!seenGroupIds.has(grp.id), `settings.json: duplicate rootGroup "${grp.id}"`);
    seenGroupIds.add(grp.id);
    assert(validPresentations.has(grp.mobilePresentation), `settings.json: rootGroup ${grp.id} invalid mobilePresentation`);
    if (grp.desktopTab !== null) {
      assert(tabIds.has(grp.desktopTab), `settings.json: rootGroup ${grp.id} unknown desktopTab "${grp.desktopTab}"`);
    }
    assert(Array.isArray(grp.items) && grp.items.length > 0, `settings.json: rootGroup ${grp.id} must have >= 1 item`);
    for (const item of grp.items) validateItem(`rootGroup.${grp.id}`, item, new Set([1]));
  }

  for (const page of settings.pages) {
    const allowedChildDepths = page.depth === 1 ? new Set([2]) : new Set();
    for (const sec of page.sections) {
      assert(Array.isArray(sec.items) && sec.items.length > 0, `settings.json: section ${page.id}.${sec.id} must have >= 1 item`);
      if (sec.platforms !== undefined) {
        for (const p of sec.platforms) assert(validPlatforms.has(p), `settings.json: section ${page.id}.${sec.id} unknown platform "${p}"`);
      }
      for (const item of sec.items) validateItem(`page.${page.id}.${sec.id}`, item, allowedChildDepths);
    }
  }

  for (const page of settings.pages) {
    assert(linkedPages.has(page.id), `settings.json: orphan page "${page.id}" is never linked`);
  }
  for (const [key, def] of Object.entries(settings.keys)) {
    if (def.ui === false) continue;
    assert(seenSettingKeys.has(key), `settings.json: UI setting "${key}" is never referenced in rootGroups or pages`);
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
    // A band (Inbox on Today) has no sidebar row, so no sidebarOrder.
    if (d.visibility === "todayBand") {
      assert(d.sidebarOrder === undefined, `destinations.json: ${d.id} is a todayBand and cannot have a sidebarOrder`);
    } else {
      assert(d.sidebarOrder > lastOrder, `destinations.json: sidebarOrder must strictly increase at "${d.id}"`);
      lastOrder = d.sidebarOrder;
    }
    assert(typeof d.canHide === "boolean", `destinations.json: ${d.id} missing boolean canHide`);
    assert(typeof d.emptyState?.title === "string" && typeof d.emptyState?.detail === "string", `destinations.json: ${d.id} needs emptyState.title and .detail`);
    assert(d.icon in icons.icons, `destinations.json: ${d.id} unknown icon "${d.icon}"`);
    assert(d.featureId in caps.capabilities, `destinations.json: ${d.id} unknown featureId "${d.featureId}"`);
    // Optional ordered sections a list groups its rows into (Agent stages).
    if (d.groups !== undefined) {
      assert(Array.isArray(d.groups) && d.groups.length > 0, `destinations.json: ${d.id}.groups must be a non-empty array`);
      const seenGroups = new Set();
      for (const g of d.groups) {
        assert(typeof g.id === "string" && !seenGroups.has(g.id), `destinations.json: ${d.id} duplicate or missing group id "${g.id}"`);
        seenGroups.add(g.id);
        assert(typeof g.title === "string" && g.title.length > 0, `destinations.json: ${d.id}.groups.${g.id} needs a title`);
        assert(g.icon in icons.icons, `destinations.json: ${d.id}.groups.${g.id} unknown icon "${g.icon}"`);
      }
    }
  }
  for (const f of ["title", "detail", "pointerDetail", "touchDetail", "syncingTitle"]) {
    assert(typeof dests.genericEmptyState?.[f] === "string", `destinations.json: genericEmptyState.${f} missing`);
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
        if (item.titleField !== undefined) {
          assert(typeof actions.actions[item.id][item.titleField] === "string", `actions.json: menu ${menuName} item ${item.id} titleField "${item.titleField}" is not a title of that action`);
        }
      } else if (item.kind === "destination") {
        assert(destIds.has(item.id), `actions.json: menu ${menuName} references unknown destination "${item.id}"`);
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
  // The menu bar (ADR 0015): one composition, each shell maps `system` menus
  // onto its own (App, File, View, Help) and adds the rest as new menus.
  const validSystemMenus = new Set(["app", "file", "edit", "view", "window", "help"]);
  assert(Array.isArray(actions.menuBar) && actions.menuBar.length > 0, "actions.json: menuBar missing");
  const menuIds = new Set();
  for (const m of actions.menuBar) {
    assert(!menuIds.has(m.id), `actions.json: duplicate menuBar menu "${m.id}"`);
    menuIds.add(m.id);
    assert(typeof m.title === "string" && m.title.length > 0, `actions.json: menuBar.${m.id} missing title`);
    if (m.system !== undefined) assert(validSystemMenus.has(m.system), `actions.json: menuBar.${m.id} unknown system menu "${m.system}"`);
    checkMenuItems(`menuBar.${m.id}`, m.items);
  }

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

// First run (ADR 0015): the steps, copy and button actions every client
// renders. `kind` picks the view; `action` is the only behavior a button may
// name, so a client implements a closed set and the registry stays data.
const FIRST_RUN_KINDS = new Set(["intro", "account", "choices", "connectAgent", "finish"]);
const FIRST_RUN_ACTIONS = new Set(["next", "finish", "signIn", "importThings", "importReminders", "copySetupPrompt", "copyFirstPrompt"]);
const FIRST_RUN_CONDITIONS = new Set(["signedIn"]);

function validateFirstRun(surfaces, icons, caps, settings) {
  const fr = surfaces.firstRun;
  assert(fr && Array.isArray(fr.steps) && fr.steps.length > 0, "surfaces.json: firstRun.steps missing");
  assert(fr.featureId in caps.capabilities, `surfaces.json: firstRun unknown featureId "${fr.featureId}"`);
  const done = settings.keys[fr.completionSetting];
  assert(done && done.scope === "synced", `surfaces.json: firstRun.completionSetting "${fr.completionSetting}" must be a synced settings key`);
  assert(typeof fr.prompts?.setup === "string" && typeof fr.prompts?.first === "string", "surfaces.json: firstRun.prompts needs setup and first");
  const getStarted = surfaces.notices.items.find((n) => n.id === "getStarted");
  const stepIds = new Set((getStarted?.steps ?? []).map((st) => st.id));
  const platforms = new Set(caps.platforms);
  const ids = new Set();
  const checkButton = (ctx, b) => {
    if (b === undefined) return;
    assert(typeof b.title === "string" && b.title.length > 0, `surfaces.json: firstRun ${ctx} button missing title`);
    assert(FIRST_RUN_ACTIONS.has(b.action), `surfaces.json: firstRun ${ctx} unknown action "${b.action}"`);
  };
  for (const st of fr.steps) {
    assert(!ids.has(st.id), `surfaces.json: firstRun duplicate step "${st.id}"`);
    ids.add(st.id);
    assert(FIRST_RUN_KINDS.has(st.kind), `surfaces.json: firstRun ${st.id} unknown kind "${st.kind}"`);
    assert(st.icon in icons.icons, `surfaces.json: firstRun ${st.id} unknown icon "${st.icon}"`);
    assert(typeof st.title === "string" && st.title.length > 0, `surfaces.json: firstRun ${st.id} missing title`);
    for (const c of [st.skipWhen, st.requires]) {
      if (c !== undefined) assert(FIRST_RUN_CONDITIONS.has(c), `surfaces.json: firstRun ${st.id} unknown condition "${c}"`);
    }
    if (st.completesGetStartedStep !== undefined) {
      assert(stepIds.has(st.completesGetStartedStep), `surfaces.json: firstRun ${st.id} unknown Get started step "${st.completesGetStartedStep}"`);
    }
    for (const pt of st.points ?? []) assert(pt.icon in icons.icons, `surfaces.json: firstRun ${st.id} point unknown icon "${pt.icon}"`);
    for (const ch of st.choices ?? []) {
      assert(ch.icon in icons.icons, `surfaces.json: firstRun ${st.id}.${ch.id} unknown icon "${ch.icon}"`);
      assert(FIRST_RUN_ACTIONS.has(ch.action), `surfaces.json: firstRun ${st.id}.${ch.id} unknown action "${ch.action}"`);
      for (const p of ch.platforms ?? []) assert(platforms.has(p), `surfaces.json: firstRun ${st.id}.${ch.id} unknown platform "${p}"`);
    }
    checkButton(`${st.id}.primary`, st.primary);
    checkButton(`${st.id}.secondary`, st.secondary);
    checkButton(`${st.id}.tertiary`, st.tertiary);
    checkButton(`${st.id}.afterDone`, st.afterDone);
    if (st.kind === "choices") assert((st.choices ?? []).length > 0, `surfaces.json: firstRun ${st.id} needs choices`);
  }
  assert(fr.steps[fr.steps.length - 1].kind === "finish", "surfaces.json: firstRun last step must be kind finish");
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
  const attrIds = new Set();
  for (const attr of surfaces.taskAttributes) {
    assert(!attrIds.has(attr.id), `surfaces.json: duplicate attribute ${attr.id}`);
    attrIds.add(attr.id);
    assert(["field", "inline", "popover", "chip"].includes(attr.surfaceTier), `surfaces.json: attribute ${attr.id} unknown surfaceTier "${attr.surfaceTier}"`);
    assert(attr.icon in icons.icons, `surfaces.json: attribute ${attr.id} unknown icon "${attr.icon}"`);
    assert(attr.featureId in caps.capabilities, `surfaces.json: attribute ${attr.id} unknown featureId "${attr.featureId}"`);
  }
}

// ---- plans.json (ADR 0010, ADR 0023) ----
const PLAN_LEVELS = ["device", "account", "plus"];
const PLAN_LIMIT_PLANS = ["account", "plus"];

/** Every string in a JSON value, with its path. */
function stringsOf(node, p, out = []) {
  if (typeof node === "string") out.push([p, node]);
  else if (Array.isArray(node)) node.forEach((v, i) => stringsOf(v, `${p}.${i}`, out));
  else if (node && typeof node === "object") for (const [k, v] of Object.entries(node)) if (k !== "description") stringsOf(v, `${p}.${k}`, out);
  return out;
}

function validatePlans(plans, icons, caps) {
  assert(plans.version === 1, "plans.json: version must be 1");
  assert(plans.featureId in caps.capabilities, `plans.json: unknown featureId "${plans.featureId}"`);
  for (const f of ["name", "shortName", "headline", "subhead"]) assert(typeof plans[f] === "string" && plans[f].length > 0, `plans.json: ${f} missing`);
  // House rule: rendered copy has no em or en dashes.
  for (const [p, v] of stringsOf(plans, "plans")) assert(!/[–—]/.test(v), `plans.json: ${p} contains an em or en dash`);
  assert(typeof plans.checkout?.open === "boolean", "plans.json: checkout.open must be a boolean");
  assert(Number.isInteger(plans.trial?.days) && plans.trial.days > 0, "plans.json: trial.days must be a positive integer");
  assert(plans.trial.kind === "reverse", "plans.json: trial.kind must be reverse (ADR 0010: one server-side trial, no store offer)");
  assert(plans.trial.title.includes(String(plans.trial.days)), "plans.json: trial.title must state trial.days");

  const priceIds = new Set();
  for (const pr of plans.prices) {
    assert(!priceIds.has(pr.id), `plans.json: duplicate price "${pr.id}"`);
    priceIds.add(pr.id);
    assert(/^com\.septena\.tasks\.sync\.[a-z]+$/.test(pr.productId), `plans.json: price ${pr.id} productId must start com.septena.tasks.sync.`);
    assert(Number.isInteger(pr.amountMinor) && pr.amountMinor > 0, `plans.json: price ${pr.id} amountMinor must be a positive integer`);
    assert(pr.currency === "EUR", `plans.json: price ${pr.id} currency must be EUR`);
    assert(["year", "month"].includes(pr.interval), `plans.json: price ${pr.id} unknown interval "${pr.interval}"`);
    const whole = String(pr.amountMinor / 100);
    assert(pr.label.includes(whole), `plans.json: price ${pr.id} label must state ${whole}`);
  }
  assert(plans.prices.filter((x) => x.highlighted).length === 1, "plans.json: exactly one price must be highlighted");

  assert(JSON.stringify(plans.levels.map((l) => l.id)) === JSON.stringify(PLAN_LEVELS), `plans.json: levels must be ${PLAN_LEVELS.join(", ")}`);
  assert(JSON.stringify(plans.cards.map((c) => c.id)) === JSON.stringify(["free", "plus"]), "plans.json: cards must be free, plus");
  assert(plans.cards.filter((c) => c.highlighted).length === 1, "plans.json: exactly one card must be highlighted");

  const lim = plans.limits;
  const keys = Object.keys(lim.account).sort();
  for (const plan of PLAN_LIMIT_PLANS) {
    assert(JSON.stringify(Object.keys(lim[plan] ?? {}).sort()) === JSON.stringify(keys), `plans.json: limits.${plan} must have the same keys as limits.account`);
    for (const [k, v] of Object.entries(lim[plan])) {
      assert(v === null || typeof v === "boolean" || (Number.isInteger(v) && v >= 0), `plans.json: limits.${plan}.${k} must be null, a boolean or a non-negative integer`);
    }
  }

  const rowIds = new Set();
  for (const o of plans.outcomes) {
    assert(o.icon in icons.icons, `plans.json: outcome ${o.id} unknown icon "${o.icon}"`);
    for (const r of o.rows) {
      assert(!rowIds.has(r.id), `plans.json: duplicate row "${r.id}"`);
      rowIds.add(r.id);
      if (r.featureId !== undefined) assert(r.featureId in caps.capabilities, `plans.json: row ${r.id} unknown featureId "${r.featureId}"`);
      if (r.status !== undefined) assert(r.status === "planned", `plans.json: row ${r.id} status must be planned`);
      for (const lv of PLAN_LEVELS) {
        const c = r.cells?.[lv];
        assert(typeof c === "boolean" || (typeof c === "string" && c.length > 0), `plans.json: row ${r.id} cell ${lv} must be a boolean or text`);
      }
      if (r.limit !== undefined) {
        assert(r.limit in lim.account, `plans.json: row ${r.id} unknown limit "${r.limit}"`);
        // The copy states the number the server enforces.
        for (const plan of PLAN_LIMIT_PLANS) {
          const v = lim[plan][r.limit];
          const cell = r.cells[plan];
          if (Number.isInteger(v) && v > 0) {
            assert(typeof cell === "string" && new RegExp(`(^|\\D)${v}(\\D|$)`).test(cell), `plans.json: row ${r.id} ${plan} cell must state the limit ${v}`);
          }
        }
      }
    }
  }
  for (const list of ["promises", "upsells"]) {
    const ids = new Set();
    for (const n of plans[list]) {
      assert(!ids.has(n.id), `plans.json: duplicate ${list} "${n.id}"`);
      ids.add(n.id);
      assert(n.title && n.detail, `plans.json: ${list} ${n.id} needs title and detail`);
    }
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
// Localized registry copy (ADR 0020). Set once the strings are collected.
let BY_KEY = null;
const L = (s, obj, field) => L10N.swiftLookup(BY_KEY, s, obj?.l10nKeys?.[field] ?? s);
const LOpt = (s, obj, field) => (s === undefined || s === null ? "nil" : L(s, obj, field));
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

function generateSwift({ entities, rules, icons, tokens, caps, settings, dests, actions, surfaces, plans }) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces,plans}.json");
  lines.push("// Regenerate: node scripts/gen-registries.mjs");
  lines.push("");
  lines.push("import Foundation");
  lines.push("");
  lines.push(L10N.SWIFT_RUNTIME);

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
  lines.push("/// Canonical conversation turn fields shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryTurnFields {");
  lines.push(`  static let all: Set<String> = [${entities.turnFields.map(swiftStr).join(", ")}]`);
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
  lines.push("/// Exotic-fruit app accent descriptor (`registry/tokens.json`, ADR 0019).");
  lines.push("struct RegistryFruitAccent: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let name: String");
  lines.push("  let origin: String");
  lines.push("  let lightHex: String");
  lines.push("  let darkHex: String");
  lines.push("  let checkLightHex: String");
  lines.push("  let checkDarkHex: String");
  lines.push("  let multicolor: Bool");
  lines.push("}");
  lines.push("");
  lines.push("/// Procedural header-wash texture descriptor (`registry/tokens.json`, ADR 0019).");
  lines.push("struct RegistryTextureOption: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let name: String");
  lines.push("  let tag: String");
  lines.push("}");
  lines.push("");
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
  lines.push("  static let fruitAccents: [RegistryFruitAccent] = [");
  for (const a of tokens.fruitAccents ?? []) {
    lines.push(`    RegistryFruitAccent(id: ${swiftStr(a.id)}, name: ${L(a.name, a, "name")}, origin: ${swiftStr(a.origin)}, lightHex: ${swiftStr(a.light)}, darkHex: ${swiftStr(a.dark)}, checkLightHex: ${swiftStr(a.checkLight)}, checkDarkHex: ${swiftStr(a.checkDark)}, multicolor: ${Boolean(a.multicolor)}),`);
  }
  lines.push("  ]");
  lines.push("  static let textures: [RegistryTextureOption] = [");
  for (const t of tokens.textures ?? []) {
    lines.push(`    RegistryTextureOption(id: ${swiftStr(t.id)}, name: ${L(t.name, t, "name")}, tag: ${L(t.tag, t, "tag")}),`);
  }
  lines.push("  ]");
  lines.push("  static let textScaleFactors: [Int: Double] = [");
  for (const s of tokens.textScale.steps) {
    lines.push(`    ${s.step}: ${s.factor},`);
  }
  lines.push("  ]");
  lines.push("}");
  lines.push("");

  // 5. Settings
  const syncedKeys = Object.entries(settings.keys).filter(([, v]) => v.scope === "synced").map(([k]) => k);
  const optStr = (v) => (v === undefined || v === null ? "nil" : swiftStr(v));
  const optInt = (v) => (v === undefined || v === null ? "nil" : String(v));
  const optArr = (arr) => (arr === undefined || arr === null ? "nil" : `[${arr.map(swiftStr).join(", ")}]`);
  const emitItem = (item) => {
    const iconId = item.icon ?? null;
    const sf = iconId ? icons.icons[iconId].sfSymbol : null;
    return `RegistrySettingsItem(kind: ${swiftStr(item.kind)}, key: ${optStr(item.key)}, page: ${optStr(item.page)}, surface: ${optStr(item.surface)}, label: ${LOpt(item.label, item, "label")}, detail: ${LOpt(item.detail, item, "detail")}, iconId: ${optStr(iconId)}, sfSymbol: ${optStr(sf)}, statusKey: ${optStr(item.statusKey)}, desktopInline: ${Boolean(item.desktopInline)}, visibility: ${swiftStr(item.visibility ?? "always")}, platforms: ${optArr(item.platforms)})`;
  };

  lines.push("/// Desktop Settings sidebar tab descriptor (`registry/settings.json`).");
  lines.push("struct RegistrySettingsTab: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
  lines.push("  let group: String");
  lines.push("  let paletteSlot: Int?");
  lines.push("  let featureId: String");
  lines.push("}");
  lines.push("");
  lines.push("/// Choice option descriptor for enum/bounded settings (`registry/settings.json`).");
  lines.push("struct RegistrySettingsOption: Sendable, Hashable, Identifiable {");
  lines.push("  let value: String");
  lines.push("  let title: String");
  lines.push("  var id: String { value }");
  lines.push("}");
  lines.push("");
  lines.push("/// One item in a Settings root group or page section (`registry/settings.json`).");
  lines.push("struct RegistrySettingsItem: Sendable, Hashable, Identifiable {");
  lines.push("  let kind: String");
  lines.push("  let key: String?");
  lines.push("  let page: String?");
  lines.push("  let surface: String?");
  lines.push("  let label: String?");
  lines.push("  let detail: String?");
  lines.push("  let iconId: String?");
  lines.push("  let sfSymbol: String?");
  lines.push("  let statusKey: String?");
  lines.push("  let desktopInline: Bool");
  lines.push("  let visibility: String");
  lines.push("  let platforms: [String]?");
  lines.push("  var id: String { \"\\(kind):\\(key ?? page ?? surface ?? label ?? \"item\")\" }");
  lines.push("  func applies(to platform: String) -> Bool { platforms?.contains(platform) ?? true }");
  lines.push("}");
  lines.push("");
  lines.push("/// One root-level group in mobile Settings (`registry/settings.json`).");
  lines.push("struct RegistrySettingsGroup: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let header: String?");
  lines.push("  let mobilePresentation: String");
  lines.push("  let desktopTab: String?");
  lines.push("  let items: [RegistrySettingsItem]");
  lines.push("}");
  lines.push("");
  lines.push("/// One section inside a pushed Settings page (`registry/settings.json`).");
  lines.push("struct RegistrySettingsSection: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let header: String?");
  lines.push("  let platforms: [String]?");
  lines.push("  let items: [RegistrySettingsItem]");
  lines.push("  func applies(to platform: String) -> Bool { platforms?.contains(platform) ?? true }");
  lines.push("}");
  lines.push("");
  lines.push("/// One depth-1 or depth-2 Settings page (`registry/settings.json`).");
  lines.push("struct RegistrySettingsPage: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
  lines.push("  let depth: Int");
  lines.push("  let platforms: [String]?");
  lines.push("  let featureId: String");
  lines.push("  let sections: [RegistrySettingsSection]");
  lines.push("  func applies(to platform: String) -> Bool { platforms?.contains(platform) ?? true }");
  lines.push("}");
  lines.push("");
  lines.push("/// Unified task-app settings keys, defaults, synced-key list, and taxonomy (`registry/settings.json`).");
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
  lines.push("");
  lines.push("  enum TabID {");
  for (const tab of settings.desktopTabs) {
    const camel = tab.id.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
    lines.push(`    static let ${camel} = ${swiftStr(tab.id)}`);
  }
  lines.push("  }");
  lines.push("");
  lines.push("  enum PageID {");
  for (const page of settings.pages) {
    const camel = page.id.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
    lines.push(`    static let ${camel} = ${swiftStr(page.id)}`);
  }
  lines.push("  }");
  lines.push("");
  lines.push("  static let optionsByKey: [String: [RegistrySettingsOption]] = [");
  for (const [k, def] of Object.entries(settings.keys)) {
    if (!def.options) continue;
    const opts = def.options.map((o) => `RegistrySettingsOption(value: ${swiftStr(o.value)}, title: ${L(o.title, o, "title")})`).join(", ");
    lines.push(`    ${swiftStr(k)}: [${opts}],`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let desktopTabs: [RegistrySettingsTab] = [");
  for (const tab of settings.desktopTabs) {
    lines.push(`    RegistrySettingsTab(id: ${swiftStr(tab.id)}, title: ${L(tab.title, tab, "title")}, iconId: ${swiftStr(tab.icon)}, sfSymbol: ${swiftStr(icons.icons[tab.icon].sfSymbol)}, group: ${swiftStr(tab.group)}, paletteSlot: ${optInt(tab.paletteSlot)}, featureId: ${swiftStr(tab.featureId)}),`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let rootGroups: [RegistrySettingsGroup] = [");
  for (const grp of settings.rootGroups) {
    lines.push(`    RegistrySettingsGroup(id: ${swiftStr(grp.id)}, header: ${LOpt(grp.header, grp, "header")}, mobilePresentation: ${swiftStr(grp.mobilePresentation)}, desktopTab: ${optStr(grp.desktopTab)}, items: [`);
    for (const item of grp.items) {
      lines.push(`      ${emitItem(item)},`);
    }
    lines.push("    ]),");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let pages: [RegistrySettingsPage] = [");
  for (const page of settings.pages) {
    lines.push(`    RegistrySettingsPage(id: ${swiftStr(page.id)}, title: ${L(page.title, page, "title")}, iconId: ${swiftStr(page.icon)}, sfSymbol: ${swiftStr(icons.icons[page.icon].sfSymbol)}, depth: ${page.depth}, platforms: ${optArr(page.platforms)}, featureId: ${swiftStr(page.featureId)}, sections: [`);
    for (const sec of page.sections) {
      lines.push(`      RegistrySettingsSection(id: ${swiftStr(sec.id)}, header: ${LOpt(sec.header, sec, "header")}, platforms: ${optArr(sec.platforms)}, items: [`);
      for (const item of sec.items) {
        lines.push(`        ${emitItem(item)},`);
      }
      lines.push("      ]),");
    }
    lines.push("    ]),");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let pageById: [String: RegistrySettingsPage] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })");
  lines.push("  static let tabById: [String: RegistrySettingsTab] = Dictionary(uniqueKeysWithValues: desktopTabs.map { ($0.id, $0) })");
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
  lines.push("  let canHide: Bool");
  lines.push("  let shortcutKeycaps: [String]?");
  lines.push("  let emptyTitle: String");
  lines.push("  let emptyDetail: String");
  lines.push("}");
  lines.push("");
  lines.push("/// One ordered section of a grouped smart list (`groups` in destinations.json).");
  lines.push("struct RegistryDestinationGroup: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
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
      `    RegistryDestination(id: ${swiftStr(d.id)}, navigationKey: ${swiftStr(d.navigationKey)}, serverView: ${swiftStr(d.serverView)}, title: ${L(d.title, d, "title")}, iconId: ${swiftStr(d.icon)}, sfSymbol: ${swiftStr(icons.icons[d.icon].sfSymbol)}, visibility: ${swiftStr(d.visibility)}, canHide: ${d.canHide ? "true" : "false"}, shortcutKeycaps: ${capsList}, emptyTitle: ${L(d.emptyState.title, d.emptyState, "title")}, emptyDetail: ${L(d.emptyState.detail, d.emptyState, "detail")}),`
    );
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let byId: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })");
  lines.push("  static let byNavigationKey: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.navigationKey, $0) })");
  lines.push("");
  lines.push("  /// Ordered row groups per destination id (`groups` in destinations.json).");
  lines.push("  static let groups: [String: [RegistryDestinationGroup]] = [");
  for (const d of dests.destinations) {
    if (!d.groups) continue;
    lines.push(`    ${swiftStr(d.id)}: [`);
    for (const g of d.groups) {
      lines.push(`      RegistryDestinationGroup(id: ${swiftStr(g.id)}, title: ${L(g.title, g, "title")}, iconId: ${swiftStr(g.icon)}, sfSymbol: ${swiftStr(icons.icons[g.icon].sfSymbol)}),`);
    }
    lines.push("    ],");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  /// Empty state for a list with no copy of its own (`genericEmptyState`).");
  lines.push("  enum GenericEmpty {");
  const ge = dests.genericEmptyState;
  for (const f of ["title", "detail", "pointerDetail", "touchDetail", "syncingTitle"]) lines.push(`    static let ${f}: String = ${L(ge[f], ge, f)}`);
  lines.push("  }");
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
  lines.push("/// A platform-neutral shortcut (`primary` is ⌘ on Apple, Ctrl elsewhere).");
  lines.push("struct RegistryShortcut: Sendable, Hashable {");
  lines.push("  let key: String");
  lines.push("  let modifiers: [String]");
  lines.push("  let keycaps: [String]");
  lines.push("  let excludePlatforms: [String]");
  lines.push("  /// Extra bindings for the same action (a menu item shows only one).");
  lines.push("  var alternates: [RegistryShortcut] = []");
  lines.push("}");
  lines.push("");
  lines.push("/// Where an action applies (`availability` in `registry/actions.json`).");
  lines.push("/// Empty `platforms` means every platform.");
  lines.push("struct RegistryActionAvailability: Sendable, Hashable {");
  lines.push("  let selection: String");
  lines.push("  let platforms: [String]");
  lines.push("  let excludeDestinations: [String]");
  lines.push("  let onlyDestinations: [String]");
  lines.push("  let requiresRecurrence: Bool");
  lines.push("}");
  lines.push("");
  lines.push("/// One item in a context menu or menu-bar menu (`registry/actions.json`).");
  lines.push("/// `kind` is `action`, `destination`, `submenu`, `divider` or `slot` (the shell fills a slot).");
  lines.push("struct RegistryMenuItem: Sendable, Hashable, Identifiable {");
  lines.push("  let kind: String");
  lines.push("  let id: String");
  lines.push("  let title: String?");
  lines.push("  let sfSymbol: String?");
  lines.push("  let items: [RegistryMenuItem]");
  lines.push("}");
  lines.push("");
  lines.push("/// One menu-bar menu. `system` names the platform menu it merges into (app, file, view, help).");
  lines.push("struct RegistryMenu: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let system: String?");
  lines.push("  let items: [RegistryMenuItem]");
  lines.push("}");
  lines.push("");
  const destById = new Map(dests.destinations.map((d) => [d.id, d]));
  const menuItem = (item, idx) => {
    if (item.kind === "action") {
      const a = actions.actions[item.id];
      const field = item.titleField ?? "title";
      return `RegistryMenuItem(kind: "action", id: ${swiftStr(item.id)}, title: ${L(a[field], a, field)}, sfSymbol: ${swiftStr(icons.icons[a.icon].sfSymbol)}, items: [])`;
    }
    if (item.kind === "destination") {
      const d = destById.get(item.id);
      return `RegistryMenuItem(kind: "destination", id: ${swiftStr(item.id)}, title: ${L(d.title, d, "title")}, sfSymbol: ${swiftStr(icons.icons[d.icon].sfSymbol)}, items: [])`;
    }
    if (item.kind === "submenu") {
      return `RegistryMenuItem(kind: "submenu", id: ${swiftStr(item.id)}, title: ${L(item.title, item, "title")}, sfSymbol: ${swiftStr(icons.icons[item.icon].sfSymbol)}, items: [${item.items.map(menuItem).join(", ")}])`;
    }
    if (item.kind === "slot") return `RegistryMenuItem(kind: "slot", id: ${swiftStr(item.slot)}, title: nil, sfSymbol: nil, items: [])`;
    return `RegistryMenuItem(kind: "divider", id: ${swiftStr(`divider.${idx}`)}, title: nil, sfSymbol: nil, items: [])`;
  };
  lines.push("enum RegistryActions {");
  lines.push("  static let titles: [String: String] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    lines.push(`    ${swiftStr(id)}: ${L(a.title, a, "title")},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let sfSymbols: [String: String] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    lines.push(`    ${swiftStr(id)}: ${swiftStr(icons.icons[a.icon].sfSymbol)},`);
  }
  lines.push("  ]");
  lines.push("");
  const altFields = ["desktopTitle", "activeTitle", "pluralTitle", "addTitle", "removeTitle", "shortTitle"];
  lines.push("  /// Other titles of an action: `desktopTitle`, `activeTitle` (state on), `pluralTitle`, `addTitle`, `removeTitle`, `shortTitle` (swipe buttons).");
  lines.push("  static let alternateTitles: [String: [String: String]] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    const pairs = altFields.filter((f) => typeof a[f] === "string").map((f) => `${swiftStr(f)}: ${L(a[f], a, f)}`);
    if (pairs.length) lines.push(`    ${swiftStr(id)}: [${pairs.join(", ")}],`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let shortcuts: [String: RegistryShortcut] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    if (!a.shortcut) continue;
    const sc = a.shortcut;
    const excl = `[${(sc.excludePlatforms ?? []).map(swiftStr).join(", ")}]`;
    const one = (k) => `RegistryShortcut(key: ${swiftStr(k.key)}, modifiers: [${k.modifiers.map(swiftStr).join(", ")}], keycaps: [${appleKeycaps(k).map(swiftStr).join(", ")}], excludePlatforms: ${excl}`;
    const alts = (sc.alternates ?? []).map((k) => `${one(k)})`);
    lines.push(`    ${swiftStr(id)}: ${one(sc)}${alts.length ? `, alternates: [${alts.join(", ")}]` : ""}),`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  /// Actions whose `role` is `destructive` (red in menus and swipes).");
  lines.push("  static let destructive: Set<String> = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    if (a.role === "destructive") lines.push(`    ${swiftStr(id)},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let availability: [String: RegistryActionAvailability] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    const av = a.availability ?? {};
    const arr = (v) => `[${(v ?? []).map(swiftStr).join(", ")}]`;
    lines.push(`    ${swiftStr(id)}: RegistryActionAvailability(selection: ${swiftStr(av.selection ?? "any")}, platforms: ${arr(av.platforms)}, excludeDestinations: ${arr(av.excludeDestinations)}, onlyDestinations: ${arr(av.onlyDestinations)}, requiresRecurrence: ${av.requiresRecurrence === true}),`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  /// Swipe slots in screen order, left to right (`swipeActions`).");
  lines.push(`  static let swipeLeading: [String] = [${actions.swipeActions.leading.map(swiftStr).join(", ")}]`);
  lines.push(`  static let swipeTrailing: [String] = [${actions.swipeActions.trailing.map(swiftStr).join(", ")}]`);
  lines.push("");
  lines.push("  static let contextMenus: [String: [RegistryMenuItem]] = [");
  for (const [name, items] of Object.entries(actions.contextMenus)) {
    lines.push(`    ${swiftStr(name)}: [`);
    items.forEach((it, i) => lines.push(`      ${menuItem(it, i)},`));
    lines.push("    ],");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let menuBar: [RegistryMenu] = [");
  for (const m of actions.menuBar) {
    lines.push(`    RegistryMenu(id: ${swiftStr(m.id)}, title: ${L(m.title, m, "title")}, system: ${swiftOptStr(m.system)}, items: [`);
    m.items.forEach((it, i) => lines.push(`      ${menuItem(it, i)},`));
    lines.push("    ]),");
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
      lines.push(`    RegistryShortcutEntry(id: ${swiftStr(actionId)}, label: ${L(a.title, a, "title")}, keycaps: [${primaryCaps}], excludePlatforms: [${excl}]),`);
      for (const [idx, alt] of (a.shortcut.alternates ?? []).entries()) {
        const altCaps = appleKeycaps(alt).map(swiftStr).join(", ");
        lines.push(`    RegistryShortcutEntry(id: ${swiftStr(`${actionId}.alt${idx}`)}, label: ${L(a.title, a, "title")}, keycaps: [${altCaps}], excludePlatforms: [${excl}]),`);
      }
    }
    lines.push("  ]");
  }
  lines.push("}");
  lines.push("");

  // 8. Surfaces (Notices, Prompts, Toasts, Task Attributes)
  // Templates (`{name}` placeholders, plural forms) become functions; the
  // shell passes the values and gets localized text back (ADR 0020).
  const tmplFn = (name, key) => {
    const t = L10N.swiftTemplate(BY_KEY, key);
    return `  static func ${name}(${t.params}) -> String { ${t.body} }`;
  };
  const tmplKey = (v, obj, field) => obj?.l10nKeys?.[field] ?? (typeof v === "string" ? v : v.other);
  const isTmpl = (v) => typeof v !== "string" || L10N.placeholdersOf(v).length > 0;
  /** Swift expression for a field that may be a template, with Swift locals named like its placeholders. */
  const expr = (v, obj, field) => (isTmpl(v) ? L10N.swiftTemplate(BY_KEY, tmplKey(v, obj, field)).body : L(v, obj, field));

  lines.push("/// One notice in a task list (`registry/surfaces.json` `notices`). A notice whose");
  lines.push("/// title has a count gets a title function in `RegistryNotices` instead of `title`.");
  lines.push("struct RegistryNotice: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let kind: String");
  lines.push("  let priority: Int");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
  lines.push("  let dismissScope: String");
  lines.push("  let dismissible: Bool");
  lines.push("  let explainerSlot: Bool");
  lines.push("  let featureId: String");
  lines.push("  let title: String?");
  lines.push("  let detail: String?");
  lines.push("  /// Platform key (`ios`, `ipados`, `macos`, …) → detail that replaces `detail` there.");
  lines.push("  let platformDetails: [String: String]");
  lines.push("  let primaryTitle: String?");
  lines.push("  let steps: [RegistryNoticeStep]");
  lines.push("  func detail(for platform: String) -> String? { platformDetails[platform] ?? detail }");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryNoticeStep: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("  let platformDetails: [String: String]");
  lines.push("  func detail(for platform: String) -> String { platformDetails[platform] ?? detail }");
  lines.push("}");
  lines.push("");
  const platformMap = (obj) => {
    const pairs = [];
    for (const pd of obj.platformDetails ?? []) for (const pl of pd.platforms) pairs.push(`${swiftStr(pl)}: ${L(pd.detail, pd, "detail")}`);
    return pairs.length ? `[${pairs.join(", ")}]` : "[:]";
  };
  lines.push("enum RegistryNotices {");
  lines.push(`  static let maxConcurrentExplainers: Int = ${surfaces.notices.maxConcurrentExplainers}`);
  lines.push("  static let all: [RegistryNotice] = [");
  for (const n of surfaces.notices.items) {
    const title = n.title === undefined || isTmpl(n.title) ? "nil" : L(n.title, n, "title");
    const steps = (n.steps ?? []).map((st) => `RegistryNoticeStep(id: ${swiftStr(st.id)}, title: ${L(st.title, st, "title")}, detail: ${L(st.detail, st, "detail")}, platformDetails: ${platformMap(st)})`).join(", ");
    lines.push(`    RegistryNotice(id: ${swiftStr(n.id)}, kind: ${swiftStr(n.kind)}, priority: ${n.priority}, iconId: ${swiftStr(n.icon)}, sfSymbol: ${swiftStr(icons.icons[n.icon].sfSymbol)}, dismissScope: ${swiftStr(n.dismissScope)}, dismissible: ${Boolean(n.dismissible)}, explainerSlot: ${Boolean(n.explainerSlot)}, featureId: ${swiftStr(n.featureId)}, title: ${title}, detail: ${LOpt(n.detail, n, "detail")}, platformDetails: ${platformMap(n)}, primaryTitle: ${LOpt(n.primaryTitle, n, "primaryTitle")}, steps: [${steps}]),`);
  }
  lines.push("  ]");
  lines.push("  static let byId: [String: RegistryNotice] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })");
  for (const n of surfaces.notices.items) {
    if (n.title !== undefined && isTmpl(n.title)) lines.push(tmplFn(`${n.id}Title`, tmplKey(n.title, n, "title")));
  }
  lines.push("}");
  lines.push("");

  lines.push("/// Destructive and fork confirmation copy (`registry/surfaces.json` `prompts`).");
  lines.push("struct RegistryPromptCopy: Sendable, Hashable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let message: String");
  lines.push("  let confirmTitle: String?");
  lines.push("  /// Fork prompts only: the choices, in order.");
  lines.push("  let options: [RegistryPromptOption]");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPromptOption: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("}");
  lines.push("");
  lines.push("/// A prompt that asks for a name (`registry/surfaces.json` `prompts.text`).");
  lines.push("struct RegistryTextPrompt: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let placeholder: String");
  lines.push("  let confirmTitle: String");
  lines.push("}");
  lines.push("");
  const pr = surfaces.prompts;
  const promptCopy = (p, title, message) => {
    const opts = (p.options ?? []).map((o) => `RegistryPromptOption(id: ${swiftStr(o.id)}, title: ${L(o.title, o, "title")})`).join(", ");
    return `RegistryPromptCopy(id: ${swiftStr(p.id)}, title: ${title}, message: ${message}, confirmTitle: ${LOpt(p.confirmTitle, p, "confirmTitle")}, options: [${opts}])`;
  };
  lines.push("enum RegistryPrompts {");
  lines.push(`  static let cancelTitle: String = ${L(pr.cancelTitle, pr, "cancelTitle")}`);
  lines.push(`  static let errorTitle: String = ${L(pr.error.title, pr.error, "title")}`);
  lines.push(`  static let errorConfirmTitle: String = ${L(pr.error.confirmTitle, pr.error, "confirmTitle")}`);
  lines.push("  /// Prompts with fixed copy. Prompts with counts or names are functions below.");
  lines.push("  static let fixed: [String: RegistryPromptCopy] = [");
  for (const p of pr.items) {
    if (p.variants || isTmpl(p.title) || isTmpl(p.message)) continue;
    lines.push(`    ${swiftStr(p.id)}: ${promptCopy(p, L(p.title, p, "title"), L(p.message, p, "message"))},`);
  }
  lines.push("  ]");
  lines.push("  static let text: [String: RegistryTextPrompt] = [");
  for (const t of pr.text) {
    lines.push(`    ${swiftStr(t.id)}: RegistryTextPrompt(id: ${swiftStr(t.id)}, title: ${L(t.title, t, "title")}, placeholder: ${L(t.placeholder, t, "placeholder")}, confirmTitle: ${L(t.confirmTitle, t, "confirmTitle")}),`);
  }
  lines.push("  ]");
  for (const cp of pr.countPhrases) lines.push(tmplFn(`${camelId(cp.id)}Phrase`, tmplKey(cp.label, cp, "label")));
  for (const p of pr.items) {
    if (p.variants) {
      // The first variant whose `when` counts match wins; the last has no `when`.
      const counts = p.counts ?? [];
      const params = ["name: String", ...counts.map((c) => `${c}: Int`)].join(", ");
      lines.push(`  static func ${p.id}(${params}) -> RegistryPromptCopy {`);
      lines.push(`    let name = name.isEmpty ? ${L(p.untitledName, p, "untitledName")} : name`);
      const used = new Set(p.variants.flatMap((v) => [...L10N.placeholdersOf(v.title), ...L10N.placeholdersOf(v.message)]));
      for (const c of counts) {
        const singular = c.replace(/s$/, "");
        if (used.has(`${singular}Phrase`)) lines.push(`    let ${singular}Phrase = ${camelId(c)}Phrase(count: ${c})`);
      }
      for (const v of p.variants) {
        const cond = Object.entries(v.when ?? {}).map(([c, n]) => `${c} == ${n}`).join(" && ");
        const ret = `return ${promptCopy(p, expr(v.title, v, "title"), expr(v.message, v, "message"))}`;
        lines.push(cond ? `    if ${cond} { ${ret} }` : `    ${ret}`);
      }
      lines.push("  }");
    } else if (isTmpl(p.title) || isTmpl(p.message)) {
      const names = [...new Set([...L10N.placeholdersOf(typeof p.title === "string" ? p.title : p.title.other), ...L10N.placeholdersOf(p.message), ...(typeof p.title === "string" ? [] : ["count"])])];
      const params = names.map((n) => `${n}: ${L10N.INT_PLACEHOLDERS.has(n) ? "Int" : "String"}`).join(", ");
      lines.push(`  static func ${p.id}(${params}) -> RegistryPromptCopy {`);
      lines.push(`    ${promptCopy(p, expr(p.title, p, "title"), expr(p.message, p, "message"))}`);
      lines.push("  }");
    }
  }
  lines.push("}");
  lines.push("");

  lines.push("/// Snackbar copy (`registry/surfaces.json` `toasts`).");
  lines.push("enum RegistryToasts {");
  lines.push(`  static let durationSeconds: Double = ${surfaces.toasts.durationSeconds}`);
  for (const [id, t] of Object.entries(surfaces.toasts.templates)) {
    const tmpl = L10N.swiftTemplate(BY_KEY, tmplKey(t.format, t, "format"));
    if (t.emptyTitleFormat !== undefined) {
      const ph = L10N.placeholdersOf(t.format)[0];
      lines.push(`  static func ${id}(${tmpl.params}) -> String { ${ph}.isEmpty ? ${L(t.emptyTitleFormat, t, "emptyTitleFormat")} : ${tmpl.body} }`);
    } else {
      lines.push(`  static func ${id}(${tmpl.params}) -> String { ${tmpl.body} }`);
    }
  }
  lines.push("}");
  lines.push("");

  lines.push("/// One task attribute (`registry/surfaces.json` `taskAttributes`): a composer");
  lines.push("/// pill, an inspector row and a picker title. `surfaceTier` `field` is an");
  lines.push("/// always-visible field (notes), not a pill. `chip` is a transient composer");
  lines.push("/// chip shown only on a blank new task (Paste), not a pill. `editOnly` needs a saved task.");
  lines.push("struct RegistryTaskAttribute: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let label: String");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
  lines.push("  let commitContract: String");
  lines.push("  let surfaceTier: String");
  lines.push("  let featureId: String");
  lines.push("  let editOnly: Bool");
  lines.push("  /// Pill text while the attribute's work runs (Discuss).");
  lines.push("  let workingLabel: String?");
  lines.push("  var isPill: Bool { surfaceTier == \"inline\" || surfaceTier == \"popover\" }");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistrySurfaces {");
  lines.push(`  static let taskAttributeOrder: [String] = [${surfaces.taskAttributes.map((a) => swiftStr(a.id)).join(", ")}]`);
  lines.push("  static let taskAttributes: [RegistryTaskAttribute] = [");
  for (const a of surfaces.taskAttributes) {
    lines.push(`    RegistryTaskAttribute(id: ${swiftStr(a.id)}, label: ${L(a.label, a, "label")}, iconId: ${swiftStr(a.icon)}, sfSymbol: ${swiftStr(icons.icons[a.icon].sfSymbol)}, commitContract: ${swiftStr(a.commitContract)}, surfaceTier: ${swiftStr(a.surfaceTier)}, featureId: ${swiftStr(a.featureId)}, editOnly: ${a.editOnly === true}, workingLabel: ${LOpt(a.workingLabel, a, "workingLabel")}),`);
  }
  lines.push("  ]");
  lines.push("  /// The pills, in rail order (every attribute except fields and chips).");
  lines.push("  static let taskAttributePills: [RegistryTaskAttribute] = taskAttributes.filter(\\.isPill)");
  lines.push("  static let taskAttributeLabels: [String: String] = Dictionary(uniqueKeysWithValues: taskAttributes.map { ($0.id, $0.label) })");
  lines.push("  /// The attribute with `id`. Traps on an unknown id: the ids are a closed set.");
  lines.push("  static func taskAttribute(_ id: String) -> RegistryTaskAttribute {");
  lines.push("    guard let a = taskAttributes.first(where: { $0.id == id }) else { preconditionFailure(\"unknown task attribute \\(id)\") }");
  lines.push("    return a");
  lines.push("  }");
  lines.push("  /// Count text for a pill value (`countLabel`), or nil when the attribute has none.");
  lines.push("  static func taskAttributeCount(_ id: String, count: Int) -> String? {");
  lines.push("    switch id {");
  for (const a of surfaces.taskAttributes) {
    if (a.countLabel === undefined) continue;
    lines.push(`    case ${swiftStr(a.id)}: return ${L10N.swiftTemplate(BY_KEY, tmplKey(a.countLabel, a, "countLabel")).body}`);
  }
  lines.push("    default: return nil");
  lines.push("    }");
  lines.push("  }");
  lines.push("}");
  lines.push("");

  // 8b. First run (surfaces.json `firstRun`)
  const fr = surfaces.firstRun;
  const frButton = (b) => (b === undefined ? "nil" : `RegistryFirstRunButton(title: ${L(b.title, b, "title")}, action: ${swiftStr(b.action)})`);
  lines.push("/// One button in the first run. `action` is one of a closed set the client implements.");
  lines.push("struct RegistryFirstRunButton: Sendable, Hashable {");
  lines.push("  let title: String");
  lines.push("  let action: String");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryFirstRunPoint: Sendable, Hashable {");
  lines.push("  let icon: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryFirstRunChoice: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let icon: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("  let action: String");
  lines.push("  let platforms: [String]");
  lines.push("}");
  lines.push("");
  lines.push("/// One first-run step (`registry/surfaces.json` `firstRun.steps`). `kind` picks the view.");
  lines.push("struct RegistryFirstRunStep: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let kind: String");
  lines.push("  let icon: String");
  lines.push("  let title: String");
  lines.push("  let body: String");
  lines.push("  let footnote: String?");
  lines.push("  let returningTitle: String?");
  lines.push("  let returningBody: String?");
  lines.push("  let skipWhen: String?");
  lines.push("  let requires: String?");
  lines.push("  let completesGetStartedStep: String?");
  lines.push("  let points: [RegistryFirstRunPoint]");
  lines.push("  let choices: [RegistryFirstRunChoice]");
  lines.push("  let instructions: [String]");
  lines.push("  let primary: RegistryFirstRunButton?");
  lines.push("  let secondary: RegistryFirstRunButton?");
  lines.push("  let tertiary: RegistryFirstRunButton?");
  lines.push("  /// Replaces `secondary` once the step's work is done (paired, imported).");
  lines.push("  let afterDone: RegistryFirstRunButton?");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistryFirstRun {");
  lines.push(`  static let featureId: String = ${swiftStr(fr.featureId)}`);
  lines.push(`  /// The synced setting that records a finished first run, so a second device skips it.`);
  lines.push(`  static let completionSetting: String = ${swiftStr(fr.completionSetting)}`);
  lines.push(`  static let setupPrompt: String = ${L(fr.prompts.setup, fr.prompts, "setup")}`);
  lines.push(`  static let firstPrompt: String = ${L(fr.prompts.first, fr.prompts, "first")}`);
  lines.push("  static let steps: [RegistryFirstRunStep] = [");
  for (const st of fr.steps) {
    const points = (st.points ?? []).map((pt) => `RegistryFirstRunPoint(icon: ${swiftStr(pt.icon)}, title: ${L(pt.title, pt, "title")}, detail: ${L(pt.detail, pt, "detail")})`).join(", ");
    const choices = (st.choices ?? []).map((ch) => `RegistryFirstRunChoice(id: ${swiftStr(ch.id)}, icon: ${swiftStr(ch.icon)}, title: ${L(ch.title, ch, "title")}, detail: ${L(ch.detail, ch, "detail")}, action: ${swiftStr(ch.action)}, platforms: [${(ch.platforms ?? []).map(swiftStr).join(", ")}])`).join(", ");
    const instructions = (st.instructions ?? []).map((s) => L(s)).join(", ");
    lines.push(`    RegistryFirstRunStep(id: ${swiftStr(st.id)}, kind: ${swiftStr(st.kind)}, icon: ${swiftStr(st.icon)}, title: ${L(st.title, st, "title")}, body: ${st.body === undefined ? '""' : L(st.body, st, "body")}, footnote: ${LOpt(st.footnote, st, "footnote")}, returningTitle: ${LOpt(st.returningTitle, st, "returningTitle")}, returningBody: ${LOpt(st.returningBody, st, "returningBody")}, skipWhen: ${swiftOptStr(st.skipWhen)}, requires: ${swiftOptStr(st.requires)}, completesGetStartedStep: ${swiftOptStr(st.completesGetStartedStep)}, points: [${points}], choices: [${choices}], instructions: [${instructions}], primary: ${frButton(st.primary)}, secondary: ${frButton(st.secondary)}, tertiary: ${frButton(st.tertiary)}, afterDone: ${frButton(st.afterDone)}),`);
  }
  lines.push("  ]");
  lines.push("}");
  lines.push("");

  // 10. Plans and pricing (plans.json, ADR 0010 / ADR 0023). Limits are not
  // emitted: the app reads its limits from the server's plan table.
  const P = plans;
  const cellSwift = (c, row, lv) => (c === true ? ".included" : c === false ? ".notIncluded" : `.text(${L(c, row.cells, lv)})`);
  lines.push("/// One plan-comparison cell: a check, a dash, or text.");
  lines.push("enum RegistryPlanCell: Sendable, Hashable {");
  lines.push("  case included, notIncluded, text(String)");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanPrice: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let productId: String");
  lines.push("  let amountMinor: Int");
  lines.push("  let currency: String");
  lines.push("  let interval: String");
  lines.push("  let highlighted: Bool");
  lines.push("  let label: String");
  lines.push("  let detail: String");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanCard: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("  let points: [String]");
  lines.push("  let footnote: String?");
  lines.push("  let highlighted: Bool");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanRow: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let label: String");
  lines.push("  let planned: Bool");
  lines.push("  let device: RegistryPlanCell");
  lines.push("  let account: RegistryPlanCell");
  lines.push("  let plus: RegistryPlanCell");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanOutcome: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let icon: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("  let rows: [RegistryPlanRow]");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanNote: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("}");
  lines.push("");
  lines.push("/// Plans and pricing (`registry/plans.json`). The site's /pricing page reads the same file.");
  lines.push("enum RegistryPlans {");
  for (const f of ["name", "shortName", "headline", "subhead"]) lines.push(`  static var ${f}: String { ${L(P[f], P, f)} }`);
  lines.push(`  static let checkoutOpen = ${P.checkout.open}`);
  lines.push(`  static var checkoutNotice: String { ${L(P.checkout.notice, P.checkout, "notice")} }`);
  lines.push(`  static let trialDays = ${P.trial.days}`);
  lines.push(`  static var trialTitle: String { ${L(P.trial.title, P.trial, "title")} }`);
  lines.push(`  static var trialDetail: String { ${L(P.trial.detail, P.trial, "detail")} }`);
  lines.push(`  static var priceFootnote: String { ${L(P.priceFootnote, P, "priceFootnote")} }`);
  lines.push("  static var prices: [RegistryPlanPrice] { [");
  for (const pr of P.prices) lines.push(`    RegistryPlanPrice(id: ${swiftStr(pr.id)}, productId: ${swiftStr(pr.productId)}, amountMinor: ${pr.amountMinor}, currency: ${swiftStr(pr.currency)}, interval: ${swiftStr(pr.interval)}, highlighted: ${pr.highlighted}, label: ${L(pr.label, pr, "label")}, detail: ${L(pr.detail, pr, "detail")}),`);
  lines.push("  ] }");
  lines.push("  static var cards: [RegistryPlanCard] { [");
  for (const c of P.cards) lines.push(`    RegistryPlanCard(id: ${swiftStr(c.id)}, title: ${L(c.title, c, "title")}, detail: ${L(c.detail, c, "detail")}, points: [${c.points.map((pt) => L(pt, null, null)).join(", ")}], footnote: ${LOpt(c.footnote, c, "footnote")}, highlighted: ${c.highlighted === true}),`);
  lines.push("  ] }");
  lines.push("  static var outcomes: [RegistryPlanOutcome] { [");
  for (const o of P.outcomes) {
    const rows = o.rows.map((r) => `RegistryPlanRow(id: ${swiftStr(r.id)}, label: ${L(r.label, r, "label")}, planned: ${r.status === "planned"}, device: ${cellSwift(r.cells.device, r, "device")}, account: ${cellSwift(r.cells.account, r, "account")}, plus: ${cellSwift(r.cells.plus, r, "plus")})`).join(",\n      ");
    lines.push(`    RegistryPlanOutcome(id: ${swiftStr(o.id)}, icon: ${swiftStr(o.icon)}, title: ${L(o.title, o, "title")}, detail: ${L(o.detail, o, "detail")}, rows: [\n      ${rows},\n    ]),`);
  }
  lines.push("  ] }");
  for (const list of ["promises", "upsells"]) {
    lines.push(`  static var ${list}: [RegistryPlanNote] { [`);
    for (const n of P[list]) lines.push(`    RegistryPlanNote(id: ${swiftStr(n.id)}, title: ${L(n.title, n, "title")}, detail: ${L(n.detail, n, "detail")}),`);
    lines.push("  ] }");
  }
  lines.push("  static func upsell(_ id: String) -> RegistryPlanNote? { upsells.first { $0.id == id } }");
  lines.push("");
  lines.push("  enum Action {");
  for (const [k, v] of Object.entries(P.actions)) lines.push(`    static var ${k}: String { ${L(v, P.actions, k)} }`);
  lines.push("  }");
  lines.push("");
  lines.push("  enum Copy {");
  for (const [k, v] of Object.entries(P.labels)) lines.push(`    static var ${k}: String { ${L(v, P.labels, k)} }`);
  lines.push("  }");
  lines.push("");
  lines.push("  enum Status {");
  for (const [k, v] of Object.entries(P.status)) {
    if (/\{[a-zA-Z]/.test(v)) {
      const t = L10N.swiftTemplate(BY_KEY, P.status.l10nKeys?.[k] ?? v);
      lines.push(`    static func ${k}(${t.params}) -> String { ${t.body} }`);
    } else {
      lines.push(`    static var ${k}: String { ${L(v, P.status, k)} }`);
    }
  }
  lines.push("  }");
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

function generateTS({ entities, rules, icons, tokens, caps, settings, dests, actions, surfaces, plans }) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces,plans}.json");
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
  lines.push(`export const TURN_FIELDS = ${JSON.stringify(entities.turnFields)} as const;`);
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
  lines.push(`export const SETTINGS_REGISTRY = ${JSON.stringify({ version: settings.version, keys: settings.keys, desktopTabs: settings.desktopTabs, rootGroups: settings.rootGroups, pages: settings.pages })} as const;`);
  lines.push(`export const VIEW_ALIASES = ${JSON.stringify(dests.viewAliases)} as const;`);
  lines.push(`export const DESTINATIONS = ${JSON.stringify(dests.destinations)} as const;`);
  lines.push(`export const GENERIC_EMPTY_STATE = ${JSON.stringify(dests.genericEmptyState)} as const;`);
  lines.push(`export const ICONS = ${JSON.stringify(icons.icons)} as const;`);
  lines.push(`export const DESIGN_TOKENS = ${JSON.stringify({ accentPolicy: tokens.accentPolicy, fruitAccents: tokens.fruitAccents ?? [], textures: tokens.textures ?? [], selection: tokens.selection, colors: tokens.colors, accentPalette: tokens.accentPalette, radii: tokens.radii, spacing: tokens.spacing, desktopColumn: tokens.desktopColumn, textScale: tokens.textScale })} as const;`);
  lines.push(`export const CAPABILITIES = ${JSON.stringify(caps.capabilities)} as const;`);
  lines.push(`export const ACTIONS_CATALOG = ${JSON.stringify({ actions: actions.actions, contextMenus: actions.contextMenus, menuBar: actions.menuBar, swipeActions: actions.swipeActions, shortcutsSheet: actions.shortcutsSheet })} as const;`);
  lines.push(`export const SURFACES_CATALOG = ${JSON.stringify({ notices: surfaces.notices, prompts: surfaces.prompts, toasts: surfaces.toasts, taskAttributes: surfaces.taskAttributes })} as const;`);
  lines.push(`export const FIRST_RUN = ${JSON.stringify(surfaces.firstRun)} as const;`);
  lines.push("/** Plan limits (registry/plans.json). The server's plan table: every gate reads these, never a plan name. */");
  lines.push(`export const PLAN_LIMITS = ${JSON.stringify(plans.limits)} as const;`);
  lines.push(`export const PLAN_TRIAL_DAYS = ${plans.trial.days};`);
  lines.push(`export const PLAN_PRODUCTS = ${JSON.stringify(plans.prices.map((p) => p.productId))} as const;`);
  lines.push("");
  lines.push("// Localized registry copy (ADR 0020). Keys are the English text.");
  lines.push(L10N.tsTables(BY_KEY, TRANSLATIONS));
  lines.push("");
  return lines.join("\n");
}

const kotlinStr = (s) => JSON.stringify(s).replace(/\$/g, "\\$");
const kotlinName = (s) => camelId(s).replace(/[^A-Za-z0-9_]/g, "_");
const kotlinConstName = (s) => kotlinName(s)
  .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
  .replace(/([A-Z])([A-Z][a-z])/g, "$1_$2")
  .toUpperCase();
const kotlinTypeName = (s) => {
  const name = kotlinName(s);
  return name.charAt(0).toUpperCase() + name.slice(1);
};
const kotlinLong = (value) => value === undefined ? "null" : `${value}L`;
const kotlinDouble = (value) => value === undefined ? "null" : `${Number(value)}${Number.isInteger(Number(value)) ? ".0" : ""}`;
const kotlinNullableString = (value) => value === undefined ? "null" : kotlinStr(value);
const kotlinNullableBoolean = (value) => value === undefined ? "null" : String(value);

function generateKotlinCore(bundle) {
  const { entities, rules, caps, settings, dests, actions, icons } = bundle;
  const lines = [
    "// GENERATED FILE — DO NOT EDIT BY HAND.",
    "// Sources: registry/*.json, registry/conformance/*.json",
    "// Regenerate: node scripts/gen-registries.mjs",
    "package app.septena.core.generated",
    "",
    "/** Registry-backed wire constraints shared by every client. */",
    "object RegistryEntityPatterns {",
  ];
  for (const [key, value] of Object.entries(entities.patterns)) {
    lines.push(`    const val ${kotlinName(key)}: String = ${kotlinStr(value)}`);
  }
  lines.push("    val all: Map<String, String> = linkedMapOf(");
  for (const key of Object.keys(entities.patterns)) {
    lines.push(`        ${kotlinStr(key)} to ${kotlinName(key)},`);
  }
  lines.push("    )");
  lines.push("}");
  lines.push("");

  lines.push("/** Limits and enum values come directly from `registry/entities.json`. */");
  lines.push("object RegistryEntityLimits {");
  for (const [key, value] of Object.entries(entities.limits)) {
    lines.push(`    const val ${kotlinConstName(key)}: Long = ${value}L`);
  }
  lines.push("    val all: Map<String, Long> = linkedMapOf(");
  for (const [key, value] of Object.entries(entities.limits)) {
    lines.push(`        ${kotlinStr(key)} to ${kotlinConstName(key)},`);
  }
  lines.push("    )");
  lines.push("}");
  lines.push("");

  lines.push("object RegistryEntityEnums {");
  lines.push("    val all: Map<String, List<String>> = linkedMapOf(");
  for (const [key, values] of Object.entries(entities.enums)) {
    lines.push(`        ${kotlinStr(key)} to listOf(${values.map(kotlinStr).join(", ")}),`);
  }
  lines.push("    )");
  for (const [key, values] of Object.entries(entities.enums)) {
    lines.push(`    object ${kotlinTypeName(key)} {`);
    for (const value of values) {
      lines.push(`        const val ${kotlinConstName(value)}: String = ${kotlinStr(value)}`);
    }
    lines.push("    }");
  }
  lines.push("}");
  lines.push("");
  lines.push("/** Canonical turn field keys shared with the backend. */");
  lines.push("object RegistryTurnFields {");
  lines.push(`    val all: Set<String> = linkedSetOf(${entities.turnFields.map(kotlinStr).join(", ")})`);
  lines.push("}");
  lines.push("");

  const entityNames = Object.keys(entities.entities);
  const deletableNames = entityNames.filter((name) => entities.entities[name].deletable);
  lines.push("data class RegistryColumnSpec(");
  lines.push("    val kind: String,");
  lines.push("    val format: String?,");
  lines.push("    val enumName: String?,");
  lines.push("    val nullable: Boolean?,");
  lines.push("    val min: Double?,");
  lines.push("    val max: Long?,");
  lines.push("    val maxJsonLength: Long?,");
  lines.push("    val defaultJson: String?,");
  lines.push("    val serverOwned: Boolean,");
  lines.push(")");
  lines.push("");
  lines.push("data class RegistryEntitySpec(");
  lines.push("    val table: String,");
  lines.push("    val deletable: Boolean,");
  lines.push("    val requiredOnInsert: Set<String>,");
  lines.push("    val updatable: Set<String>?,");
  lines.push("    val columns: Map<String, RegistryColumnSpec>,");
  lines.push(")");
  lines.push("");

  lines.push("/** Full entity and field contract generated from the canonical registry. */");
  lines.push("object RegistryEntities {");
  lines.push("    val all: Map<String, RegistryEntitySpec> = linkedMapOf(");
  for (const [entityName, entity] of Object.entries(entities.entities)) {
    lines.push(`        ${kotlinStr(entityName)} to RegistryEntitySpec(`);
    lines.push(`            table = ${kotlinStr(entity.table)},`);
    lines.push(`            deletable = ${entity.deletable},`);
    lines.push(`            requiredOnInsert = setOf(${entity.requiredOnInsert.map(kotlinStr).join(", ")}),`);
    lines.push(`            updatable = ${entity.updatable === undefined ? "null" : `setOf(${entity.updatable.map(kotlinStr).join(", ")})`},`);
    lines.push("            columns = linkedMapOf(");
    for (const [columnName, column] of Object.entries(entity.columns)) {
      lines.push(`                ${kotlinStr(columnName)} to RegistryColumnSpec(`);
      lines.push(`                    kind = ${kotlinStr(column.kind)},`);
      lines.push(`                    format = ${kotlinNullableString(column.format)},`);
      lines.push(`                    enumName = ${kotlinNullableString(column.enum)},`);
      lines.push(`                    nullable = ${kotlinNullableBoolean(column.nullable)},`);
      lines.push(`                    min = ${kotlinDouble(column.min)},`);
      lines.push(`                    max = ${kotlinLong(column.max)},`);
      lines.push(`                    maxJsonLength = ${kotlinLong(column.maxJsonLength)},`);
      lines.push(`                    defaultJson = ${column.default === undefined ? "null" : kotlinStr(JSON.stringify(column.default))},`);
      lines.push(`                    serverOwned = ${column.serverOwned === true},`);
      lines.push("                ),");
    }
    lines.push("            ),");
    lines.push("        ),");
  }
  lines.push("    )");
  lines.push(`    val names: List<String> = listOf(${entityNames.map(kotlinStr).join(", ")})`);
  lines.push(`    val deletableNames: Set<String> = setOf(${deletableNames.map(kotlinStr).join(", ")})`);
  lines.push("}");
  lines.push("");

  lines.push("/** Generated field keys prevent each client from maintaining its own wire spelling. */");
  lines.push("object RegistryEntityFields {");
  for (const [entityName, entity] of Object.entries(entities.entities)) {
    lines.push(`    object ${kotlinTypeName(entityName)} {`);
    for (const columnName of Object.keys(entity.columns)) {
      lines.push(`        const val ${kotlinConstName(columnName)}: String = ${kotlinStr(columnName)}`);
    }
    lines.push("    }");
  }
  lines.push("}");
  lines.push("");

  lines.push("object RegistryEntityNames {");
  for (const entityName of entityNames) {
    lines.push(`    const val ${kotlinConstName(entityName)}: String = ${kotlinStr(entityName)}`);
  }
  lines.push(`    val all: List<String> = listOf(${entityNames.map(kotlinStr).join(", ")})`);
  lines.push(`    val deletable: Set<String> = setOf(${deletableNames.map(kotlinStr).join(", ")})`);
  lines.push("}");
  lines.push("");

  lines.push("/** Numeric domain constants shared with the backend and Apple clients. */");
  lines.push("object RegistryRules {");
  for (const [key, value] of Object.entries(rules)) {
    if (key === "version") continue;
    const type = Number.isInteger(value) ? "Long" : "Double";
    const literal = Number.isInteger(value) ? `${value}L` : `${value}`;
    lines.push(`    const val ${kotlinConstName(key)}: ${type} = ${literal}`);
  }
  lines.push("}");
  lines.push("");

  const emitIdObject = (objectName, ids) => {
    lines.push(`/** Stable IDs generated from the canonical registry: ${objectName}. */`);
    lines.push(`object ${objectName} {`);
    const seen = new Set();
    for (const id of ids) {
      const constant = kotlinConstName(id);
      assert(!seen.has(constant), `${objectName}: IDs collide after Kotlin constant conversion at ${id}`);
      seen.add(constant);
      lines.push(`    const val ${constant}: String = ${kotlinStr(id)}`);
    }
    lines.push("}");
    lines.push("");
  };

  emitIdObject("RegistrySettingKeys", Object.keys(settings.keys));
  emitIdObject("RegistryDestinationIds", dests.destinations.map((destination) => destination.id));
  emitIdObject("RegistryActionIds", Object.keys(actions.actions));
  emitIdObject("RegistryCapabilityIds", Object.keys(caps.capabilities));
  emitIdObject("RegistryIconIds", Object.keys(icons.icons));
  emitIdObject("RegistryPlatformIds", caps.platforms);

  lines.push("/** Capability status by canonical feature ID and platform. */");
  lines.push("object RegistryCapabilities {");
  lines.push("    val statusByFeatureAndPlatform: Map<String, Map<String, String>> = linkedMapOf(");
  for (const [featureId, capability] of Object.entries(caps.capabilities)) {
    lines.push(`        ${kotlinStr(featureId)} to linkedMapOf(`);
    for (const [platform, status] of Object.entries(capability)) {
      if (platform === "title") continue;
      lines.push(`            ${kotlinStr(platform)} to ${kotlinStr(status)},`);
    }
    lines.push("        ),");
  }
  lines.push("    )");
  lines.push("    val androidStatusByFeatureId: Map<String, String> = linkedMapOf(");
  for (const [featureId, capability] of Object.entries(caps.capabilities)) {
    lines.push(`        ${kotlinStr(featureId)} to ${kotlinStr(capability.android)},`);
  }
  lines.push("    )");
  lines.push("}");
  lines.push("");

  // The presentation registries are consumed at runtime by every client.
  // Keep their complete canonical JSON available to Kotlin as generated
  // resources too; Android must not grow hand-maintained copies of actions,
  // settings, surfaces, destinations, icons, tokens, or capability metadata.
  lines.push("/** Complete canonical registry documents for Kotlin/JVM clients. */");
  lines.push("object RegistryDocuments {");
  for (const [name, document] of Object.entries({
    entities: bundle.entities,
    rules: bundle.rules,
    icons: bundle.icons,
    tokens: bundle.tokens,
    capabilities: bundle.caps,
    settings: bundle.settings,
    destinations: bundle.dests,
    actions: bundle.actions,
    surfaces: bundle.surfaces,
    conformance: bundle.conformance,
    localizations: bundle.translations,
  })) {
    const value = JSON.stringify(document);
    // A JVM string constant cannot exceed the class-file UTF-8 limit. Split
    // into small pieces so future registry growth cannot make generation
    // silently produce an invalid class.
    const chunks = value.match(/[\s\S]{1,12000}/g) ?? [""];
    lines.push(`    val ${kotlinName(name)}Json: String = listOf(`);
    for (const chunk of chunks) lines.push(`        ${kotlinStr(chunk)},`);
    lines.push("    ).joinToString(\"\")");
  }
  lines.push("}");
  lines.push("");

  return lines.join("\n");
}

// Rust target for the shared core (ADR 0025). Constants only: the core reads
// the registry through these, never through JSON at run time.
const rustConstName = (s) => s
  .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
  .replace(/[^A-Za-z0-9]+/g, "_")
  .replace(/^_+|_+$/g, "")
  .toUpperCase()
  .replace(/^([0-9])/, "_$1");
const rustModName = (s) => rustConstName(s).toLowerCase();
const rustStr = (s) => JSON.stringify(s);

function generateRustCore(bundle) {
  const { entities, rules, dests } = bundle;
  const lines = [
    "// GENERATED FILE — DO NOT EDIT BY HAND.",
    "// Sources: registry/entities.json, registry/rules.json, registry/destinations.json",
    "// Regenerate: node scripts/gen-registries.mjs",
    "#![allow(dead_code)]",
    "",
    "/// Numeric domain constants (`registry/rules.json`).",
    "pub mod rules {",
  ];
  for (const [key, value] of Object.entries(rules)) {
    if (key === "version") continue;
    if (Number.isInteger(value)) lines.push(`    pub const ${rustConstName(key)}: i64 = ${value};`);
    else lines.push(`    pub const ${rustConstName(key)}: f64 = ${Number(value)};`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Wire limits (`registry/entities.json` `limits`).");
  lines.push("pub mod limits {");
  for (const [key, value] of Object.entries(entities.limits)) {
    lines.push(`    pub const ${rustConstName(key)}: i64 = ${value};`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Canonical enum values (`registry/entities.json` `enums`).");
  lines.push("pub mod enums {");
  for (const [key, values] of Object.entries(entities.enums)) {
    lines.push(`    pub mod ${rustModName(key)} {`);
    const seen = new Set();
    for (const value of values) {
      const name = rustConstName(value);
      assert(!seen.has(name), `Rust: enum ${key} values collide at ${value}`);
      seen.add(name);
      lines.push(`        pub const ${name}: &str = ${rustStr(value)};`);
    }
    lines.push(`        pub const ALL: &[&str] = &[${values.map(rustStr).join(", ")}];`);
    lines.push("    }");
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Synced entity names (`registry/entities.json` `entities`).");
  lines.push("pub mod entity_names {");
  for (const name of Object.keys(entities.entities)) {
    lines.push(`    pub const ${rustConstName(name)}: &str = ${rustStr(name)};`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Destination IDs (`registry/destinations.json`).");
  lines.push("pub mod destination_ids {");
  const seen = new Set();
  for (const { id } of dests.destinations) {
    const name = rustConstName(id);
    assert(!seen.has(name), `Rust: destination IDs collide at ${id}`);
    seen.add(name);
    lines.push(`    pub const ${name}: &str = ${rustStr(id)};`);
  }
  lines.push("}");
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
const plans = readJSON("registry/plans.json");

validateEntities(entities);
validateRules(rules);
validateIcons(icons);
validateTokens(tokens);
validateCapabilities(caps);
validateSettings(settings, entities, icons, caps);
const destIds = validateDestinations(dests, icons, caps);
validateActions(actions, icons, caps, destIds);
validateSurfaces(surfaces, icons, caps);
validateFirstRun(surfaces, icons, caps, settings);
validatePlans(plans, icons, caps);
validateConformance();

BY_KEY = L10N.collectStrings({ settings, destinations: dests, actions, surfaces, tokens, plans }, assert);

const CATALOG_PATH = "Septena/Localizable.xcstrings";
const catalog = readJSON(CATALOG_PATH);
if (SEED_LANG) {
  const rel = `registry/l10n/${SEED_LANG}.json`;
  const full = path.join(REPO, rel);
  const existing = fs.existsSync(full) ? JSON.parse(fs.readFileSync(full, "utf8")) : {};
  const seeded = { ...L10N.seedFromCatalog(catalog, BY_KEY, SEED_LANG), ...existing };
  const sorted = Object.fromEntries(Object.keys(seeded).sort().map((k) => [k, seeded[k]]));
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, JSON.stringify(sorted, null, 2) + "\n", "utf8");
  console.log(`seeded ${rel}: ${Object.keys(sorted).length} translations`);
}
const TRANSLATIONS = L10N.readTranslations(REPO);
const l10nReport = L10N.checkTranslations(BY_KEY, TRANSLATIONS, assert);

const conformanceDir = path.join(REPO, "registry/conformance");
const conformance = Object.fromEntries(
  fs.readdirSync(conformanceDir).filter((name) => name.endsWith(".json")).sort()
    .map((name) => [name.replace(/\.json$/, ""), readJSON(`registry/conformance/${name}`)]),
);
const bundle = {
  entities, rules, icons, tokens, caps, settings, dests, actions, surfaces, plans, conformance,
  translations: { en: JSON.parse(L10N.englishFile(BY_KEY)), ...TRANSLATIONS },
};
const outputs = [
  ["SeptenaCore/Generated/RegistryConstants.swift", generateSwift(bundle)],
  ["backend/src/generated/registries.ts", generateTS(bundle)],
  ["android/core/src/main/kotlin/app/septena/core/generated/RegistryConstants.kt", generateKotlinCore(bundle)],
  ["core/crates/septena-core/src/generated/registry.rs", generateRustCore(bundle)],
  ["registry/l10n/en.json", L10N.englishFile(BY_KEY)],
];
// The catalog is shared with Xcode, which rewrites extraction state and
// comments on build. `--check` compares only what the registry owns.
if (CHECK) {
  const drift = L10N.catalogDrift(catalog, BY_KEY, TRANSLATIONS);
  if (drift.length) {
    throw new Error(`${CATALOG_PATH} is missing registry copy for ${drift.length} key(s), e.g. ${JSON.stringify(drift[0])} (run: node scripts/gen-registries.mjs)`);
  }
} else {
  outputs.push([CATALOG_PATH, L10N.serializeCatalog(L10N.mergeCatalog(catalog, BY_KEY, TRANSLATIONS))]);
}

let changed = 0;
for (const [rel, content] of outputs) {
  if (writeOrCheck(rel, content)) {
    console.log(`wrote ${rel}`);
    changed++;
  }
}

for (const [lang, rep] of Object.entries(l10nReport)) {
  console.log(`l10n ${lang}: ${rep.total - rep.missing}/${rep.total} registry strings translated (${rep.missing} missing, advisory)`);
  if (rep.orphans.length) console.log(`l10n ${lang}: ${rep.orphans.length} keys no registry string uses: ${rep.orphans.slice(0, 5).map((k) => JSON.stringify(k)).join(", ")}${rep.orphans.length > 5 ? ", …" : ""}`);
}

if (CHECK) {
  console.log("registries: ok (all 10 registries valid and generated files up to date)");
} else if (changed === 0) {
  console.log("registries: already up to date");
}
