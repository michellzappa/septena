# 0030. A cast of people for marketing screens

- Status: accepted
- Date: 2026-11-24
- Deciders: mz

## Context

Every marketing screen showed one sample world: a website launch, a landlord
and a dentist. It drove the website scenes, the App Store panels, the share
cards, the promo images and the press kit. Nobody owned the list: Maya, the
only name on it, is the person who receives the update. Four copies of sample
content drifted beside it (the agent mini-chats on the site, the App Store
message card, `tools/3d-studio/make_demo_screens.swift` and
`SeptenaCore/DemoSeed.swift`, which builds titles from random verbs and nouns).

A to-do app is for people with different lives, and the screenshots must show
that. Generated text reads fake, so the variety cannot come from a generator.

## Decision

Marketing screens show **a cast**: fictional people whose lists are written by
hand. Four layers stay apart:

1. **Person** (`registry/cast/<id>.json`): areas, projects, the two names that
   recur in their life, and their look (accent, texture, light or dark).
2. **Moment** (inside the person): what happens this week, with the tasks,
   drafts and answers every scene needs. Dates are day offsets and
   `{weekday+n}`, so a moment has no fixed date.
3. **Story**: what the feature does. Scenes and captions live in the site
   (`lib/task-ui/model.ts`) and name no task of any person.
4. **Casting**: which person a surface shows. Live pages can vary it. Stills
   (App Store, share cards, press kit) are fixed, at 9:41.

Every person fits every story, so a new person needs no new scene and a new
scene needs no new content.

Rules for the content:

- People are unnamed and faceless. The list is the portrait, and no screen may
  read as a testimonial. Names in a list belong to the people around them.
- A person carries several areas, whatever their job is.
- A list is connected (a recurring name appears three times or more), uneven
  (short and long titles), and has no sample-data cliché, real company, illness
  or debt.
- A person shows only what ships. The schema has no field for tags, checklists
  or priority.

`scripts/registry-cast.mjs` enforces the format and these rules, as far as a
script can, in `gen-registries.mjs --check`. The cast has no generated
bindings and no translations: another language gets a person of its own, not a
translated one.

## Consequences

- One source feeds the site, the App Store panels, the 3D device render and
  the native demo seed. The last two still hold their own copies until they
  read the cast.
- `studio.json` is the first sample world as a `legacy` person, exempt from the
  content rules. It leaves when the site is cast.
- A still is captured only for the person cast in it. Every other combination
  renders live.
- `/house/language` (Starlings) owns who the examples show; it follows this ADR.

## Links

- Review page: `septena.app/scenes/cast` (septena-site `components/scenes/cast-gallery.tsx`)
- ADR 0015 (registries), ADR 0022 (rejected: the site draws scenes in code)
