import CloudKit
import SwiftData
import WidgetKit

/// Publishes a single, tiny CloudKit record holding the watch's entire "Next"
/// payload so the watch can do one O(1) `record(for:)` read instead of replaying
/// the whole zone. Written to the **default** private zone so it stays clear of
/// CKSyncEngine's `septena-v1` zone.
///
/// The payload is the full day's open checklist (`loadNextItems` with no bucket
/// filter) — every habit is tagged with its bucket in `subtitle`, so the watch
/// filters to the current time-of-day bucket itself and the snapshot stays valid
/// all day. It's rewritten on every checklist mutation and on app foreground.
enum WatchSnapshotPublisher {
  static let recordType = "WatchSnapshot"
  static let recordName = "watch-next-snapshot"
  private static let containerID = "iCloud.com.septena.cloud"

  /// Compute on the main actor (SwiftData read), then save off-main. Best-effort:
  /// a failed write is retried by the next mutation / foreground.
  @MainActor
  static func publish(context: ModelContext, date: String = SeptenaDate.today) {
    // The full Next feed (suggestions + tasks/chores/habits/supplements in the
    // user's saved section order) comes from the one shared builder, so the
    // watch snapshot can never diverge from the app's Next list.
    let items = NextFeed.flat(context: context, date: date)
    // Carry this phone's current linger prefs in the payload so the watch and
    // widget filter to the current bucket exactly as this phone's Next list does
    // (App Group defaults are per-device, so they can't reach the watch otherwise).
    let defaults = UserDefaults.standard
    let lingerHabits = defaults.object(forKey: NextLinger.habitsKey) as? Bool
      ?? NextLinger.habitsDefault
    let lingerSupplements = defaults.object(forKey: NextLinger.supplementsKey) as? Bool
      ?? NextLinger.supplementsDefault
    // The user's actual (possibly customized) section accents, so the watch
    // tints its Next group rules to match the phone instead of a default
    // palette. Falls back to the shipped baseline when nothing's mirrored yet.
    let sections = SettingsMirror.loadSections(context: context)
    let configs = sections.isEmpty ? SectionTheme.defaultPalette : sections
    let sectionColors = Dictionary(configs.map { ($0.key, $0.color) },
                                   uniquingKeysWith: { a, _ in a })
    // Cannabis capsule state so the watch quick-add mirrors the phone menu's
    // Continue (Hit N) / New capsule / Edible. The cap is the user's setting
    // (ResponseCache key matches `SettingsView.CacheKey.cannabis`), default 3.
    // The last vape's hit prefers today's, else the most recent vape — matching
    // the phone's `lastCannabisVape` fallback.
    let usesPerCapsule = ResponseCache.load(CannabisConfig.self,
                                            forKey: "settings.cannabis")?.usesPerCapsule ?? 3
    let vapesDesc = FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.method == "vape" },
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)])
    let vapes = (try? context.fetch(vapesDesc)) ?? []
    let lastVapeHit = (vapes.first { $0.date == date } ?? vapes.first)?.hit
    let response = NextItemsResponse(date: date, bucket: "", items: items,
                                     lingerHabits: lingerHabits,
                                     lingerSupplements: lingerSupplements,
                                     sectionColors: sectionColors,
                                     cannabisUsesPerCapsule: usesPerCapsule,
                                     cannabisLastVapeHit: lastVapeHit)
    guard let payload = try? JSONEncoder().encode(response) else { return }

    // Nudge the iOS "Next" home/lock-screen widget to re-read the snapshot.
    // Same trigger as the watch complication's reload — every checklist edit
    // and app foreground flows through here. The kind string matches
    // `NextWidget.kind` in the SeptenaWidgets target (separate module, so it
    // can't be referenced directly). No-op on platforms without the widget.
    #if os(iOS)
    WidgetCenter.shared.reloadTimelines(ofKind: "NextWidget")
    #endif

    Task.detached(priority: .utility) {
      await save(payload: payload, date: date)
    }
  }

  private static func save(payload: Data, date: String) async {
    let db = CKContainer(identifier: containerID).privateCloudDatabase
    let id = CKRecord.ID(recordName: recordName)   // default zone
    do {
      let record = (try? await db.record(for: id))
        ?? CKRecord(recordType: recordType, recordID: id)
      record["payload"]   = payload as CKRecordValue
      record["date"]      = date as CKRecordValue
      record["updatedAt"] = Date() as CKRecordValue
      try await db.save(record)
    } catch {
      // Best-effort — the next publish() call reconciles.
    }
  }
}
