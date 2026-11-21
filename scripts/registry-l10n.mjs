// Registry localization (ADR 0020). Imported by `gen-registries.mjs`.
//
// - Collects every user-facing string in `registry/*.json`.
// - Key = the English text (or an `l10nKeys.<field>` override on the same
//   object), so the catalog's existing translations carry over.
// - Placeholders are named (`{count}`, `{name}`, `{date}`). On Apple they
//   become `%lld` (integer names) or `%@` (all others), in English order.
// - A plural string is an object `{ "one": "...", "other": "..." }`. Its key
//   is the `other` form.
//
// Files:
// - `registry/l10n/en.json` — generated: every key, English, source paths.
// - `registry/l10n/<lang>.json` — hand-maintained translations: key → text
//   (or plural forms), named placeholders.
// - `Septena/Localizable.xcstrings` — the generator writes the registry keys
//   into the catalog. Their comment says the entry is generated.

import fs from "node:fs";
import path from "node:path";

/** Placeholder names that carry an integer (`%lld` on Apple). */
export const INT_PLACEHOLDERS = new Set(["count"]);
const PLURAL_FORMS = new Set(["zero", "one", "two", "few", "many", "other"]);
export const GENERATED_COMMENT_PREFIX = "Generated from registry";

/** Which fields hold user-facing copy, per registry file. */
const FIELDS = {
  settings: new Set(["title", "header", "label", "detail", "footer"]),
  destinations: new Set(["title", "detail", "pointerDetail", "touchDetail", "syncingTitle"]),
  actions: new Set(["title", "desktopTitle", "activeTitle", "pluralTitle", "addTitle", "removeTitle", "shortTitle"]),
  surfaces: new Set([
    "title", "primaryTitle", "detail", "message", "confirmTitle", "cancelTitle", "format",
    "emptyTitleFormat", "singularFormat", "body", "footnote", "returningTitle", "returningBody",
    "label", "countLabel", "workingLabel", "instructions", "setup", "first", "placeholder", "untitledName",
  ]),
  tokens: new Set(["name", "tag", "label"]),
};
/** Fields skipped even when their name matches (machine data). */
const SKIP_PATHS = [/^settings\.keys\.[^.]+\.(title|label)$/];

export const isPlural = (v) =>
  v && typeof v === "object" && !Array.isArray(v) && typeof v.other === "string" &&
  Object.keys(v).every((k) => PLURAL_FORMS.has(k));

export const placeholdersOf = (s) => [...s.matchAll(/\{([a-zA-Z][a-zA-Z0-9]*)\}/g)].map((m) => m[1]);

const segment = (v, idx) => (v && typeof v === "object" && typeof v.id === "string" ? v.id : String(idx));

/**
 * Walks one registry file and returns `[{ key, english, path }]`.
 * `english` is a string or a plural object.
 */
function collectFile(fileId, json) {
  const fields = FIELDS[fileId];
  const out = [];
  const walk = (node, p) => {
    if (Array.isArray(node)) {
      node.forEach((child, i) => walk(child, `${p}.${segment(child, i)}`));
      return;
    }
    if (!node || typeof node !== "object") return;
    for (const [k, v] of Object.entries(node)) {
      const here = `${p}.${k}`;
      if (k === "description" || k === "l10nKeys") continue;
      if (fields.has(k) && !SKIP_PATHS.some((re) => re.test(here))) {
        const key = node.l10nKeys?.[k];
        if (typeof v === "string") {
          out.push({ key: key ?? v, english: v, path: here });
          continue;
        }
        if (isPlural(v)) {
          out.push({ key: key ?? v.other, english: v, path: here });
          continue;
        }
        if (Array.isArray(v) && v.every((x) => typeof x === "string")) {
          v.forEach((s, i) => out.push({ key: s, english: s, path: `${here}.${i}` }));
          continue;
        }
      }
      walk(v, here);
    }
  };
  walk(json, fileId);
  return out;
}

const sameEnglish = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** Collects and validates all registry copy. Returns a Map key → entry. */
export function collectStrings(files, assert) {
  const byKey = new Map();
  for (const [fileId, json] of Object.entries(files)) {
    for (const s of collectFile(fileId, json)) {
      const forms = typeof s.english === "string" ? [s.english] : Object.values(s.english);
      assert(forms.every((f) => f.trim().length > 0), `l10n: ${s.path} has empty English text`);
      assert(s.key.trim().length > 0, `l10n: ${s.path} has an empty key`);
      if (isPlural(s.english)) {
        const other = placeholdersOf(s.english.other);
        assert(other.includes("count"), `l10n: ${s.path} plural needs {count} in "other"`);
        for (const [form, text] of Object.entries(s.english)) {
          const ph = placeholdersOf(text).filter((n) => n !== "count");
          const want = other.filter((n) => n !== "count");
          assert(sameEnglish([...ph].sort(), [...want].sort()), `l10n: ${s.path}.${form} placeholders differ from "other"`);
        }
      }
      const prev = byKey.get(s.key);
      if (prev) {
        assert(sameEnglish(prev.english, s.english), `l10n: key "${s.key}" has two English texts (${prev.paths[0]} vs ${s.path}); add l10nKeys to one of them`);
        prev.paths.push(s.path);
      } else {
        byKey.set(s.key, { key: s.key, english: s.english, paths: [s.path] });
      }
    }
  }
  // Two keys that collapse to one Apple key (`{a}` and `{b}` both become
  // `%@`) would share one translation. Give one of them an `l10nKeys` entry.
  const apple = new Map();
  for (const e of byKey.values()) {
    const k = catalogKey(e);
    assert(!apple.has(k), `l10n: "${e.key}" and "${apple.get(k)}" share the catalog key "${k}"; add l10nKeys to one of them`);
    apple.set(k, e.key);
  }
  return byKey;
}

const englishOther = (e) => (typeof e === "string" ? e : e.other);
export const placeholderOrder = (entry) => placeholdersOf(englishOther(entry.english)).filter((n, i, a) => a.indexOf(n) === i);
const specFor = (name) => (INT_PLACEHOLDERS.has(name) ? "lld" : "@");

/**
 * Named → Apple format. `order` is the English placeholder order. When the
 * text uses the placeholders in English order, specifiers are plain;
 * otherwise positional (`%2$@`).
 */
export function toAppleFormat(text, order, isTemplate) {
  if (!isTemplate) return text;
  const used = placeholdersOf(text);
  const inOrder = used.every((n, i) => order[i] === n) && used.length === order.length;
  return text.replace(/%/g, "%%").replace(/\{([a-zA-Z][a-zA-Z0-9]*)\}/g, (_, n) => {
    const idx = order.indexOf(n);
    return inOrder ? `%${specFor(n)}` : `%${idx + 1}$${specFor(n)}`;
  });
}

/** Apple format → named, using the English placeholder order. */
export function fromAppleFormat(text, order) {
  let seq = 0;
  return text
    .replace(/%(?:(\d+)\$)?(@|lld|ld|d|li|i|lu|u)/g, (_, pos) => {
      const idx = pos ? Number(pos) - 1 : seq++;
      return order[idx] ? `{${order[idx]}}` : "{?}";
    })
    .replace(/%%/g, "%");
}

export const isTemplate = (entry) => isPlural(entry.english) || placeholderOrder(entry).length > 0;
export const catalogKey = (entry) => toAppleFormat(entry.key, placeholderOrder(entry), isTemplate(entry));

/** `registry/l10n/en.json` content. */
export function englishFile(byKey) {
  const obj = {};
  for (const key of [...byKey.keys()].sort()) {
    const e = byKey.get(key);
    const row = typeof e.english === "string" ? { text: e.english } : { forms: e.english };
    const ph = placeholderOrder(e);
    if (ph.length) row.placeholders = ph;
    row.paths = e.paths;
    obj[key] = row;
  }
  return JSON.stringify(obj, null, 2) + "\n";
}

export function readTranslations(repo) {
  const dir = path.join(repo, "registry/l10n");
  const out = {};
  if (!fs.existsSync(dir)) return out;
  for (const f of fs.readdirSync(dir).sort()) {
    if (!f.endsWith(".json") || f === "en.json") continue;
    const lang = f.slice(0, -5);
    out[lang] = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
  }
  return out;
}

/**
 * Validates translations. Fails on a placeholder mismatch or a shape
 * mismatch (plural vs plain). Returns advisory counts: missing and orphaned.
 */
export function checkTranslations(byKey, translations, assert) {
  const report = {};
  for (const [lang, table] of Object.entries(translations)) {
    let missing = 0;
    const orphans = [];
    for (const [key, entry] of byKey) {
      const tr = table[key];
      if (tr === undefined) { missing++; continue; }
      const want = [...placeholderOrder(entry)].sort();
      if (typeof entry.english === "string") {
        assert(typeof tr === "string", `l10n ${lang}: "${key}" must be a string`);
        assert(sameEnglish([...new Set(placeholdersOf(tr))].sort(), want), `l10n ${lang}: "${key}" placeholders differ from English`);
      } else {
        const forms = typeof tr === "string" ? { other: tr } : tr;
        assert(isPlural(forms), `l10n ${lang}: "${key}" must be plural forms or a string`);
        for (const [form, text] of Object.entries(forms)) {
          const got = [...new Set(placeholdersOf(text))].filter((n) => form === "other" || n !== "count").sort();
          const exp = want.filter((n) => form === "other" || n !== "count");
          assert(sameEnglish(got, exp), `l10n ${lang}: "${key}" form ${form} placeholders differ from English`);
        }
      }
    }
    for (const key of Object.keys(table)) if (!byKey.has(key)) orphans.push(key);
    report[lang] = { missing, orphans, total: byKey.size };
  }
  return report;
}

// ---- Xcode string catalog ----

/** Serializes like Xcode does (`"key" : value`, empty object on 3 lines). */
export function serializeCatalog(v, ind = 0) {
  const pad = "  ".repeat(ind);
  if (v === null) return "null";
  if (Array.isArray(v)) return "[\n" + v.map((x) => pad + "  " + serializeCatalog(x, ind + 1)).join(",\n") + "\n" + pad + "]";
  if (typeof v === "object") {
    const ks = Object.keys(v);
    if (!ks.length) return "{\n\n" + pad + "}";
    return "{\n" + ks.map((k) => pad + "  " + JSON.stringify(k) + " : " + serializeCatalog(v[k], ind + 1)).join(",\n") + "\n" + pad + "}";
  }
  return JSON.stringify(v);
}

const unit = (value) => ({ stringUnit: { state: "translated", value } });
const pluralUnit = (forms, order) => ({
  variations: {
    plural: Object.fromEntries(Object.entries(forms).map(([f, t]) => [f, unit(toAppleFormat(t, order, true))])),
  },
});

/** The catalog localizations a registry entry must carry. */
function expectedLocalizations(entry, translations) {
  const order = placeholderOrder(entry);
  const tmpl = isTemplate(entry);
  const key = catalogKey(entry);
  const locs = {};
  if (typeof entry.english === "string") {
    const en = toAppleFormat(entry.english, order, tmpl);
    if (en !== key) locs.en = unit(en);
  } else {
    locs.en = pluralUnit(entry.english, order);
  }
  for (const [lang, table] of Object.entries(translations)) {
    const tr = table[entry.key];
    if (tr === undefined) continue;
    if (typeof tr === "string") locs[lang] = unit(toAppleFormat(tr, order, tmpl));
    else locs[lang] = pluralUnit(tr, order);
  }
  return locs;
}

const keyCompare = (a, b) => a.localeCompare(b, "en", { numeric: true });

/**
 * Returns the catalog with every registry key written. Existing entries keep
 * their extraction state and any localization the registry does not own;
 * a new entry is `manual`, so Xcode does not mark it stale.
 */
export function mergeCatalog(catalog, byKey, translations) {
  const strings = { ...catalog.strings };
  const added = [];
  for (const entry of byKey.values()) {
    const key = catalogKey(entry);
    const prev = strings[key];
    const comment = `${GENERATED_COMMENT_PREFIX} ${entry.paths[0]}. Edit registry/*.json or registry/l10n; Xcode edits are overwritten.`;
    const next = {};
    // A key Swift source also uses keeps the comment Xcode extracts from
    // source; only keys the registry alone owns carry the generated comment.
    if (!prev || prev.comment?.startsWith(GENERATED_COMMENT_PREFIX)) next.comment = comment;
    else if (prev.comment !== undefined) next.comment = prev.comment;
    next.extractionState = prev ? prev.extractionState : "manual";
    if (prev?.shouldTranslate !== undefined) next.shouldTranslate = prev.shouldTranslate;
    const locs = { ...(prev?.localizations ?? {}), ...expectedLocalizations(entry, translations) };
    if (Object.keys(locs).length) {
      next.localizations = Object.fromEntries(Object.keys(locs).sort().map((l) => [l, locs[l]]));
    }
    for (const [k, v] of Object.entries(prev ?? {})) {
      if (!(k in next) && k !== "localizations") next[k] = v;
    }
    if (next.extractionState === undefined) delete next.extractionState;
    strings[key] = orderEntry(next);
    if (!prev) added.push(key);
  }
  // Keep the file's order; insert new keys where Xcode would sort them.
  const existing = Object.keys(catalog.strings);
  const newKeys = added.sort(keyCompare);
  const ordered = [];
  let j = 0;
  for (const k of existing) {
    while (j < newKeys.length && keyCompare(newKeys[j], k) < 0) ordered.push(newKeys[j++]);
    ordered.push(k);
  }
  while (j < newKeys.length) ordered.push(newKeys[j++]);
  return { ...catalog, strings: Object.fromEntries(ordered.map((k) => [k, strings[k]])) };
}

/**
 * Keys whose catalog entry is missing or carries other registry-owned
 * localizations. Ignores extraction state and comments, which Xcode rewrites.
 */
export function catalogDrift(catalog, byKey, translations) {
  const drift = [];
  for (const entry of byKey.values()) {
    const key = catalogKey(entry);
    const prev = catalog.strings[key];
    if (!prev) { drift.push(key); continue; }
    const want = expectedLocalizations(entry, translations);
    for (const [lang, loc] of Object.entries(want)) {
      if (JSON.stringify(prev.localizations?.[lang]) !== JSON.stringify(loc)) { drift.push(key); break; }
    }
  }
  return drift;
}

/** Xcode writes entry fields alphabetically. */
function orderEntry(e) {
  return Object.fromEntries(Object.keys(e).sort().map((k) => [k, e[k]]));
}

/** Reads translations for registry keys out of the catalog (one-time seed). */
export function seedFromCatalog(catalog, byKey, lang) {
  const out = {};
  for (const entry of byKey.values()) {
    const loc = catalog.strings[catalogKey(entry)]?.localizations?.[lang];
    if (!loc) continue;
    const order = placeholderOrder(entry);
    if (loc.stringUnit) {
      const v = isTemplate(entry) ? fromAppleFormat(loc.stringUnit.value, order) : loc.stringUnit.value;
      out[entry.key] = isPlural(entry.english) ? { other: v } : v;
    } else if (loc.variations?.plural) {
      const forms = Object.fromEntries(
        Object.entries(loc.variations.plural).map(([f, u]) => [f, fromAppleFormat(u.stringUnit.value, order)]),
      );
      out[entry.key] = isPlural(entry.english) ? forms : forms.other;
    }
  }
  return out;
}

// ---- Code emitters ----

const swiftStr = (s) => JSON.stringify(s);

/** Swift expression for a plain registry string. */
export function swiftLookup(byKey, english, key = english) {
  const entry = byKey.get(key);
  if (!entry) throw new Error(`l10n: no registry string for "${key}"`);
  return key === english ? `RegistryL10n.t(${swiftStr(english)})` : `RegistryL10n.t(${swiftStr(key)}, english: ${swiftStr(english)})`;
}

/** Swift parameter list and call for a template entry. */
export function swiftTemplate(byKey, key) {
  const entry = byKey.get(key);
  if (!entry) throw new Error(`l10n: no registry template for "${key}"`);
  const order = placeholderOrder(entry);
  const params = order.map((n) => `${n}: ${INT_PLACEHOLDERS.has(n) ? "Int" : "String"}`).join(", ");
  const args = order.join(", ");
  const ck = catalogKey(entry);
  if (isPlural(entry.english)) {
    const one = entry.english.one !== undefined ? swiftStr(toAppleFormat(entry.english.one, order, true)) : "nil";
    const other = swiftStr(toAppleFormat(entry.english.other, order, true));
    return { params, body: `RegistryL10n.plural(${swiftStr(ck)}, count: count, one: ${one}, other: ${other}, args: [${args}])` };
  }
  const en = toAppleFormat(englishOther(entry.english), order, true);
  return { params, body: `RegistryL10n.format(${swiftStr(ck)}, english: ${swiftStr(en)}, args: [${args}])` };
}

export const SWIFT_RUNTIME = `/// Registry copy lookup (ADR 0020). The key is the English text, so the
/// string catalog's translations apply. \`registry/l10n/<lang>.json\` holds
/// the translations; the generator writes them into \`Localizable.xcstrings\`.
enum RegistryL10n {
  private static let missing = "\\u{1}registry-l10n-missing"

  /// The localized text for \`key\`, or \`english\` when no table has it.
  static func t(_ key: String, english: String? = nil) -> String {
    let value = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    return value == missing ? (english ?? key) : value
  }

  /// A template with \`%@\` / \`%lld\` placeholders.
  static func format(_ key: String, english: String, args: [CVarArg]) -> String {
    String(format: t(key, english: english), locale: Locale.current, arguments: args)
  }

  /// A plural template. The catalog's plural variations pick the form; with
  /// no table, English \`one\` / \`other\` stands in.
  static func plural(_ key: String, count: Int, one: String?, other: String, args: [CVarArg]) -> String {
    let value = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    let fmt = value == missing ? (count == 1 ? (one ?? other) : other) : value
    return String(format: fmt, locale: Locale.current, arguments: args)
  }
}
`;

/** TS: the translation tables and a lookup with named placeholders. */
export function tsTables(byKey, translations) {
  const en = {};
  for (const key of [...byKey.keys()].sort()) en[key] = byKey.get(key).english;
  const langs = { en };
  for (const lang of Object.keys(translations).sort()) {
    const t = {};
    for (const key of Object.keys(translations[lang]).sort()) if (byKey.has(key)) t[key] = translations[lang][key];
    langs[lang] = t;
  }
  return [
    "export type RegistryPluralForms = { zero?: string; one?: string; two?: string; few?: string; many?: string; other: string };",
    `export const REGISTRY_L10N: Record<string, Record<string, string | RegistryPluralForms>> = ${JSON.stringify(langs)};`,
    `export const REGISTRY_LANGUAGES = ${JSON.stringify(Object.keys(langs))} as const;`,
    "",
    "/** Registry copy in `lang` (falls back to the base language, then English). Fills `{name}` placeholders from `vars`; plural forms pick by `vars.count`. */",
    "export function registryText(key: string, lang = \"en\", vars: Record<string, string | number> = {}): string {",
    "  const base = lang.split(\"-\")[0];",
    "  const entry = REGISTRY_L10N[lang]?.[key] ?? REGISTRY_L10N[base]?.[key] ?? REGISTRY_L10N.en[key] ?? key;",
    "  let text: string;",
    "  if (typeof entry === \"string\") {",
    "    text = entry;",
    "  } else {",
    "    const count = Number(vars.count ?? 0);",
    "    const form = new Intl.PluralRules(lang).select(count) as keyof RegistryPluralForms;",
    "    text = entry[form] ?? entry.other;",
    "  }",
    "  return text.replace(/\\{([a-zA-Z][a-zA-Z0-9]*)\\}/g, (m, name: string) => (name in vars ? String(vars[name]) : m));",
    "}",
  ].join("\n");
}
