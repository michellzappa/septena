# Changelog updates

A change a person can see in the task app (Septena on iPhone, iPad and Mac)
gets one file in `changelog/updates/`. The updates show on
`septena.app/changelog`, newest first. Septena Life's release notes stay in
`Septena/Resources/changelog.json`; they are not updates.

## Write one

Name it `YYYY-MM-DD-short-slug.md`, with today's date and a slug no other
change would pick. One file is one change. Two changes are two files. Small
fixes from one day can share a file when they read better together.

```markdown
---
id: 2026-11-20-today-order
date: 2026-11-20
kind: new
platforms: [ios, ipad, mac]
refs: [septena#66]
---

**Today keeps its own order.** Optional detail: what a person notices.
```

- `id` is the file name without `.md`.
- `kind` is `new` (a person could not do it before), `improved` (it works or
  reads better), `fixed` (it was broken), or `removed`.
- `platforms` lists `ios`, `ipad`, `mac`, one or more.
- `refs` lists issues and pull requests (`septena#87`), or `[]`.
- `feature` (optional) is a feature ID from the task app's feature map.
- No `version`: the release step assigns it.
- The body starts with a bold headline in English. Updates are public: no
  internal paths, code names or people's names, and no em dashes. Headlines
  go through the humanizer skill.

A change nobody sees (docs, tools, a refactor, the factory, Septena Life)
needs no update.

## Commands

```sh
node tools/changelog.mjs           # the updates, newest first
node tools/changelog.mjs --check   # every file is well formed
node tools/changelog.mjs --json    # what septena.app/changelog renders
```
