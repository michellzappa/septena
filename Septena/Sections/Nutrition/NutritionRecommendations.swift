import Foundation

// Scoring for the Nutrition quick-add menu's "Recommended" section.
//
// Dedup the 30-day meal history by foods[0] (the same key AddNutritionPage
// uses), then score each meal by:
//
//   - Time-of-day match — how many past instances of this meal fell
//     within ±2 hours of the current hour. Weighted heaviest because
//     "what do I usually eat at this time" is the strongest predictor.
//   - Repetition count — log-scaled so a daily staple doesn't blow
//     past a meal you actually want now.
//   - Recency bonus — a small constant if the most-recent instance is
//     within the last 7 days, so meals you're currently into surface
//     above meals from weeks ago.
//
// Returns the top N representatives sorted by score.

enum NutritionRecommendations {

  static func topRecommended(from entries: [NutritionEntry],
                             now: Date = .now,
                             limit: Int = 3) -> [NutritionEntry] {
    let cal = Calendar.current
    let currentHour = cal.component(.hour, from: now)

    // Dedup → key (foods[0] lowercased) → (representative entry, instance count, time-match count, most-recent date+time key)
    struct Bucket {
      var representative: NutritionEntry
      var count: Int
      var timeMatchCount: Int
      var mostRecentKey: String   // "YYYY-MM-DD HH:mm" for ordering
    }

    var buckets: [String: Bucket] = [:]
    for e in entries {
      guard let firstFood = e.foods.first?.lowercased() else { continue }
      let entryHour = hour(from: e.time) ?? currentHour
      let timeDelta = abs(entryHour - currentHour)
      // Wrap-around at midnight: 23h and 1h are 2h apart, not 22h.
      let wrappedDelta = min(timeDelta, 24 - timeDelta)
      let isTimeMatch = wrappedDelta <= 2
      let entryKey = "\(e.date) \(e.time)"

      if var existing = buckets[firstFood] {
        existing.count += 1
        if isTimeMatch { existing.timeMatchCount += 1 }
        if entryKey > existing.mostRecentKey {
          existing.representative = e
          existing.mostRecentKey = entryKey
        }
        buckets[firstFood] = existing
      } else {
        buckets[firstFood] = Bucket(
          representative: e,
          count: 1,
          timeMatchCount: isTimeMatch ? 1 : 0,
          mostRecentKey: entryKey
        )
      }
    }

    // Score and sort.
    let today = SeptenaDate.today
    let scored = buckets.values.map { (b: Bucket) -> (NutritionEntry, Double) in
      let timeScore = Double(b.timeMatchCount) * 2.0
      let freqScore = log(Double(b.count) + 1.0)
      let recencyScore = isWithin7Days(b.mostRecentKey, today: today) ? 0.5 : 0
      return (b.representative, timeScore + freqScore + recencyScore)
    }
    .sorted { $0.1 > $1.1 }
    .prefix(limit)
    .map { $0.0 }

    return scored
  }

  /// Parse "HH:mm" → hour (0–23), returning nil on malformed input.
  private static func hour(from time: String) -> Int? {
    guard let colon = time.firstIndex(of: ":"),
          let h = Int(time[..<colon]) else { return nil }
    return h
  }

  /// True when `key` (= "YYYY-MM-DD HH:mm") is within 7 days of today
  /// (calendar days, ignoring time component).
  private static func isWithin7Days(_ key: String, today: String) -> Bool {
    guard let spaceIdx = key.firstIndex(of: " ") else { return false }
    let date = String(key[..<spaceIdx])
    // Lexicographic comparison works because the format is fixed-width
    // ISO 8601. "today" - 7 days is computed string-wise via parsing.
    let cal = Calendar.current
    guard
      let todayDate = SeptenaDate.parse(today),
      let entryDate = SeptenaDate.parse(date),
      let diff = cal.dateComponents([.day], from: entryDate, to: todayDate).day
    else { return false }
    return diff <= 7 && diff >= 0
  }
}
