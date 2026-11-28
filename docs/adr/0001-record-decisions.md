# 0001. Record decisions as ADRs; plan with specs, roadmap, issues

- Status: accepted
- Date: 2026-11-19
- Deciders: mz

## Context

`docs/` holds about 65 files: plans, specs, handoffs, audits. Most have no
status, and several mix a decision, a design and a build log in one file.
Several sessions run in parallel, and agents start without the history of
earlier sessions. Decisions get re-argued, and stale plans get followed. Two
examples: the Android plan and the native sharing spec both rest on iCloud,
which ADR 0002 drops.

## Decision

Planning uses four records, each with one job (`docs/README.md`):

- **ADR** for a decision and its reason. Frozen once accepted.
- **Spec** for how one feature works, with phases. Frozen as historical when it
  ships.
- **Roadmap** (`docs/ROADMAP.md`) for the order of tracks and milestones.
- **GitHub issues and milestones** on `septena/septena` for units of work.
  Every issue links its spec. Every milestone maps to one roadmap phase.

Existing docs stay where they are. The index gives each one a status. New work
follows the rules in `docs/README.md`.

## Consequences

- An agent reads `docs/README.md` → the ADRs for its area → one spec → its
  issue. It does not need to read the whole folder.
- Decisions carry a date and a reason, so a later session can see why
  something is the way it is before it changes it.
- Cost: every hard-to-reverse decision needs a short extra file.
- The issue tracker is public. Strategy and pricing stay out of it.

## Links

- `docs/README.md`, `docs/ROADMAP.md`
