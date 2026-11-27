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
import { checkReaders } from "./registry-readers.mjs";
import { validateCast } from "./registry-cast.mjs";
import { mcpToolNames } from "./lib/mcp-tools.mjs";

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
    "doStaleHours",
    "doLapseHours",
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
    // The filled variant a control shows while it is on (DesignSpec: a toggle
    // that is on shows its filled symbol).
    if (map.sfSymbolOn !== undefined) {
      assert(typeof map.sfSymbolOn === "string" && map.sfSymbolOn.length > 0, `icons.json: ${id}.sfSymbolOn must be non-empty string`);
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
  if (tokens.multicolorGlyphs !== undefined) {
    for (const [icon, role] of Object.entries(tokens.multicolorGlyphs.glyphs ?? {})) {
      assert(icons.icons?.[icon], `tokens.json: multicolorGlyphs icon "${icon}" is not in icons.json`);
      assert(/^#[0-9a-fA-F]{6}$/.test(tokens.colors?.[role] ?? ""), `tokens.json: multicolorGlyphs "${icon}" role "${role}" must name a hex in colors`);
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
    // The agent door (ADR 0050, AS7 #628): the MCP tools that reach the
    // capability, or "none". Every name must be a tool the backend registers.
    const agent = entry.agent;
    assert(agent === "none" || (Array.isArray(agent) && agent.length > 0), `capabilities.json: ${id} needs "agent": a list of MCP tool names, or "none"`);
    if (Array.isArray(agent)) {
      assert(new Set(agent).size === agent.length, `capabilities.json: ${id}.agent names a tool twice`);
      for (const tool of agent) assert(MCP_TOOLS.has(tool), `capabilities.json: ${id}.agent names "${tool}", which the backend does not register (scripts/lib/mcp-tools.mjs)`);
    }
    const known = new Set(["title", "agent", ...caps.platforms]);
    for (const key of Object.keys(entry)) assert(known.has(key), `capabilities.json: ${id} has unknown field "${key}"`);
  }
}

// skills/<name>/SKILL.md (ADR 0050 §6, AS6 #627): one procedure per skill, the
// site serves each at septena.app/skills/<name>/SKILL.md. The frontmatter has
// `name` (the folder) and `description`. Every tool a skill names must be one
// the backend registers, and backend/skill.md (the full brief) links each one.
function validateSkills() {
  const dir = path.join(REPO, "skills");
  const names = fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort();
  assert(names.length > 0, "skills/: no skills");
  const brief = fs.readFileSync(path.join(REPO, "backend/skill.md"), "utf8");
  for (const name of names) {
    const rel = `skills/${name}/SKILL.md`;
    assert(/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name), `${rel}: the folder name must be lowercase words joined by hyphens`);
    assert(fs.existsSync(path.join(REPO, rel)), `${rel}: missing`);
    const text = fs.readFileSync(path.join(REPO, rel), "utf8");
    const fm = text.match(/^---\n([\s\S]*?)\n---\n/);
    assert(fm, `${rel}: needs YAML frontmatter with name and description`);
    const field = (key) => fm[1].match(new RegExp(`^${key}: (.+)$`, "m"))?.[1]?.trim();
    assert(field("name") === name, `${rel}: frontmatter name must be "${name}"`);
    const description = field("description");
    assert(description && description.length <= 1024, `${rel}: frontmatter needs a description of at most 1024 characters`);
    assert(!/[\u2013\u2014]/.test(text), `${rel}: no em or en dashes`);
    for (const [tool] of text.matchAll(/\btasks_[a-z_]+\b/g)) {
      assert(MCP_TOOLS.has(tool), `${rel}: names "${tool}", which the backend does not register (scripts/lib/mcp-tools.mjs)`);
    }
    assert(brief.includes(`https://septena.app/skills/${name}/SKILL.md`), `backend/skill.md: link the skill ${name} (https://septena.app/skills/${name}/SKILL.md)`);
  }
}

function validateSettings(settings, entities, icons, caps) {
  assert(settings.version === 2, "settings.json: version must be 2");
  assert(/^https:\/\/[^\s]+[^/\s]$/.test(settings.helpURL ?? ""), "settings.json: helpURL must be an https URL with no trailing slash");
  const validTypes = new Set(["bool", "int", "enum", "string", "string[]", "record"]);
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

  // mz (2026-11-22): AI is never drawn with sparkles, on any platform.
  // One exception, chosen by mz on 2026-11-24: the "added by agent" mark is
  // SF `text.bubble.badge.sparkles` (a text bubble with a small sparkles
  // badge). Material and Lucide stay sparkle-free.
  const SPARKLES_ALLOWED = new Set(["task.added_by_agent:sfSymbol"]);
  for (const [id, icon] of Object.entries(icons.icons)) {
    if (!/(^|[._])(ai|agent|agents|claude)([._]|$)/.test(id)) continue;
    for (const family of ["sfSymbol", "material", "lucide"]) {
      if (SPARKLES_ALLOWED.has(`${id}:${family}`)) continue;
      assert(!/sparkle|auto_awesome/.test(icon[family] ?? ""), `icons.json: ${id} uses a sparkles glyph; AI icons never use sparkles`);
    }
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
    assert(item.desktopInline === undefined, `settings.json: ${ctx} desktopInline is removed; every surface shares the same subpages`);
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

  // `copy`: the words a custom surface or a status line spells out, keyed by
  // the surface id (or statusKey) and then by a copy id (#260, #370).
  const statusKeys = new Set(
    [...settings.rootGroups.flatMap((g) => g.items), ...settings.pages.flatMap((pg) => pg.sections.flatMap((s) => s.items))]
      .map((i) => i.statusKey).filter(Boolean),
  );
  for (const [owner, entries] of Object.entries(settings.copy ?? {})) {
    assert(seenSurfaces.has(owner) || statusKeys.has(owner), `settings.json: copy "${owner}" names no surface or statusKey`);
    assert(Array.isArray(entries) && entries.length > 0, `settings.json: copy "${owner}" must be a non-empty array`);
    const ids = new Set();
    for (const e of entries) {
      assert(typeof e.id === "string" && /^[a-zA-Z][a-zA-Z0-9]*$/.test(e.id), `settings.json: copy "${owner}" has an invalid id "${e.id}"`);
      assert(!ids.has(e.id), `settings.json: copy "${owner}" duplicate id "${e.id}"`);
      ids.add(e.id);
      assert(typeof e.label === "string" && e.label.trim().length > 0, `settings.json: copy ${owner}.${e.id} needs a label`);
      assert(!/[–—]/.test(e.label), `settings.json: copy ${owner}.${e.id} contains an em or en dash`);
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
    // Embedded destinations (Inbox on Today, Deleted inside Logbook, Faded inside Review) have no sidebar row.
    if (d.visibility === "todayBand" || d.visibility === "logbookTab" || d.visibility === "reviewGroup") {
      assert(d.sidebarOrder === undefined, `destinations.json: ${d.id} is ${d.visibility} and cannot have a sidebarOrder`);
      assert(d.sidebarSection === undefined, `destinations.json: ${d.id} is ${d.visibility} and cannot have a sidebarSection`);
    } else {
      assert(d.sidebarOrder > lastOrder, `destinations.json: sidebarOrder must strictly increase at "${d.id}"`);
      lastOrder = d.sidebarOrder;
      assert(d.sidebarSection === "top" || d.sidebarSection === "bottom", `destinations.json: ${d.id} invalid sidebarSection "${d.sidebarSection}"`);
    }
    assert(typeof d.canHide === "boolean", `destinations.json: ${d.id} missing boolean canHide`);
    assert(typeof d.canMoveSection === "boolean", `destinations.json: ${d.id} missing boolean canMoveSection`);
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
  // Primary+digit follows the account's sidebar, so no destination owns a key.
  const digits = dests.digitShortcuts;
  assert(Array.isArray(digits?.modifiers) && digits.modifiers.length > 0, "destinations.json: digitShortcuts.modifiers missing");
  assert(Number.isInteger(digits.max) && digits.max >= 1 && digits.max <= 9, "destinations.json: digitShortcuts.max must be 1-9");
  assert(dests.destinations.some((d) => d.visibility === digits.visibility), `destinations.json: digitShortcuts.visibility "${digits.visibility}" matches no destination`);
  for (const d of dests.destinations) {
    assert(d.shortcut === undefined, `destinations.json: ${d.id} cannot own a shortcut; digitShortcuts numbers the lists`);
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
    // `platforms` limits a step to those platforms (absent: every platform);
    // `featureId` skips it where that capability does not ship (ADR 0015).
    for (const p of st.platforms ?? []) assert(platforms.has(p), `surfaces.json: firstRun ${st.id} unknown platform "${p}"`);
    if (st.featureId !== undefined) assert(st.featureId in caps.capabilities, `surfaces.json: firstRun ${st.id} unknown featureId "${st.featureId}"`);
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

function validateSurfaces(surfaces, icons, caps, plans) {
  assert(surfaces.version === 1, "surfaces.json: version must be 1");
  assert(surfaces.notices.maxConcurrentExplainers === 1, "surfaces.json: maxConcurrentExplainers must be 1");
  const ls = surfaces.listSort;
  assert(ls && ls.icon in icons.icons, "surfaces.json: listSort missing or unknown icon");
  assert(ls.featureId in caps.capabilities, `surfaces.json: listSort unknown featureId "${ls.featureId}"`);
  assert(typeof ls.menuTitle === "string" && ls.menuTitle.length > 0, "surfaces.json: listSort.menuTitle missing");
  assert(typeof ls.sortedBy === "string" && ls.sortedBy.includes("{sort}"), "surfaces.json: listSort.sortedBy must contain {sort}");
  const upsellIds = new Set(plans.upsells.map((u) => u.id));
  for (const n of surfaces.notices.items) {
    assert(n.icon in icons.icons, `surfaces.json: notice ${n.id} unknown icon "${n.icon}"`);
    assert(n.featureId in caps.capabilities, `surfaces.json: notice ${n.id} unknown featureId "${n.featureId}"`);
    // An upsell notice takes its title and detail from plans.json `upsells`
    // (spec §3.2): one copy of the words, never a second one here.
    if (n.upsell !== undefined) {
      assert(upsellIds.has(n.upsell), `surfaces.json: notice ${n.id} unknown upsell "${n.upsell}"`);
      assert(n.title === undefined && n.detail === undefined && n.platformDetails === undefined,
        `surfaces.json: notice ${n.id} is an upsell; its title and detail come from plans.json`);
    }
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
    // An on/off attribute shows a filled symbol while on, so its icon must declare one.
    if (attr.toggle === true) {
      assert(typeof icons.icons[attr.icon]?.sfSymbolOn === "string", `surfaces.json: toggle attribute ${attr.id} needs an icon with sfSymbolOn`);
    }
  }
  // The task page (ADR 0029, docs/TASK_PAGE_SPEC.md): ordered blocks from a
  // closed set of kinds. Each platform writes one renderer per kind; the
  // registry holds order, depth and gating, never geometry (ADR 0028).
  const page = surfaces.taskPage;
  assert(page && Array.isArray(page.blocks) && page.blocks.length > 0, "surfaces.json: taskPage.blocks missing");
  assert(page.featureId in caps.capabilities, `surfaces.json: taskPage unknown featureId "${page.featureId}"`);
  const blockIds = new Set();
  for (const b of page.blocks) {
    assert(!blockIds.has(b.id), `surfaces.json: duplicate taskPage block ${b.id}`);
    blockIds.add(b.id);
    assert(TASK_PAGE_BLOCK_KINDS.has(b.kind), `surfaces.json: taskPage block ${b.id} unknown kind "${b.kind}"`);
    assert(Array.isArray(b.depths) && b.depths.length > 0 && b.depths.every((d) => TASK_PAGE_DEPTHS.has(d)), `surfaces.json: taskPage block ${b.id} needs depths from ${[...TASK_PAGE_DEPTHS].join(", ")}`);
    assert(b.featureId in caps.capabilities, `surfaces.json: taskPage block ${b.id} unknown featureId "${b.featureId}"`);
    if (b.attribute !== undefined) assert(attrIds.has(b.attribute), `surfaces.json: taskPage block ${b.id} unknown attribute "${b.attribute}"`);
    if (["checklist", "attachments", "references", "conversation", "history"].includes(b.kind)) {
      assert(typeof b.label === "string" || b.attribute !== undefined, `surfaces.json: taskPage block ${b.id} needs a label or an attribute`);
    }
    // The agent prompt copy (docs/AGENT_PROMPT_SPEC.md): the kickers, the
    // question when a hand-off has no note, and the line after Accept.
    if (b.kind === "conversation") {
      for (const k of ["askKicker", "reviewKicker", "reviewFallback", "acceptedLabel"]) {
        assert(typeof b[k] === "string" && b[k].length > 0, `surfaces.json: taskPage block ${b.id} needs ${k}`);
      }
    }
    // Provenance (who added the task) is permanent metadata: the label, the
    // name a human author shows as, the name for an agent row that carries
    // no `sourceClient`, and the agent glyph the row and the page share.
    if (b.kind === "provenance") {
      for (const k of ["label", "selfLabel", "agentFallbackName"]) {
        assert(typeof b[k] === "string" && b[k].length > 0, `surfaces.json: taskPage block ${b.id} needs ${k}`);
      }
      assert(b.icon in icons.icons, `surfaces.json: taskPage block ${b.id} unknown icon "${b.icon}"`);
    }
  }
  for (const kind of TASK_PAGE_BLOCK_KINDS) {
    assert(page.blocks.filter((b) => b.kind === kind).length === 1, `surfaces.json: taskPage needs exactly one "${kind}" block`);
  }
}

// Project and area notes on the page (docs/PROJECT_NOTES_SPEC.md §6).
function validatePlaceNotes(surfaces, caps) {
  const t = surfaces.placeNotes;
  assert(t && t.featureId in caps.capabilities, "surfaces.json: placeNotes needs a known featureId");
  assert(Number.isInteger(t.previewLines) && t.previewLines > 0, "surfaces.json: placeNotes.previewLines is not a positive integer");
  for (const key of ["showMore", "showLess"]) {
    assert(typeof t[key]?.title === "string" && t[key].title.length > 0, `surfaces.json: placeNotes.${key} needs a title`);
  }
}

// Do (docs/DO_SPEC.md §3 to §5): the copy of the screen, the notice and the
// history, and the lengths it offers.
function validateDoing(surfaces, caps, entities) {
  const d = surfaces.doing;
  assert(d && d.featureId in caps.capabilities, "surfaces.json: doing needs a known featureId");
  assert(d.lengths.length > 0 && d.lengths.every((m) => Number.isInteger(m) && m > 0 && m <= entities.limits.doPlannedMinutesMax), "surfaces.json: doing.lengths are minutes up to doPlannedMinutesMax");
  assert(JSON.stringify(Object.keys(d.exits)) === JSON.stringify(entities.enums.doExit), "surfaces.json: doing.exits has one label per doExit, in order");
  for (const [p, v] of stringsOf(d, "doing")) assert(!/[–—]/.test(v), `surfaces.json: ${p} contains an em or en dash`);
}

// References (docs/TASK_REFERENCES_SPEC.md §8): a label and an icon per key
// kind, the fallback for a kind this build does not know, the labels of the
// roles that show one, and the copy of Add Reference.
// Waiting (docs/REVIEW_SPEC.md §6): the row label, the sheet copy and the
// check-back date the sheet offers.
function validateWaiting(surfaces, caps) {
  const w = surfaces.waiting;
  assert(w && w.featureId in caps.capabilities, "surfaces.json: waiting needs a known featureId");
  assert(typeof w.label?.format === "string" && w.label.format.includes("{name}"), "surfaces.json: waiting.label.format needs {name}");
  for (const [f, v] of [["title", w.sheet?.title], ["placeholder", w.sheet?.placeholder], ["confirmTitle", w.sheet?.confirmTitle],
    ["checkBack.title", w.sheet?.checkBack?.title], ["noCheckBack.title", w.sheet?.noCheckBack?.title]]) {
    assert(typeof v === "string" && v.length > 0, `surfaces.json: waiting.sheet.${f} is missing`);
  }
  assert(Number.isInteger(w.defaultCheckBackDays) && w.defaultCheckBackDays > 0, "surfaces.json: waiting.defaultCheckBackDays is not a positive integer");
  for (const [p, v] of stringsOf(w, "waiting")) assert(!/[–—]/.test(v), `surfaces.json: ${p} contains an em or en dash`);
}

function validateTaskReferences(surfaces, icons, caps, entities) {
  const t = surfaces.taskReferences;
  assert(t && t.featureId in caps.capabilities, "surfaces.json: taskReferences needs a known featureId");
  for (const [kind, k] of [...Object.entries(t.kinds), ["otherKind", t.otherKind]]) {
    assert(/^[a-z][a-z0-9_-]*$/i.test(kind), `surfaces.json: taskReferences kind "${kind}" is not a kind`);
    assert(typeof k.label === "string" && k.label.length > 0, `surfaces.json: taskReferences ${kind} needs a label`);
    assert(k.icon in icons.icons, `surfaces.json: taskReferences ${kind} unknown icon "${k.icon}"`);
  }
  for (const [role, r] of Object.entries(t.roles)) {
    assert(entities.enums.taskRefRole.includes(role), `surfaces.json: taskReferences unknown role "${role}"`);
    assert(typeof r.label === "string" && r.label.length > 0, `surfaces.json: taskReferences role ${role} needs a label`);
  }
  assert(Number.isInteger(t.add.suggestions.max) && t.add.suggestions.max > 0, "surfaces.json: taskReferences.add.suggestions.max is not a positive integer");
  for (const [p, v] of stringsOf(t, "taskReferences")) assert(!/[–—]/.test(v), `surfaces.json: ${p} contains an em or en dash`);
}

// The date board (docs/TASK_ROW_MENU_SPEC.md): the rows under the day strip of
// the When and Deadline pickers, from a closed set of kinds in one order. Each
// row names its group; a group is contiguous and the groups keep the order of
// `groups`. Platforms draw one divider where the group changes, and the day
// strip opens the first group.
function checkTaskDateBoard({ surfaces, icons, caps, actions }) {
  const rows = surfaces.taskDateBoard?.rows ?? [];
  const groups = surfaces.taskDateBoard?.groups ?? [];
  assert(groups.length === DATE_BOARD_GROUPS.length && groups.every((g, i) => g === DATE_BOARD_GROUPS[i]), `surfaces.json: taskDateBoard.groups must be ${JSON.stringify(DATE_BOARD_GROUPS)}`);
  assert(typeof surfaces.taskDateBoard?.tomorrow?.label === "string", "surfaces.json: taskDateBoard.tomorrow.label is missing");
  let lastGroup = 0;
  for (const r of rows) {
    const g = groups.indexOf(r.group);
    assert(g >= 0, `surfaces.json: taskDateBoard row ${r.id} unknown group "${r.group}"`);
    assert(g >= lastGroup, `surfaces.json: taskDateBoard row ${r.id} breaks the group order (groups are contiguous, in taskDateBoard.groups order)`);
    lastGroup = g;
  }
  const attrIds = new Set(surfaces.taskAttributes.map((a) => a.id));
  for (const kind of DATE_BOARD_ROW_KINDS) {
    assert(rows.filter((r) => r.kind === kind).length === 1, `surfaces.json: taskDateBoard needs exactly one "${kind}" row`);
  }
  for (const r of rows) {
    assert(DATE_BOARD_ROW_KINDS.has(r.kind), `surfaces.json: taskDateBoard row ${r.id} unknown kind "${r.kind}"`);
    assert(r.icon in icons.icons, `surfaces.json: taskDateBoard row ${r.id} unknown icon "${r.icon}"`);
    assert(r.featureId in caps.capabilities, `surfaces.json: taskDateBoard row ${r.id} unknown featureId "${r.featureId}"`);
    assert((typeof r.label === "string") !== (r.action in actions.actions), `surfaces.json: taskDateBoard row ${r.id} needs a label or a known action`);
    assert(Array.isArray(r.attributes) && r.attributes.length > 0, `surfaces.json: taskDateBoard row ${r.id} needs attributes`);
    for (const a of [...r.attributes, ...(r.attributeLabels ?? []).map((l) => l.attribute)]) {
      assert(DATE_BOARD_ATTRIBUTES.has(a) && attrIds.has(a), `surfaces.json: taskDateBoard row ${r.id} unknown attribute "${a}"`);
    }
  }
}
const DATE_BOARD_ROW_KINDS = new Set(["calendar", "time", "repeatRule", "clear"]);
const DATE_BOARD_GROUPS = ["pick", "refine", "remove"];
const DATE_BOARD_ATTRIBUTES = new Set(["when", "deadline"]);

// One picker per attribute (ADR 0029): every popover attribute is opened by
// exactly one action, so the pill, the page row, the context menu, the menu
// bar and the shortcut all reach the same picker.
function checkOpensAttribute({ actions, surfaces }) {
  const attrById = new Map(surfaces.taskAttributes.map((a) => [a.id, a]));
  const openers = new Map();
  for (const [id, a] of Object.entries(actions.actions)) {
    if (a.opensAttribute === undefined) continue;
    assert(attrById.has(a.opensAttribute), `actions.json: ${id} opensAttribute names unknown attribute "${a.opensAttribute}"`);
    assert(!openers.has(a.opensAttribute), `actions.json: attribute "${a.opensAttribute}" is opened by both ${openers.get(a.opensAttribute)} and ${id}`);
    openers.set(a.opensAttribute, id);
  }
  for (const attr of surfaces.taskAttributes) {
    if (attr.surfaceTier !== "popover") continue;
    assert(openers.has(attr.id), `actions.json: popover attribute "${attr.id}" has no action with opensAttribute (ADR 0029: one picker per attribute)`);
  }
}
const TASK_PAGE_BLOCK_KINDS = new Set(["header", "notes", "attributes", "checklist", "attachments", "references", "conversation", "provenance", "history"]);
const TASK_PAGE_DEPTHS = new Set(["inline", "page", "review"]);

// ---- plans.json (ADR 0010, ADR 0023) ----
// Pro is a real plan (ADR 0045, ADR 0052) that sells like Plus (ADR 0059):
// the site shows it, the server applies it from a grant or a Pro product, and
// the apps name it on an account that has it. The app paywalls offer it in #719.
const PLAN_LEVELS = ["free", "plus", "pro"];
const PLAN_LIMIT_PLANS = ["account", "plus", "pro"];

/** Every string in a JSON value, with its path. */
function stringsOf(node, p, out = []) {
  if (typeof node === "string") out.push([p, node]);
  else if (Array.isArray(node)) node.forEach((v, i) => stringsOf(v, `${p}.${i}`, out));
  else if (node && typeof node === "object") for (const [k, v] of Object.entries(node)) if (k !== "description") stringsOf(v, `${p}.${k}`, out);
  return out;
}

function validateImportSources(file, caps) {
  assert(file.version === 1, "import-sources.json: version must be 1");
  const ids = new Set();
  for (const s of file.sources) {
    assert(/^[a-z][a-z-]*$/.test(s.id) && !ids.has(s.id), `import-sources.json: bad or duplicate id "${s.id}"`);
    ids.add(s.id);
    assert(typeof s.name === "string" && s.name.length > 0, `import-sources.json: ${s.id} needs a name`);
    assert(file.statuses.includes(s.status), `import-sources.json: ${s.id} unknown status "${s.status}"`);
    assert(file.inputs.includes(s.input), `import-sources.json: ${s.id} unknown input "${s.input}"`);
    assert(Number.isInteger(s.issue) && s.issue > 0, `import-sources.json: ${s.id} needs an issue`);
    assert(!/[–—]/.test(s.detail ?? ""), `import-sources.json: ${s.id} detail contains an em or en dash`);
    // "ships" here and in the capability ledger must be the same claim.
    if (s.status === "ships") {
      const cap = caps.capabilities[s.featureId];
      assert(cap && caps.platforms.some((p) => cap[p] === "ships"), `import-sources.json: ${s.id} ships, but capability "${s.featureId}" ships on no platform`);
      assert(s.detail, `import-sources.json: ${s.id} ships and needs a detail`);
    } else {
      assert(!s.featureId || !caps.platforms.some((p) => caps.capabilities[s.featureId]?.[p] === "ships"), `import-sources.json: ${s.id} is ${s.status}, but its capability ships`);
    }
  }
  const listed = new Set(file.sources.map((s) => s.featureId).filter(Boolean));
  for (const id of Object.keys(caps.capabilities)) assert(!id.startsWith("import.") || listed.has(id), `import-sources.json: capability "${id}" has no source`);
}

function validatePlans(plans, icons, caps, importSources) {
  assert(plans.version === 1, "plans.json: version must be 1");
  assert(plans.featureId in caps.capabilities, `plans.json: unknown featureId "${plans.featureId}"`);
  for (const f of ["name", "shortName", "proName", "headline", "subhead", "ladderHeadline", "accountNote", "agentNote"]) assert(typeof plans[f] === "string" && plans[f].length > 0, `plans.json: ${f} missing`);
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
  // Benefits (docs/PREMIUM_LANGUAGE.md): each states its plan's value, so the
  // words cannot drift from the server's plan table.
  const WORDS = { 1: "one", 2: "two", 3: "three", 365: "year" };
  for (const tier of ["plus", "pro"]) {
    const list = plans.benefits?.[tier];
    assert(Array.isArray(list) && list.length > 0, `plans.json: benefits.${tier} missing`);
    for (const b of list) {
      assert(b.id && b.icon && b.title && b.detail, `plans.json: benefits.${tier}.${b.id} needs id, icon, title, detail`);
      assert(b.icon in icons.icons, `plans.json: benefits.${tier}.${b.id} unknown icon "${b.icon}"`);
      if (!b.limit) continue;
      assert(b.limit in plans.limits[tier], `plans.json: benefits.${tier}.${b.id} unknown limit "${b.limit}"`);
      const v = plans.limits[tier][b.limit];
      const t = b.title.toLowerCase();
      if (v === null) assert(/no limit|every|all/.test(t), `plans.json: benefits.${tier}.${b.id} must say there is no limit`);
      else assert(t.includes(String(v)) || (WORDS[v] && t.includes(WORDS[v])), `plans.json: benefits.${tier}.${b.id} must state ${v}`);
    }
  }
  assert(/^https:\/\//.test(plans.compareURL ?? ""), "plans.json: compareURL must be an https URL");
  // An upsell moment names the plan that answers it, so the paywall opens on that plan.
  for (const u of plans.upsells) assert(["plus", "pro"].includes(u.plan), `plans.json: upsell ${u.id} needs plan "plus" or "pro"`);
  // ADR 0059: Pro sells like Plus, in the same subscription group. Its prices
  // must state the Pro level's amounts, and its products sit under .sync.pro.
  const proLevel = plans.levels.find((l) => l.id === "pro");
  for (const pr of plans.proPrices ?? []) {
    assert(!priceIds.has(pr.id), `plans.json: duplicate price "${pr.id}"`);
    priceIds.add(pr.id);
    assert(/^com\.septena\.tasks\.sync\.pro\.[a-z]+$/.test(pr.productId), `plans.json: pro price ${pr.id} productId must start com.septena.tasks.sync.pro.`);
    assert(Number.isInteger(pr.amountMinor) && pr.amountMinor > 0, `plans.json: pro price ${pr.id} amountMinor must be a positive integer`);
    assert(pr.currency === "EUR", `plans.json: pro price ${pr.id} currency must be EUR`);
    assert(["year", "month"].includes(pr.interval), `plans.json: pro price ${pr.id} unknown interval "${pr.interval}"`);
    const whole = String(pr.amountMinor / 100);
    assert(pr.label.includes(whole), `plans.json: pro price ${pr.id} label must state ${whole}`);
    assert(proLevel.detail.includes(whole), `plans.json: the pro level detail must state ${whole}`);
  }
  assert(Array.isArray(plans.proPrices) && plans.proPrices.length > 0, "plans.json: proPrices missing (ADR 0059)");

  // ADR 0061: 7-Year Plus Pass (one-time / Apple Non-Renewing Subscription, Plus only).
  const pass = plans.pass;
  assert(pass && typeof pass === "object", "plans.json: pass missing (ADR 0061)");
  assert(!priceIds.has(pass.id), `plans.json: duplicate price "${pass.id}"`);
  priceIds.add(pass.id);
  assert(pass.plan === "plus", "plans.json: pass.plan must be plus (ADR 0061: no Pro single buy)");
  assert(/^com\.septena\.tasks\.sync\.plus\.[a-z0-9]+$/.test(pass.productId), `plans.json: pass productId "${pass.productId}" must start com.septena.tasks.sync.plus.`);
  assert(Number.isInteger(pass.years) && pass.years > 0, "plans.json: pass.years must be a positive integer");
  assert(Number.isInteger(pass.amountMinor) && pass.amountMinor > 0, "plans.json: pass.amountMinor must be a positive integer");
  assert(pass.currency === "EUR", "plans.json: pass.currency must be EUR");
  for (const f of ["title", "detail", "label", "rateDetail", "action"]) assert(typeof pass[f] === "string" && pass[f].length > 0, `plans.json: pass.${f} missing`);
  assert(pass.label.includes(String(pass.amountMinor / 100)), `plans.json: pass.label must state ${pass.amountMinor / 100}`);

  // ADR 0060: pinned currencies (EUR baseline + USD, GBP, BRL) for the pricing
  // page and web checkout. EUR amounts must stay in lockstep with prices/proPrices.
  assert(plans.defaultCurrency === "EUR", "plans.json: defaultCurrency must be EUR (ADR 0060)");
  assert(Array.isArray(plans.currencies) && plans.currencies.length > 0, "plans.json: currencies missing (ADR 0060)");
  const curCodes = new Set();
  const curCountries = new Set();
  for (const cur of plans.currencies) {
    assert(/^[A-Z]{3}$/.test(cur.code) && !curCodes.has(cur.code), `plans.json: bad or duplicate currency "${cur.code}"`);
    curCodes.add(cur.code);
    assert(typeof cur.symbol === "string" && cur.symbol.length > 0, `plans.json: currency ${cur.code} needs symbol`);
    assert(typeof cur.taxInclusive === "boolean", `plans.json: currency ${cur.code} needs taxInclusive boolean`);
    assert(typeof cur.freeLabel === "string" && cur.freeLabel.includes("0"), `plans.json: currency ${cur.code} needs freeLabel`);
    assert(typeof cur.footnote === "string" && cur.footnote.length > 0, `plans.json: currency ${cur.code} needs footnote`);
    assert(Array.isArray(cur.countries), `plans.json: currency ${cur.code} countries must be an array`);
    for (const cc of cur.countries) {
      assert(/^[A-Z]{2}$/.test(cc) && !curCountries.has(cc), `plans.json: currency ${cur.code} bad or duplicate country "${cc}"`);
      curCountries.add(cc);
    }
    for (const tier of ["plus", "pro"]) {
      for (const iv of ["year", "month"]) {
        const entry = cur[tier]?.[iv];
        assert(entry && Number.isInteger(entry.amountMinor) && entry.amountMinor > 0, `plans.json: currency ${cur.code}.${tier}.${iv} needs positive integer amountMinor`);
        const whole = String(entry.amountMinor / 100);
        assert(typeof entry.label === "string" && entry.label.includes(whole), `plans.json: currency ${cur.code}.${tier}.${iv} label must state ${whole}`);
        assert(typeof entry.detail === "string" && entry.detail.length > 0, `plans.json: currency ${cur.code}.${tier}.${iv} needs detail`);
      }
    }
    const curPass = cur.plus?.pass;
    assert(curPass && Number.isInteger(curPass.amountMinor) && curPass.amountMinor > 0, `plans.json: currency ${cur.code}.plus.pass needs positive integer amountMinor`);
    const passWhole = String(curPass.amountMinor / 100);
    assert(typeof curPass.label === "string" && curPass.label.includes(passWhole), `plans.json: currency ${cur.code}.plus.pass label must state ${passWhole}`);
    assert(typeof curPass.detail === "string" && curPass.detail.length > 0, `plans.json: currency ${cur.code}.plus.pass needs detail`);
    assert(cur.pro?.pass === undefined, `plans.json: currency ${cur.code}.pro must not have a pass (ADR 0061)`);
  }
  const eurCur = plans.currencies.find((c) => c.code === plans.defaultCurrency);
  assert(eurCur, "plans.json: defaultCurrency must exist in currencies");
  for (const pr of plans.prices) assert(eurCur.plus[pr.interval].amountMinor === pr.amountMinor, `plans.json: EUR plus.${pr.interval} must match prices.${pr.id}`);
  for (const pr of plans.proPrices) assert(eurCur.pro[pr.interval].amountMinor === pr.amountMinor, `plans.json: EUR pro.${pr.interval} must match proPrices.${pr.id}`);
  assert(eurCur.plus.pass.amountMinor === plans.pass.amountMinor, "plans.json: EUR plus.pass must match pass.amountMinor");

  assert(JSON.stringify(plans.levels.map((l) => l.id)) === JSON.stringify(PLAN_LEVELS), `plans.json: levels must be ${PLAN_LEVELS.join(", ")}`);
  assert(JSON.stringify(plans.cards.map((c) => c.id)) === JSON.stringify(PLAN_LEVELS), `plans.json: cards must be ${PLAN_LEVELS.join(", ")}`);
  // ADR 0059: Pro sells like Plus, so no card carries a status: every card is on sale.
  assert(plans.cards.every((c) => c.status === undefined), "plans.json: plan cards carry no status (ADR 0059: every plan is on sale)");
  assert(plans.cards.filter((c) => c.highlighted).length === 1, "plans.json: exactly one card must be highlighted");
  for (const k of ["seePlus", "startTrial", "trialStarted", "trialBilling", "success", "pending", "serverRetry", "failed", "ownedApple", "ownedWeb", "ownedGoogle", "ownedGrant", "ownedGrantPro", "ownedOtherAccount", "done"]) {
    assert(typeof plans.paywall?.[k] === "string" && plans.paywall[k].length > 0, `plans.json: paywall.${k} missing`);
  }
  assert(plans.paywall.startTrial.includes(String(plans.trial.days)), `plans.json: paywall.startTrial must state ${plans.trial.days} days`);
  for (const k of ["terms", "privacy"]) assert(/^https:\/\/[^\s]+$/.test(plans.legal?.[k] ?? ""), `plans.json: legal.${k} must be an https URL`);
  for (const c of plans.cards) assert(c.icon in icons.icons, `plans.json: card ${c.id} icon "${c.icon}" is not in icons.json`);

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
          const cell = r.cells[plan === "account" ? "free" : plan];
          if (Number.isInteger(v) && v > 0) {
            assert(typeof cell === "string" && new RegExp(`(^|\\D)${v}(\\D|$)`).test(cell), `plans.json: row ${r.id} ${plan} cell must state the limit ${v}`);
          }
        }
      }
    }
  }
  for (const id of plans.cardRows) assert(rowIds.has(id), `plans.json: cardRows names unknown row "${id}"`);
  assert(plans.fullApp?.title && plans.fullApp.points?.length > 0, "plans.json: fullApp needs title and points");
  for (const p of plans.fullApp.points) assert(p.id && p.title, "plans.json: every fullApp point needs an id and a title");
  // The site adds the importers to this line from import-sources.json. No plan copy names one.
  assert(plans.fullApp.points.some((p) => p.id === "import"), "plans.json: fullApp needs the import point");
  for (const [p, v] of stringsOf(plans, "plans")) for (const s of importSources.sources) assert(!v.includes(s.name), `plans.json: ${p} names ${s.name}; importers are listed only in import-sources.json`);
  for (const list of ["promises", "upsells"]) {
    const ids = new Set();
    for (const n of plans[list]) {
      assert(!ids.has(n.id), `plans.json: duplicate ${list} "${n.id}"`);
      ids.add(n.id);
      assert(n.title && n.detail, `plans.json: ${list} ${n.id} needs title and detail`);
    }
  }
}

// ---- sign-in.json (ADR 0047, docs/SIGN_IN_SURFACES_SPEC.md §3) ----
const SIGN_IN_FLOWS = new Set(["native", "web", "none"]);
const SIGN_IN_KINDS = ["provider", "email", "device"];

function validateSignIn(signIn, icons, caps, plans) {
  assert(signIn.version === 1, "sign-in.json: version must be 1");
  for (const [p, v] of stringsOf(signIn, "signIn")) assert(!/[–—]/.test(v), `sign-in.json: ${p} contains an em or en dash`);
  assert(Array.isArray(signIn.platforms) && signIn.platforms.length > 0, "sign-in.json: missing platforms");
  for (const p of signIn.platforms) assert(caps.platforms.includes(p), `sign-in.json: unknown platform "${p}"`);
  const ids = new Set();
  for (const m of signIn.methods) {
    assert(/^[a-z]+$/.test(m.id) && !ids.has(m.id), `sign-in.json: bad or duplicate method id "${m.id}"`);
    ids.add(m.id);
    assert(SIGN_IN_KINDS.includes(m.kind), `sign-in.json: method ${m.id} unknown kind "${m.kind}"`);
    assert(m.kind !== "provider" || (typeof m.name === "string" && m.name.length > 0), `sign-in.json: provider ${m.id} needs a name`);
    assert(typeof m.title === "string" && m.title.length > 0, `sign-in.json: method ${m.id} needs a title`);
    assert(m.icon in icons.icons, `sign-in.json: method ${m.id} icon "${m.icon}" is not in icons.json`);
    assert(typeof m.createsAccount === "boolean", `sign-in.json: method ${m.id} createsAccount must be a boolean`);
    // ADR 0047: device approval needs a signed-in device; every other method creates an account.
    assert(m.createsAccount === (m.kind !== "device"), `sign-in.json: method ${m.id} createsAccount must be ${m.kind !== "device"}`);
    assert(m.featureId in caps.capabilities, `sign-in.json: method ${m.id} unknown featureId "${m.featureId}"`);
    assert(JSON.stringify(Object.keys(m.flows ?? {}).sort()) === JSON.stringify([...signIn.platforms].sort()), `sign-in.json: method ${m.id} needs a flow for exactly ${signIn.platforms.join(", ")}`);
    for (const [p, f] of Object.entries(m.flows)) {
      assert(SIGN_IN_FLOWS.has(f), `sign-in.json: method ${m.id} flow on ${p} must be native, web or none`);
      assert(f !== "none" || (typeof m.notes === "string" && m.notes.length > 0), `sign-in.json: method ${m.id} is none on ${p}; say why in notes`);
    }
  }
  const byId = Object.fromEntries(signIn.methods.map((m) => [m.id, m]));
  assert(JSON.stringify(Object.keys(signIn.order ?? {}).sort()) === JSON.stringify([...signIn.platforms].sort()), `sign-in.json: order needs exactly ${signIn.platforms.join(", ")}`);
  for (const [p, list] of Object.entries(signIn.order)) {
    const want = signIn.methods.filter((m) => m.flows[p] !== "none").map((m) => m.id).sort();
    assert(new Set(list).size === list.length && JSON.stringify([...list].sort()) === JSON.stringify(want), `sign-in.json: order.${p} must list exactly the methods that are not none on ${p} (${want.join(", ")})`);
    // Providers, then email, then device approval; the platform's native provider first.
    const ranks = list.map((id) => SIGN_IN_KINDS.indexOf(byId[id].kind));
    assert(ranks.every((r, i) => i === 0 || ranks[i - 1] <= r), `sign-in.json: order.${p} must list providers, then email, then device`);
    const native = list.filter((id) => byId[id].kind === "provider" && byId[id].flows[p] === "native");
    assert(native.length <= 1, `sign-in.json: order.${p} has more than one native provider`);
    assert(native.length === 0 || list[0] === native[0], `sign-in.json: order.${p} must start with its native provider "${native[0]}"`);
  }
  assert(signIn.copy.terms.includes("{terms}") && signIn.copy.terms.includes("{privacy}"), "sign-in.json: copy.terms needs {terms} and {privacy}");
  assert(signIn.email.codeSent.includes("{email}"), "sign-in.json: email.codeSent needs {email}");
  assert(signIn.existingAccount.detail.includes("{email}") && signIn.existingAccount.detail.includes("{provider}"), "sign-in.json: existingAccount.detail needs {email} and {provider}");
  assert(signIn.existingAccount.manualDetail.includes("{email}") && signIn.existingAccount.manualDetail.includes("{provider}"), "sign-in.json: existingAccount.manualDetail needs {email} and {provider}");
  assert(signIn.manage?.addProvider?.includes("{provider}"), "sign-in.json: manage.addProvider needs {provider}");
  assert(signIn.errors.wrongCode?.other?.includes("{count}"), "sign-in.json: errors.wrongCode must be a plural with {count}");
  assert(plans.legal?.terms && plans.legal?.privacy, "sign-in.json: the Terms and Privacy URLs come from plans.json legal");
}

// The code map (ADR 0050, AS9): public claims and the file that keeps each.
// No bindings: septena.app renders it. Every path must exist in this repo, so
// a rename here fails before the site's own check does.
function validateCodeMap(map, caps) {
  assert(map.repo === "michellzappa/septena" && map.branch === "main", "code-map.json: repo must be michellzappa/septena on main");
  assert(Array.isArray(map.entries) && map.entries.length > 0, "code-map.json: entries must be a non-empty array");
  const ids = new Set();
  for (const e of map.entries) {
    assert(typeof e.id === "string" && /^[a-z0-9-]+$/.test(e.id), `code-map.json: bad id ${JSON.stringify(e.id)}`);
    assert(!ids.has(e.id), `code-map.json: duplicate id ${e.id}`);
    ids.add(e.id);
    assert(typeof e.label === "string" && e.label.trim() && !/[\u2013\u2014]/.test(e.label), `code-map.json: ${e.id} needs a label without en or em dashes`);
    assert(typeof e.path === "string" && !e.path.startsWith("/") && !e.path.includes(".."), `code-map.json: ${e.id} path must be relative to the repo`);
    const full = path.join(REPO, e.path);
    assert(fs.existsSync(full), `code-map.json: ${e.id} path ${e.path} does not exist`);
    assert(fs.statSync(full).isDirectory() === e.path.endsWith("/"), `code-map.json: ${e.id} path ${e.path}: a folder ends in /, a file does not`);
    if (e.feature !== undefined) assert(caps.capabilities[e.feature], `code-map.json: ${e.id} feature ${e.feature} is not in capabilities.json`);
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

// Rules, limits and patterns that only the server enforces. The Apple client
// never reads them, so Swift does not get them (the reader check in
// `scripts/registry-readers.mjs` fails on generated code nobody reads).
// TypeScript gets every key; Kotlin skips the server-only rules too.
const SERVER_ONLY = new Set([
  "agentRunBudget", "claimTtlDefaultSeconds", "claimTtlMaxSeconds",
  "tombstoneTtlDays", "clientOpTtlDays", "changeLogTtlDays",
  "attachmentPointerMax", "maxUserAttachmentBytes", "time24",
]);
const L = (s, obj, field) => L10N.swiftLookup(BY_KEY, s, obj?.l10nKeys?.[field] ?? s);
const LOpt = (s, obj, field) => (s === undefined || s === null ? "nil" : L(s, obj, field));
const swiftOptStr = (s) => (s === undefined || s === null ? "nil" : JSON.stringify(s));
const camelId = (s) => s.replace(/[._-]+([a-zA-Z0-9])/g, (_, c) => c.toUpperCase());
const SWIFT_KEYWORDS = new Set([
  "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
  "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
  "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
  "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
  "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
  "as", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
]);
const swiftCaseName = (id) => camelId(id);
const swiftCaseDecl = (id) => {
  const name = swiftCaseName(id);
  return SWIFT_KEYWORDS.has(name) ? `\`${name}\`` : name;
};
const swiftCaseRef = (id) => `.${swiftCaseName(id)}`;

function appleKeycaps(sc) {
  const caps = [];
  if (sc.modifiers.includes("ctrl")) caps.push("⌃");
  if (sc.modifiers.includes("alt")) caps.push("⌥");
  if (sc.modifiers.includes("shift")) caps.push("⇧");
  if (sc.modifiers.includes("primary")) caps.push("⌘");
  const keyMap = { delete: "⌫", escape: "esc", return: "↩", space: "space", tab: "tab" };
  caps.push(keyMap[sc.key] ?? sc.key.toUpperCase());
  return caps;
}

function generateSwift({ entities, rules, icons, tokens, caps, settings, dests, actions, surfaces, plans }) {
  const lines = [];
  lines.push("// GENERATED FILE — DO NOT EDIT BY HAND.");
  lines.push("// Sources: registry/{entities,rules,icons,tokens,capabilities,settings,destinations,actions,surfaces,plans,import-sources}.json");
  lines.push("// Regenerate: node scripts/gen-registries.mjs");
  lines.push("");
  lines.push("import Foundation");
  lines.push("");
  lines.push(L10N.SWIFT_RUNTIME);

  // 1. Entities & Limits
  lines.push("/// Wire schema size and count limits shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityLimits {");
  for (const [k, v] of Object.entries(entities.limits)) {
    if (SERVER_ONLY.has(k)) continue;
    const type = v > 2_000_000_000 || k.endsWith("Bytes") ? "Int64" : "Int";
    lines.push(`  static let ${k}: ${type} = ${v}`);
  }
  lines.push("}");
  lines.push("");
  lines.push("/// Wire schema regex strings shared with the backend (`registry/entities.json`).");
  lines.push("enum RegistryEntityPatterns {");
  for (const [k, v] of Object.entries(entities.patterns)) {
    if (SERVER_ONLY.has(k)) continue;
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
    if (k === "version" || SERVER_ONLY.has(k)) continue;
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
  lines.push("");
  lines.push("  /// Filled variants (`icons.json` `sfSymbolOn`) a control shows while it is on.");
  lines.push("  static let sfSymbolsOn: [String: String] = [");
  for (const [id, map] of Object.entries(icons.icons)) {
    if (map.sfSymbolOn !== undefined) lines.push(`    ${swiftStr(id)}: ${swiftStr(map.sfSymbolOn)},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  /// The symbol for `id` in a control's state: its filled variant while on,");
  lines.push("  /// when the icon declares one. Every on/off control reads its icon here.");
  lines.push("  static func sfSymbol(for id: String, on: Bool) -> String {");
  lines.push("    on ? (sfSymbolsOn[id] ?? sfSymbol(for: id)) : sfSymbol(for: id)");
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
  lines.push("  /// Icon id → hex for icons that keep their semantic color under the");
  lines.push("  /// multicolor fruit (`multicolorGlyphs`); other fruits tint them with the accent.");
  lines.push(`  static let multicolorGlyphHex: [String: String] = [${Object.entries(tokens.multicolorGlyphs?.glyphs ?? {}).map(([icon, role]) => `${swiftStr(icon)}: ${swiftStr(tokens.colors[role])}`).join(", ") || ":"}]`);
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
  // A label or detail with `{name}` placeholders becomes a function
  // (`RegistrySettings.<surface><Field>(name:)`); the item field is nil.
  const settingsTemplates = [];
  const camel = (id) => id.replace(/[_.-]([a-z0-9])/g, (_, c) => c.toUpperCase());
  const itemText = (item, field) => {
    const v = item[field];
    if (typeof v === "string" && L10N.placeholdersOf(v).length > 0) {
      const name = camel(item.surface ?? item.key ?? item.page) + field[0].toUpperCase() + field.slice(1);
      const t = L10N.swiftTemplate(BY_KEY, item.l10nKeys?.[field] ?? v);
      settingsTemplates.push(`  static func ${name}(${t.params}) -> String { ${t.body} }`);
      return "nil";
    }
    return LOpt(v, item, field);
  };
  // An item's capability: its own, else its setting key's, else the page it
  // opens, else the page it sits on (ADR 0015 gating).
  const pageFeature = Object.fromEntries(settings.pages.map((pg) => [pg.id, pg.featureId]));
  const itemFeature = (item, onPage) =>
    item.featureId ?? (item.key ? settings.keys[item.key]?.featureId : undefined) ?? (item.page ? pageFeature[item.page] : undefined) ?? onPage?.featureId ?? null;
  const emitItem = (item, onPage) => {
    const iconId = item.icon ?? null;
    const sf = iconId ? icons.icons[iconId].sfSymbol : null;
    return `RegistrySettingsItem(kind: ${swiftStr(item.kind)}, key: ${optStr(item.key)}, page: ${optStr(item.page)}, surface: ${optStr(item.surface)}, label: ${itemText(item, "label")}, detail: ${itemText(item, "detail")}, iconId: ${optStr(iconId)}, sfSymbol: ${optStr(sf)}, statusKey: ${optStr(item.statusKey)}, visibility: ${swiftStr(item.visibility ?? "always")}, platforms: ${optArr(item.platforms)}, featureId: ${optStr(itemFeature(item, onPage))})`;
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
  lines.push("  /// The tab shows on `platform` when its capability ships (ADR 0015).");
  lines.push("  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }");
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
  lines.push("  let visibility: String");
  lines.push("  let platforms: [String]?");
  lines.push("  let featureId: String?");
  lines.push("  var id: String { \"\\(kind):\\(key ?? page ?? surface ?? label ?? \"item\")\" }");
  lines.push("  /// The item shows on `platform`: listed there and its capability ships (ADR 0015).");
  lines.push("  func applies(to platform: String) -> Bool { (platforms?.contains(platform) ?? true) && featureId.map { RegistryCapabilities.isAvailable($0, on: platform) } != false }");
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
  lines.push("  let footer: String?");
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
  lines.push("  /// The page shows on `platform`: listed there and its capability ships (ADR 0015).");
  lines.push("  func applies(to platform: String) -> Bool { (platforms?.contains(platform) ?? true) && RegistryCapabilities.isAvailable(featureId, on: platform) }");
  lines.push("}");
  lines.push("");
  lines.push("/// Unified task-app settings keys, defaults, synced-key list, and taxonomy (`registry/settings.json`).");
  lines.push("enum RegistrySettings {");
  lines.push("  /// The help center. Help rows and menu items open it or a page below it.");
  lines.push(`  static let helpURL = URL(string: ${swiftStr(settings.helpURL)})!`);
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
      lines.push(`      ${emitItem(item, null)},`);
    }
    lines.push("    ]),");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let pages: [RegistrySettingsPage] = [");
  for (const page of settings.pages) {
    lines.push(`    RegistrySettingsPage(id: ${swiftStr(page.id)}, title: ${L(page.title, page, "title")}, iconId: ${swiftStr(page.icon)}, sfSymbol: ${swiftStr(icons.icons[page.icon].sfSymbol)}, depth: ${page.depth}, platforms: ${optArr(page.platforms)}, featureId: ${swiftStr(page.featureId)}, sections: [`);
    for (const sec of page.sections) {
      lines.push(`      RegistrySettingsSection(id: ${swiftStr(sec.id)}, header: ${LOpt(sec.header, sec, "header")}, footer: ${LOpt(sec.footer, sec, "footer")}, platforms: ${optArr(sec.platforms)}, items: [`);
      for (const item of sec.items) {
        lines.push(`        ${emitItem(item, page)},`);
      }
      lines.push("      ]),");
    }
    lines.push("    ]),");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let pageById: [String: RegistrySettingsPage] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })");
  lines.push("  static let tabById: [String: RegistrySettingsTab] = Dictionary(uniqueKeysWithValues: desktopTabs.map { ($0.id, $0) })");
  lines.push("  private static let allItems: [RegistrySettingsItem] = rootGroups.flatMap(\\.items) + pages.flatMap { $0.sections.flatMap(\\.items) }");
  lines.push("  /// Item by `surface` id (custom surfaces and the account card link).");
  lines.push("  static let itemBySurface: [String: RegistrySettingsItem] = Dictionary(allItems.compactMap { i in i.surface.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })");
  lines.push("  /// `setting` item by settings key.");
  lines.push("  static let itemByKey: [String: RegistrySettingsItem] = Dictionary(allItems.compactMap { i in i.kind == \"setting\" ? i.key.map { ($0, i) } : nil }, uniquingKeysWith: { a, _ in a })");
  lines.push("  /// Section `id` on page `page`.");
  lines.push("  static func section(_ id: String, page: String) -> RegistrySettingsSection? { pageById[page]?.sections.first { $0.id == id } }");
  lines.push("  /// Label of a surface item; the surface id when the registry has none.");
  lines.push("  static func label(surface: String) -> String { itemBySurface[surface]?.label ?? surface }");
  lines.push("  /// Label of a setting item; the key when the registry has none.");
  lines.push("  static func label(key: String) -> String { itemByKey[key]?.label ?? key }");
  for (const fn of settingsTemplates) lines.push(fn);
  // Plain surface copy (`copy` in settings.json). Templates (`{name}`) are
  // read by the runtime-JSON clients; Swift spells those with interpolation.
  lines.push("  /// Plain copy of a settings surface (`copy` in settings.json); the copy id when the registry has none.");
  lines.push("  static func copy(_ surface: String, _ id: String) -> String { copyTable[surface + \".\" + id] ?? id }");
  lines.push("  private static let copyTable: [String: String] = [");
  for (const [owner, entries] of Object.entries(settings.copy ?? {})) {
    for (const e of entries) {
      if (L10N.placeholdersOf(e.label).length > 0) continue;
      lines.push(`    ${swiftStr(`${owner}.${e.id}`)}: ${L(e.label, e, "label")},`);
    }
  }
  lines.push("  ]");
  lines.push("}");
  lines.push("");

  // 6. Destinations
  const emitIdEnum = (typeName, doc, ids) => {
    lines.push(`/// ${doc}`);
    lines.push(`enum ${typeName}: String, CaseIterable, Hashable, Sendable {`);
    const seen = new Set();
    for (const id of ids) {
      const name = swiftCaseName(id);
      assert(!seen.has(name), `${typeName}: IDs collide after Swift case conversion at ${id}`);
      seen.add(name);
      lines.push(`  case ${swiftCaseDecl(id)} = ${swiftStr(id)}`);
    }
    lines.push("}");
    lines.push("");
  };

  emitIdEnum("RegistryDestinationID", "Canonical smart-list IDs (`registry/destinations.json`).", dests.destinations.map((d) => d.id));
  lines.push("/// Canonical smart-list metadata (`registry/destinations.json`).");
  lines.push("struct RegistryDestination: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryDestinationID");
  lines.push("  let navigationKey: String");
  lines.push("  let serverView: String");
  lines.push("  let title: String");
  lines.push("  let iconId: String");
  lines.push("  let sfSymbol: String");
  lines.push("  let sidebarSection: String");
  lines.push("  let visibility: String");
  lines.push("  let canHide: Bool");
  lines.push("  let canMoveSection: Bool");
  lines.push("  /// The list keeps a manual order and takes a Sort By (docs/LIST_SORT_SPEC.md).");
  lines.push("  let supportsManualOrder: Bool");
  lines.push("  let emptyTitle: String");
  lines.push("  let emptyDetail: String");
  lines.push("  let featureId: String");
  lines.push("  /// The list shows on `platform` when its capability ships (ADR 0015).");
  lines.push("  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }");
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
    lines.push(
      `    RegistryDestination(id: ${swiftCaseRef(d.id)}, navigationKey: ${swiftStr(d.navigationKey)}, serverView: ${swiftStr(d.serverView)}, title: ${L(d.title, d, "title")}, iconId: ${swiftStr(d.icon)}, sfSymbol: ${swiftStr(icons.icons[d.icon].sfSymbol)}, sidebarSection: ${swiftStr(d.sidebarSection ?? "top")}, visibility: ${swiftStr(d.visibility)}, canHide: ${d.canHide ? "true" : "false"}, canMoveSection: ${d.canMoveSection ? "true" : "false"}, supportsManualOrder: ${d.supportsManualOrder ? "true" : "false"}, emptyTitle: ${L(d.emptyState.title, d.emptyState, "title")}, emptyDetail: ${L(d.emptyState.detail, d.emptyState, "detail")}, featureId: ${swiftStr(d.featureId)}),`
    );
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let byId: [RegistryDestinationID: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })");
  lines.push("  static let byNavigationKey: [String: RegistryDestination] = Dictionary(uniqueKeysWithValues: all.map { ($0.navigationKey, $0) })");
  lines.push("");
  lines.push("  /// Digit shortcuts in order (`digitShortcuts` in destinations.json): the first");
  lines.push("  /// enabled list in the sidebar takes the first one.");
  lines.push("  static let digitShortcuts: [RegistryShortcut] = [");
  for (let n = 1; n <= dests.digitShortcuts.max; n++) {
    const sc = { key: String(n), modifiers: dests.digitShortcuts.modifiers };
    lines.push(`    RegistryShortcut(key: ${swiftStr(sc.key)}, modifiers: [${sc.modifiers.map(swiftStr).join(", ")}], keycaps: [${appleKeycaps(sc).map(swiftStr).join(", ")}], excludePlatforms: []),`);
  }
  lines.push("  ]");
  lines.push("  /// Only lists with this `visibility` take a digit.");
  lines.push(`  static let digitShortcutVisibility: String = ${swiftStr(dests.digitShortcuts.visibility)}`);
  lines.push("");
  lines.push("  /// Ordered row groups per destination id (`groups` in destinations.json).");
  lines.push("  static let groups: [RegistryDestinationID: [RegistryDestinationGroup]] = [");
  for (const d of dests.destinations) {
    if (!d.groups) continue;
    lines.push(`    ${swiftCaseRef(d.id)}: [`);
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
  emitIdEnum("RegistryActionID", "Canonical action IDs (`registry/actions.json` `actions`).", Object.keys(actions.actions));
  emitIdEnum("RegistryContextMenuID", "Canonical context-menu IDs (`registry/actions.json` `contextMenus`).", Object.keys(actions.contextMenus));
  emitIdEnum("RegistryMenuBarID", "Canonical menu-bar menu IDs (`registry/actions.json` `menuBar`).", actions.menuBar.map((m) => m.id));
  lines.push("/// Generated shortcut-sheet entry (`registry/actions.json`).");
  lines.push("struct RegistryShortcutEntry: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let actionId: RegistryActionID");
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
  lines.push("  let excludeDestinations: [RegistryDestinationID]");
  lines.push("  let onlyDestinations: [RegistryDestinationID]");
  lines.push("  let requiresRecurrence: Bool");
  lines.push("  /// The action's capability (`featureId`); a menu hides it where it does not ship.");
  lines.push("  let featureId: String");
  lines.push("}");
  lines.push("");
  lines.push("/// One item in a context menu or menu-bar menu (`registry/actions.json`).");
  lines.push("/// `kind` is `action`, `destination`, `submenu`, `divider` or `slot` (the shell fills a slot).");
  lines.push("struct RegistryMenuItem: Sendable, Hashable, Identifiable {");
  lines.push("  let kind: String");
  lines.push("  let id: String");
  lines.push("  let actionId: RegistryActionID?");
  lines.push("  let title: String?");
  lines.push("  let sfSymbol: String?");
  lines.push("  let items: [RegistryMenuItem]");
  lines.push("}");
  lines.push("");
  lines.push("/// One menu-bar menu. `system` names the platform menu it merges into (app, file, view, help).");
  lines.push("struct RegistryMenu: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryMenuBarID");
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
      return `RegistryMenuItem(kind: "action", id: ${swiftStr(item.id)}, actionId: ${swiftCaseRef(item.id)}, title: ${L(a[field], a, field)}, sfSymbol: ${swiftStr(icons.icons[a.icon].sfSymbol)}, items: [])`;
    }
    if (item.kind === "destination") {
      const d = destById.get(item.id);
      return `RegistryMenuItem(kind: "destination", id: ${swiftStr(item.id)}, actionId: nil, title: ${L(d.title, d, "title")}, sfSymbol: ${swiftStr(icons.icons[d.icon].sfSymbol)}, items: [])`;
    }
    if (item.kind === "submenu") {
      return `RegistryMenuItem(kind: "submenu", id: ${swiftStr(item.id)}, actionId: nil, title: ${L(item.title, item, "title")}, sfSymbol: ${swiftStr(icons.icons[item.icon].sfSymbol)}, items: [${item.items.map(menuItem).join(", ")}])`;
    }
    if (item.kind === "slot") return `RegistryMenuItem(kind: "slot", id: ${swiftStr(item.slot)}, actionId: nil, title: nil, sfSymbol: nil, items: [])`;
    return `RegistryMenuItem(kind: "divider", id: ${swiftStr(`divider.${idx}`)}, actionId: nil, title: nil, sfSymbol: nil, items: [])`;
  };
  lines.push("enum RegistryActions {");
  lines.push("  static let titles: [RegistryActionID: String] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    lines.push(`    ${swiftCaseRef(id)}: ${L(a.title, a, "title")},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let sfSymbols: [RegistryActionID: String] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    lines.push(`    ${swiftCaseRef(id)}: ${swiftStr(icons.icons[a.icon].sfSymbol)},`);
  }
  lines.push("  ]");
  lines.push("");
  const altFields = ["desktopTitle", "activeTitle", "pluralTitle", "addTitle", "removeTitle", "shortTitle"];
  lines.push("  /// Other titles of an action: `desktopTitle`, `activeTitle` (state on), `pluralTitle`, `addTitle`, `removeTitle`, `shortTitle` (compact buttons).");
  lines.push("  static let alternateTitles: [RegistryActionID: [String: String]] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    const pairs = altFields.filter((f) => typeof a[f] === "string").map((f) => `${swiftStr(f)}: ${L(a[f], a, f)}`);
    if (pairs.length) lines.push(`    ${swiftCaseRef(id)}: [${pairs.join(", ")}],`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let shortcuts: [RegistryActionID: RegistryShortcut] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    if (!a.shortcut) continue;
    const sc = a.shortcut;
    const excl = `[${(sc.excludePlatforms ?? []).map(swiftStr).join(", ")}]`;
    const one = (k) => `RegistryShortcut(key: ${swiftStr(k.key)}, modifiers: [${k.modifiers.map(swiftStr).join(", ")}], keycaps: [${appleKeycaps(k).map(swiftStr).join(", ")}], excludePlatforms: ${excl}`;
    const alts = (sc.alternates ?? []).map((k) => `${one(k)})`);
    lines.push(`    ${swiftCaseRef(id)}: ${one(sc)}${alts.length ? `, alternates: [${alts.join(", ")}]` : ""}),`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  /// The task attribute whose picker an action opens (`opensAttribute`, ADR 0029).");
  lines.push("  /// Every entry point for an attribute (pill, page row, context menu, menu bar,");
  lines.push("  /// shortcut) runs this action, so all of them open the same picker.");
  lines.push("  static let opensAttribute: [RegistryActionID: RegistryTaskAttributeID] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    if (a.opensAttribute !== undefined) lines.push(`    ${swiftCaseRef(id)}: ${swiftCaseRef(a.opensAttribute)},`);
  }
  lines.push("  ]");
  lines.push("  /// The action that opens the picker for `attributeId`, or nil for an attribute with no picker.");
  lines.push("  static func action(opening attributeId: RegistryTaskAttributeID) -> RegistryActionID? {");
  lines.push("    opensAttribute.first(where: { $0.value == attributeId })?.key");
  lines.push("  }");
  lines.push("");
  lines.push("  /// Actions whose `role` is `destructive` (red in menus).");
  lines.push("  static let destructive: Set<RegistryActionID> = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    if (a.role === "destructive") lines.push(`    ${swiftCaseRef(id)},`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let availability: [RegistryActionID: RegistryActionAvailability] = [");
  for (const [id, a] of Object.entries(actions.actions)) {
    const av = a.availability ?? {};
    const arr = (v) => `[${(v ?? []).map(swiftStr).join(", ")}]`;
    const destArr = (v) => `[${(v ?? []).map(swiftCaseRef).join(", ")}]`;
    lines.push(`    ${swiftCaseRef(id)}: RegistryActionAvailability(selection: ${swiftStr(av.selection ?? "any")}, platforms: ${arr(av.platforms)}, excludeDestinations: ${destArr(av.excludeDestinations)}, onlyDestinations: ${destArr(av.onlyDestinations)}, requiresRecurrence: ${av.requiresRecurrence === true}, featureId: ${swiftStr(a.featureId)}),`);
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let contextMenus: [RegistryContextMenuID: [RegistryMenuItem]] = [");
  for (const [name, items] of Object.entries(actions.contextMenus)) {
    lines.push(`    ${swiftCaseRef(name)}: [`);
    items.forEach((it, i) => lines.push(`      ${menuItem(it, i)},`));
    lines.push("    ],");
  }
  lines.push("  ]");
  lines.push("");
  lines.push("  static let menuBar: [RegistryMenu] = [");
  for (const m of actions.menuBar) {
    lines.push(`    RegistryMenu(id: ${swiftCaseRef(m.id)}, title: ${L(m.title, m, "title")}, system: ${swiftOptStr(m.system)}, items: [`);
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
      lines.push(`    RegistryShortcutEntry(id: ${swiftStr(actionId)}, actionId: ${swiftCaseRef(actionId)}, label: ${L(a.title, a, "title")}, keycaps: [${primaryCaps}], excludePlatforms: [${excl}]),`);
      for (const [idx, alt] of (a.shortcut.alternates ?? []).entries()) {
        const altCaps = appleKeycaps(alt).map(swiftStr).join(", ");
        lines.push(`    RegistryShortcutEntry(id: ${swiftStr(`${actionId}.alt${idx}`)}, actionId: ${swiftCaseRef(actionId)}, label: ${L(a.title, a, "title")}, keycaps: [${altCaps}], excludePlatforms: [${excl}]),`);
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

  emitIdEnum("RegistryNoticeID", "Canonical notice IDs (`registry/surfaces.json` `notices`).", surfaces.notices.items.map((n) => n.id));
  lines.push("/// One notice in a task list (`registry/surfaces.json` `notices`). A notice whose");
  lines.push("/// title has a count gets a title function in `RegistryNotices` instead of `title`.");
  lines.push("struct RegistryNotice: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryNoticeID");
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
  lines.push("  /// The `registry/plans.json` upsell this notice shows. Its title and detail");
  lines.push("  /// come from `RegistryPlans.upsell(_:)`, never from this row.");
  lines.push("  let upsellId: String?");
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
  lines.push("  /// The close button's title and accessibility label on every notice.");
  lines.push(`  static let dismissTitle: String = ${L(surfaces.notices.dismissTitle, surfaces.notices, "dismissTitle")}`);
  lines.push("  static let all: [RegistryNotice] = [");
  for (const n of surfaces.notices.items) {
    const title = n.title === undefined || isTmpl(n.title) ? "nil" : L(n.title, n, "title");
    const steps = (n.steps ?? []).map((st) => `RegistryNoticeStep(id: ${swiftStr(st.id)}, title: ${L(st.title, st, "title")}, detail: ${L(st.detail, st, "detail")}, platformDetails: ${platformMap(st)})`).join(", ");
    lines.push(`    RegistryNotice(id: ${swiftCaseRef(n.id)}, kind: ${swiftStr(n.kind)}, priority: ${n.priority}, iconId: ${swiftStr(n.icon)}, sfSymbol: ${swiftStr(icons.icons[n.icon].sfSymbol)}, dismissScope: ${swiftStr(n.dismissScope)}, dismissible: ${Boolean(n.dismissible)}, explainerSlot: ${Boolean(n.explainerSlot)}, featureId: ${swiftStr(n.featureId)}, title: ${title}, detail: ${LOpt(n.detail, n, "detail")}, platformDetails: ${platformMap(n)}, primaryTitle: ${LOpt(n.primaryTitle, n, "primaryTitle")}, upsellId: ${n.upsell === undefined ? "nil" : swiftStr(n.upsell)}, steps: [${steps}]),`);
  }
  lines.push("  ]");
  lines.push("  static let byId: [RegistryNoticeID: RegistryNotice] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })");
  for (const n of surfaces.notices.items) {
    if (n.title !== undefined && isTmpl(n.title)) lines.push(tmplFn(`${n.id}Title`, tmplKey(n.title, n, "title")));
  }
  lines.push("}");
  lines.push("");

  const pr = surfaces.prompts;
  emitIdEnum("RegistryPromptID", "Canonical prompt IDs (`registry/surfaces.json` `prompts`).", [...pr.items, ...pr.text].map((p) => p.id));
  emitIdEnum("RegistryPromptOptionID", "Canonical fork-prompt option IDs (`registry/surfaces.json` `prompts.items[].options`).", [...new Set(pr.items.flatMap((p) => (p.options ?? []).map((o) => o.id)))]);
  lines.push("/// Destructive and fork confirmation copy (`registry/surfaces.json` `prompts`).");
  lines.push("struct RegistryPromptCopy: Sendable, Hashable {");
  lines.push("  let id: RegistryPromptID");
  lines.push("  let title: String");
  lines.push("  let message: String");
  lines.push("  let confirmTitle: String?");
  lines.push("  /// Fork prompts only: the choices, in order.");
  lines.push("  let options: [RegistryPromptOption]");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPromptOption: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryPromptOptionID");
  lines.push("  let title: String");
  lines.push("}");
  lines.push("");
  lines.push("/// A prompt that asks for a name (`registry/surfaces.json` `prompts.text`).");
  lines.push("struct RegistryTextPrompt: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryPromptID");
  lines.push("  let title: String");
  lines.push("  let placeholder: String");
  lines.push("  let confirmTitle: String");
  lines.push("}");
  lines.push("");
  const promptCopy = (p, title, message) => {
    const opts = (p.options ?? []).map((o) => `RegistryPromptOption(id: ${swiftCaseRef(o.id)}, title: ${L(o.title, o, "title")})`).join(", ");
    return `RegistryPromptCopy(id: ${swiftCaseRef(p.id)}, title: ${title}, message: ${message}, confirmTitle: ${LOpt(p.confirmTitle, p, "confirmTitle")}, options: [${opts}])`;
  };
  lines.push("enum RegistryPrompts {");
  lines.push(`  static let cancelTitle: String = ${L(pr.cancelTitle, pr, "cancelTitle")}`);
  lines.push(`  static let errorTitle: String = ${L(pr.error.title, pr.error, "title")}`);
  lines.push(`  static let errorConfirmTitle: String = ${L(pr.error.confirmTitle, pr.error, "confirmTitle")}`);
  lines.push("  /// Prompts with fixed copy. Prompts with counts or names are functions below.");
  lines.push("  static let fixed: [RegistryPromptID: RegistryPromptCopy] = [");
  for (const p of pr.items) {
    if (p.variants || isTmpl(p.title) || isTmpl(p.message)) continue;
    lines.push(`    ${swiftCaseRef(p.id)}: ${promptCopy(p, L(p.title, p, "title"), L(p.message, p, "message"))},`);
  }
  lines.push("  ]");
  lines.push("  static let text: [RegistryPromptID: RegistryTextPrompt] = [");
  for (const t of pr.text) {
    lines.push(`    ${swiftCaseRef(t.id)}: RegistryTextPrompt(id: ${swiftCaseRef(t.id)}, title: ${L(t.title, t, "title")}, placeholder: ${L(t.placeholder, t, "placeholder")}, confirmTitle: ${L(t.confirmTitle, t, "confirmTitle")}),`);
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
  lines.push("  /// How long a snackbar stays (`registry/rules.json` `toastDurationSeconds`).");
  lines.push("  static let durationSeconds: Double = Double(RegistryRules.toastDurationSeconds)");
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

  emitIdEnum("RegistryTaskAttributeID", "Canonical task attribute IDs (`registry/surfaces.json` `taskAttributes`).", surfaces.taskAttributes.map((a) => a.id));
  lines.push("/// One task attribute (`registry/surfaces.json` `taskAttributes`): a composer");
  lines.push("/// pill, an inspector row and a picker title. `surfaceTier` `field` is an");
  lines.push("/// always-visible field (notes), not a pill. `chip` is a transient composer");
  lines.push("/// chip shown only on a blank new task (Paste), not a pill. `editOnly` needs a saved task.");
  lines.push("struct RegistryTaskAttribute: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryTaskAttributeID");
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
  lines.push("  /// The attribute's symbol in its state: the filled variant while set or on.");
  lines.push("  func sfSymbol(on: Bool) -> String { RegistryIcons.sfSymbol(for: iconId, on: on) }");
  lines.push("  /// The attribute shows on `platform` when its capability ships (ADR 0015).");
  lines.push("  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistrySurfaces {");
  lines.push("  static let taskAttributes: [RegistryTaskAttribute] = [");
  for (const a of surfaces.taskAttributes) {
    lines.push(`    RegistryTaskAttribute(id: ${swiftCaseRef(a.id)}, label: ${L(a.label, a, "label")}, iconId: ${swiftStr(a.icon)}, sfSymbol: ${swiftStr(icons.icons[a.icon].sfSymbol)}, commitContract: ${swiftStr(a.commitContract)}, surfaceTier: ${swiftStr(a.surfaceTier)}, featureId: ${swiftStr(a.featureId)}, editOnly: ${a.editOnly === true}, workingLabel: ${LOpt(a.workingLabel, a, "workingLabel")}),`);
  }
  lines.push("  ]");
  lines.push("  /// The pills that show on `platform`, in rail order (every attribute except");
  lines.push("  /// fields and chips, whose capability ships there).");
  lines.push("  static func taskAttributePills(on platform: String) -> [RegistryTaskAttribute] {");
  lines.push("    taskAttributes.filter { $0.isPill && $0.applies(to: platform) }");
  lines.push("  }");
  lines.push("  /// The attribute with `id`.");
  lines.push("  static func taskAttribute(_ id: RegistryTaskAttributeID) -> RegistryTaskAttribute {");
  lines.push("    guard let a = taskAttributes.first(where: { $0.id == id }) else { preconditionFailure(\"unknown task attribute \\(id)\") }");
  lines.push("    return a");
  lines.push("  }");
  lines.push("  /// Count text for a pill value (`countLabel`), or nil when the attribute has none.");
  lines.push("  static func taskAttributeCount(_ id: RegistryTaskAttributeID, count: Int) -> String? {");
  lines.push("    switch id {");
  for (const a of surfaces.taskAttributes) {
    if (a.countLabel === undefined) continue;
    lines.push(`    case ${swiftCaseRef(a.id)}: return ${L10N.swiftTemplate(BY_KEY, tmplKey(a.countLabel, a, "countLabel")).body}`);
  }
  lines.push("    default: return nil");
  lines.push("    }");
  lines.push("  }");
  // The task page (ADR 0029): ordered blocks, each shown at the depths it names.
  const attrLabel = new Map(surfaces.taskAttributes.map((a) => [a.id, L(a.label, a, "label")]));
  lines.push("  /// The task page (`surfaces.json` `taskPage`, ADR 0029) in block order.");
  lines.push("  static let taskPageBlocks: [RegistryTaskPageBlock] = [");
  for (const b of surfaces.taskPage.blocks) {
    const label = b.label !== undefined ? L(b.label, b, "label") : b.attribute !== undefined ? attrLabel.get(b.attribute) : "nil";
    lines.push(`    RegistryTaskPageBlock(id: ${swiftStr(b.id)}, kind: .${b.kind}, depths: [${b.depths.map((d) => "." + d).join(", ")}], label: ${label}, attributeId: ${b.attribute === undefined ? "nil" : swiftCaseRef(b.attribute)}, featureId: ${swiftStr(b.featureId)}, editOnly: ${b.editOnly === true}),`);
  }
  lines.push("  ]");
  lines.push("  /// The blocks a host renders at `depth` on `platform`, in order. A create");
  lines.push("  /// (no saved task yet) passes `isEditing: false` to drop `editOnly` blocks.");
  lines.push("  static func taskPageBlocks(_ depth: RegistryTaskPageDepth, on platform: String, isEditing: Bool = true) -> [RegistryTaskPageBlock] {");
  lines.push("    taskPageBlocks.filter { $0.depths.contains(depth) && $0.applies(to: platform) && (isEditing || !$0.editOnly) }");
  lines.push("  }");
  lines.push("  /// The rows under the date board's day strip, in order (`surfaces.json` `taskDateBoard`).");
  lines.push("  static let dateBoardRows: [RegistryDateBoardRow] = [");
  for (const r of surfaces.taskDateBoard.rows) {
    const action = actions.actions[r.action];
    const label = action ? L(action.title, action, "title") : L(r.label, r, "label");
    const own = (r.attributeLabels ?? []).map((l) => `.${l.attribute}: ${L(l.label, l, "label")}`).join(", ");
    lines.push(`    RegistryDateBoardRow(id: ${swiftStr(r.id)}, kind: .${r.kind}, group: .${r.group}, label: ${label}, attributeLabels: [${own || ":"}], sfSymbol: ${swiftStr(icons.icons[r.icon].sfSymbol)}, attributes: [${r.attributes.map((a) => "." + a).join(", ")}], featureId: ${swiftStr(r.featureId)}),`);
  }
  lines.push("  ]");
  lines.push("  static func dateBoardRows(for attribute: RegistryDateBoardAttribute, on platform: String) -> [RegistryDateBoardRow] {");
  lines.push("    dateBoardRows.filter { $0.applies(to: attribute, on: platform) }");
  lines.push("  }");
  lines.push(`  static let taskDateBoardOverdueLabel: String = ${L(surfaces.taskDateBoard.overdue.label, surfaces.taskDateBoard.overdue, "label")}`);
  const cal = surfaces.taskDateBoard.rows.find((r) => r.kind === "calendar");
  lines.push("  /// The calendar row when the task has a date past the day strip.");
  lines.push(tmplFn("dateBoardCalendarLabel", tmplKey(cal.valueLabel, cal, "valueLabel")));
  const tmrw = surfaces.taskDateBoard.tomorrow;
  lines.push("  /// The word for the day after today, in date labels.");
  lines.push(`  static let tomorrowLabel: String = ${L(tmrw.label, tmrw, "label")}`);
  const prov = surfaces.taskPage.blocks.find((b) => b.kind === "provenance");
  lines.push("  /// Provenance block (`taskPage.provenance`): the name a task you added shows as,");
  lines.push("  /// the name for an agent row with no `sourceClient`, and the agent glyph.");
  lines.push(`  static let provenanceSelfLabel: String = ${L(prov.selfLabel, prov, "selfLabel")}`);
  lines.push(`  static let provenanceAgentFallbackName: String = ${swiftStr(prov.agentFallbackName)}`);
  lines.push(`  static let provenanceAgentSymbol: String = ${swiftStr(icons.icons[prov.icon].sfSymbol)}`);
  const convoBlock = surfaces.taskPage.blocks.find((b) => b.kind === "conversation");
  lines.push("  /// Agent prompt copy (`taskPage.conversation`, docs/AGENT_PROMPT_SPEC.md).");
  for (const k of ["askKicker", "reviewKicker", "reviewFallback", "acceptedLabel"]) {
    lines.push(`  static let agentPrompt${k[0].toUpperCase()}${k.slice(1)}: String = ${L(convoBlock[k], convoBlock, k)}`);
  }
  lines.push("  /// The weekly fade sweep's title (`surfaces.json` `fadeSweep`).");
  lines.push(`  static let fadeSweepTitle: String = ${L(surfaces.fadeSweep.title, surfaces.fadeSweep, "title")}`);
  const qf = surfaces.quickFind;
  lines.push("  /// Quick Find copy (`surfaces.json` `quickFind`).");
  lines.push(`  static let quickFindPlaceholder: String = ${L(qf.placeholder, qf, "placeholder")}`);
  lines.push(`  static let quickFindCommandPlaceholder: String = ${L(qf.commandPlaceholder, qf, "commandPlaceholder")}`);
  lines.push(`  static let quickFindEmptyTitle: String = ${L(qf.emptyState.title, qf.emptyState, "title")}`);
  lines.push(`  static let quickFindEmptyDetail: String = ${L(qf.emptyState.detail, qf.emptyState, "detail")}`);
  lines.push(`  static let quickFindCompletedLabel: String = ${L(qf.completed.label, qf.completed, "label")}`);
  const ls = surfaces.listSort;
  lines.push("  /// Sort By copy (`surfaces.json` `listSort`, docs/LIST_SORT_SPEC.md).");
  lines.push(`  static let listSortMenuTitle: String = ${L(ls.menuTitle, ls, "menuTitle")}`);
  lines.push(`  static let listSortSymbol: String = ${swiftStr(icons.icons[ls.icon].sfSymbol)}`);
  lines.push("  /// \"Sorted by {sort}\": the list header line when the sort is not Manual.");
  lines.push(tmplFn("listSortSortedBy", tmplKey(ls.sortedBy, ls, "sortedBy")));
  lines.push("  /// The block of `kind`. Each kind appears exactly once (the generator checks it).");
  lines.push("  static func taskPageBlock(_ kind: RegistryTaskPageBlockKind) -> RegistryTaskPageBlock {");
  lines.push("    guard let b = taskPageBlocks.first(where: { $0.kind == kind }) else { preconditionFailure(\"no task page block \\(kind)\") }");
  lines.push("    return b");
  lines.push("  }");
  lines.push("}");
  lines.push("");
  lines.push("/// The attributes that the date board edits.");
  lines.push("enum RegistryDateBoardAttribute: String, Sendable, Hashable {");
  for (const a of DATE_BOARD_ATTRIBUTES) lines.push(`  case ${a}`);
  lines.push("}");
  lines.push("");
  lines.push("/// The closed set of date board rows. Each platform writes one handler per kind.");
  lines.push("enum RegistryDateBoardRowKind: String, Sendable, Hashable {");
  for (const k of DATE_BOARD_ROW_KINDS) lines.push(`  case ${k}`);
  lines.push("}");
  lines.push("");
  lines.push("/// The date board's row groups, in order. The day strip opens `pick`; a divider separates groups.");
  lines.push("enum RegistryDateBoardGroup: String, Sendable, Hashable {");
  for (const g of DATE_BOARD_GROUPS) lines.push(`  case ${g}`);
  lines.push("}");
  lines.push("");
  lines.push("/// One row under the date board's day strip (`surfaces.json` `taskDateBoard.rows`).");
  lines.push("struct RegistryDateBoardRow: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let kind: RegistryDateBoardRowKind");
  lines.push("  let group: RegistryDateBoardGroup");
  lines.push("  let label: String");
  lines.push("  /// Attribute → label that replaces `label` in that attribute's picker.");
  lines.push("  let attributeLabels: [RegistryDateBoardAttribute: String]");
  lines.push("  let sfSymbol: String");
  lines.push("  let attributes: [RegistryDateBoardAttribute]");
  lines.push("  let featureId: String");
  lines.push("  func label(for attribute: RegistryDateBoardAttribute) -> String { attributeLabels[attribute] ?? label }");
  lines.push("  /// The row shows in `attribute`'s picker on `platform` when its capability ships there (ADR 0015).");
  lines.push("  func applies(to attribute: RegistryDateBoardAttribute, on platform: String) -> Bool {");
  lines.push("    attributes.contains(attribute) && RegistryCapabilities.isAvailable(featureId, on: platform)");
  lines.push("  }");
  lines.push("}");
  lines.push("");
  lines.push("/// The closed set of task page block kinds (ADR 0029). Each platform writes one renderer per kind.");
  lines.push("enum RegistryTaskPageBlockKind: String, Sendable, Hashable, CaseIterable {");
  for (const k of TASK_PAGE_BLOCK_KINDS) lines.push(`  case ${k}`);
  lines.push("}");
  lines.push("");
  lines.push("/// Where a task page block shows: `inline` (the quick edit in the row), `page` (the full task page), or `review` (the page of a task waiting for the user to accept it).");
  lines.push("enum RegistryTaskPageDepth: String, Sendable, Hashable {");
  for (const d of TASK_PAGE_DEPTHS) lines.push(`  case ${d}`);
  lines.push("}");
  lines.push("");
  lines.push("/// One block of the task page (`surfaces.json` `taskPage.blocks`). `label` is the");
  lines.push("/// section heading (its own, or its attribute's); nil for header, notes and attributes.");
  lines.push("struct RegistryTaskPageBlock: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let kind: RegistryTaskPageBlockKind");
  lines.push("  let depths: [RegistryTaskPageDepth]");
  lines.push("  let label: String?");
  lines.push("  let attributeId: RegistryTaskAttributeID?");
  lines.push("  let featureId: String");
  lines.push("  let editOnly: Bool");
  lines.push("  /// The block shows on `platform` when its capability ships there (ADR 0015).");
  lines.push("  func applies(to platform: String) -> Bool { RegistryCapabilities.isAvailable(featureId, on: platform) }");
  lines.push("}");
  lines.push("");

  // 8a. References (surfaces.json `taskReferences`)
  const refs = surfaces.taskReferences;
  const refTmpl = (node) => L10N.swiftTemplate(BY_KEY, tmplKey(node.format, node, "format"));
  const refKind = (id, k) => `RegistryTaskReferenceKind(id: ${swiftStr(id)}, label: ${L(k.label, k, "label")}, sfSymbol: ${swiftStr(icons.icons[k.icon].sfSymbol)})`;
  lines.push("/// The label and the symbol of one reference kind (`surfaces.json` `taskReferences.kinds`).");
  lines.push("struct RegistryTaskReferenceKind: Sendable, Hashable {");
  lines.push("  let id: String");
  lines.push("  let label: String");
  lines.push("  let sfSymbol: String");
  lines.push("}");
  lines.push("");
  lines.push("/// Task references (`surfaces.json` `taskReferences`, docs/TASK_REFERENCES_SPEC.md §8).");
  lines.push("enum RegistryTaskReferences {");
  lines.push("  static let kinds: [RegistryTaskReferenceKind] = [");
  for (const [id, k] of Object.entries(refs.kinds)) lines.push(`    ${refKind(id, k)},`);
  lines.push("  ]");
  lines.push("  /// A kind this build does not know.");
  lines.push(`  static let otherKind: RegistryTaskReferenceKind = ${refKind("", refs.otherKind)}`);
  lines.push("  static func kind(_ id: String) -> RegistryTaskReferenceKind { kinds.first { $0.id == id } ?? otherKind }");
  lines.push("  /// The label of a role that shows one, by role.");
  lines.push(`  static let roleLabels: [String: String] = [${Object.entries(refs.roles).map(([id, r]) => `${swiftStr(id)}: ${L(r.label, r, "label")}`).join(", ")}]`);
  for (const [name, node] of [["open", refs.open], ["createdFrom", refs.createdFrom], ["limitReached", refs.add.limitReached], ["suggestion", refs.add.suggestions], ["alsoIn", refs.alsoIn]]) {
    const t = refTmpl(node);
    lines.push(`  static func ${name}(${t.params}) -> String { ${t.body} }`);
  }
  for (const [name, node, field] of [
    ["addPlaceholder", refs.add, "placeholder"], ["addConfirmTitle", refs.add, "confirmTitle"],
    ["offersTitle", refs.add.offers, "title"], ["invalidMessage", refs.add.invalid, "message"],
    ["failedMessage", refs.add.failed, "message"], ["alreadyTaskTitle", refs.alreadyTask, "title"],
  ]) lines.push(`  static let ${name}: String = ${L(node[field], node, field)}`);
  lines.push("  /// The most links of one task's title and notes that show as suggestions.");
  lines.push(`  static let maxSuggestions = ${refs.add.suggestions.max}`);
  lines.push("}");
  lines.push("");

  // 8a. Do (surfaces.json `doing`, docs/DO_SPEC.md)
  const doing = surfaces.doing;
  lines.push("/// Do: one task now (`registry/surfaces.json` `doing`, docs/DO_SPEC.md §3 to §5).");
  lines.push("enum RegistryDoing {");
  lines.push("  /// The lengths offered, in minutes.");
  lines.push(`  static let lengths: [Int] = [${doing.lengths.join(", ")}]`);
  for (const [name, node, field] of [
    ["lastTimeTitle", doing.screen.lastTime, "title"], ["firstStepTitle", doing.screen.firstStep, "title"],
    ["lengthTitle", doing.screen.length, "title"], ["noLengthTitle", doing.screen.length.noneTitle, "title"],
    ["stopNoteTitle", doing.stopNote, "title"], ["stopNoteSaveTitle", doing.stopNote, "confirmTitle"],
    ["stopNoteSkipTitle", doing.stopNote, "dismissTitle"], ["openExitLabel", doing.openExit, "label"],
  ]) lines.push(`  static let ${name}: String = ${L(node[field], node, field)}`);
  for (const [name, node] of [
    ["lengthOption", doing.screen.length.option], ["notice", doing.notice], ["stale", doing.stale],
    ["plannedEnd", doing.plannedEnd], ["needsYou", doing.needsYou],
  ]) {
    const t = L10N.swiftTemplate(BY_KEY, tmplKey(node.format, node, "format"));
    lines.push(`  static func ${name}(${t.params}) -> String { ${t.body} }`);
  }
  lines.push("  /// The label of an exit (`doExit`) in the history.");
  lines.push(`  static let exitLabels: [String: String] = [${Object.entries(doing.exits).map(([id, e]) => `${swiftStr(id)}: ${L(e.label, e, "label")}`).join(", ")}]`);
  lines.push("}");
  lines.push("");

  // 8a. Waiting (surfaces.json `waiting`, docs/REVIEW_SPEC.md §6)
  const waiting = surfaces.waiting;
  lines.push("/// Waiting on a person (`registry/surfaces.json` `waiting`, docs/REVIEW_SPEC.md §6).");
  lines.push("enum RegistryWaiting {");
  {
    const t = L10N.swiftTemplate(BY_KEY, tmplKey(waiting.label.format, waiting.label, "format"));
    lines.push(`  static func label(${t.params}) -> String { ${t.body} }`);
  }
  for (const [name, node, field] of [
    ["sheetTitle", waiting.sheet, "title"], ["namePlaceholder", waiting.sheet, "placeholder"],
    ["confirmTitle", waiting.sheet, "confirmTitle"], ["checkBackTitle", waiting.sheet.checkBack, "title"],
    ["noCheckBackTitle", waiting.sheet.noCheckBack, "title"],
  ]) lines.push(`  static let ${name}: String = ${L(node[field], node, field)}`);
  lines.push("  /// The check-back date Waiting On… offers, in days from today.");
  lines.push(`  static let defaultCheckBackDays = ${waiting.defaultCheckBackDays}`);
  lines.push("}");
  lines.push("");

  // 8a. Project and area notes (surfaces.json `placeNotes`)
  const placeNotes = surfaces.placeNotes;
  lines.push("/// The notes on a project's or an area's page (`registry/surfaces.json` `placeNotes`).");
  lines.push("enum RegistryPlaceNotes {");
  lines.push("  /// Lines of the folded notes.");
  lines.push(`  static let previewLines = ${placeNotes.previewLines}`);
  for (const key of ["showMore", "showLess"]) {
    lines.push(`  static let ${key}Title: String = ${L(placeNotes[key].title, placeNotes[key], "title")}`);
  }
  lines.push("}");
  lines.push("");

  // 8a. Shared projects (surfaces.json `sharing`, docs/PROJECT_SHARING_SPEC.md)
  const sharing = surfaces.sharing;
  lines.push("/// Shared projects (`registry/surfaces.json` `sharing`).");
  lines.push("enum RegistrySharing {");
  lines.push(`  static let title: String = ${L(sharing.title, sharing, "title")}`);
  for (const e of sharing.copy) lines.push(`  static let ${e.id}: String = ${L(e.label, e, "label")}`);
  lines.push("}");
  lines.push("");

  // 8a. Sign-in by device approval (surfaces.json `deviceSignIn`, ADR 0016)
  const deviceSignIn = surfaces.deviceSignIn;
  lines.push("/// Sign-in by device approval (`registry/surfaces.json` `deviceSignIn`).");
  lines.push("enum RegistryDeviceSignIn {");
  lines.push(`  static let title: String = ${L(deviceSignIn.title, deviceSignIn, "title")}`);
  for (const e of deviceSignIn.copy) lines.push(`  static let ${e.id}: String = ${L(e.label, e, "label")}`);
  lines.push("}");
  lines.push("");

  // 8a'. Signing in with another account (surfaces.json `accountSwitch`, #575)
  const accountSwitch = surfaces.accountSwitch;
  lines.push("/// The question before a sign-in replaces another account's tasks (`registry/surfaces.json` `accountSwitch`).");
  lines.push("enum RegistryAccountSwitch {");
  lines.push(`  static let title: String = ${L(accountSwitch.title, accountSwitch, "title")}`);
  for (const e of accountSwitch.copy) lines.push(`  static let ${e.id}: String = ${L(e.label, e, "label")}`);
  lines.push("}");
  lines.push("");

  // 8a''. Contact Support (surfaces.json `support`, ADR 0054)
  const supportCopy = surfaces.support;
  lines.push("/// Contact Support's screen (`registry/surfaces.json` `support`, ADR 0054).");
  lines.push("enum RegistrySupport {");
  lines.push(`  static let title: String = ${L(supportCopy.title, supportCopy, "title")}`);
  for (const e of supportCopy.copy) lines.push(`  static let ${e.id}: String = ${L(e.label, e, "label")}`);
  lines.push("}");
  lines.push("");

  // 8b. First run (surfaces.json `firstRun`)
  const fr = surfaces.firstRun;
  emitIdEnum("RegistryFirstRunStepID", "Canonical first-run step IDs (`registry/surfaces.json` `firstRun.steps`).", fr.steps.map((s) => s.id));
  emitIdEnum("RegistryFirstRunActionID", "Canonical first-run button action IDs (`registry/surfaces.json` `firstRun.steps`).", [...FIRST_RUN_ACTIONS]);
  const frButton = (b) => (b === undefined ? "nil" : `RegistryFirstRunButton(title: ${L(b.title, b, "title")}, action: ${swiftCaseRef(b.action)})`);
  lines.push("/// One button in the first run. `action` is one of a closed set the client implements.");
  lines.push("struct RegistryFirstRunButton: Sendable, Hashable {");
  lines.push("  let title: String");
  lines.push("  let action: RegistryFirstRunActionID");
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
  lines.push("  let action: RegistryFirstRunActionID");
  lines.push("  let platforms: [String]");
  lines.push("}");
  lines.push("");
  lines.push("/// One first-run step (`registry/surfaces.json` `firstRun.steps`). `kind` picks the view.");
  lines.push("struct RegistryFirstRunStep: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistryFirstRunStepID");
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
  lines.push("  /// The platforms this step shows on; empty means every platform.");
  lines.push("  let platforms: [String]");
  lines.push("  /// The step shows only where this capability ships (`RegistryCapabilities.isAvailable`).");
  lines.push("  let featureId: String?");
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
    const choices = (st.choices ?? []).map((ch) => `RegistryFirstRunChoice(id: ${swiftStr(ch.id)}, icon: ${swiftStr(ch.icon)}, title: ${L(ch.title, ch, "title")}, detail: ${L(ch.detail, ch, "detail")}, action: ${swiftCaseRef(ch.action)}, platforms: [${(ch.platforms ?? []).map(swiftStr).join(", ")}])`).join(", ");
    const instructions = (st.instructions ?? []).map((s) => L(s)).join(", ");
    lines.push(`    RegistryFirstRunStep(id: ${swiftCaseRef(st.id)}, kind: ${swiftStr(st.kind)}, icon: ${swiftStr(st.icon)}, title: ${L(st.title, st, "title")}, body: ${st.body === undefined ? '""' : L(st.body, st, "body")}, footnote: ${LOpt(st.footnote, st, "footnote")}, returningTitle: ${LOpt(st.returningTitle, st, "returningTitle")}, returningBody: ${LOpt(st.returningBody, st, "returningBody")}, skipWhen: ${swiftOptStr(st.skipWhen)}, requires: ${swiftOptStr(st.requires)}, completesGetStartedStep: ${swiftOptStr(st.completesGetStartedStep)}, platforms: [${(st.platforms ?? []).map(swiftStr).join(", ")}], featureId: ${swiftOptStr(st.featureId)}, points: [${points}], choices: [${choices}], instructions: [${instructions}], primary: ${frButton(st.primary)}, secondary: ${frButton(st.secondary)}, tertiary: ${frButton(st.tertiary)}, afterDone: ${frButton(st.afterDone)}),`);
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
  lines.push("/// One-time non-renewing pass for Plus (ADR 0061).");
  lines.push("struct RegistryPlanPass: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let plan: String");
  lines.push("  let productId: String");
  lines.push("  let years: Int");
  lines.push("  let amountMinor: Int");
  lines.push("  let currency: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("  let label: String");
  lines.push("  let rateDetail: String");
  lines.push("  let action: String");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanCard: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  /// Registry icon id (icons.json).");
  lines.push("  let icon: String");
  lines.push("  let detail: String");
  lines.push("  let footnote: String?");
  lines.push("  let highlighted: Bool");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanRow: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let label: String");
  lines.push("  let planned: Bool");
  lines.push("  let free: RegistryPlanCell");
  lines.push("  let plus: RegistryPlanCell");
  lines.push("  let pro: RegistryPlanCell");
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
  lines.push("/// One benefit of a paid plan (`benefits` in plans.json, docs/PREMIUM_LANGUAGE.md).");
  lines.push("struct RegistryPlanBenefit: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  /// Registry icon id (icons.json); its tile color is `AppearancePreferences.glyphSwiftUIColor`.");
  lines.push("  let icon: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("}");
  lines.push("");
  lines.push("struct RegistryPlanNote: Sendable, Hashable, Identifiable {");
  lines.push("  let id: String");
  lines.push("  let title: String");
  lines.push("  let detail: String");
  lines.push("  /// For an upsell moment: the plan that answers it (`plus` or `pro`). The paywall opens on it.");
  lines.push("  var plan: String? = nil");
  lines.push("}");
  lines.push("");
  lines.push("/// Plans and pricing (`registry/plans.json`). The site's /pricing page reads the same file.");
  lines.push("enum RegistryPlans {");
  for (const f of ["name", "shortName", "proName", "headline", "subhead"]) lines.push(`  static var ${f}: String { ${L(P[f], P, f)} }`);
  lines.push(`  static let checkoutOpen = ${P.checkout.open}`);
  lines.push(`  static var checkoutNotice: String { ${L(P.checkout.notice, P.checkout, "notice")} }`);
  lines.push(`  static let trialDays = ${P.trial.days}`);
  lines.push(`  static var trialTitle: String { ${L(P.trial.title, P.trial, "title")} }`);
  lines.push(`  static var trialDetail: String { ${L(P.trial.detail, P.trial, "detail")} }`);
  lines.push(`  static var priceFootnote: String { ${L(P.priceFootnote, P, "priceFootnote")} }`);
  lines.push("  static var prices: [RegistryPlanPrice] { [");
  for (const pr of P.prices) lines.push(`    RegistryPlanPrice(id: ${swiftStr(pr.id)}, productId: ${swiftStr(pr.productId)}, amountMinor: ${pr.amountMinor}, currency: ${swiftStr(pr.currency)}, interval: ${swiftStr(pr.interval)}, highlighted: ${pr.highlighted}, label: ${L(pr.label, pr, "label")}, detail: ${L(pr.detail, pr, "detail")}),`);
  lines.push("  ] }");
  lines.push("  /// What Pro costs (ADR 0059): the higher level of the same subscription group.");
  lines.push("  static var proPrices: [RegistryPlanPrice] { [");
  for (const pr of P.proPrices) lines.push(`    RegistryPlanPrice(id: ${swiftStr(pr.id)}, productId: ${swiftStr(pr.productId)}, amountMinor: ${pr.amountMinor}, currency: ${swiftStr(pr.currency)}, interval: ${swiftStr(pr.interval)}, highlighted: ${pr.highlighted}, label: ${L(pr.label, pr, "label")}, detail: ${L(pr.detail, pr, "detail")}),`);
  lines.push("  ] }");
  lines.push("  /// The 7-Year Plus Pass (ADR 0061): one-time Non-Renewing Subscription, Plus only.");
  lines.push(`  static var pass: RegistryPlanPass { RegistryPlanPass(id: ${swiftStr(P.pass.id)}, plan: ${swiftStr(P.pass.plan)}, productId: ${swiftStr(P.pass.productId)}, years: ${P.pass.years}, amountMinor: ${P.pass.amountMinor}, currency: ${swiftStr(P.pass.currency)}, title: ${L(P.pass.title, P.pass, "title")}, detail: ${L(P.pass.detail, P.pass, "detail")}, label: ${L(P.pass.label, P.pass, "label")}, rateDetail: ${L(P.pass.rateDetail, P.pass, "rateDetail")}, action: ${L(P.pass.action, P.pass, "action")}) }`);
  for (const tier of ["plus", "pro"]) {
    lines.push(`  static var ${tier}Benefits: [RegistryPlanBenefit] { [`);
    for (const b of P.benefits[tier]) lines.push(`    RegistryPlanBenefit(id: ${swiftStr(b.id)}, icon: ${swiftStr(b.icon)}, title: ${L(b.title, b, "title")}, detail: ${L(b.detail, b, "detail")}),`);
    lines.push("  ] }");
  }
  lines.push("  /// The full comparison of every plan, on the website.");
  lines.push(`  static let compareURL = URL(string: ${swiftStr(P.compareURL)})!`);
  lines.push("  /// The rows every plan card lists (`cardRows`), in order.");
  lines.push(`  static let cardRowIDs: [String] = [${P.cardRows.map(swiftStr).join(", ")}]`);
  lines.push("  static var cards: [RegistryPlanCard] { [");
  const cardSwift = (c) => `RegistryPlanCard(id: ${swiftStr(c.id)}, title: ${L(c.title, c, "title")}, icon: ${swiftStr(c.icon)}, detail: ${L(c.detail, c, "detail")}, footnote: ${LOpt(c.footnote, c, "footnote")}, highlighted: ${c.highlighted === true})`;
  for (const c of P.cards.filter((c) => c.status === undefined)) lines.push(`    ${cardSwift(c)},`);
  lines.push("  ] }");
  lines.push("  /// The Pro card, for an account that has Pro. The paywalls offer it in #719 (ADR 0059).");
  lines.push(`  static var proCard: RegistryPlanCard { ${cardSwift(P.cards.find((c) => c.id === "pro"))} }`);
  lines.push("  static var outcomes: [RegistryPlanOutcome] { [");
  for (const o of P.outcomes) {
    const rows = o.rows.map((r) => `RegistryPlanRow(id: ${swiftStr(r.id)}, label: ${L(r.label, r, "label")}, planned: ${r.status === "planned"}, free: ${cellSwift(r.cells.free, r, "free")}, plus: ${cellSwift(r.cells.plus, r, "plus")}, pro: ${cellSwift(r.cells.pro, r, "pro")})`).join(",\n      ");
    lines.push(`    RegistryPlanOutcome(id: ${swiftStr(o.id)}, icon: ${swiftStr(o.icon)}, title: ${L(o.title, o, "title")}, detail: ${L(o.detail, o, "detail")}, rows: [\n      ${rows},\n    ]),`);
  }
  lines.push("  ] }");
  for (const list of ["promises", "upsells"]) {
    lines.push(`  static var ${list}: [RegistryPlanNote] { [`);
    for (const n of P[list]) lines.push(`    RegistryPlanNote(id: ${swiftStr(n.id)}, title: ${L(n.title, n, "title")}, detail: ${L(n.detail, n, "detail")}${n.plan ? `, plan: ${swiftStr(n.plan)}` : ""}),`);
    lines.push("  ] }");
  }
  lines.push("  static func card(_ id: String) -> RegistryPlanCard? { cards.first { $0.id == id } }");
  lines.push("  static func upsell(_ id: String) -> RegistryPlanNote? { upsells.first { $0.id == id } }");
  lines.push("  /// The paywall's Terms of Use and Privacy Policy links (App Review 3.1.2).");
  lines.push(`  static let termsURL = URL(string: ${swiftStr(P.legal.terms)})!`);
  lines.push(`  static let privacyURL = URL(string: ${swiftStr(P.legal.privacy)})!`);
  lines.push("");
  lines.push("  enum Action {");
  for (const [k, v] of Object.entries(P.actions)) lines.push(`    static var ${k}: String { ${L(v, P.actions, k)} }`);
  lines.push("  }");
  lines.push("");
  lines.push("  enum Copy {");
  for (const [k, v] of Object.entries(P.labels)) lines.push(`    static var ${k}: String { ${L(v, P.labels, k)} }`);
  lines.push("  }");
  lines.push("");
  // Status and the Plus sheet's words (spec §7.1): a value with a
  // placeholder becomes a function taking it.
  for (const [name, block] of [["Status", P.status], ["Paywall", P.paywall]]) {
    lines.push(`  enum ${name} {`);
    for (const [k, v] of Object.entries(block)) {
      if (k === "l10nKeys") continue;
      if (/\{[a-zA-Z]/.test(v)) {
        const t = L10N.swiftTemplate(BY_KEY, block.l10nKeys?.[k] ?? v);
        lines.push(`    static func ${k}(${t.params}) -> String { ${t.body} }`);
      } else {
        lines.push(`    static var ${k}: String { ${L(v, block, k)} }`);
      }
    }
    lines.push("  }");
    if (name === "Status") lines.push("");
  }
  lines.push("}");
  lines.push("");

  // 11. Sign-in methods and the sign-in screen (sign-in.json, ADR 0047).
  const SI = bundle.signIn;
  const swiftBlock = (block, indent = "    ") => {
    for (const [k, v] of Object.entries(block)) {
      if (k === "l10nKeys") continue;
      const isPl = typeof v === "object";
      if (isPl || /\{[a-zA-Z]/.test(v)) {
        const t = L10N.swiftTemplate(BY_KEY, block.l10nKeys?.[k] ?? (isPl ? v.other : v));
        lines.push(`${indent}static func ${k}(${t.params}) -> String { ${t.body} }`);
      } else {
        lines.push(`${indent}static var ${k}: String { ${L(v, block, k)} }`);
      }
    }
  };
  lines.push("/// How a platform offers a sign-in method (`registry/sign-in.json`).");
  lines.push("enum RegistrySignInFlow: String, Sendable {");
  lines.push("  /// The platform's own flow. For email and device, the client draws the form.");
  lines.push("  case native");
  lines.push("  /// A redirect through api.septena.app in the system browser sheet.");
  lines.push("  case web");
  lines.push("  /// The platform cannot offer the method.");
  lines.push('  case unavailable = "none"');
  lines.push("}");
  lines.push("");
  lines.push("enum RegistrySignInMethodId: String, Sendable, CaseIterable {");
  for (const m of SI.methods) lines.push(`  case ${swiftCaseDecl(m.id)} = ${swiftStr(m.id)}`);
  lines.push("}");
  lines.push("");
  lines.push("struct RegistrySignInMethod: Sendable, Hashable, Identifiable {");
  lines.push("  let id: RegistrySignInMethodId");
  lines.push("  /// `provider`, `email` or `device`.");
  lines.push("  let kind: String");
  lines.push("  /// The provider's name for copy (`{provider}`); nil for email and device.");
  lines.push("  let name: String?");
  lines.push("  let title: String");
  lines.push("  /// Registry icon id (icons.json).");
  lines.push("  let icon: String");
  lines.push("  /// False only for device approval: it needs an account that exists.");
  lines.push("  let createsAccount: Bool");
  lines.push("  let featureId: String");
  lines.push("  /// Flow by platform id (`ios`, `ipados`, `macos`, ...).");
  lines.push("  let flows: [String: RegistrySignInFlow]");
  lines.push("}");
  lines.push("");
  lines.push("/// The sign-in screen (`registry/sign-in.json`, ADR 0047). It is also the");
  lines.push("/// create-account screen. The backend's GET /v1/auth/methods says which");
  lines.push("/// methods are on; hide the others.");
  lines.push("enum RegistrySignIn {");
  lines.push("  static var methods: [RegistrySignInMethod] { [");
  for (const m of SI.methods) {
    const flows = SI.platforms.map((p) => `${swiftStr(p)}: .${m.flows[p] === "none" ? "unavailable" : m.flows[p]}`).join(", ");
    lines.push(`    RegistrySignInMethod(id: ${swiftCaseRef(m.id)}, kind: ${swiftStr(m.kind)}, name: ${swiftOptStr(m.name)}, title: ${L(m.title, m, "title")}, icon: ${swiftStr(m.icon)}, createsAccount: ${m.createsAccount}, featureId: ${swiftStr(m.featureId)}, flows: [${flows}]),`);
  }
  lines.push("  ] }");
  lines.push("  /// Method order by platform id: the platform's provider, the other providers, email, device.");
  lines.push("  static let order: [String: [RegistrySignInMethodId]] = [");
  for (const p of SI.platforms) lines.push(`    ${swiftStr(p)}: [${SI.order[p].map(swiftCaseRef).join(", ")}],`);
  lines.push("  ]");
  lines.push("  static func method(_ id: RegistrySignInMethodId) -> RegistrySignInMethod? { methods.first { $0.id == id } }");
  lines.push("  /// The methods `platform` offers, in screen order.");
  lines.push("  static func methods(on platform: String) -> [RegistrySignInMethod] {");
  lines.push("    let all = methods");
  lines.push("    return (order[platform] ?? []).compactMap { id in all.first { $0.id == id } }");
  lines.push("  }");
  lines.push("  /// The Terms line's links (plans.json `legal`).");
  lines.push("  static var termsURL: URL { RegistryPlans.termsURL }");
  lines.push("  static var privacyURL: URL { RegistryPlans.privacyURL }");
  lines.push("");
  for (const [name, block] of [["Copy", SI.copy], ["Email", SI.email], ["Errors", SI.errors], ["ExistingAccount", SI.existingAccount], ["Manage", SI.manage]]) {
    lines.push(`  enum ${name} {`);
    swiftBlock(block);
    lines.push("  }");
  }
  lines.push("}");
  lines.push("");

  lines.push("/// One app Septena imports from, or plans to (`registry/import-sources.json`).");
  lines.push("struct RegistryImportSource: Sendable, Hashable {");
  lines.push("  let id: String");
  lines.push("  let name: String");
  lines.push("  let status: String");
  lines.push("  let input: String");
  lines.push("  let issue: Int");
  lines.push("  let detail: String?");
  lines.push("}");
  lines.push("");
  lines.push("enum RegistryImportSources {");
  lines.push("  static var all: [RegistryImportSource] { [");
  for (const s of bundle.importSources.sources) lines.push(`    RegistryImportSource(id: ${swiftStr(s.id)}, name: ${swiftStr(s.name)}, status: ${swiftStr(s.status)}, input: ${swiftStr(s.input)}, issue: ${s.issue}, detail: ${LOpt(s.detail, s, "detail")}),`);
  lines.push("  ] }");
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
  lines.push("  /// `ships`, `partial`, `planned` or `not_applicable`; nil for an unknown platform or ID.");
  lines.push("  static func status(_ featureId: String, on platform: String) -> String? {");
  lines.push("    byPlatform[platform]?[featureId]");
  lines.push("  }");
  lines.push("");
  lines.push("  /// A surface for `featureId` renders on `platform` only when it ships there");
  lines.push("  /// (fully or partly). Planned and not-applicable features show no dead UI (ADR 0015).");
  lines.push("  static func isAvailable(_ featureId: String, on platform: String) -> Bool {");
  lines.push("    switch status(featureId, on: platform) {");
  lines.push('    case "ships", "partial": return true');
  lines.push("    default: return false");
  lines.push("    }");
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
  lines.push(`export const HELP_URL = ${JSON.stringify(settings.helpURL)};`);
  lines.push(`export const SETTINGS_REGISTRY = ${JSON.stringify({ version: settings.version, keys: settings.keys, copy: settings.copy, desktopTabs: settings.desktopTabs, rootGroups: settings.rootGroups, pages: settings.pages })} as const;`);
  lines.push(`export const VIEW_ALIASES = ${JSON.stringify(dests.viewAliases)} as const;`);
  lines.push(`export const DESTINATIONS = ${JSON.stringify(dests.destinations)} as const;`);
  lines.push(`export const GENERIC_EMPTY_STATE = ${JSON.stringify(dests.genericEmptyState)} as const;`);
  lines.push(`export const ICONS = ${JSON.stringify(icons.icons)} as const;`);
  lines.push(`export const DESIGN_TOKENS = ${JSON.stringify({ accentPolicy: tokens.accentPolicy, fruitAccents: tokens.fruitAccents ?? [], textures: tokens.textures ?? [], selection: tokens.selection, colors: tokens.colors, multicolorGlyphs: tokens.multicolorGlyphs?.glyphs ?? {}, accentPalette: tokens.accentPalette, radii: tokens.radii, spacing: tokens.spacing, desktopColumn: tokens.desktopColumn, textScale: tokens.textScale })} as const;`);
  lines.push(`export const CAPABILITIES = ${JSON.stringify(caps.capabilities)} as const;`);
  lines.push(`export const ACTIONS_CATALOG = ${JSON.stringify({ actions: actions.actions, contextMenus: actions.contextMenus, menuBar: actions.menuBar, shortcutsSheet: actions.shortcutsSheet })} as const;`);
  lines.push(`export const SURFACES_CATALOG = ${JSON.stringify({ notices: surfaces.notices, prompts: surfaces.prompts, toasts: surfaces.toasts, taskAttributes: surfaces.taskAttributes, taskDateBoard: surfaces.taskDateBoard, taskPage: surfaces.taskPage, waiting: surfaces.waiting, sharing: surfaces.sharing, accountSwitch: surfaces.accountSwitch, deviceSignIn: surfaces.deviceSignIn, quickFind: surfaces.quickFind, listSort: surfaces.listSort, support: surfaces.support })} as const;`);
  lines.push(`export const FIRST_RUN = ${JSON.stringify(surfaces.firstRun)} as const;`);
  lines.push("/** Plan limits (registry/plans.json). The server's plan table: every gate reads these, never a plan name. */");
  lines.push(`export const PLAN_LIMITS = ${JSON.stringify(plans.limits)} as const;`);
  lines.push(`export const PLAN_TRIAL_DAYS = ${plans.trial.days};`);
  lines.push(`export const PLAN_PRODUCTS = ${JSON.stringify(plans.prices.map((p) => p.productId))} as const;`);
  lines.push("/** The plan each store product gives (ADR 0059, ADR 0061). A product not listed gives nothing. */");
  lines.push(`export const PLAN_PRODUCT_PLANS = ${JSON.stringify(Object.fromEntries([...plans.prices.map((p) => [p.productId, "plus"]), ...plans.proPrices.map((p) => [p.productId, "pro"]), [plans.pass.productId, plans.pass.plan]]))} as const;`);
  lines.push("/** Fixed-duration non-renewing pass products (ADR 0061). Apple omits expiresDate on these; the server computes expiry from purchaseDate + years. */");
  lines.push(`export const PLAN_PASS_PRODUCTS = ${JSON.stringify({ [plans.pass.productId]: { plan: plans.pass.plan, years: plans.pass.years } })} as const;`);
  lines.push("/** The plan page and the plan sheet's words, prices and benefits (registry/plans.json, docs/PREMIUM_LANGUAGE.md). English; localize with registryText(). */");
  lines.push(`export const PLAN_UI = ${JSON.stringify({ name: plans.name, shortName: plans.shortName, proName: plans.proName, headline: plans.headline, subhead: plans.subhead, checkout: plans.checkout, trial: { title: plans.trial.title, detail: plans.trial.detail }, priceFootnote: plans.priceFootnote, prices: plans.prices, proPrices: plans.proPrices, pass: plans.pass, cards: plans.cards, benefits: { plus: plans.benefits.plus, pro: plans.benefits.pro }, upsells: plans.upsells, promises: plans.promises, paywall: plans.paywall, status: plans.status, compareURL: plans.compareURL })} as const;`);
  lines.push("/** Upsell copy by moment id (registry/plans.json `upsells`). Server refusals quote it, so the words match the app. */");
  lines.push(`export const PLAN_UPSELLS = ${JSON.stringify(Object.fromEntries(plans.upsells.map((u) => [u.id, { title: u.title, detail: u.detail }])))} as const;`);
  lines.push("/** Sign-in methods, order per platform and screen copy (registry/sign-in.json, ADR 0047). Copy is English; localize with registryText(). GET /v1/auth/methods says which methods are on. */");
  lines.push(`export const SIGN_IN = ${JSON.stringify({ platforms: bundle.signIn.platforms, methods: bundle.signIn.methods.map(({ notes, ...m }) => m), order: bundle.signIn.order, copy: bundle.signIn.copy, email: bundle.signIn.email, errors: bundle.signIn.errors, existingAccount: bundle.signIn.existingAccount, manage: bundle.signIn.manage, legal: plans.legal })} as const;`);
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
    if (key === "version" || SERVER_ONLY.has(key)) continue;
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
  lines.push("object RegistryLinks {");
  lines.push("    /** The help center (`settings.json` `helpURL`). */");
  lines.push(`    const val HELP: String = ${JSON.stringify(settings.helpURL)}`);
  lines.push("}");
  lines.push("");
  emitIdObject("RegistryDestinationIds", dests.destinations.map((destination) => destination.id));
  emitIdObject("RegistryActionIds", Object.keys(actions.actions));
  emitIdObject("RegistryCapabilityIds", Object.keys(caps.capabilities));
  emitIdObject("RegistryIconIds", Object.keys(icons.icons));
  emitIdObject("RegistryPlatformIds", caps.platforms);
  emitIdObject("RegistrySignInMethodIds", bundle.signIn.methods.map((m) => m.id));

  // Surface IDs (#283, ADR 0028). `RegistryCatalog.surface(id)` finds an
  // object by its `id` anywhere in surfaces.json, so a UI that names these
  // IDs must use the constants (a removed ID then fails to compile), and an
  // emitted ID must match exactly one object in the document.
  const { surfaces } = bundle;
  const surfaceIdGroups = {
    RegistryNoticeIds: surfaces.notices.items.map((n) => n.id),
    RegistryPromptIds: [...surfaces.prompts.items, ...surfaces.prompts.text].map((p) => p.id),
    RegistryPlacesScreenIds: ["labels", "emptyStates", "errors"]
      .flatMap((k) => (surfaces.prompts.placesScreen[k] ?? []).map((x) => x.id)),
    RegistryFirstRunStepIds: surfaces.firstRun.steps.map((s) => s.id),
    RegistryTaskAttributeIds: surfaces.taskAttributes.map((a) => a.id),
    RegistryTaskPageBlockIds: surfaces.taskPage.blocks.map((b) => b.id),
    // Top-level surfaces looked up by id (taskRowMenu, taskSelection, ...).
    RegistrySurfaceIds: Object.values(surfaces)
      .filter((v) => v && typeof v === "object" && !Array.isArray(v) && typeof v.id === "string")
      .map((v) => v.id),
  };
  const idCounts = new Map();
  (function countIds(v) {
    if (Array.isArray(v)) return v.forEach(countIds);
    if (v && typeof v === "object") {
      if (typeof v.id === "string") idCounts.set(v.id, (idCounts.get(v.id) ?? 0) + 1);
      Object.values(v).forEach(countIds);
    }
  })(surfaces);
  for (const [objectName, ids] of Object.entries(surfaceIdGroups)) {
    for (const id of ids) {
      assert(idCounts.get(id) === 1, `surfaces.json: id "${id}" (${objectName}) must be unique in the document; RegistryCatalog.surface looks it up by id alone`);
    }
    emitIdObject(objectName, ids);
  }
  // Count phrase IDs (`prompts.countPhrases`): `countPhrase(id, …)` looks them
  // up in that list alone, so they need not be unique in the whole document.
  emitIdObject("RegistryCountPhraseIds", surfaces.prompts.countPhrases.map((p) => p.id));
  if (surfaces.taskDetail) {
    const detail = surfaces.taskDetail;
    assert(idCounts.get(detail.id) === 1, `surfaces.json: id "${detail.id}" must be unique in the document`);
    lines.push("/** Task detail surface (surfaces.json `taskDetail`): its ID and the keys of its field and control labels. */");
    lines.push("object RegistryTaskDetail {");
    lines.push(`    const val ID: String = ${kotlinStr(detail.id)}`);
    for (const [objectName, block] of [["Fields", detail.fields], ["Controls", detail.controls]]) {
      lines.push(`    object ${objectName} {`);
      for (const key of Object.keys(block ?? {})) {
        lines.push(`        const val ${kotlinConstName(key)}: String = ${kotlinStr(key)}`);
      }
      lines.push("    }");
    }
    lines.push("}");
    lines.push("");
  }

  lines.push("/** Capability status by canonical feature ID and platform. */");
  lines.push("object RegistryCapabilities {");
  lines.push("    val statusByFeatureAndPlatform: Map<String, Map<String, String>> = linkedMapOf(");
  for (const [featureId, capability] of Object.entries(caps.capabilities)) {
    lines.push(`        ${kotlinStr(featureId)} to linkedMapOf(`);
    for (const platform of caps.platforms) {
      lines.push(`            ${kotlinStr(platform)} to ${kotlinStr(capability[platform])},`);
    }
    lines.push("        ),");
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
    plans: bundle.plans,
    signIn: bundle.signIn,
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
    // rustfmt style (core/rustfmt.toml, max_width 120): core.yml checks it.
    // rustfmt also breaks an array literal wider than `array_width` (60% of
    // max_width = 72) even when the whole line fits.
    const array = `[${values.map(rustStr).join(", ")}]`;
    const all = `        pub const ALL: &[&str] = &${array};`;
    if (all.length <= 120 && array.length <= 72) lines.push(all);
    else {
      lines.push("        pub const ALL: &[&str] = &[");
      for (const value of values) lines.push(`            ${rustStr(value)},`);
      lines.push("        ];");
    }
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
const MCP_TOOLS = new Set(mcpToolNames(REPO));
const settings = readJSON("registry/settings.json");
const dests = readJSON("registry/destinations.json");
const actions = readJSON("registry/actions.json");
const surfaces = readJSON("registry/surfaces.json");
const plans = readJSON("registry/plans.json");
const importSources = readJSON("registry/import-sources.json");
const signIn = readJSON("registry/sign-in.json");

validateEntities(entities);
validateRules(rules);
validateIcons(icons);
validateTokens(tokens);
validateCapabilities(caps);
validateSettings(settings, entities, icons, caps);
const destIds = validateDestinations(dests, icons, caps);
validateActions(actions, icons, caps, destIds);
validateSurfaces(surfaces, icons, caps, plans);
validateTaskReferences(surfaces, icons, caps, entities);
validateWaiting(surfaces, caps);
validatePlaceNotes(surfaces, caps);
validateDoing(surfaces, caps, entities);
checkOpensAttribute({ actions, surfaces });
checkTaskDateBoard({ surfaces, icons, caps, actions });
validateFirstRun(surfaces, icons, caps, settings);
validateImportSources(importSources, caps);
validatePlans(plans, icons, caps, importSources);
validateSignIn(signIn, icons, caps, plans);
validateConformance();
validateCodeMap(readJSON("registry/code-map.json"), caps);
validateSkills();
// Marketing content only: no generated bindings, no localized strings (ADR 0030).
validateCast(
  fs.readdirSync(path.join(REPO, "registry/cast")).filter((name) => name.endsWith(".json")).sort()
    .map((file) => ({ file, person: readJSON(`registry/cast/${file}`) })),
  { tokens, caps, inboxTitle: dests.destinations.find((item) => item.id === "inbox").title },
  assert,
);

BY_KEY = L10N.collectStrings({ settings, destinations: dests, actions, surfaces, tokens, plans, importSources, signIn }, assert);

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
  entities, rules, icons, tokens, caps, settings, dests, actions, surfaces, plans, importSources, signIn, conformance,
  translations: { en: JSON.parse(L10N.englishFile(BY_KEY)), ...TRANSLATIONS },
};
/**
 * docs/FEATURE_MAP.md: the capability ledger as a table. The prose feature map
 * lives in Starlings Docs (/product/feature-map-septena-task-app) and joins to
 * this table by Feature ID. No date or commit inside, so the file changes only
 * when the ledger changes.
 */
function generateFeatureMap({ caps }) {
  const LABELS = { ios: "iPhone", ipados: "iPad", macos: "Mac", web: "Web", android: "Android", windows: "Windows", watchos: "Watch" };
  const CODES = { ships: "ships", partial: "partial", planned: "planned", not_applicable: "-" };
  const rows = Object.entries(caps.capabilities);
  const cell = (text) => String(text).replaceAll("|", "/");
  const lines = [
    "# Feature map: status per platform",
    "",
    "Generated by `scripts/gen-registries.mjs` from `registry/capabilities.json`. Do not edit: change the JSON and run the generator. `--check` fails when this file is out of date.",
    "",
    "The ledger says what is in the code on `main`, not what a store has released. How the features connect, and the words the app uses, are in Starlings Docs `/product/feature-map-septena-task-app`.",
    "",
    "**ships** is built, **partial** has known holes, **planned** is not built, **-** does not apply.",
    "",
    `| Status | ${caps.platforms.map((p) => LABELS[p] ?? p).join(" | ")} |`,
    `|---|${caps.platforms.map(() => "---").join("|")}|`,
    ...caps.statuses.map((st) => `| ${CODES[st] ?? st} | ${caps.platforms.map((p) => rows.filter(([, c]) => c[p] === st).length).join(" | ")} |`),
    "",
    "**Agent** lists the MCP tools at `api.septena.app/mcp` that reach the feature; **none** means an agent cannot reach it.",
    "",
    `| ID | Feature | ${caps.platforms.map((p) => LABELS[p] ?? p).join(" | ")} | Agent |`,
    `|---|---|${caps.platforms.map(() => "---").join("|")}|---|`,
    ...rows.map(([id, c]) => `| \`${id}\` | ${cell(c.title)} | ${caps.platforms.map((p) => CODES[c[p]] ?? c[p]).join(" | ")} | ${c.agent === "none" ? "none" : c.agent.map((t) => `\`${t}\``).join(", ")} |`),
    "",
  ];
  return lines.join("\n");
}

const tsOutput = generateTS(bundle);
const outputs = [
  ["SeptenaCore/Generated/RegistryConstants.swift", generateSwift(bundle)],
  ["backend/src/generated/registries.ts", tsOutput],
  ["web/src/lib/generated/registries.ts", tsOutput],
  ["android/core/src/main/kotlin/app/septena/core/generated/RegistryConstants.kt", generateKotlinCore(bundle)],
  ["core/crates/septena-core/src/generated/registry.rs", generateRustCore(bundle)],
  ["docs/FEATURE_MAP.md", generateFeatureMap(bundle)],
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
  // Every generated member needs a reader (ADR 0020 P3).
  const { problems } = checkReaders(REPO);
  if (problems.length) {
    throw new Error(`generated registry code without a reader:\n  ${problems.join("\n  ")}`);
  }
  console.log("registries: ok (all 11 registries valid and generated files up to date)");
} else if (changed === 0) {
  console.log("registries: already up to date");
}
