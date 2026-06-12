import Testing
import Foundation

// Golden tests for SeptenaCore/GutSymptomMigrationMap.swift — the pure core of
// the Gut → Symptoms migration. The contract: severity maps are stable and
// deterministic, and event ids are a pure function of the source gut row (so
// re-running the migration upserts in place instead of duplicating).

@Suite struct GutSymptomMapTests {

  @Test func discomfortSeverityMapsKnownLevels() {
    #expect(GutSymptomMap.discomfortSeverity("low") == 3)
    #expect(GutSymptomMap.discomfortSeverity("med") == 6)
    #expect(GutSymptomMap.discomfortSeverity("medium") == 6)
    #expect(GutSymptomMap.discomfortSeverity("high") == 9)
  }

  @Test func discomfortSeverityIsCaseAndWhitespaceInsensitive() {
    #expect(GutSymptomMap.discomfortSeverity("  HIGH ") == 9)
    #expect(GutSymptomMap.discomfortSeverity("Low") == 3)
  }

  @Test func discomfortSeverityNilForEmptyOrUnknown() {
    #expect(GutSymptomMap.discomfortSeverity("") == nil)
    #expect(GutSymptomMap.discomfortSeverity(nil) == nil)
    #expect(GutSymptomMap.discomfortSeverity("—") == nil)
    #expect(GutSymptomMap.discomfortSeverity("severe") == nil)
  }

  @Test func bloodSeverityScalesAndClamps() {
    #expect(GutSymptomMap.bloodSeverity(0) == nil)
    #expect(GutSymptomMap.bloodSeverity(-1) == nil)
    #expect(GutSymptomMap.bloodSeverity(1) == 3)
    #expect(GutSymptomMap.bloodSeverity(2) == 6)
    #expect(GutSymptomMap.bloodSeverity(3) == 9)
    #expect(GutSymptomMap.bloodSeverity(5) == 9) // clamps at 9
  }

  @Test func eventIDsAreDeterministicAndDistinct() {
    #expect(GutSymptomMap.discomfortEventID(gutID: "ba4e73e4") == "gut-discomfort:ba4e73e4")
    #expect(GutSymptomMap.bloodEventID(gutID: "ba4e73e4") == "gut-blood:ba4e73e4")
    // Same source row yields two distinct ids → discomfort and blood never collide.
    #expect(GutSymptomMap.discomfortEventID(gutID: "x") != GutSymptomMap.bloodEventID(gutID: "x"))
  }
}
