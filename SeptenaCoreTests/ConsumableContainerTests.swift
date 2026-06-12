import Testing
import Foundation

// Golden tests for SeptenaCore/ConsumableContainer.swift — the "capsule / hit"
// math behind every container-style intake tracker (cannabis being the original
// shape). The watch and phone quick-add both render these exact choices, so a
// regression silently changes the wrist list for existing users. The expected
// rows are spelled out here as the contract (they were once an equivalence check
// against the now-deleted `CannabisCapsule`; the contract is the same).

@Suite struct ConsumableContainerTests {

  // A container "vape" method (cap 3) plus a capsule-free "edible" — the shape
  // the migrator synthesizes for the legacy cannabis kind. Symbols/nouns live
  // in config now rather than being hardcoded in a per-substance helper.
  private static let cannabisMethods: [ConsumableContainer.Method] = [
    .init(token: "vape",   label: "Vape",   symbol: "wind",        usesContainer: true),
    .init(token: "edible", label: "Edible", symbol: "circle.fill", usesContainer: false),
  ]

  private func cannabisChoices(lastCount: Int?, cap: Int) -> [SuggestionBlocks.Choice] {
    ConsumableContainer.choices(
      lastCount: lastCount,
      containerCap: cap,
      containerNoun: "capsule",
      countNoun: "Hit",
      methods: Self.cannabisMethods
    )
  }

  // The full state space the watch can be in — no last hit, an inactive zero, a
  // partial hit (offers Continue), the hit that filled the cap, and an over-cap
  // value. Continue appears only while the capsule has room (1 ≤ last < cap).
  @Test func capsuleChoicesAcrossStates() {
    let newAndEdible: [SuggestionBlocks.Choice] = [
      .init(value: "vape:1", label: "New capsule", symbol: "plus.circle"),
      .init(value: "edible", label: "Edible",      symbol: "circle.fill"),
    ]
    func continueRow(_ hit: Int) -> SuggestionBlocks.Choice {
      .init(value: "vape:\(hit)", label: "Continue (Hit \(hit))", symbol: "arrow.clockwise")
    }
    #expect(cannabisChoices(lastCount: nil, cap: 3) == newAndEdible)
    #expect(cannabisChoices(lastCount: 0,   cap: 3) == newAndEdible)
    #expect(cannabisChoices(lastCount: 1,   cap: 3) == [continueRow(2)] + newAndEdible)
    #expect(cannabisChoices(lastCount: 2,   cap: 3) == [continueRow(3)] + newAndEdible)
    #expect(cannabisChoices(lastCount: 3,   cap: 3) == newAndEdible)
    #expect(cannabisChoices(lastCount: 4,   cap: 3) == newAndEdible)
  }

  // The exact rows for the two interesting states, spelled out so a regression
  // shows up as a readable diff rather than just "!= expected".
  @Test func activeCapsuleOffersContinueNewEdible() {
    let out = cannabisChoices(lastCount: 1, cap: 3)
    #expect(out == [
      .init(value: "vape:2", label: "Continue (Hit 2)", symbol: "arrow.clockwise"),
      .init(value: "vape:1", label: "New capsule",      symbol: "plus.circle"),
      .init(value: "edible", label: "Edible",           symbol: "circle.fill"),
    ])
  }

  @Test func filledCapsuleDropsContinue() {
    let out = cannabisChoices(lastCount: 3, cap: 3) // hit 3 filled the cap
    #expect(out == [
      .init(value: "vape:1", label: "New capsule", symbol: "plus.circle"),
      .init(value: "edible", label: "Edible",      symbol: "circle.fill"),
    ])
  }

  @Test func noVapeYetOffersNewCapsuleOnly() {
    let out = cannabisChoices(lastCount: nil, cap: 3)
    #expect(out == [
      .init(value: "vape:1", label: "New capsule", symbol: "plus.circle"),
      .init(value: "edible", label: "Edible",      symbol: "circle.fill"),
    ])
  }

  // Helper-level contract (used directly by the quick-add menus): a last count
  // in [1, cap) means the capsule has room; continueCount is the next hit.
  @Test func activeAndContinueContract() {
    #expect(ConsumableContainer.hasActiveContainer(lastCount: nil, containerCap: 3) == false)
    #expect(ConsumableContainer.hasActiveContainer(lastCount: 0,   containerCap: 3) == false)
    #expect(ConsumableContainer.hasActiveContainer(lastCount: 1,   containerCap: 3) == true)
    #expect(ConsumableContainer.hasActiveContainer(lastCount: 2,   containerCap: 3) == true)
    #expect(ConsumableContainer.hasActiveContainer(lastCount: 3,   containerCap: 3) == false)
    #expect(ConsumableContainer.hasActiveContainer(lastCount: 4,   containerCap: 3) == false)
    #expect(ConsumableContainer.continueCount(lastCount: nil) == 1)
    #expect(ConsumableContainer.continueCount(lastCount: 0)   == 1)
    #expect(ConsumableContainer.continueCount(lastCount: 2)   == 3)
    #expect(ConsumableContainer.continueCount(lastCount: 4)   == 5)
  }

  // Decode `choices` values back into (method, count). Tolerant of a bare
  // "vape" / "edible" (no count) so older payloads still write something.
  @Test func parseDecodesValues() {
    let cases: [(value: String, method: String, count: Int?)] = [
      ("vape:1", "vape", 1), ("vape:2", "vape", 2), ("edible", "edible", nil),
      ("vape", "vape", nil), ("v60", "v60", nil), ("matcha:9", "matcha", 9),
    ]
    for c in cases {
      let got = ConsumableContainer.parse(value: c.value)
      #expect(got.method == c.method, "value=\(c.value)")
      #expect(got.count == c.count, "value=\(c.value)")
    }
  }

  // The no-container case (caffeine): every method lists flat as a plain choice,
  // `usesContainer` ignored — the same set the static SuggestionBlocks row holds.
  @Test func noContainerListsMethodsFlat() {
    let caffeine: [ConsumableContainer.Method] = [
      .init(token: "v60",    label: "V60",    symbol: "cup.and.saucer", usesContainer: false),
      .init(token: "matcha", label: "Matcha", symbol: "leaf",           usesContainer: false),
      .init(token: "other",  label: "Other",  symbol: "mug",            usesContainer: false),
    ]
    let out = ConsumableContainer.choices(
      lastCount: nil, containerCap: nil, containerNoun: "", countNoun: "", methods: caffeine
    )
    #expect(out == [
      .init(value: "v60",    label: "V60",    symbol: "cup.and.saucer"),
      .init(value: "matcha", label: "Matcha", symbol: "leaf"),
      .init(value: "other",  label: "Other",  symbol: "mug"),
    ])
  }
}
