import SwiftUI

// Training mini-app — historical log of exercise entries grouped by
// session (date + session-type pair). Uses the new LogRow since entries
// aren't checklist items; they're records of what already happened.
// Header summary: this week's session count + Z2 minutes vs target.

struct TrainingDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var entries: [ExerciseEntry] = []
  @State private var cardio: CardioHistoryResponse? = nil
  @State private var loading = true

  private var accent: Color { theme.color(for: "training") }

  /// Group entries by (date, session). Server returns most-recent first
  /// already, so just preserve first-appearance order per session key.
  private var sessions: [SessionBlock] {
    var order: [String] = []
    var byKey: [String: [ExerciseEntry]] = [:]
    for e in entries {
      let key = "\(e.date)|\(e.session)"
      if byKey[key] == nil { order.append(key) }
      byKey[key, default: []].append(e)
    }
    return order.map { key in
      let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      return SessionBlock(date: String(parts[0]),
                          session: parts.count > 1 ? String(parts[1]) : "",
                          entries: byKey[key] ?? [])
    }
  }

  var body: some View {
    List {
      summary
      ForEach(sessions, id: \.key) { block in
        Section {
          ForEach(block.entries) { entry in
            LogRow(
              title: entry.exercise ?? "—",
              detail: detailLine(entry),
              trailing: entry.loggedAt.map(timeOnly),
              accent: accent
            )
            .listRowInsets(EdgeInsets())
          }
        } header: {
          HStack {
            Text(block.session.capitalized.isEmpty ? "Session" : block.session.capitalized)
            Spacer()
            Text(friendlyDate(block.date))
              .foregroundStyle(.secondary)
          }
        }
      }
      if !loading && entries.isEmpty {
        ContentUnavailableView("No entries yet",
                               systemImage: "figure.strengthtraining.traditional",
                               description: Text("Log a session in the webapp to see it here."))
      }
    }
    .listStyle(.insetGrouped)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Training")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  // MARK: - Summary

  private var summary: some View {
    let sessionsThisWeek = uniqueSessionDates(thisWeek: true).count
    let z2 = Int(cardio?.daily.reduce(0) { $0 + $1.minutes } ?? 0)
    let target = cardio?.targetWeeklyMin ?? 150
    return Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(sessionsThisWeek)", label: "sessions", tint: accent)
        stat(value: "\(z2)", label: "Z2 min", tint: accent, unit: "m")
        Spacer()
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Z2 CARDIO")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
          Spacer()
          Text("\(z2)/\(target)m").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        ProgressView(value: Double(min(z2, target)),
                     total: Double(max(target, 1)))
          .tint(accent)
      }
    }
  }

  private func stat(value: String, label: String, tint: Color, unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
        if let unit {
          Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: - Loading

  private func load() async {
    loading = true
    let since = sinceDate(daysBack: 14)
    async let e: [ExerciseEntry]? = try? await client.trainingEntries(since: since)
    async let c: CardioHistoryResponse? = try? await client.trainingCardioHistory(days: 7)
    let (entriesRes, cardioRes) = await (e, c)
    entries = entriesRes ?? []
    cardio = cardioRes
    loading = false
  }

  // MARK: - Helpers

  private struct SessionBlock {
    let date: String
    let session: String
    let entries: [ExerciseEntry]
    var key: String { "\(date)|\(session)" }
  }

  /// Build a detail line that adapts to the entry shape — strength rows
  /// favor weight × sets × reps; cardio favors duration · distance.
  private func detailLine(_ e: ExerciseEntry) -> String? {
    var parts: [String] = []
    if let w = e.weight, w > 0 {
      parts.append(formatWeight(w))
    }
    if let s = e.sets, let r = e.reps {
      parts.append("\(s)×\(r)")
    } else if let r = e.reps {
      parts.append(r)
    }
    if let d = e.durationMin, d > 0 {
      parts.append("\(Int(d)) min")
    }
    if let m = e.distanceM, m > 0 {
      parts.append(formatDistance(m))
    }
    if let lvl = e.level, lvl > 0 {
      parts.append("L\(Int(lvl))")
    }
    if let diff = e.difficulty, !diff.isEmpty {
      parts.append(diff)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func formatWeight(_ w: Double) -> String {
    w.truncatingRemainder(dividingBy: 1) == 0
      ? "\(Int(w))kg"
      : String(format: "%.1fkg", w)
  }

  private func formatDistance(_ m: Double) -> String {
    m >= 1000
      ? String(format: "%.1f km", m / 1000)
      : "\(Int(m)) m"
  }

  private func timeOnly(_ ts: String) -> String {
    // Server returns ISO8601 like "2026-05-17T07:42:11" — grab HH:MM.
    if let tIdx = ts.firstIndex(of: "T") {
      let after = ts.index(after: tIdx)
      let end = ts.index(after, offsetBy: 5, limitedBy: ts.endIndex) ?? ts.endIndex
      return String(ts[after..<end])
    }
    return ts
  }

  /// "Today" / "Yesterday" / weekday name / full date — same vocabulary as
  /// the rest of the app's date display.
  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = .current
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
      let weekday = DateFormatter()
      weekday.dateFormat = "EEEE"
      return weekday.string(from: d)
    }
    let pretty = DateFormatter()
    pretty.dateFormat = "MMM d"
    return pretty.string(from: d)
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: d)
  }

  /// Unique YYYY-MM-DD dates among entries, optionally restricted to the
  /// current calendar week.
  private func uniqueSessionDates(thisWeek: Bool) -> Set<String> {
    guard thisWeek else { return Set(entries.map(\.date)) }
    let cal = Calendar.current
    let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                      from: Date())) ?? Date()
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let cutoff = fmt.string(from: weekStart)
    return Set(entries.map(\.date).filter { $0 >= cutoff })
  }
}
