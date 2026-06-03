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
}

extension NextItemsResponse {
  /// The day's open items narrowed to the given time-of-day bucket, ready to show.
  ///
  /// The snapshot payload is all-day (`bucket == ""`) and tags each habit with its
  /// bucket in `subtitle`. Chores, supplements and tasks always apply; habits are
  /// kept only when their bucket matches, with the now-implicit bucket stripped from
  /// `subtitle`. Single-sourced here so the watch and the iOS widget never disagree
  /// about which items are due now (see `WatchConnectivity` and `SeptenaWidgets`).
  func itemsForBucket(_ bucket: DayBucket) -> [NextItem] {
    let key = bucket.rawValue
    return items.compactMap { item in
      guard item.kind == "habit" else { return item }
      guard item.subtitle == key else { return nil }
      var habit = item
      habit.subtitle = nil
      return habit
    }
  }
}
