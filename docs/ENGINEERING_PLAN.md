# Engineering plan

**Status:** active. **Owner:** Claude (engineering lead since 2026-11-24, by
mz's decision). mz owns product decisions, the device tests and every step
that needs his accounts. **Last updated:** 2026-11-24.

This is the engineering order of work. The product order is in
`docs/ROADMAP.md`; this file says how the code gets there and which
engineering work goes first. Issues carry the work; this file carries the
order and the reasons.

## 1. Where the code stands (audit, 2026-11-24)

**Strong, keep it:**

- One source per concept. `registry/*.json` holds UI, copy, actions,
  settings and entity fields; `scripts/gen-registries.mjs` writes the Swift,
  Kotlin, TypeScript and Rust constants and fails CI on drift.
- Shared test vectors. `registry/conformance/*.json` is the expected answer
  for each rule on every platform.
- The shared Rust core (ADR 0025) holds the task rules. The backend, Android
  and the Apple date writes call it.
- Mutators are the one write path; one undo stack; ADRs and specs explain
  the decisions.

**Weak, fix first:**

1. The backend has no CI. Its type check and tests run only by hand, and it
   is deployed from a laptop.
2. Android has no launch guard and its conformance runner is not in CI. A
   launch crash (#308, fixed in #341) shipped unseen.
3. No check is required on `main`, and pushes cancel the Apple build on
   `main`, so `main` often has no finished build.
4. Rules still copied outside the core: the Apple list rules (D3 read half),
   the Android sync engine, the iCal feed's window.
5. `AGENTS.md` has grown into a long list of traps. Each trap that a lint
   rule or a type can enforce should become one, and leave the file.

## 2. Principles

- **CI is the gate.** A change is done when CI says so, not when an agent
  says so. Every surface (Apple, Android, backend, core, registry) has a job.
- **One copy of a rule.** A rule lives in the core or in a registry file.
  Never copy it to a platform; call it. A "LOCKSTEP" comment is a bug report.
- **Small PRs, merged the same session.** Worktree per session; `wt/*`
  branches never outlive the task.
- **mz tests on devices; agents never do.** Every PR names what mz checks by
  hand.

## 3. Order

| Phase | Work | Issues | Needs from mz |
|---|---|---|---|
| F — Foundation | F1 backend CI · F2 deploy from CI · F3 Android conformance + launch guard · F4 protected `main`, builds that finish | #342 #343 #344 #345 | F2: the deploy job is in backend.yml and skips until the CLOUDFLARE_API_TOKEN secret exists. F4: a ruleset blocks force pushes and deletion of `main`; required checks are off because every agent pushes to `main` directly, and runs on `main` finish (#410). |
| C — Core complete | Apple lists on the core (D3 read half) · Android sync on the core · server fade pass · iCal on the core | #290 #173/#247 #271 #291 | #250 device test (gates D3). #271: yes to the server running the fade pass. |
| L — Launch | The launch milestone in `docs/ROADMAP.md`: paid sync, free limits, App Store sets | Launch milestone | The store and account steps marked (mz). |
| W — Web client | Spec, then the client on the core's WASM (C2) | #21 #248 | Review of the spec. |

F runs first because every later phase leans on it: without it, each
change to the core can break a platform no one checks. C and L can run in
parallel once F1–F3 are in.

## 4. How to read progress

- GitHub milestone "F Foundation: CI is the gate" and the `track:foundation`
  label.
- `docs/SHARED_CORE_SPEC.md` (status line) for the core.
- `docs/TASK_DATES_SPEC.md` (D1–D5 status notes) for dates.
