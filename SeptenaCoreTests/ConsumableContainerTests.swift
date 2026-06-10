import Testing
import Foundation

// Golden tests for SeptenaCore/ConsumableContainer.swift. The contract that
// matters: fed the cannabis config, the generic container must produce output
// byte-identical to the legacy `CannabisCapsule` it replaces — because the
// watch and phone quick-add both render those exact choices today and the
// migrator will reconstruct cannabis by feeding this config. If these ever
// diverge, the wrist list silently changes for existing users.

@Suite struct ConsumableContainerTests {

  // The cannabis kind as the migrator will synthesize it: a container "vape"
  // method (cap 3) plus a capsule-free "edible". Symbols/nouns reproduce
  // `CannabisCapsule`'s hardcoded ones exactly — these live in config now.
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

  // The whole point: identical choices across the full state space the watch
  // can be in — no last hit, a filled/partial/over-cap last hit, hit zero.
  @Test func matchesCannabisCapsuleAcrossStates() {
    for lastHit in [nil, 0, 1, 2, 3, 4] as [Int?] {
      let legacy  = CannabisCapsule.choices(lastHit: lastHit, usesPerCapsule: 3)
      let generic = cannabisChoices(lastCount: lastHit, cap: 3)
      #expect(generic == legacy, "lastHit=\(String(describing: lastHit))")
    }
  }

  // The exact rows for the two interesting states, spelled out so a regression
  // shows up as a readable diff rather than just "!= legacy".
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

  // Helper-level identity, since call sites use these directly (CannabisQuickAddMenu).
  @Test func activeAndContinueMatchLegacy() {
    for lastHit in [nil, 0, 1, 2, 3, 4] as [Int?] {
      #expect(ConsumableContainer.hasActiveContainer(lastCount: lastHit, containerCap: 3)
              == CannabisCapsule.hasActiveCapsule(lastHit: lastHit, usesPerCapsule: 3))
      #expect(ConsumableContainer.continueCount(lastCount: lastHit)
              == CannabisCapsule.continueHit(lastHit: lastHit))
    }
  }

  @Test func parseRoundTripsLikeLegacy() {
    for value in ["vape:1", "vape:2", "edible", "vape", "v60", "matcha:9"] {
      let legacy  = CannabisCapsule.parse(value: value)
      let generic = ConsumableContainer.parse(value: value)
      #expect(generic.method == legacy.method)
      #expect(generic.count == legacy.hit)
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
