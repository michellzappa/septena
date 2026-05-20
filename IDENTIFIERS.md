# Identifiers — design note

How Septena identifies user-named entities (areas, projects, chores, habits,
supplements, sections, …) so renames don't lose data, agents speak natural
names, and deeplinks survive.

Tasks are excluded — they're content with a title, not labels with a name.
Tasks keep id-only.

## The model

Three fields on every label-style entity:

| Field | Mutable? | Purpose |
|-------|----------|---------|
| `id` | **No** — frozen at creation | Stable identity. CK `recordName`. Foreign-key target. Tool-arg "exact match." |
| `slug` | Yes — auto-updates on rename | Natural-name lookup. Deeplink path. Tool-arg "fuzzy match." Always deduped. |
| `title` | Yes — freely editable | Display. May collide freely. |

### `id` (shortid)

- **Format**: base36 lowercase, no ambiguous chars (no `0`/`o`, `1`/`l`).
  - Areas/projects: 4 chars (~1.6M combos — enough for personal scale).
  - Chores/habits/sections etc: 4 chars.
- **Lifetime**: immutable. Generated once at create. Stays the same across
  every rename, every device, forever.
- **Collision**: try once, retry once with an extra char if the rare birthday
  collision hits. After two retries, fall through to UUID (panic mode, never
  fires in practice).
- **Existing records keep their current ids unchanged.** `septena`,
  `obsidian`, etc. are now treated as opaque ids that happen to look readable.

### `slug`

- **Format**: lowercase, alphanumeric+dash, derived from `title`.
- **Updates**: on every rename, recompute from new title. Dedup against
  other live entities of the same type — collisions become `home-2`, `home-3`.
- **History**: last 3 previous slugs kept in `previousSlugs: [String]` field
  so a lookup for the old name still resolves for a couple of weeks of
  conversation/deeplink lifetime. Capped at 3 entries, FIFO.
- **Nullable** in storage. Old records lazy-backfill: on first `apply()` from
  CK (or first read), populate slug from title if nil. No big-bang migration.

### `title`

Display string. Whatever the user typed. Unicode, emoji, length up to you.

## Resolution rule

When MCP / UI / any code accepts a string referring to one of these entities:

1. **Exact `id` match** wins. Lowest ambiguity.
2. Else **exact `slug` match** on a live record.
3. Else **exact `slug` match** in any record's `previousSlugs`.
4. Else **case-insensitive `title` substring** match — return ambiguous-match
   error if more than one hits.

This rule is identical across types so the resolver helper is one function
per entity (`resolveAreaId(_:)`, `resolveProjectId(_:)`, etc.) all built
on the same primitive.

## Rename flow

```
user renames "Obsidian" → "Notes":
  title       := "Notes"
  oldSlug     := slug                    // "obsidian"
  newSlug     := dedup(IDSlug.from("Notes"))   // "notes"
  if newSlug != oldSlug:
    previousSlugs.insert(oldSlug, at: 0)
    previousSlugs = Array(previousSlugs.prefix(3))
    slug := newSlug
  id stays "b2ck" forever.
```

## CK schema impact

Each label-type CKRecord gets two new fields:

```
slug             STRING
previousSlugs    STRING_LIST
```

Additive change. Add both to the schema in Development, verify, then promote
to Production. Use real names — don't burn reserved slots, those are for
unforeseen needs.

## SwiftData impact

Add to each `@Model` class (AreaEntity, ProjectEntity, and later
ChoreEntity etc):

```swift
var slug: String?              // nil = legacy record awaiting backfill
var previousSlugs: [String] = []
```

`String?` not `String` so the schema migration is trivially additive — no
default-value gymnastics on legacy rows. Tighten to non-optional later if
you want, after backfill is universal.

## Tasks

Tasks are content, not labels. Keep `id` only. Lookup by id or by title
fuzzy search. No slug, no `previousSlugs`.

- Existing tasks keep their ids (FastAPI date-prefix slugs or CK-mode
  UUIDs — both are opaque from now on).
- New tasks get base36-6 shortids for compactness.

## Extending to a new entity type — checklist

When chores, habits, sections, supplements, or any other label-style
entity moves to CK (or is otherwise reshaped for MCP access), apply this
pattern. **Do not invent a new id strategy per type** — agents and
deeplink handlers rely on the rule being uniform.

For each new type `Foo`:

- [ ] **SwiftData entity** ([Persistence.swift](SeptenaCore/Persistence.swift))
  - Add `var slug: String?` (optional so additive migration is trivial)
  - Add `var previousSlugs: [String] = []`
  - Update `init` with both new params, defaulted to nil / `[]`
- [ ] **CKRecord schema** (new `FooRecord.swift` under
  `SeptenaCore/CloudKit/`, mirroring `AreaRecord.swift`)
  - Add `slug` (STRING) and `previousSlugs` (STRING_LIST) to
    `FooCloudKitSchema.Field`
  - Wire both in `toCloudKitRecord()` and `apply(_:)`
  - In `apply(_:)`, lazy-backfill `slug = id` when nil for legacy records
- [ ] **Backend** (`FoosBackend.swift`, mirroring `AreasBackend.swift`)
  - `uniqueShortcode()` — try-4-then-6-then-UUID-prefix
  - `uniqueSlug(for:excluding:)` — dedup against other live records of
    the same type, excluding the caller's own id
  - `create(...)` uses `uniqueShortcode()` for `id`, `uniqueSlug` for `slug`
  - `rename(id:, to:)` recomputes slug, pushes old onto `previousSlugs`
    (FIFO cap 3) when the slug actually changed
- [ ] **Resolver helper** ([Resolver.swift](SeptenaCore/CloudKit/Resolver.swift))
  - Copy `resolveAreaId(_:)` body, swap `AreaEntity` → `FooEntity`,
    "area" → "foo" in error strings
- [ ] **MCP tool layer** (when wired)
  - Accept either id or natural name in tool args
  - Resolve internally via `EntityResolver.resolveFooId(_:in:)`
  - Return both `id` and `slug` in tool responses so the agent learns
    the canonical form

For an entity that **stays on FastAPI** (no CK move yet) but still needs
MCP access:

- [ ] Add `slug` + `previousSlugs` to the wire DTO and to the local SwiftData
  mirror
- [ ] Server stores both, updates slug on rename, manages `previousSlugs`
  history server-side
- [ ] Local `EntityResolver` works against the cached SwiftData rows the
  same way

## Foreign keys

Cross-type references store the **target id**, never the slug. So
`task.area = "k7m2"`, not `task.area = "obsidian"`. The resolver runs
once at write time (turning a natural-name input into an id), then the
stored value is immune to renames.

The only exception is **migrated FastAPI records** whose `task.area`
field currently holds the legacy slug-as-id (`"septena"`, `"obsidian"`).
Those continue to work because the resolver matches id-first — and for
those records, the id IS the legacy slug. New records use real shortids
and the foreign keys hold those shortids.

## Migration plan, summarized

1. Add `slug: String?` + `previousSlugs: [String]` to `AreaEntity` and
   `ProjectEntity`.
2. Add `slug` + `previousSlugs` fields to `AreaRecord` + `ProjectRecord`
   schemas (CK Development environment auto-creates on first write).
3. Switch new area/project creates to shortid + auto-slug.
4. On `apply(_:)` from CK or on read, lazy-backfill `slug` from `title`
   if nil and the record's id ≠ its slug (otherwise leave `slug` nil and
   treat id-as-slug for legacy lookup compatibility).
5. Wire `rename` paths to update `slug` + push old onto `previousSlugs`.
6. Add `resolveAreaId(_:)` and `resolveProjectId(_:)` helpers.
7. Use the same code shape later when chores/habits/etc need it.

## What this design doesn't try to do

- **Server-side index on `slug`**. Lookups happen in the local SwiftData
  mirror; CK queries by field aren't needed. If we later add server-side
  search, mark `slug` queryable in CK Dashboard.
- **Cross-type id collision protection**. Slugs are scoped per type
  (`obsidian` can be both an area and a project; the resolver always knows
  which type it's looking in). If you ever want a global "find anything
  named X" search, that's a separate union-search helper on top.
- **Renaming with concurrent CK writes from two devices**. CK's last-writer-
  wins applies; we may end up with both devices having different `slug`
  values for a brief window. Self-corrects on next sync. Single-user, single-
  device scenario this doesn't matter.
