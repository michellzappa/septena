import Testing
import Foundation

// Tests for the pure migration core in SeptenaCore/IntakeModel.swift — the
// deterministic-id + field-map logic that §7.1 calls "the whole trick". The
// CloudKit/SwiftData-bound migrator (Migration.swift) is integration-tested
// once the Dev schema is deployed; this covers the part that must be exactly
// right for idempotence and multi-device convergence.

@Suite struct IntakeMigrationTests {

  // MARK: Deterministic ids

  @Test func eventIdIsPureFunctionOfSource() {
    #expect(IntakeMigrationMap.eventID(section: "caffeine", legacyID: "ab12cd34") == "caffeine:ab12cd34")
    #expect(IntakeMigrationMap.eventID(section: "cannabis", legacyID: "ff99") == "cannabis:ff99")
    // Same input → same id, always (the convergence guarantee).
    #expect(IntakeMigrationMap.eventID(section: "caffeine", legacyID: "x")
            == IntakeMigrationMap.eventID(section: "caffeine", legacyID: "x"))
  }

  @Test func strainSlugIsStableAndClean() {
    #expect(IntakeMigrationMap.slug("Blue Dream") == "blue-dream")
    #expect(IntakeMigrationMap.slug("  OG Kush!! ") == "og-kush")
    #expect(IntakeMigrationMap.slug("Sour/Diesel #2") == "sour-diesel-2")
    #expect(IntakeMigrationMap.slug("Café Crème") == "caf-cr-me") // non-ascii → dashes, deterministic
  }

  // MARK: Field map — lossless, the three renames

  @Test func caffeineEventMapsLosslessly() {
    let legacy = LegacyIntakeEvent(section: "caffeine", legacyID: "c1", date: "2026-06-10",
                                   method: "v60", note: "morning", grams: 18,
                                   beanOrStrain: "house-blend", hit: nil,
                                   occurredAt: nil, updatedAt: nil)
    let m = IntakeMigrationMap.map(legacy)
    #expect(m.id == "caffeine:c1")
    #expect(m.kindID == IntakeMigrationMap.caffeineKindID)
    #expect(m.method == "v60")
    #expect(m.amount == 18)            // grams → amount
    #expect(m.count == nil)
    #expect(m.itemID == "caffeine:house-blend") // beans (an id) → itemID
    #expect(m.note == "morning")
  }

  @Test func cannabisVapeMapsHitToCount() {
    let legacy = LegacyIntakeEvent(section: "cannabis", legacyID: "z9", date: "2026-06-10",
                                   method: "vape", grams: 0.05, beanOrStrain: "Blue Dream", hit: 2)
    let m = IntakeMigrationMap.map(legacy)
    #expect(m.id == "cannabis:z9")
    #expect(m.kindID == IntakeMigrationMap.cannabisKindID)
    #expect(m.count == 2)             // hit → count
    #expect(m.amount == 0.05)         // grams → amount
    #expect(m.itemID == "cannabis:blue-dream") // strain (text) → slug → itemID
  }

  @Test func cannabisEdibleNoStrainHasNoItemRef() {
    let legacy = LegacyIntakeEvent(section: "cannabis", legacyID: "e1", date: "2026-06-10",
                                   method: "edible", grams: 0.1, beanOrStrain: nil, hit: nil)
    let m = IntakeMigrationMap.map(legacy)
    #expect(m.itemID == nil)
    #expect(m.amount == 0.1)
    #expect(m.count == nil)
  }

  @Test func emptyBeanOrStrainYieldsNilItem() {
    let legacy = LegacyIntakeEvent(section: "caffeine", legacyID: "c2", date: "2026-06-10",
                                   method: "matcha", beanOrStrain: "")
    #expect(IntakeMigrationMap.map(legacy).itemID == nil)
  }

  // MARK: Seeds

  @Test func caffeineSeedMatchesTodaysConfig() {
    let seed = IntakeMigrationMap.caffeineSeed()
    #expect(seed.id == "ik-caffeine")
    #expect(seed.unit == "g")
    #expect(seed.doseStyle == "amount")
    #expect(seed.containerCap == nil)        // no container model
    #expect(seed.catalogNoun == "Beans")
    #expect(seed.methods.map(\.token) == ["v60", "matcha", "other"])
    #expect(seed.methods.allSatisfy { !$0.usesContainer })
  }

  @Test func cannabisSeedSynthesizesContainerAndCount() {
    let seed = IntakeMigrationMap.cannabisSeed(name: "Cannabis", usesPerCapsule: 3,
                                               observedMethods: ["vape", "edible"])
    #expect(seed.id == "ik-cannabis")
    #expect(seed.doseStyle == "both")
    #expect(seed.countNoun == "Hit")
    #expect(seed.containerNoun == "capsule")
    #expect(seed.containerCap == 3)
    // vape carries the container flag; edible does not — feeds ConsumableContainer.
    let vape = seed.methods.first { $0.token == "vape" }
    let edible = seed.methods.first { $0.token == "edible" }
    #expect(vape?.usesContainer == true)
    #expect(edible?.usesContainer == false)
  }

  @Test func cannabisSeedKeepsUnexpectedMethodsAsPlainRows() {
    let seed = IntakeMigrationMap.cannabisSeed(usesPerCapsule: 4,
                                               observedMethods: ["vape", "tincture"])
    let tincture = seed.methods.first { $0.token == "tincture" }
    #expect(tincture != nil)
    #expect(tincture?.usesContainer == false)
    #expect(tincture?.label == "Tincture")
  }

  @Test func cannabisSeedDefaultsMethodsWhenNoneObserved() {
    let seed = IntakeMigrationMap.cannabisSeed(usesPerCapsule: 3, observedMethods: [])
    #expect(Set(seed.methods.map(\.token)) == ["vape", "edible"])
  }

  // MARK: methodsJSON round-trip (the kind's stored column)

  @Test func methodRowsJSONRoundTrip() throws {
    let rows = [
      IntakeMethodRow(token: "vape", label: "Vape", symbol: "wind", usesContainer: true),
      IntakeMethodRow(token: "edible", label: "Edible", symbol: "circle.fill", defaultAmount: 0.1),
    ]
    let data = try JSONEncoder().encode(rows)
    let back = try JSONDecoder().decode([IntakeMethodRow].self, from: data)
    #expect(back == rows)
  }
}
