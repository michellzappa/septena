import Foundation

// Wire types for the "Next" feed — the serializable shape shared by the app,
// the Mac app, the watch, and the iOS widget. Kept in its own small file (like
// `DayBucket.swift`) and added to each target's membership so every surface
// decodes the same `WatchSnapshot` payload without a shared framework. This
// replaces the former hand-maintained copy in `SeptenaWatch/WatchModels.swift`.

struct NextItem: Codable, Identifiable, Hashable {
  var id: String
  var kind: String
  var title: String
  var subtitle: String?
  var trailing: String?
  var overdue: Bool
  var sortKey: Int

  enum CodingKeys: String, CodingKey {
    case id, kind, title, subtitle, trailing, overdue
    case sortKey = "sortKey"
  }
}

struct NextItemsResponse: Codable {
  var date: String
  var bucket: String
  var items: [NextItem]
  /// The phone's per-section "carry over missed items" prefs at publish time,
  /// carried in the payload so the watch and widget filter exactly as the phone
  /// would (App Group defaults are per-device and don't cross to the watch).
  /// Optional so older payloads still decode — `itemsForBucket` falls back to the
  /// shipped `NextLinger` defaults when absent.
  var lingerHabits: Bool? = nil
  var lingerSupplements: Bool? = nil
}

/// UserDefaults keys + defaults for the per-section "carry over missed items"
/// toggle (a.k.a. linger): keep an item on the Next list after its time-of-day
/// bucket has passed, until it's done. Per-device by design — it's a glance
/// filter, so it stays out of the CloudKit schema. The toggle lives in each
/// section's settings; these keys are the shared contract between that toggle,
/// the iOS Next list, and the watch/widget snapshot filter (`itemsForBucket`),
/// so all three live here in SeptenaCore. Defaults preserve shipped behavior:
/// supplements linger, habits stay strict.
public enum NextLinger {
  public static let supplementsKey = "next.linger.supplements"
  public static let supplementsDefault = true
  public static let habitsKey = "next.linger.habits"
  public static let habitsDefault = false
}

extension NextItemsResponse {
  /// The day's open items narrowed to the given time-of-day bucket, ready to show.
  ///
  /// This is the watch/widget twin of the phone's `NextOpenSection` filters
  /// (`habitsNow` / `supplementsNow`) — same rules, same linger prefs (carried in
  /// the payload), so the three surfaces never disagree about what's due now.
  ///
  /// The snapshot payload is all-day (`bucket == ""`) and tags each bucketed item
  /// with its bucket in `subtitle`. Chores and tasks have no time-of-day and always
  /// apply. Habits and supplements are bucketed; both have the now-implicit bucket
  /// stripped from `subtitle` once they pass the filter:
  ///   • habits — strict by default (exactly the current bucket); with carry-over
  ///     on, any undone habit whose bucket has already opened. Never shows early.
  ///   • supplements — "anytime" (nil bucket) shows all day; a bucketed dose shows
  ///     during its window and, with carry-over on (the default), lingers through
  ///     later buckets until taken. Never shows early.
  func itemsForBucket(_ bucket: DayBucket) -> [NextItem] {
    let key = bucket.rawValue
    let now = bucket.order
    let lingerHabits = self.lingerHabits ?? NextLinger.habitsDefault
    let lingerSupplements = self.lingerSupplements ?? NextLinger.supplementsDefault
    return items.compactMap { item in
      switch item.kind {
      case "habit":
        if lingerHabits {
          // Carry-over: any undone habit whose bucket has opened (order ≤ now).
          // A non-DayBucket value ("anytime") isn't part of the now-strip.
          guard let b = item.subtitle.flatMap(DayBucket.init(rawValue:)), b.order <= now
          else { return nil }
        } else {
          // Strict: exact current-bucket match — no past, no future.
          guard item.subtitle == key else { return nil }
        }
        var habit = item
        habit.subtitle = nil
        return habit
      case "supplement":
        // nil / non-DayBucket bucket = "anytime" → always show.
        guard let b = item.subtitle.flatMap(DayBucket.init(rawValue:)) else { return item }
        let keep = lingerSupplements ? (b.order <= now) : (b.order == now)
        guard keep else { return nil }
        var supp = item
        supp.subtitle = nil
        return supp
      default:
        return item
      }
    }
  }
}
