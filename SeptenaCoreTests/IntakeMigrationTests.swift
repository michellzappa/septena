import Testing
import Foundation

// Tests for the pure intake model in SeptenaCore/IntakeModel.swift — the
// shipped templates, the label→token slug, and the kind's stored methods
// column. (The one-time legacy caffeine/cannabis migration has been removed;
// its deterministic-id/field-map tests went with it.)

@Suite struct IntakeModelTests {

  // MARK: Slug — label → stable token

  @Test func slugIsStableAndClean() {
    #expect(IntakeTemplates.slug("Blue Dream") == "blue-dream")
    #expect(IntakeTemplates.slug("  OG Kush!! ") == "og-kush")
    #expect(IntakeTemplates.slug("Sour/Diesel #2") == "sour-diesel-2")
    #expect(IntakeTemplates.slug("Café Crème") == "caf-cr-me") // non-ascii → dashes, deterministic
  }

  // MARK: Shipped templates

  @Test func caffeineTemplateMatchesConfig() {
    let seed = IntakeTemplates.caffeine()
    #expect(seed.id == "ik-caffeine")
    #expect(seed.unit == "g")
    #expect(seed.doseStyle == "amount")
    #expect(seed.containerCap == nil)        // no container model
    #expect(seed.catalogNoun == "Beans")
    #expect(seed.methods.map(\.token) == ["v60", "matcha", "other"])
    #expect(seed.methods.allSatisfy { !$0.usesContainer })
  }

  @Test func nicotineTemplateUsesContainer() {
    let seed = IntakeTemplates.nicotine()
    #expect(seed.id == "ik-nicotine")
    #expect(seed.containerNoun == "pack")
    #expect(seed.containerCap == 20)
    // The cigarette method drives the container "New pack / Continue (cig N)" rows.
    #expect(seed.methods.first { $0.token == "cigarette" }?.usesContainer == true)
    #expect(seed.methods.first { $0.token == "vape" }?.usesContainer == false)
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
