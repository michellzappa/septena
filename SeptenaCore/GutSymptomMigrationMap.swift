import Foundation

/// Pure, dependency-free core of the Gut → Symptoms migration: stable ids and
/// the severity maps that turn a bowel-movement's `discomfortLevel` / `blood`
/// fields into standalone symptom events. Foundation-only so it unit-tests in
/// the hermetic `SeptenaCoreTests` bundle (see docs/GUT_SYMPTOMS_MIGRATION_PLAN).
public enum GutSymptomMap {
  /// Stable definition ids, used only when no same-titled definition exists yet
  /// (the migrator prefers an existing title match — see `ensureDefinition`).
  public static let discomfortDefinitionID = "gut-sym-discomfort"
  public static let bloodDefinitionID = "gut-sym-blood"

  public static let discomfortTitle = "Abdominal discomfort"
  public static let bloodTitle = "Blood in stool"

  /// Deterministic symptom-event id from the source gut row, so re-running the
  /// migration upserts in place instead of duplicating.
  public static func discomfortEventID(gutID: String) -> String { "gut-discomfort:\(gutID)" }
  public static func bloodEventID(gutID: String) -> String { "gut-blood:\(gutID)" }

  /// `discomfortLevel` ("low" / "med" / "high") → 0–10 severity. `nil` for empty
  /// or unknown so the migrator skips the row.
  public static func discomfortSeverity(_ level: String?) -> Int? {
    switch level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "low": return 3
    case "med", "medium": return 6
    case "high": return 9
    default: return nil
    }
  }

  /// Legacy `blood` count (1–3, occasionally higher) → 0–10 severity. `nil` when
  /// there's no blood to migrate.
  public static func bloodSeverity(_ blood: Int) -> Int? {
    guard blood > 0 else { return nil }
    return min(9, blood * 3)
  }
}
