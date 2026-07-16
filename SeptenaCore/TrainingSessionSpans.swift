import Foundation

/// Shared training-session span logic for the day-timeline bar and the rhythm-
/// wheel band. One coherent workout = each exercise entry contributes a time
/// span; spans that overlap or sit within `sessionGapHours` of each other merge
/// into a single session.
///
/// Keep `DayTimelineView`, `RhythmData.trainingBands`, and
/// `RhythmSnapshotBuilder` on this — the three surfaces must agree on what a
/// session's start and end are.
enum TrainingSessionSpans {
  /// One exercise row's contribution to a session span.
  struct Entry: Sendable, Hashable {
    let date: String           // YYYY-MM-DD
    let concludedAt: String?   // local ISO8601 session start
    let endedAt: String?       // local ISO8601 session end (concluding entry)
    let loggedAt: String?      // UTC ISO8601 "…Z"
    let durationMin: Double?
    /// Fallback start when `concludedAt` is absent (pre-migration / manual rows).
    let occurredAt: Date?

    init(date: String,
         concludedAt: String? = nil,
         endedAt: String? = nil,
         loggedAt: String? = nil,
         durationMin: Double? = nil,
         occurredAt: Date? = nil) {
      self.date = date
      self.concludedAt = concludedAt
      self.endedAt = endedAt
      self.loggedAt = loggedAt
      self.durationMin = durationMin
      self.occurredAt = occurredAt
    }
  }

  /// Fractional local hour-of-day (0..24).
  struct Span: Sendable, Hashable {
    var startHour: Double
    var endHour: Double
  }

  /// Gaps shorter than this between consecutive entries are rests within one
  /// workout; a longer gap starts a new session pill / wheel band.
  static let sessionGapHours = 0.75

  /// Minimum visible duration (3 minutes) so zero-length strength sets still
  /// read on the timeline rail and the wheel arc.
  static let minimumSpanHours = 0.05

  /// Per-entry span, or `nil` when the row has no plottable start time.
  static func entrySpan(_ entry: Entry) -> Span? {
    guard let startH = startHour(for: entry) else { return nil }
    let loggedH = entry.loggedAt.flatMap(localHour(fromISO:))
    let cardioEnd = (entry.durationMin ?? 0) > 0
      ? startH + (entry.durationMin ?? 0) / 60
      : startH
    var end = max(startH, cardioEnd, loggedH ?? startH)
    if let ended = entry.endedAt, ended.count >= 16,
       let endedH = parseHHMM(String(ended.dropFirst(11).prefix(5))) {
      end = max(end, endedH)
    }
    return Span(startHour: startH, endHour: end)
  }

  /// Merged session spans for one calendar date, sorted by start.
  static func sessions(on date: String, entries: [Entry]) -> [Span] {
    let spans = entries
      .filter { $0.date == date }
      .compactMap(entrySpan)
      .sorted { $0.startHour < $1.startHour }
    return merge(spans)
  }

  /// Merge overlapping / near-adjacent spans into coherent sessions.
  static func merge(_ spans: [Span]) -> [Span] {
    var merged: [Span] = []
    for s in spans {
      if var last = merged.last, s.startHour <= last.endHour + sessionGapHours {
        last.endHour = max(last.endHour, s.endHour)
        merged[merged.count - 1] = last
      } else {
        merged.append(s)
      }
    }
    return merged
  }

  static func withMinimumWidth(_ span: Span) -> Span {
    Span(startHour: span.startHour,
         endHour: max(span.endHour, span.startHour + minimumSpanHours))
  }

  // MARK: - Private

  private static func startHour(for entry: Entry) -> Double? {
    if let concluded = entry.concludedAt, concluded.count >= 16 {
      let startHHMM = String(concluded.dropFirst(11).prefix(5))
      if let h = parseHHMM(startHHMM) { return h }
    }
    guard let occurred = entry.occurredAt, occurred > .distantPast else { return nil }
    let c = Calendar.current.dateComponents([.hour, .minute], from: occurred)
    return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
  }

  /// UTC ISO8601 timestamp ("…Z") → fractional hour-of-day in the user's zone.
  /// `loggedAt` is stored in UTC but session starts are local wall-clock.
  private static func localHour(fromISO ts: String) -> Double? {
    guard let d = ISO8601DateFormatter().date(from: ts) else { return nil }
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    guard let h = c.hour else { return nil }
    return Double(h) + Double(c.minute ?? 0) / 60
  }

  /// "HH:MM" → fractional hour. Returns nil on malformed input.
  private static func parseHHMM(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count == 2,
          let h = Double(parts[0]),
          let m = Double(parts[1]) else { return nil }
    return h + m / 60
  }
}
