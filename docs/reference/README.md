# Things 3 Reference

Goal: redo the Engage app with the look & feel of Things 3 for iOS. This is a personal app, so we copy closely rather than aiming for originality.

## How to use these docs

- **visual-design.md** — colors, typography, spacing, iconography
- **navigation.md** — sidebar / list / detail structure, transitions
- **interactions.md** — gestures, animations, the Magic Plus button
- **components.md** — task row, checkbox, header, date chip, etc.
- **screens.md** — screen-by-screen spec mapped to your screenshots

When implementing a feature, reference the relevant doc sections. Spec is intentionally opinionated but not rigid — prefer "feels right" over pixel-perfect.

## Philosophy of Things 3 (what we're copying)

1. **Calm, white, spacious.** No chrome, no tab bars, no visual noise. Content floats on white.
2. **Typographic hierarchy, not boxes.** Sections are separated by typography + thin dividers, not cards or containers.
3. **Soft motion.** Everything springs, slides, or fades — nothing pops. Animations are a core part of the identity.
4. **Gestures first.** Swipe to schedule, swipe to complete. The Magic Plus button drags into the list to insert at a specific position.
5. **Color is accent only.** The UI is black/white/gray. Color (blue, yellow, red, green) is reserved for meaningful accents: Today star, Inbox icon, overdue flag, project dot.
6. **Dates are human.** "today", "3d left", "Sun", "This Evening" — never "2026-04-07".

## Sources

- Cultured Code design blog: https://culturedcode.com/things/blog/
- Federico Viticci's Things 3 review (MacStories)
- The screenshots in `/screenshots/` (provided by user, 2026-04)

## Our screenshots (reference)

1. **Sidebar** — Inbox, Today, Upcoming, Anytime, Someday, Logbook + Areas with nested Projects
2. **Inbox list** — minimal, two unscheduled tasks, checkbox + title only
3. **Today list** — calendar events block at top, then tasks grouped by Area/Project with headers
4. **Project list (Morning)** — repeating tasks with day chips and recurrence glyph
5. **Multi-select mode** — radio-style selection circles on right, bottom action bar (When / Move / Delete / •••)
