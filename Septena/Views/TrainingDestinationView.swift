import SwiftUI
import Charts

// Training mini-app — historical log of exercise entries grouped by
// session (date + session-type pair). Uses the new LogRow since entries
// aren't checklist items; they're records of what already happened.
// Header summary: this week's session count + Z2 minutes vs target.

struct TrainingDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav
  @Environment(TrainingDraftStore.self) private var draftStore

  @State private var entries: [ExerciseEntry] = []
  @State private var cardio: CardioHistoryResponse? = nil
  @State private var loading = true
  @State private var editing: ExerciseEntry? = nil

  // Chart state — mirrors the webapp's training dashboard. `selectedExercise`
  // is either a real exercise name or one of the two meta tokens below;
  // `progression` is the per-exercise series fetched on demand.
  @State private var selectedExercise: String = MetaExercise.strength
  @State private var progression: [ProgressionPoint] = []
  @State private var progressionLoading = false
  @State private var windowDays: Int = 30

  private var accent: Color { theme.color(for: "training") }

  /// Group entries by (date, session), newest first. Sessions sort by
  /// `date` desc; entries within a session sort by `loggedAt` desc (or
  /// id desc as a fallback when the server hasn't stamped a timestamp).
  /// The server's own ordering isn't trusted here — explicit sorts keep
  /// the list stable regardless of which endpoint variant we hit.
  private var sessions: [SessionBlock] {
    var byKey: [String: [ExerciseEntry]] = [:]
    for e in entries {
      let key = "\(e.date)|\(e.session)"
      byKey[key, default: []].append(e)
    }
    return byKey.keys
      .sorted(by: >)  // "YYYY-MM-DD|session" — date dominates
      .map { key in
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let items = (byKey[key] ?? []).sorted { lhs, rhs in
          (lhs.loggedAt ?? lhs.id) > (rhs.loggedAt ?? rhs.id)
        }
        return SessionBlock(date: String(parts[0]),
                            session: parts.count > 1 ? String(parts[1]) : "",
                            entries: items)
      }
  }

  var body: some View {
    List {
      if let d = draftStore.draft {
        activeSessionSection(d)
      }
      summary
      z2CardioSection
      consistencySection
      progressionSection
      ForEach(sessions, id: \.key) { block in
        Section {
          ForEach(block.entries) { entry in
            Button {
              guard entry.file != nil else { return }
              editing = entry
            } label: {
              LogRow(
                title: entry.exercise ?? "—",
                detail: detailLine(entry),
                trailing: entry.loggedAt.map(timeOnly),
                accent: accent
              )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .contextMenu {
              if entry.file != nil {
                Button(role: .destructive) {
                  delete(entry)
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
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
                               systemImage: theme.icon(for: "training"),
                               description: Text("Log a session in the webapp to see it here."))
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Training")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
    // Training's quick-add is the Start session sheet itself, so we
    // don't route through `AddInfoSheet` (its training page is a v1
    // no-op that just dismisses). Top-right icon stays the verb glyph
    // — Training's verb is `.start`, not `.add`.
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          nav.showTrainingSession = true
        } label: {
          Label("Start session", systemImage: "play.fill")
        }
        .tint(accent)
      }
    }
    .sheet(item: $editing) { entry in
      EditExerciseEntrySheet(
        original: entry,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  private func applyLocalUpdate(_ updated: ExerciseEntry) {
    guard let idx = entries.firstIndex(where: { $0.id == updated.id }) else { return }
    entries[idx] = updated
    ResponseCache.save(entries, forKey: CacheKey.entries)
  }

  private func delete(_ entry: ExerciseEntry) {
    guard let file = entry.file else { return }
    outbox.enqueue(
      method: "DELETE",
      path: "/api/training/entries",
      body: ["file": file],
      kind: "training.delete"
    )
    entries.removeAll { $0.file == file }
    ResponseCache.save(entries, forKey: CacheKey.entries)
    Haptics.warning()
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

  @ViewBuilder
  private func activeSessionSection(_ d: DraftSession) -> some View {
    Section {
      HStack(spacing: 12) {
        Text(d.emoji ?? "▶").font(.title3).frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text(d.label).font(.headline)
          Text("\(d.doneCount)/\(max(d.totalCount, 1)) done · started \(d.time)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          nav.showTrainingSession = true
        } label: {
          Text("Open").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        Button(role: .destructive) {
          draftStore.discard()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
      }
    } header: {
      Text("Active session")
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

  private enum CacheKey {
    // Bumped to 90d so the progression chart's widest window (90 days) is
    // always populated from cache. Old "training.entries14" cache lingers
    // harmlessly until the user opens the screen and we overwrite it.
    static let entries = "training.entries90"
    static let cardio  = "training.cardio30"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.entries) { entries = v }
    if let v = ResponseCache.load(CardioHistoryResponse.self, forKey: CacheKey.cardio) { cardio = v }
    loading = false
  }

  private func load() async {
    loading = true
    let since = sinceDate(daysBack: 90)
    async let e: [ExerciseEntry]? = try? await client.trainingEntries(since: since)
    async let c: CardioHistoryResponse? = try? await client.trainingCardioHistory(days: 30)
    let (entriesRes, cardioRes) = await (e, c)
    if let entriesRes {
      entries = entriesRes
      ResponseCache.save(entriesRes, forKey: CacheKey.entries)
    }
    if let cardioRes {
      cardio = cardioRes
      ResponseCache.save(cardioRes, forKey: CacheKey.cardio)
    }
    loading = false
  }

  // MARK: - Charts

  /// Last 7 days of Z2 cardio minutes with the rolling 7-day sum stacked
  /// on top of each day's bar as a faded accent. Mirrors the webapp's
  /// Zone 2 card (`training-dashboard.tsx`): solid bar = today's minutes
  /// (accent at 0.9 opacity), faded bar above = `rolling_7d` (accent at
  /// 0.3 opacity). Weekly target sits as a dashed rule. Stacks visually
  /// communicate "today's contribution → ceiling toward the weekly goal."
  @ViewBuilder
  private var z2CardioSection: some View {
    if let c = cardio, !c.daily.isEmpty {
      // Gap-fill to the last 7 dates ending today so the chart always
      // shows 7 columns even if the server skipped empty days.
      let byDate = Dictionary(uniqueKeysWithValues: c.daily.map { ($0.date, $0) })
      let series: [CardioDay] = last7Dates.map { d in
        byDate[d] ?? CardioDay(date: d, minutes: 0, rolling7d: nil)
      }
      let target = c.targetWeeklyMin
      let weekly = series.reduce(0) { $0 + $1.minutes }
      // Stack ceiling = max(daily + rolling_7d). Webapp pads to
      // ceil(target/0.9); match that so the dashed target line sits at
      // ~90% of the y-domain when no day has yet exceeded the weekly goal.
      let stackedMax = series.map { Double($0.minutes) + ($0.rolling7d ?? 0) }.max() ?? 0
      let yMax = max(stackedMax, ceil(Double(target) / 0.9))
      let avg = series.isEmpty ? 0 : weekly / series.count
      let avgText = avg > 0 ? "Seven-day average \(avg) minutes." : ""
      let summary = "Zone 2 cardio chart. Weekly total \(weekly) minutes, target \(target). \(avgText)"
      Section {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Zone 2 cardio").font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(weekly)/\(target)m")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Chart {
            // x value is the ISO date (unique per day) — using the
            // weekday letter would collide same-letter days (Sat/Sun,
            // Tue/Thu) into a single column. The axis formats the label
            // back to a narrow weekday for display.
            ForEach(series, id: \.date) { d in
              // Today's contribution — solid.
              BarMark(
                x: .value("Day", d.date),
                y: .value("Min", d.minutes),
                width: .ratio(0.6)
              )
              .foregroundStyle(d.minutes == 0
                               ? Color.secondary.opacity(0.2)
                               : accent.opacity(0.9))
              .cornerRadius(2)
              .accessibilityLabel(weekdayFull(d.date))
              .accessibilityValue(d.minutes == 0
                                  ? "no Z2 minutes"
                                  : "\(d.minutes) Z2 minutes")
              // Rolling 7-day sum — faded, stacked on top. Implicit
              // stacking via shared x category.
              if let r = d.rolling7d, r > 0 {
                BarMark(
                  x: .value("Day", d.date),
                  y: .value("7d sum", r),
                  width: .ratio(0.6)
                )
                .foregroundStyle(accent.opacity(0.3))
                .cornerRadius(2)
                .accessibilityLabel(weekdayFull(d.date))
                .accessibilityValue("7-day rolling sum \(Int(r.rounded())) minutes")
              }
            }
            RuleMark(y: .value("Target", target))
              .foregroundStyle(accent.opacity(0.7))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
              .annotation(position: .top, alignment: .trailing) {
                Text(verbatim: "\(target)m target").font(.caption2).foregroundStyle(.secondary)
              }
              .accessibilityHidden(true)
          }
          .chartXScale(domain: series.map(\.date))
          .chartYScale(domain: 0...yMax)
          .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
              AxisValueLabel { if let d = v.as(Double.self) { Text(verbatim: "\(Int(d))m").font(.caption2) } }
              AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
            }
          }
          .chartXAxis {
            AxisMarks(values: series.map(\.date)) { v in
              AxisValueLabel {
                if let iso = v.as(String.self) {
                  Text(verbatim: weekdayInitial(iso)).font(.caption2)
                }
              }
            }
          }
          .frame(height: 140)
        }
        .a11yCombineKeepingChildren(summary)
      } header: {
        Text("Cardio")
      }
    }
  }

  /// Seven ISO dates ending today, oldest → newest. Used by `z2CardioSection`
  /// to gap-fill the bar chart so empty days appear as zero columns rather
  /// than silently disappearing from the series.
  private var last7Dates: [String] {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let cal = Calendar.current
    return (0..<7).reversed().compactMap { off in
      cal.date(byAdding: .day, value: -off, to: Date()).map(fmt.string(from:))
    }
  }

  /// Consistency heatmap — one cell per day, intensity from entry count.
  /// Anchors to today's week on the right and fills as many week columns
  /// as the row width allows, clamped to the earliest logged entry so we
  /// don't render dead history. Uses the shared `ConsistencyHeatmap`.
  private var consistencySection: some View {
    // Tally entries per date.
    var counts: [String: Int] = [:]
    for e in entries { counts[e.date, default: 0] += 1 }
    let firstDate = entries.map(\.date).min().flatMap(ConsistencyHeatmap.date(fromISO:))
    let end = Date()
    let activeDays = counts.values.filter { $0 > 0 }.count
    return Section {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Consistency").font(.subheadline.weight(.semibold))
          Spacer()
          Text("\(activeDays) active days")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ConsistencyHeatmap(endDate: end, firstDataDate: firstDate, accent: accent) { iso in
          let c = counts[iso] ?? 0
          let level: Int = {
            if c <= 0 { return 0 }
            if c == 1 { return 1 }
            if c == 2 { return 2 }
            if c == 3 { return 3 }
            return 4
          }()
          let label = c > 0 ? "\(iso) · \(c) \(c == 1 ? "entry" : "entries")" : "\(iso) · rest"
          return HeatmapDay(level: level, label: label)
        }
      }
    }
  }

  /// Per-exercise progression line chart. Pills above the chart switch
  /// the selected exercise (or one of the two meta aggregates).
  private var progressionSection: some View {
    let pills = pillOptions
    let line = lineData
    let yMax: Double = {
      let vals = line.compactMap(\.value)
      guard let m = vals.max(), m > 0 else { return 1 }
      return m * 1.15
    }()
    let vals = line.compactMap(\.value)
    let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    let avgText = avg > 0
      ? "Window average \(yLabel(avg))."
      : ""
    let summary = "\(MetaExercise.label(for: selectedExercise)) progression chart. \(chartSubtitle). \(avgText)"

    return Section {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(MetaExercise.label(for: selectedExercise))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Spacer()
          Picker("Window", selection: $windowDays) {
            Text("30d").tag(30)
            Text("60d").tag(60)
            Text("90d").tag(90)
          }
          .pickerStyle(.segmented)
          .frame(width: 170)
        }
        Text(chartSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)

        if line.isEmpty || line.allSatisfy({ $0.value == nil }) {
          Text(progressionLoading ? "Loading…" : "No data for this exercise yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
          Chart {
            ForEach(line) { p in
              if let v = p.value {
                LineMark(
                  x: .value("Date", p.day),
                  y: .value("Metric", v)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
                PointMark(
                  x: .value("Date", p.day),
                  y: .value("Metric", v)
                )
                .symbolSize(28)
                .foregroundStyle(accent)
                .accessibilityLabel(weekdayFull(p.id))
                .accessibilityValue(yLabel(v))
              }
            }
          }
          .chartYScale(domain: 0...yMax)
          .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
              AxisValueLabel {
                if let d = v.as(Double.self) { Text(yLabel(d)).font(.caption2) }
              }
              AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
            }
          }
          .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
              if let d = value.as(Date.self) {
                AxisValueLabel { Text(shortMonthDay(d)).font(.caption2) }
              }
              AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
            }
          }
          .frame(height: 180)
        }

        VStack(alignment: .leading, spacing: 6) {
          if !pills.strength.isEmpty {
            pillRow(title: "Strength", items: pills.strength)
          }
          if !pills.cardio.isEmpty {
            pillRow(title: "Cardio & mobility", items: pills.cardio)
          }
        }
      }
      .a11yCombineKeepingChildren(summary)
    } header: {
      Text("Progression")
    }
    .onChange(of: selectedExercise, initial: false) { _, _ in
      Task { await loadProgression() }
    }
  }

  private func pillRow(title: String, items: [PillItem]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(items) { item in
            let isSelected = item.name == selectedExercise
            Button {
              selectedExercise = item.name
            } label: {
              HStack(spacing: 4) {
                Text(item.label).font(.caption.weight(.medium))
                Text("\(item.count)")
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(
                isSelected ? accent : accent.opacity(0.10),
                in: Capsule()
              )
              .foregroundStyle(isSelected ? Color.white : accent)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  // MARK: - Chart data

  private struct LinePoint: Identifiable {
    let id: String
    let day: Date
    let value: Double?
  }

  private struct PillItem: Identifiable {
    let name: String
    let label: String
    let count: Int
    var id: String { name }
  }

  /// One value per calendar day in `[today - windowDays, today]`. Meta
  /// charts sum across all matching entries; per-exercise charts average.
  private var lineData: [LinePoint] {
    let cutoff = sinceDate(daysBack: windowDays)
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"

    var byDate: [String: [Double]] = [:]
    let meta = MetaExercise.isMeta(selectedExercise)
    let kind = metricKind(for: selectedExercise)

    if meta {
      for e in entries where e.date >= cutoff {
        if selectedExercise == MetaExercise.strength {
          guard isStrengthEntry(e), let v = volumeValue(e) else { continue }
          byDate[e.date, default: []].append(v)
        } else {
          guard isCardioEntry(e), let d = e.durationMin else { continue }
          byDate[e.date, default: []].append(d)
        }
      }
    } else {
      for p in progression where p.date >= cutoff {
        guard let v = pointValue(p, kind: kind) else { continue }
        byDate[p.date, default: []].append(v)
      }
    }

    guard let start = fmt.date(from: cutoff),
          let end = fmt.date(from: today) else { return [] }
    var out: [LinePoint] = []
    var day = start
    while day <= end {
      let iso = fmt.string(from: day)
      let bucket = byDate[iso] ?? []
      let reduced: Double? = bucket.isEmpty
        ? nil
        : (meta
           ? bucket.reduce(0, +)
           : bucket.reduce(0, +) / Double(bucket.count))
      out.append(LinePoint(id: iso, day: day, value: reduced))
      guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return out
  }

  private var pillOptions: (strength: [PillItem], cardio: [PillItem]) {
    var counts: [String: Int] = [:]
    var hasCardio: [String: Bool] = [:]
    for e in entries {
      guard let name = e.exercise, !name.isEmpty else { continue }
      counts[name, default: 0] += 1
      if isCardioEntry(e) { hasCardio[name] = true }
    }
    let names = counts.keys.sorted { (a, b) in
      let ca = counts[a] ?? 0; let cb = counts[b] ?? 0
      if ca != cb { return ca > cb }
      return a < b
    }
    var strength: [PillItem] = []
    var cardio: [PillItem] = []
    for n in names {
      let item = PillItem(name: n, label: n.capitalized, count: counts[n] ?? 0)
      if hasCardio[n] == true { cardio.append(item) } else { strength.append(item) }
    }
    let metaS = PillItem(name: MetaExercise.strength, label: "All strength", count: strength.count)
    let metaC = PillItem(name: MetaExercise.cardio,   label: "All cardio",   count: cardio.count)
    return (strength: [metaS] + strength, cardio: [metaC] + cardio)
  }

  private var today: String { SeptenaDate.today }

  private enum MetricKind { case weight, duration, pace, volume, cardioTotal }

  /// Pick a metric kind from the entry shape — same idea as the webapp's
  /// `metricKind()` but driven entirely off the data we've already loaded.
  private func metricKind(for exercise: String) -> MetricKind {
    if exercise == MetaExercise.strength { return .volume }
    if exercise == MetaExercise.cardio { return .cardioTotal }
    let rel = entries.filter { $0.exercise == exercise }
    if rel.contains(where: { ($0.distanceM ?? 0) > 0 && ($0.durationMin ?? 0) > 0 }) {
      return .pace
    }
    if rel.contains(where: { ($0.durationMin ?? 0) > 0 && $0.weight == nil }) {
      return .duration
    }
    return .weight
  }

  private func pointValue(_ p: ProgressionPoint, kind: MetricKind) -> Double? {
    switch kind {
    case .pace:
      guard let m = p.distanceM, let d = p.durationMin, d > 0 else { return nil }
      return (m / d * 10).rounded() / 10
    case .duration: return p.durationMin
    case .weight: return p.weight
    case .volume, .cardioTotal: return nil
    }
  }

  private func volumeValue(_ e: ExerciseEntry) -> Double? {
    guard let w = e.weight, w > 0,
          let s = e.sets.flatMap(Int.init), s > 0,
          let r = e.reps.flatMap(Int.init), r > 0 else { return nil }
    return Double(s * r) * w
  }

  private func isCardioEntry(_ e: ExerciseEntry) -> Bool {
    (e.distanceM ?? 0) > 0 || ((e.durationMin ?? 0) > 0 && e.weight == nil)
  }

  private func isStrengthEntry(_ e: ExerciseEntry) -> Bool {
    e.weight != nil && !isCardioEntry(e)
  }

  private var chartSubtitle: String {
    switch metricKind(for: selectedExercise) {
    case .volume: return "Total volume per session (kg)"
    case .cardioTotal: return "Total cardio minutes per session"
    case .pace: return "Pace (m/min) per session"
    case .duration: return "Duration (min) per session"
    case .weight: return "Weight (kg) over time"
    }
  }

  private func yLabel(_ v: Double) -> String {
    switch metricKind(for: selectedExercise) {
    case .volume, .cardioTotal: return "\(Int(v))"
    case .pace: return String(format: "%.0f", v)
    case .duration: return "\(Int(v))m"
    case .weight: return "\(Int(v))kg"
    }
  }

  private func shortMonthDay(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "MMM d"
    return f.string(from: d)
  }

  // Full weekday name for VoiceOver — visual axis uses narrow initials.
  private func weekdayFull(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let w = DateFormatter(); w.dateFormat = "EEEE"
    return w.string(from: d)
  }

  private func weekdayInitial(_ iso: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return "" }
    let w = DateFormatter(); w.dateFormat = "EEEEE"
    return w.string(from: d)
  }

  private func loadProgression() async {
    if MetaExercise.isMeta(selectedExercise) {
      progression = []
      return
    }
    progressionLoading = true
    if let data = try? await client.trainingProgression(exercise: selectedExercise) {
      progression = data
    }
    progressionLoading = false
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

// MARK: - Meta exercise tokens
//
// Sentinel "exercise" ids for the two aggregate charts. Chosen so they can't
// collide with a real exercise name. Mirrors the webapp's META_STRENGTH /
// META_CARDIO constants.
enum MetaExercise {
  static let strength = "__all_strength__"
  static let cardio   = "__all_cardio__"

  static func isMeta(_ name: String) -> Bool {
    name == strength || name == cardio
  }

  static func label(for name: String) -> String {
    switch name {
    case strength: return "All strength"
    case cardio:   return "All cardio"
    default:       return name.capitalized
    }
  }
}

// MARK: - Draft store
//
// One in-progress training session, persisted to UserDefaults as JSON so a
// background-kill or crash mid-workout doesn't lose progress. Mirrors the
// webapp's IndexedDB draft. Per-entry saves are POSTed as the user marks
// each exercise "Done" — `TrainingDestinationView` then refreshes and the
// new entries roll into the historical log immediately.

@MainActor
@Observable
final class TrainingDraftStore {
  private static let key = "septena.training.draft"

  /// Cached session-types from the server. Empty until first fetch.
  var sessionTypes: [SessionTypeConfig] = []
  /// Days since the last session of each type — feeds the palette's
  /// "Last 2d ago" badges. Keyed by type id ("upper", "cardio", ...).
  var daysAgo: [String: Int] = [:]
  /// Server-suggested next type, if any.
  var suggested: String? = nil

  /// Currently active draft. Nil when no session is in flight.
  var draft: DraftSession?

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
       let decoded = try? JSONDecoder().decode(DraftSession.self, from: data) {
      draft = decoded
    }
  }

  // MARK: - Persistence

  private func persist() {
    guard let draft else {
      UserDefaults.standard.removeObject(forKey: Self.key)
      return
    }
    if let data = try? JSONEncoder().encode(draft) {
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }

  // MARK: - Catalog

  /// Pull session-type config + days-since-last-session in parallel from
  /// the server. `/api/training/suggested-workout` already does the
  /// exercise-taxonomy classification (a day counts as "upper" only with
  /// ≥3 upper-group exercises, "cardio" needs ≥30 Z2 min and no strength,
  /// etc.) — far richer than what we'd derive from the flat `session`
  /// field client-side. So we just read it directly.
  func refreshCatalog(client: SeptenaClient) async {
    async let types = try? await client.sessionTypes()
    async let sw    = try? await client.suggestedWorkout()
    let (t, s) = await (types, sw)
    if let t { sessionTypes = t }
    if let s {
      daysAgo = s.daysAgo
      suggested = s.suggested?.type
    }
  }


  // MARK: - Start / discard

  /// Build a fresh draft for `type`, pre-filling each exercise from the
  /// user's last entry for it. Replaces any existing draft.
  func start(type: SessionTypeConfig, client: SeptenaClient) async {
    let exercises = type.exercises
    let last: [String: LastEntryValues] =
      (try? await client.lastEntries(exercises: exercises)) ?? [:]
    let entries = exercises.map { ex in
      DraftEntry.from(exercise: ex, last: last[ex])
    }
    let now = Date()
    let timeF = DateFormatter()
    timeF.dateFormat = "HH:mm"
    timeF.locale = Locale(identifier: "en_US_POSIX")
    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime]
    draft = DraftSession(
      date: SeptenaDate.today,
      time: timeF.string(from: now),
      sessionType: type.id,
      emoji: type.emoji,
      label: type.label,
      entries: entries,
      startedAt: isoF.string(from: now),
      updatedAt: isoF.string(from: now)
    )
    persist()
  }

  func discard() {
    draft = nil
    persist()
  }

  // MARK: - Mutate

  func update(_ patch: (inout DraftSession) -> Void) {
    guard var d = draft else { return }
    patch(&d)
    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime]
    d.updatedAt = isoF.string(from: Date())
    draft = d
    persist()
  }

  /// POST one entry to the backend and flip its status to `done` on
  /// success / `failed` on error. Mirrors the webapp's per-exercise save.
  func markDone(index: Int, client: SeptenaClient) async {
    guard let d = draft, d.entries.indices.contains(index) else { return }
    update { $0.entries[index].status = .saving }
    do {
      var entry = d.entries[index]
      entry.status = .done
      let written = try await client.postTrainingSession(
        date: d.date, time: d.time, sessionType: d.sessionType,
        entries: [entry]
      )
      update {
        $0.entries[index].status = .done
        $0.entries[index].savedFile = written.first
      }
    } catch {
      SeptenaLog.error("training save failed", error)
      update { $0.entries[index].status = .failed }
    }
  }

  func markSkipped(index: Int) {
    update {
      guard $0.entries.indices.contains(index) else { return }
      $0.entries[index].status = .skipped
    }
  }
}

// MARK: - Session logger UI
//
// Webapp parity: header with elapsed / cardio / lifted stats; per-exercise
// expandable cards with weight/sets/reps (strength) or duration/distance/
// level (cardio); incremental save on "Done"; resume-after-crash via the
// `TrainingDraftStore`'s UserDefaults persistence. Lives as a sheet over
// the dashboard so the user can swipe away and come back without losing
// state.

struct TrainingSessionView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  /// Re-render the elapsed counter once per minute. Cheap and avoids a
  /// timer goroutine flickering the whole sheet.
  @State private var tick = Date()

  private var accent: Color { theme.color(for: "training") }

  var body: some View {
    NavigationStack {
      Group {
        if store.draft != nil {
          logger
        } else {
          picker
        }
      }
      .background(Theme.paperBackground)
      .navigationTitle(store.draft.map { "\($0.emoji ?? "💪") \($0.label)" } ?? "Start training")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        if store.draft != nil {
          ToolbarItem(placement: .primaryAction) {
            Button("Finish") { finish() }
              .tint(accent)
              .bold()
          }
        }
      }
      .tint(accent)
    }
    .task {
      if store.sessionTypes.isEmpty {
        await store.refreshCatalog(client: client)
      }
    }
  }

  // MARK: - Type picker (no draft yet)

  private var picker: some View {
    List {
      if store.sessionTypes.isEmpty {
        Section { ProgressView() }
      } else {
        Section("Pick a session") {
          ForEach(store.sessionTypes) { type in
            Button { start(type) } label: {
              HStack(spacing: 12) {
                Text(type.emoji ?? "💪").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                  Text(type.label).font(.septenaTaskTitle)
                    .foregroundStyle(Theme.inkPrimary)
                  if let d = store.daysAgo[type.id] {
                    Text(d == 0 ? "Today" :
                         d == 1 ? "1 day ago" : "\(d) days ago")
                      .font(.septenaMeta)
                      .foregroundStyle(Theme.inkSecondary)
                  } else {
                    Text("No prior session")
                      .font(.septenaMeta)
                      .foregroundStyle(Theme.inkSecondary)
                  }
                }
                Spacer()
                if store.suggested == type.id {
                  Text("Suggested")
                    .font(.septenaBadge)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent.opacity(0.18),
                                in: Capsule())
                    .foregroundStyle(accent)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
  }

  // MARK: - Logger (active draft)

  @ViewBuilder
  private var logger: some View {
    if let d = store.draft {
      List {
        statsHeader(d)
        Section {
          ForEach(Array(d.entries.enumerated()), id: \.element.exercise) { idx, e in
            TrainingExerciseCard(
              index: idx,
              entry: e,
              accent: accent
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
          }
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #else
      .listStyle(.inset)
      #endif
      .onAppear { tick = Date() }
    }
  }

  private func statsHeader(_ d: DraftSession) -> some View {
    let elapsed = elapsedMinutes(since: d.startedAt)
    let lifted = d.entries
      .filter { $0.status == .done && !$0.isCardio }
      .reduce(0.0) { acc, e in
        let s = Double(e.sets ?? 0)
        let r = Double(e.reps.flatMap { Int($0) } ?? 0)
        return acc + (e.weight ?? 0) * s * r
      }
    let cardio = d.entries
      .filter { $0.status == .done && $0.isCardio }
      .reduce(0.0) { $0 + ($1.durationMin ?? 0) }
    return Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(elapsed)", label: "elapsed", unit: "m")
        stat(value: "\(Int(cardio))", label: "cardio", unit: "m")
        stat(value: "\(Int(lifted))", label: "lifted", unit: "kg")
        Spacer()
      }
      let done = d.doneCount
      let total = max(d.totalCount, 1)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("PROGRESS")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(done)/\(total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ProgressView(value: Double(done), total: Double(total))
          .tint(accent)
      }
    }
  }

  private func stat(value: String, label: String, unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(accent)
        if let unit {
          Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: - Actions

  private func start(_ type: SessionTypeConfig) {
    Task { await store.start(type: type, client: client) }
  }

  private func finish() {
    store.discard()
    dismiss()
  }

  /// Whole-minute elapsed since the ISO8601 `startedAt`. Cheap re-eval on
  /// each render; we don't bother with sub-minute precision.
  private func elapsedMinutes(since iso: String) -> Int {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let start = f.date(from: iso) else { return 0 }
    return max(0, Int(Date().timeIntervalSince(start) / 60))
  }
}

// MARK: - Exercise card

/// Expandable per-exercise card in the active session. Collapsed shows the
/// summary; tapping expands to weight/sets/reps inputs (or duration/
/// distance/level for cardio) plus the difficulty pills and a Done button.
struct TrainingExerciseCard: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(TrainingDraftStore.self) private var store

  let index: Int
  let entry: DraftEntry
  let accent: Color

  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded { editor }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.cardSurface)
    )
    .opacity(opacityFor(entry.status))
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      statusIcon
        .foregroundStyle(statusTint)
        .font(.system(size: 18, weight: .regular))
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.exercise.capitalized)
          .font(.septenaCardTitle)
          .foregroundStyle(Theme.inkPrimary)
        if let s = summaryLine {
          Text(s)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      Spacer()
      Image(systemName: expanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.inkSecondary)
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch entry.status {
    case .pending: Image(systemName: "circle")
    case .saving:  ProgressView().controlSize(.small)
    case .done:    Image(systemName: "checkmark.circle.fill")
    case .failed:  Image(systemName: "exclamationmark.triangle.fill")
    case .skipped: Image(systemName: "minus.circle")
    }
  }

  private var statusTint: Color {
    switch entry.status {
    case .done:    return accent
    case .failed:  return .red
    case .skipped: return Theme.inkSecondary
    default:       return Theme.inkSecondary
    }
  }

  private func opacityFor(_ status: DraftEntry.Status) -> Double {
    switch status {
    case .done:    return 0.75
    case .skipped: return 0.45
    default:       return 1
    }
  }

  private var summaryLine: String? {
    var parts: [String] = []
    if entry.isCardio {
      if let d = entry.durationMin, d > 0 { parts.append("\(Int(d)) min") }
      if let m = entry.distanceM, m > 0 {
        parts.append(m >= 1000 ? String(format: "%.1f km", m/1000) : "\(Int(m)) m")
      }
      if let l = entry.level, l > 0 { parts.append("L\(l)") }
    } else {
      if let w = entry.weight, w > 0 {
        parts.append(w.truncatingRemainder(dividingBy: 1) == 0
                     ? "\(Int(w))kg" : String(format: "%.1fkg", w))
      }
      if let s = entry.sets, let r = entry.reps { parts.append("\(s)×\(r)") }
      if !entry.difficulty.isEmpty { parts.append(entry.difficulty) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Editor (expanded)

  @ViewBuilder
  private var editor: some View {
    Divider().padding(.vertical, 10)
    if entry.isCardio {
      cardioInputs
    } else {
      strengthInputs
      difficultyPicker
    }
    HStack(spacing: 8) {
      Button("Skip") {
        store.markSkipped(index: index)
        expanded = false
      }
      .buttonStyle(.bordered)
      .tint(.secondary)
      Spacer()
      Button(entry.status == .failed ? "Retry"
             : entry.status == .done ? "Update" : "Done") {
        Task {
          await store.markDone(index: index, client: client)
          if entry.status != .failed { expanded = false }
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(accent)
      .disabled(entry.status == .saving)
    }
    .padding(.top, 12)
  }

  // MARK: - Strength fields

  private var strengthInputs: some View {
    HStack(spacing: 10) {
      numberField(label: "Weight", unit: "kg",
                  value: Binding(
                    get: { entry.weight.map { fmt($0) } ?? "" },
                    set: { setWeight($0) }
                  ))
      numberField(label: "Sets",
                  value: Binding(
                    get: { entry.sets.map(String.init) ?? "" },
                    set: { setSets(Int($0)) }
                  ))
      numberField(label: "Reps",
                  value: Binding(
                    get: { entry.reps ?? "" },
                    set: { setReps($0) }
                  ))
    }
  }

  private var difficultyPicker: some View {
    HStack(spacing: 6) {
      ForEach(["easy", "medium", "hard"], id: \.self) { d in
        Button {
          store.update { $0.entries[index].difficulty = d }
        } label: {
          Text(d.capitalized)
            .font(.septenaMetaStrong)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
              entry.difficulty == d ? accent.opacity(0.22) : Theme.mutedSurface,
              in: Capsule()
            )
            .foregroundStyle(entry.difficulty == d ? accent : Theme.inkSecondary)
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .padding(.top, 8)
  }

  // MARK: - Cardio fields

  private var cardioInputs: some View {
    HStack(spacing: 10) {
      numberField(label: "Duration", unit: "min",
                  value: Binding(
                    get: { entry.durationMin.map { fmt($0) } ?? "" },
                    set: { setDuration($0) }
                  ))
      numberField(label: "Distance", unit: "m",
                  value: Binding(
                    get: { entry.distanceM.map { fmt($0) } ?? "" },
                    set: { setDistance($0) }
                  ))
      numberField(label: "Level",
                  value: Binding(
                    get: { entry.level.map(String.init) ?? "" },
                    set: { setLevel(Int($0)) }
                  ))
    }
  }

  // MARK: - Field helpers

  private func numberField(label: String,
                           unit: String? = nil,
                           value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        TextField("", text: value)
          #if os(iOS)
          .keyboardType(.decimalPad)
          #endif
          .textFieldStyle(.plain)
          .font(.system(.title3, design: .rounded).weight(.medium))
        if let unit {
          Text(unit).font(.septenaMeta).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(Theme.mutedSurface,
                  in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  private func fmt(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0
      ? String(Int(d)) : String(format: "%.1f", d)
  }

  private func setWeight(_ s: String) {
    store.update { $0.entries[index].weight = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
  private func setSets(_ v: Int?) {
    store.update { $0.entries[index].sets = v }
  }
  private func setReps(_ s: String) {
    store.update { $0.entries[index].reps = s.isEmpty ? nil : s }
  }
  private func setDuration(_ s: String) {
    store.update { $0.entries[index].durationMin = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
  private func setDistance(_ s: String) {
    store.update { $0.entries[index].distanceM = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
  private func setLevel(_ v: Int?) {
    store.update { $0.entries[index].level = v }
  }
}
