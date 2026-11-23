# 0028. The registry owns vocabulary; each platform owns layout and interaction

- Status: accepted
- Date: 2026-11-23
- Deciders: mz

## Context

ADR 0015 put the cross-platform contracts in `registry/*.json`. ADR 0020
added copy and translations. ADR 0025 moved pure task rules into the shared
Rust core. mz asked how far this can go: "to which degree can our design be
registry-oriented, so platform implementations don't drift?"

An audit on 2026-11-23 found:

- The Apple shells read the registry heavily (about 180 reads of
  `RegistrySettings`, 130 of `RegistryActions`, 70 of `RegistryPrompts`).
  The generator, the reader check and the `registry-owned-literal` lint stop
  most drift there.
- Android reads registry copy at run time through `RegistryCatalog`, but
  names entries by string literals. A removed ID compiles and shows an empty
  string. No lint scans Kotlin.
- Android keeps Kotlin copies of task rules (`TaskFadeRules`,
  `RecurrenceRules`, `TaskViewRules`, `TaskReminderRules`,
  `ConversationRules`). ADR 0025 says they become core calls (#247).
- The Swift model enums are hand-written (#259).
- About 136 `Text("…")` literals in the Swift shells are outside the
  registry. The lint catches only literals that already equal a registry
  string.
- Nothing checks a `ships` claim in `capabilities.json` against code.
- Each shell decides by hand which attributes a task row shows and which
  blocks a screen holds.

A registry that also describes layout, focus, gestures and motion is a
server-driven UI language. It fights the AGENTS.md rule "use standard,
default SwiftUI, never get creative", and the platform traps that AGENTS.md
lists (focus in a split view, `NSTableView` batch updates, row hit areas)
come from exactly that layer.

## Decision

The registry owns **vocabulary**: every noun, verb, number and word that
more than one platform shows. That is entities and enums, rule constants and
conformance vectors, actions and shortcuts, menus, destinations, settings,
notices, prompts, toasts, icons, tokens, plans, copy and translations, flow
steps, and the order of attributes and blocks on a surface. Rule logic lives
once, in the shared core (ADR 0025). Each platform owns **layout and
interaction**: geometry, navigation idiom, focus, keyboard handling,
gestures and motion, written in that platform's standard toolkit.

Every platform reads the registry through **generated, typed members**,
never through string IDs or copied text, and the same checks guard every
platform:

1. Generated code with no reader fails `gen-registries --check`.
2. A shell literal that equals registry copy or a registry ID fails the
   design lint, in Swift and in Kotlin.
3. A new user-facing literal in a shell fails unless it is on a
   shrinking allowlist.
4. A `ships` claim in `capabilities.json` needs a reader on that platform.

## Consequences

- A new feature starts as a registry entry. The shells render it. A second
  platform gets the words, order and gating at no extra cost; it writes
  only the layout.
- Parity of behavior comes from the conformance vectors and the core, not
  from shared layout. Two platforms can look different and still agree on
  every word and rule.
- The registry grows a `rowAnatomy` and `screenSlots` block (#286), but no
  geometry.
- Each new string costs a registry edit and a generator run. Agents must
  not bypass the lint with an allowlist entry that has no issue.
- Android work in flight must switch from string IDs to generated constants
  (#283).

## Links

- ADR 0013, ADR 0015, ADR 0020, ADR 0024, ADR 0025
- #180 Kotlin codegen (parent of #283)
- #283 Android typed registry IDs and the Kotlin literal lint
- #247 Android calls the core instead of Kotlin rule copies
- #259 Swift model enums read the registry
- #284 Every user-facing shell literal comes from the registry (extends #260)
- #285 A `ships` claim needs a reader
- #286 Spec: row anatomy and screen slots
