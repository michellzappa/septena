import SwiftData
import SwiftUI

// Per-symptom detail — tap a symptom in Patterns to see its own severity
// heatmap, headline stats, and recent occurrences. Mirrors the habit /
// supplement `LoggableDetailView` surface (same `LogDetailScaffold`), but the
// heatmap encodes daily *peak severity* in 0…4 bands rather than done/skipped,
// because a symptom is graded, not binary. Everything is derived at read time
// from the definition's dated `SymptomEventEntity` rows.

struct SymptomDetailView: View {
  let symptomID: String
  let title: String
  let emoji: String?
  let accent: Color
  /// Routes the toolbar "Edit" back to the parent (opens a new log sheet).
  var onEdit: (() -> Void)? = nil

  var body: some View {
    LogDetailScaffold(
      title: title,
      accent: accent,
      load: { ctx in Self.detail(symptomID: symptomID, emoji: emoji, context: ctx) },
      onEdit: onEdit
    )
  }

  /// Build the shared `LogDetail` from one symptom's event history. Stats read
  /// frequency + intensity (events, average, peak); the heatmap bands the daily
  /// peak severity so worse days read darker.
  static func detail(symptomID: String, emoji: String?, context: ModelContext) -> LogDetail {
    let id = symptomID
    let descriptor = FetchDescriptor<SymptomEventEntity>(
      predicate: #Predicate { $0.symptomID == id },
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    )
    let events = (try? context.fetch(descriptor)) ?? []

    var d = LogDetail()
    d.emoji = emoji
    d.heatmapTitle = "Severity"

    guard !events.isEmpty else {
      d.subtitle = "No history yet"
      return d
    }

    let distinctDays = Set(events.map(\.date))
    let avg = Double(events.reduce(0) { $0 + $1.severity }) / Double(events.count)
    let peak = events.map(\.severity).max() ?? 0

    let dayWord = distinctDays.count == 1 ? "day" : "days"
    let timeWord = events.count == 1 ? "time" : "times"
    d.subtitle = "Logged \(events.count) \(timeWord) over \(distinctDays.count) \(dayWord)"
    d.tiles = [
      LogStat(value: "\(events.count)", caption: "events", tone: .accent),
      LogStat(value: avg.decimalString(1), caption: "avg /10"),
      LogStat(value: "\(peak)", caption: "peak /10"),
    ]

    // Heatmap bands the *daily peak* severity (matching the section's severity
    // trend chart), so a day with one severe spike reads as severe.
    var peakByDate: [String: Int] = [:]
    for e in events { peakByDate[e.date] = max(peakByDate[e.date] ?? 0, e.severity) }
    d.heatmap = LogHeatmap(
      firstDate: LogDetailFormat.firstDate(Array(distinctDays)),
      level: { iso in severityLevel(peakByDate[iso] ?? 0) },
      detail: "peak by day"
    )

    // Recent occurrences, newest first — one row per event (not per day), so
    // multiple flares on the same day each show with their own time.
    d.recent = events.prefix(14).map { e in
      LogRecent(title: LogDetailFormat.longDay(e.date),
                detail: recentDetail(e),
                trailing: EventTimestamp.hhmm(from: e.occurredAt),
                status: .none)
    }
    return d
  }

  /// Severity 0…10 → heatmap intensity band 0…4. Empty days stay at 0; the
  /// remaining ten points spread across the four accent stops.
  static func severityLevel(_ severity: Int) -> Int {
    switch severity {
    case ...0: return 0
    case 1...2: return 1
    case 3...4: return 2
    case 5...7: return 3
    default: return 4
    }
  }

  private static func recentDetail(_ e: SymptomEventEntity) -> String {
    var parts = ["severity \(e.severity)/10"]
    if let region = e.bodyRegion, !region.isEmpty { parts.append(region) }
    if let quality = e.quality, !quality.isEmpty { parts.append(quality) }
    return parts.joined(separator: " · ")
  }
}
