# Identifiers — design note

How Septena identifies user-named entities (areas, projects, chores, habits,
supplements, sections, …) so renames don't break references, agents speak
natural names, and the data model stays trivial.

Tasks are excluded — they're content with a title, not labels with a name.
Tasks keep id-only.

## The model

Two fields on every label-style entity:

| Field | Mutable? | Visible? | Purpose |
|-------|----------|----------|---------|
| `id` | **No** — frozen at creation | No | Stable identity. CK `recordName`. Foreign-key target. |
| `title` | Yes — freely editable | Yes | The user-facing name. Also what agents see. |

That's it. No slug, no previousSlugs, no derived URL form. Renaming a title
is just a title write — no derived fields to update, no FK breakage because
references store the immutable `id`.

### `id` (shortid)

- **Format**: base32 lowercase, no ambiguous chars (no `0`/`o`, `1`/`l`/`i`).
  - All label-style entities: 4 chars (~1M combos — plenty for personal scale).
- **Lifetime**: immutable. Generated once at create. Stays the same across
  every rename, every device, forever.
- **Collision**: try once, retry once with an extra char if the rare
  birthday collision hits. After two retries, fall through to UUID prefix
  (panic mode — never fires in practice).
- **Existing records keep their current ids unchanged.** Some are slug-shaped
  legacy strings (`septena`, `obsidian`, `home`, `home1`) because the old
  code used the slug as the id. Those are now opaque ids that happen to be
  human-readable. Harmless.
- **Never shown to users.** Ids are plumbing. The user sees titles.

### `title`

Display string. Whatever the user typed. Unicode, emoji, length unrestricted.
May collide freely with other titles — disambiguation is the resolver's job.

## Resolution rule

When MCP / UI / any code accepts a string referring to one of these entities:

1. **Exact `id` match** wins. Lowest ambiguity, fastest path.
2. Else **exact `title` match** (case-insensitive). Returns ambiguous-match
   error if more than one hits.
3. Else **case-insensitive `title` substring** match — returns ambiguous-match
   error if more than one hits.

This rule is identical across types so the resolver helper is one function
per entity, all built on the same primitive.

## Rename flow

```
user renames "Obsidian" → "Notes":
  entity.title := "Notes"
  // no derived fields to update
  // id stays the same forever
```

That's the whole operation. Tasks/projects pointing at this area's id keep
working. No URL handles to migrate. No history to maintain.

## CK schema

Each label-type CKRecord has these fields (plus type-specific extras):

```
title            STRING
context          STRING   (areas/projects only)
…type-specific…
```

**No `slug` or `previousSlugs` fields are written.** Existing CloudKit
records may still have those fields populated on the server (from before
the slug removal); the decoder ignores them and they're harmless storage.

## SwiftData

Each `@Model` class has:

```swift
@Attribute(.unique) var id: String   // immutable shortid
var title: String                    // the display name
// no slug, no previousSlugs
```

(There may be vestigial `slug: String?` and `previousSlugs: [String]`
fields on the existing schema during the transition — see the slug-removal
Stage 2 task for cleanup. They're set to nil/empty by current code and read
by nothing.)

## Tasks

Tasks are content, not labels. Keep `id` only.

- Existing tasks keep their ids (FastAPI date-prefix strings or CK-mode
  UUIDs — both are opaque from now on).
- New tasks get base32-6 shortids for compactness.

## Foreign keys

Cross-type references store the **target id**, never the title. So
`task.area = "k7m2"`, not `task.area = "Obsidian"`. The resolver runs
once at write time (turning a natural-name input into an id), then the
stored value is immune to renames.

The only exception is **migrated FastAPI records** whose `task.area`
field currently holds a legacy slug-as-id (`"septena"`, `"obsidian"`).
Those continue to work because the resolver matches id-first — and for
those records, the id IS the legacy slug.

## Extending to a new entity type — checklist

When chores, habits, sections, supplements, or any other label-style
entity moves to CK (or is otherwise reshaped for MCP access), apply this
pattern. **Do not invent a new id strategy per type** — agents and
deeplink handlers rely on the rule being uniform.

For each new type `Foo`:

- [ ] **SwiftData entity** ([Persistence.swift](SeptenaCore/Persistence.swift))
  - `@Attribute(.unique) var id: String`
  - `var title: String`
  - No slug fields.
- [ ] **CKRecord schema** (new `FooRecord.swift` under
  `SeptenaCore/CloudKit/`, mirroring `AreaRecord.swift`)
  - Add `title` (and any type-specific fields) to `FooCloudKitSchema.Field`
  - Wire in `toCloudKitRecord()` and `apply(_:)`
- [ ] **Backend** (`FoosBackend.swift`, mirroring `AreasBackend.swift`)
  - `uniqueShortcode()` — try-4-then-6-then-UUID-prefix
  - `create(title:...)` uses `uniqueShortcode()` for `id`
  - `rename(id:to:)` just sets `title`. No slug bookkeeping.
- [ ] **MCP tool layer** (when wired)
  - Accept either id or title in tool args
  - Resolve internally via the id-or-title resolver
  - Return both `id` and `title` in tool responses so the agent learns
    the canonical id

## MCP gateway contract

When the hosted MCP gateway (`mcp.septena.app`) is built out, its
resolution contract for area/project/etc references in tool args:

1. If the arg looks like a valid id (4-char base32), exact-match by id.
2. Else case-insensitive title match. If multiple hit, return an
   ambiguous-match error listing the candidates so the agent can ask
   the user to disambiguate.

Tool responses always return both `id` and `title`. The agent learns to
use the id for subsequent calls (faster, unambiguous) but can present
the title to the user.

## What this design doesn't try to do

- **URL-safe handles for deeplinks**. If you later need them, derive
  them at read time from the title (lowercased, hyphenated) — but tasks
  reference by id, so the derived form is purely for URLs, not storage.
- **Server-side title index in CK**. Lookups happen in the local
  SwiftData mirror; CK queries by field aren't needed.
- **Cross-type id collision protection**. Ids are scoped per type
  (`k7m2` can be both an area and a project; the resolver always knows
  which type it's looking in).
- **Renaming with concurrent CK writes from two devices**. CK's
  last-writer-wins applies; brief window of disagreement on title.
  Self-corrects on next sync.

## Removed in 2026: the slug concept

Earlier versions of this doc described a three-field model with
`slug` (mutable derived URL handle) and `previousSlugs` (FIFO history
for old-name lookups). That added complexity for a problem we don't
have — we never built URL-based access, the agent surface doesn't need
URL-safe handles, and the slug fields were a source of drift between
title and slug (e.g., area with id="home" titled "Admin" but slug="home").

The slug fields still exist on legacy CloudKit records as harmless
storage. New code doesn't read or write them.
