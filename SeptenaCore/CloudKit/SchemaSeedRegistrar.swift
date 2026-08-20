import Foundation
import CloudKit
import OSLog

#if DEBUG
/// One-shot **DEBUG-only** dev utility that registers CloudKit schema fields
/// which exist in code but have never been written in this Development
/// environment — optional fields no real record happened to set, so they
/// never auto-registered. See `docs/CloudKitSchema.md` § "Dev schema
/// reconciliation".
///
/// Why it matters: **Production CloudKit does not auto-register fields on
/// write** (unlike Development). Any field the app can write that isn't in the
/// deployed Production schema makes that record's save fail. So every such
/// field must be present in the Development schema *before* "Deploy Schema
/// Changes to Production", or a real user hitting it in Prod gets a silent
/// write failure / stuck `CKSyncEngine` change.
///
/// Mechanism — deliberately isolated: it writes throwaway records into a
/// dedicated temp zone (`schema-seed-temp`), **never** the live `septena-v1`
/// zone. `CKSyncEngine` only tracks `septena-v1`, so these records never sync
/// to the user's watch / widgets / other devices. CloudKit schema is
/// container+environment-wide (zone-independent), so the fields still register
/// in the Development schema. The temp zone is then deleted — and because the
/// Development schema is additive, deleting records never drops the fields.
///
/// Idempotent and self-disabling (UserDefaults flag, only set on success so a
/// failure retries next launch). Gated to DEBUG so it can never run against a
/// Production (TestFlight/App Store) build.
@MainActor
enum SchemaSeedRegistrar {
  static let userDefaultsKey = "schema.seedMissingFields.v1"

  private static let logger = Log.schemaSeed

  private static let tempZoneID = CKRecordZone.ID(
    zoneName: "schema-seed-temp",
    ownerName: CKCurrentUserDefaultName
  )

  /// Fire-and-forget, run-once boot hook gated by `userDefaultsKey`.
  static func runIfNeeded() {
    guard !UserDefaults.standard.bool(forKey: userDefaultsKey) else { return }
    Task {
      do {
        let summary = try await register()
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        logger.info("SchemaSeedRegistrar succeeded:\n\(summary, privacy: .public)")
      } catch {
        // Leave the flag unset so the next launch retries. Always attempt
        // temp-zone teardown so a partial run leaves nothing behind.
        logger.error("SchemaSeedRegistrar failed: \(error.localizedDescription, privacy: .public)")
        try? await deleteTempZone()
      }
    }
  }

  /// Writes one throwaway record per affected type, populating only the
  /// fields the Dev-schema diff found missing (all `String`/`Double`, so
  /// there's no risk of registering an existing field with a wrong type),
  /// then tears the temp zone down. Returns a human-readable summary.
  @discardableResult
  static func register() async throws -> String {
    let db = CKContainer(identifier: SeptenaCloudKit.containerIdentifier).privateCloudDatabase

    // Temp zone must exist before any record save in it.
    _ = try await db.save(CKRecordZone(zoneID: tempZoneID))

    let seeds: [CKRecord] = [
      seed(TaskCloudKitSchema.recordType, "seed-task-recurrence",
        strings: [
          TaskCloudKitSchema.Field.recurrencePaused,
          TaskCloudKitSchema.Field.recurrenceSeriesID,
          TaskCloudKitSchema.Field.recurrenceAnchorDate,
        ]),
      seed(AreaCloudKitSchema.recordType, "seed-area", strings: [
        AreaCloudKitSchema.Field.context,
        AreaCloudKitSchema.Field.attachment,
      ]),
      seed(ProjectCloudKitSchema.recordType, "seed-project", strings: [
        ProjectCloudKitSchema.Field.completedAt,
        ProjectCloudKitSchema.Field.context,
        ProjectCloudKitSchema.Field.githubRepo,
        ProjectCloudKitSchema.Field.attachment,
      ]),
      seed(SessionTypeCloudKitSchema.recordType, "seed-sessiontype", strings: [
        SessionTypeCloudKitSchema.Field.kind,
      ]),
      seed(NutritionEntryCloudKitSchema.recordType, "seed-nutrition-entry",
        strings: [
          NutritionEntryCloudKitSchema.Field.mealType,
          NutritionEntryCloudKitSchema.Field.ingredients,
        ],
        doubles: [
          NutritionEntryCloudKitSchema.Field.sugarG,
          NutritionEntryCloudKitSchema.Field.saturatedFatG,
          NutritionEntryCloudKitSchema.Field.alcoholG,
          NutritionEntryCloudKitSchema.Field.sodiumMg,
          NutritionEntryCloudKitSchema.Field.cholesterolMg,
          NutritionEntryCloudKitSchema.Field.potassiumMg,
        ]),
      seed(NutritionDailySummaryCloudKitSchema.recordType, "seed-nutrition-day",
        doubles: [
          NutritionDailySummaryCloudKitSchema.Field.sugarG,
          NutritionDailySummaryCloudKitSchema.Field.saturatedFatG,
          NutritionDailySummaryCloudKitSchema.Field.alcoholG,
          NutritionDailySummaryCloudKitSchema.Field.sodiumMg,
          NutritionDailySummaryCloudKitSchema.Field.cholesterolMg,
          NutritionDailySummaryCloudKitSchema.Field.potassiumMg,
        ]),
    ]

    let (saveResults, _) = try await db.modifyRecords(saving: seeds, deleting: [])
    for (recordID, result) in saveResults {
      if case .failure(let error) = result {
        try? await deleteTempZone()
        throw SchemaSeedError.recordSaveFailed(recordID.recordName, error)
      }
    }

    // Remove every seed record in one shot. Schema fields persist.
    try await deleteTempZone()

    return """
    Registered missing Development-schema fields on \(saveResults.count) record types:
    • Task.recurrencePaused, .recurrenceSeriesID, .recurrenceAnchorDate
    • Area.context, .attachment (reservedString2)
    • Project.completedAt, .context, .githubRepo, .attachment (reservedString1)
    • SessionType.kind
    • NutritionEntry.mealType, .ingredients, .sugarG, .saturatedFatG, .alcoholG, .sodiumMg, .cholesterolMg, .potassiumMg
    • NutritionDaySum.sugarG, .saturatedFatG, .alcoholG, .sodiumMg, .cholesterolMg, .potassiumMg
    Temp zone 'schema-seed-temp' deleted. Verify in CloudKit Console → Schema, then Deploy to Production.
    """
  }

  // MARK: - Helpers

  private static func seed(
    _ recordType: String,
    _ recordName: String,
    strings: [String] = [],
    doubles: [String] = []
  ) -> CKRecord {
    let record = CKRecord(
      recordType: recordType,
      recordID: CKRecord.ID(recordName: recordName, zoneID: tempZoneID)
    )
    for key in strings { record[key] = "schema-seed" as CKRecordValue }
    for key in doubles { record[key] = 0.0 as CKRecordValue }
    return record
  }

  private static func deleteTempZone() async throws {
    let db = CKContainer(identifier: SeptenaCloudKit.containerIdentifier).privateCloudDatabase
    _ = try await db.deleteRecordZone(withID: tempZoneID)
  }

  enum SchemaSeedError: LocalizedError {
    case recordSaveFailed(String, Error)

    var errorDescription: String? {
      switch self {
      case .recordSaveFailed(let name, let error):
        return "Failed to save seed record \(name): \(error.localizedDescription)"
      }
    }
  }
}
#endif
