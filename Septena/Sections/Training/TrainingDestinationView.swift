import SwiftUI
import SwiftData
import Charts

// Training mini-app — historical log of exercise entries grouped by
// session (date + session-type pair). Uses the new LogRow since entries
// aren't checklist items; they're records of what already happened.
// Header summary: this week's session count + Z2 minutes vs target.

struct TrainingDestinationView: View {
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }
  @Environment(\.modelContext) private var modelContext
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
    SectionDrawer(sectionKey: "training",
                  title: "Training",
                  onLog: { _ in nav.showTrainingSession = true }) {
      if let d = draftStore.draft {
        activeSessionSection(d)
      }
      summary
      z2CardioSection
      strengthVolumeSection
      volumeTrendSection
      consistencySection
      progressionSection
      ForEach(sessions, id: \.key) { block in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            sessionTypeMenu(for: block)
            Spacer()
            Text(friendlyDate(block.date))
              .foregroundStyle(.secondary)
          }
          .font(.subheadline)
          .padding(.horizontal, 16)
          DrawerSection(padding: .none) {
            ForEach(block.entries) { entry in
              if entry.file != nil {
                LogEntryRow(
                  title: entry.exercise ?? "—",
                  detail: detailLine(entry),
                  trailing: entry.loggedAt.map(timeOnly),
                  accessory: glyphAccessory(for: entry),
                  onEdit: { editing = entry },
                  onDelete: { delete(entry) }
                )
              } else {
                LogEntryRow(
                  title: entry.exercise ?? "—",
                  detail: detailLine(entry),
                  trailing: entry.loggedAt.map(timeOnly),
                  accessory: glyphAccessory(for: entry)
                )
              }
            }
          }
        }
      }
      if !loading && entries.isEmpty {
        ContentUnavailableView("No entries yet",
                               systemImage: theme.icon(for: "training"),
                               description: Text("Log a session in the webapp to see it here."))
      }
    }
    .trackScreen("training")
    .tint(accent)
    .task {
      paintFromCache()
      draftStore.refreshCatalog(context: modelContext)
      await load()
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

  /// Tappable session-type picker shown in each day's section header.
  /// Picking a new value bulk-retags every entry on that date — both in
  /// SwiftData (via `trainingMutator.retagSession`) and in the local
  /// `entries` array so the chart and grouping refresh immediately.
  @ViewBuilder
  private func sessionTypeMenu(for block: SessionBlock) -> some View {
    let current = block.session
    let activeType = draftStore.sessionTypes.first { $0.id == current }
    let label = activeType?.label ?? (current.isEmpty ? "Untagged" : current.capitalized)
    let icon = activeType?.kind.icon ?? (current.isEmpty ? "questionmark.circle" : nil)
    Menu {
      // Use the routine catalog the user has configured (upper/lower/cardio/
      // yoga/…), with a final "Untagged" option for clearing.
      ForEach(draftStore.sessionTypes.filter { !$0.archived }, id: \.id) { st in
        Button {
          retag(date: block.date, to: st.id)
        } label: {
          // Show the routine's SF Symbol; SwiftUI Menus auto-render a
          // trailing checkmark when the button is the active selection
          // (no need to manually swap the systemImage).
          Label(st.label, systemImage: st.kind.icon)
        }
      }
      Divider()
      Button {
        retag(date: block.date, to: "")
      } label: {
        Label("Untagged", systemImage: "questionmark.circle")
      }
    } label: {
      HStack(spacing: 4) {
        if let icon { Image(systemName: icon) }
        Text(label)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .tint(accent)
  }

  /// Apply a session-type change to every entry on `date`: SwiftData write
  /// + CK sync via the mutator, plus an in-place patch of `entries` so the
  /// daily list and chart series re-bucket without waiting for a reload.
  private func retag(date: String, to newSessionType: String) {
    let count = trainingMutator.retagSession(date: date, to: newSessionType)
    guard count > 0 else { return }
    for idx in entries.indices where entries[idx].date == date {
      entries[idx].session = newSessionType
    }
    ResponseCache.save(entries, forKey: CacheKey.entries)
    Haptics.tick()
  }

  private func delete(_ entry: ExerciseEntry) {
    guard let id = entry.file else { return }
    trainingMutator.deleteEntry(id: id)
    entries.removeAll { $0.file == id }
    ResponseCache.save(entries, forKey: CacheKey.entries)
    Haptics.warning()
  }

  // MARK: - Summary

  private var summary: some View {
    let sessionsThisWeek = uniqueSessionDates(thisWeek: true).count
    let z2 = Int(cardio?.daily.last?.rolling7d ?? 0)
    let target = cardio?.targetWeeklyMin ?? 150
    return DrawerSection {
      VStack(alignment: .leading, spacing: 8) {
        StatStrip(stats: [
          Stat(value: "\(sessionsThisWeek)", label: "sessions", tint: accent),
          Stat(value: "\(z2)", label: "Z2 min", tint: accent, unit: "m"),
        ])
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
  }

  @ViewBuilder
  private func activeSessionSection(_ d: DraftSession) -> some View {
    let kindIcon = draftStore.sessionTypes.first { $0.id == d.sessionType }?.kind.icon
      ?? SessionKind.defaulted(for: d.sessionType).icon
    DrawerSection("Active session") {
      HStack(spacing: 12) {
        Image(systemName: kindIcon)
          .font(.title3.weight(.medium))
          .foregroundStyle(accent)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(d.label).font(.septenaCardTitle)
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
    let entriesRes = ChecklistMirror.loadTrainingEntries(context: modelContext, since: since)
    let cardioRes = ChecklistMirror.loadTrainingCardioHistory(context: modelContext, days: 30)
    entries = entriesRes
    ResponseCache.save(entriesRes, forKey: CacheKey.entries)
    cardio = cardioRes
    ResponseCache.save(cardioRes, forKey: CacheKey.cardio)
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
      DrawerSection("Cardio") {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
    }
  }

  /// Trailing-7-day "effective hard sets" — the headline strength-volume
  /// number. Counts each strength entry's `sets` × difficulty weight:
  /// hard/max = 1.0, moderate = 0.5, easy/unset = 0. Floor 10, target 12,
  /// soft ceiling 20 reflect the hypertrophy meta-analysis consensus
  /// (Schoenfeld et al.) on sets-to-failure per week as the primary
  /// stimulus driver. Single number, no per-muscle split — that's the MVP.
  private static let hardSetsTarget: Double = 12
  private static let hardSetsCeiling: Double = 20

  private func effectiveHardSets(in days: Int) -> Double {
    let cutoff = sinceDate(daysBack: days)
    var total: Double = 0
    for e in entries where isStrengthEntry(e) && e.date >= cutoff {
      guard let s = e.sets.flatMap(Int.init), s > 0 else { continue }
      let weight: Double
      switch (e.difficulty ?? "").lowercased() {
      case "hard", "max":   weight = 1.0
      case "moderate":      weight = 0.5
      default:              weight = 0
      }
      total += Double(s) * weight
    }
    return total
  }

  /// Strength-volume card — trailing 7-day effective hard sets vs target.
  /// Sibling to `z2CardioSection`; both answer "am I doing enough to drive
  /// adaptation this week." See `effectiveHardSets(in:)` for the math.
  @ViewBuilder
  private var strengthVolumeSection: some View {
    let raw = effectiveHardSets(in: 7)
    let value = Int(raw.rounded())
    let target = Self.hardSetsTarget
    let ceiling = Self.hardSetsCeiling
    // Progress fills toward the target; once past target, color shifts to
    // signal "in the productive band" until the ceiling.
    let progress = min(raw, target) / target
    let overTarget = raw > target
    let overCeiling = raw > ceiling
    DrawerSection {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Strength volume").font(.subheadline.weight(.semibold))
          Spacer()
          Text("\(value)/\(Int(target)) hard sets")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ProgressView(value: progress)
          .tint(accent)
        Text(overCeiling
             ? "Past the 20-set ceiling — consider a deload."
             : overTarget
               ? "In the productive 12–20 hard-set band."
               : "Target \(Int(target)) hard sets/week to drive hypertrophy.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Volume / intensity trend (8 weeks)

  /// Per-week aggregate of effective hard sets and mean difficulty over
  /// the last 8 ISO weeks. Mean difficulty maps easy=1, moderate/medium=2,
  /// hard=3, max=4 — same ladder the difficulty pills present, so the
  /// sparkline reads as "average pill height per week."
  private struct WeekVolumePoint: Identifiable {
    let weekStart: Date
    let hardSets: Double
    let meanIntensity: Double?  // nil when no rated sets that week
    var id: Date { weekStart }
  }

  private var weeklyVolumeTrend: [WeekVolumePoint] {
    let cal = Calendar.current
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    // Anchor to this week's start (Monday-ish per user locale).
    let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
    guard let thisWeekStart = cal.date(from: comps) else { return [] }
    var weeks: [Date] = []
    for off in (0..<8).reversed() {
      if let d = cal.date(byAdding: .weekOfYear, value: -off, to: thisWeekStart) {
        weeks.append(d)
      }
    }
    // Bucket entries into weeks once, then derive both series.
    var setsByWeek: [Date: Double] = [:]
    var intensityByWeek: [Date: (sum: Double, count: Int)] = [:]
    for e in entries where isStrengthEntry(e) {
      guard let day = fmt.date(from: e.date) else { continue }
      let dComps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
      guard let wkStart = cal.date(from: dComps) else { continue }
      if let s = e.sets.flatMap(Int.init), s > 0 {
        let weight: Double
        switch (e.difficulty ?? "").lowercased() {
        case "hard", "max": weight = 1.0
        case "moderate":    weight = 0.5
        default:            weight = 0
        }
        setsByWeek[wkStart, default: 0] += Double(s) * weight
      }
      if let i = intensityScore(e.difficulty) {
        let cur = intensityByWeek[wkStart] ?? (0, 0)
        intensityByWeek[wkStart] = (cur.sum + i, cur.count + 1)
      }
    }
    return weeks.map { w in
      let agg = intensityByWeek[w]
      let mean = agg.map { $0.sum / Double($0.count) }
      return WeekVolumePoint(weekStart: w,
                             hardSets: setsByWeek[w] ?? 0,
                             meanIntensity: mean)
    }
  }

  private func intensityScore(_ d: String?) -> Double? {
    switch (d ?? "").lowercased() {
    case "easy":              return 1
    case "medium", "moderate": return 2
    case "hard":              return 3
    case "max":               return 4
    default:                  return nil
    }
  }

  /// 8-week trailing chart of weekly effective hard sets (bars) with the
  /// 12-set target line and the 20-set ceiling shaded, and a thin mean-
  /// intensity sparkline below. Reads as "am I trending up or coasting?"
  /// — a temporal companion to `strengthVolumeSection`.
  @ViewBuilder
  private var volumeTrendSection: some View {
    let series = weeklyVolumeTrend
    let hasData = series.contains { $0.hardSets > 0 }
    if hasData {
      let target = Self.hardSetsTarget
      let ceiling = Self.hardSetsCeiling
      let maxBar = series.map(\.hardSets).max() ?? 0
      let yMax = max(maxBar, ceiling) * 1.15
      let lastWeek = series.last?.hardSets ?? 0
      let prevWeek = series.dropLast().last?.hardSets ?? 0
      let delta = lastWeek - prevWeek
      let avgIntensity: Double = {
        let vals = series.compactMap(\.meanIntensity)
        return vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
      }()
      let weekFmt: (Date) -> String = { d in
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
      }
      let summary: String = {
        let dir = delta >= 0 ? "up" : "down"
        return "8-week volume trend. This week \(Int(lastWeek)) hard sets, \(dir) \(Int(abs(delta))) from last week. Average intensity \(String(format: "%.1f", avgIntensity)) out of 4."
      }()
      DrawerSection("Volume trend") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("8-week volume").font(.subheadline.weight(.semibold))
            Spacer()
            Text(delta == 0
                 ? "flat vs last week"
                 : "\(delta > 0 ? "+" : "")\(Int(delta)) vs last week")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Chart {
            // Productive band — shaded between target and ceiling so the
            // user can see at-a-glance which bars land "in the band."
            RectangleMark(
              xStart: .value("start", series.first?.weekStart ?? Date()),
              xEnd: .value("end", series.last?.weekStart ?? Date()),
              yStart: .value("target", target),
              yEnd: .value("ceiling", ceiling)
            )
            .foregroundStyle(accent.opacity(0.08))
            .accessibilityHidden(true)
            ForEach(series) { w in
              BarMark(
                x: .value("Week", w.weekStart, unit: .weekOfYear),
                y: .value("Hard sets", w.hardSets),
                width: .ratio(0.6)
              )
              .foregroundStyle(w.hardSets == 0
                               ? Color.secondary.opacity(0.2)
                               : (w.hardSets >= target ? accent.opacity(0.9)
                                                       : accent.opacity(0.5)))
              .cornerRadius(2)
              .accessibilityLabel(weekFmt(w.weekStart))
              .accessibilityValue("\(Int(w.hardSets)) hard sets")
            }
            RuleMark(y: .value("target", target))
              .foregroundStyle(accent.opacity(0.7))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
              .annotation(position: .top, alignment: .trailing) {
                Text("\(Int(target)) target")
                  .font(.caption2).foregroundStyle(.secondary)
              }
              .accessibilityHidden(true)
          }
          .chartYScale(domain: 0...yMax)
          .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
              AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))").font(.caption2) } }
              AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
            }
          }
          .chartXAxis {
            AxisMarks(values: series.map(\.weekStart)) { v in
              AxisValueLabel {
                if let d = v.as(Date.self) {
                  Text(weekFmt(d)).font(.caption2)
                }
              }
            }
          }
          .frame(height: 140)

          // Intensity sparkline — tucked under the volume chart, same
          // x-domain so weeks line up visually. Empty weeks (no rated
          // sets) just leave a gap in the line.
          intensitySparkline(series, avg: avgIntensity)
        }
        .a11yCombineKeepingChildren(summary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
    }
  }

  @ViewBuilder
  private func intensitySparkline(_ series: [WeekVolumePoint], avg: Double) -> some View {
    let weekFmt: (Date) -> String = { d in
      let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Intensity").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Text("avg \(String(format: "%.1f", avg))/4")
          .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
      Chart {
        ForEach(series) { w in
          if let v = w.meanIntensity {
            LineMark(
              x: .value("Week", w.weekStart, unit: .weekOfYear),
              y: .value("Intensity", v)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(accent)
            .accessibilityLabel(weekFmt(w.weekStart))
            .accessibilityValue("intensity \(String(format: "%.1f", v))")
            PointMark(
              x: .value("Week", w.weekStart, unit: .weekOfYear),
              y: .value("Intensity", v)
            )
            .symbolSize(18)
            .foregroundStyle(accent)
            .accessibilityHidden(true)
          }
        }
      }
      .chartYScale(domain: 1...4)
      .chartYAxis {
        AxisMarks(position: .leading, values: [1, 2, 3, 4]) { v in
          AxisValueLabel {
            if let d = v.as(Int.self) {
              Text(intensityRung(d)).font(.caption2)
            }
          }
          AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
        }
      }
      .chartXAxis(.hidden)
      .frame(height: 56)
    }
  }

  private func intensityRung(_ i: Int) -> String {
    switch i {
    case 1: return "E"
    case 2: return "M"
    case 3: return "H"
    case 4: return "X"
    default: return ""
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
    return DrawerSection {
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

    return DrawerSection("Progression") {
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
                if let s = p.series {
                  LineMark(
                    x: .value("Date", p.day),
                    y: .value("Metric", v),
                    series: .value("Group", s)
                  )
                  .interpolationMethod(.linear)
                  .foregroundStyle(by: .value("Group", s))
                  .accessibilityHidden(true)
                  PointMark(
                    x: .value("Date", p.day),
                    y: .value("Metric", v)
                  )
                  .symbolSize(28)
                  .foregroundStyle(by: .value("Group", s))
                  .accessibilityLabel(weekdayFull(p.id))
                  .accessibilityValue("\(s), \(yLabel(v))")
                } else {
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
          }
          .chartLegend(line.contains(where: { $0.series != nil }) ? .visible : .hidden)
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
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
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
                  .foregroundStyle(accent.opacity(isSelected ? 1.0 : 0.55))
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(
                accent.opacity(isSelected ? 0.28 : 0.10),
                in: Capsule()
              )
              .foregroundStyle(accent)
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
    /// Series label for split charts (e.g. "Upper", "Lower"). `nil` when the
    /// chart is a single line.
    var series: String? = nil
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

    // "All strength" splits each session-category ("upper", "lower", …) into
    // its own connected line — without this the chart zig-zags between leg
    // and arm days because their totals live on different magnitudes.
    if meta && selectedExercise == MetaExercise.strength {
      return splitStrengthLineData(cutoff: cutoff)
    }

    if meta {
      for e in entries where e.date >= cutoff {
        guard isCardioEntry(e), let d = e.durationMin else { continue }
        byDate[e.date, default: []].append(d)
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

  /// "All strength" view, split per session category. Each session id gets
  /// its own line; days without that category's data are simply omitted so
  /// adjacent same-category sessions connect cleanly.
  private func splitStrengthLineData(cutoff: String) -> [LinePoint] {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    var byKey: [String: [String: [Double]]] = [:]   // session -> iso -> [volume]
    for e in entries where e.date >= cutoff {
      guard isStrengthEntry(e), let v = volumeValue(e) else { continue }
      let session = e.session.isEmpty ? "other" : e.session
      byKey[session, default: [:]][e.date, default: []].append(v)
    }
    var out: [LinePoint] = []
    for (session, perDay) in byKey {
      let label = session.capitalized
      for (iso, values) in perDay {
        guard let date = fmt.date(from: iso) else { continue }
        let total = values.reduce(0, +)
        out.append(LinePoint(id: "\(session)-\(iso)", day: date, value: total, series: label))
      }
    }
    return out.sorted { $0.day < $1.day }
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
    progression = ChecklistMirror.loadTrainingProgression(context: modelContext,
                                                          exercise: selectedExercise)
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
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Difficulty pips + cardio level bars rendered inline next to the
  /// numeric stats. Mirrors the webapp's `DifficultyGlyph` / `LevelGlyph`
  /// row in `training-dashboard.tsx`. Returns nil when neither glyph would
  /// render so the detail line collapses cleanly.
  private func glyphAccessory(for e: ExerciseEntry) -> AnyView? {
    let hasDifficulty = (e.difficulty ?? "").isEmpty == false
    let hasLevel = (e.level ?? 0) > 0
    guard hasDifficulty || hasLevel else { return nil }
    return AnyView(
      HStack(spacing: 6) {
        if hasDifficulty {
          DifficultyGlyph(difficulty: e.difficulty)
        }
        if hasLevel, let lvl = e.level {
          LevelGlyph(level: Int(lvl), accent: accent)
        }
      }
    )
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
    // `loggedAt` is written as UTC ISO8601 ("…Z"); display in the user's zone.
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: ts) {
      let f = DateFormatter()
      f.dateFormat = "HH:mm"
      f.timeZone = .current
      return f.string(from: d)
    }
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
  func refreshCatalog(context: ModelContext) {
    sessionTypes = ChecklistMirror.loadSessionTypes(context: context)
    let s = ChecklistMirror.loadSuggestedWorkout(context: context)
    daysAgo = s.daysAgo
    suggested = s.suggested?.type
  }

  /// Re-hydrate progression context (last-entry, PR baselines, recents)
  /// and nil-fill any missing prefill fields on the active draft. Safe
  /// to call repeatedly; never overwrites user-set values. Pays for
  /// itself when a draft persisted by an older build is loaded against
  /// a newer prefill / casing rule.
  func backfillDraftFromHistory(context: ModelContext) {
    guard var d = draft else { return }
    let exercises = d.entries.map(\.exercise)
    let last = ChecklistMirror.loadLastEntries(context: context, exercises: exercises)
    let lastByKey = Dictionary(uniqueKeysWithValues: exercises.compactMap { ex -> (String, LastEntryValues)? in
      guard let v = last[ex] else { return nil }
      return (exerciseKey(ex), v)
    })
    d.lastByExercise = lastByKey
    d.prBaselines = TrainingPRCalculator.baselines(for: exercises, in: context)
    d.recentByExercise = TrainingPRCalculator.recents(for: exercises, in: context, limit: 3)

    // Re-sync entries to **per-exercise** category, falling back to
    // the routine's `kind` only when an exercise has no definition.
    // Covers two cases:
    //   1. Routine kind changed in Settings since the draft started
    //      (e.g. Cardio routine that was first `.mixed`).
    //   2. Routine mixes categories — e.g. an Upper strength routine
    //      with Elliptical/Rowing as cardio warm-ups. Each entry
    //      needs the input shape its exercise expects, not the
    //      routine's blanket kind.
    //
    // We touch only the category flags and drop the now-irrelevant
    // metric fields for the previous category — explicit values for
    // the new kind are left alone in case the user already typed
    // something.
    let routineKind = sessionTypes.first(where: { $0.id == d.sessionType })?.kind ?? .mixed
    let kinds = exerciseKinds(for: d.entries.map(\.exercise),
                              fallback: routineKind, context: context)
    for i in d.entries.indices {
      let k = kinds[d.entries[i].exercise] ?? routineKind
      let cardio = (k == .cardio)
      let mobility = (k == .mobility)
      if d.entries[i].isCardio != cardio || d.entries[i].isMobility != mobility {
        d.entries[i].isCardio = cardio
        d.entries[i].isMobility = mobility
        if mobility {
          // Yoga: TIME + difficulty only. Keep durationMin; drop the
          // strength + cardio-specific metrics.
          d.entries[i].weight = nil
          d.entries[i].sets = nil
          d.entries[i].reps = nil
          d.entries[i].distanceM = nil
          d.entries[i].level = nil
        } else if cardio {
          // Cardio has no difficulty UI — clear any leaked value so we
          // don't persist a stale "medium" from a prior strength shape.
          d.entries[i].weight = nil
          d.entries[i].sets = nil
          d.entries[i].reps = nil
          d.entries[i].difficulty = ""
        } else {
          d.entries[i].durationMin = nil
          d.entries[i].distanceM = nil
          d.entries[i].level = nil
        }
      }
    }

    for i in d.entries.indices {
      guard let l = last[d.entries[i].exercise] else { continue }
      // Only refill fields the entry's category cares about, so a
      // cardio-shaped entry doesn't accidentally inherit a stray
      // historical weight value from when the exercise was logged
      // as strength.
      if d.entries[i].isMobility {
        if d.entries[i].durationMin == nil, let v = l.durationMin { d.entries[i].durationMin = v }
      } else if d.entries[i].isCardio {
        if d.entries[i].durationMin == nil, let v = l.durationMin { d.entries[i].durationMin = v }
        if d.entries[i].distanceM == nil, let v = l.distanceM { d.entries[i].distanceM = v }
        if d.entries[i].level == nil, let v = l.level { d.entries[i].level = v }
      } else {
        if d.entries[i].weight == nil, let v = l.weight { d.entries[i].weight = v }
        if d.entries[i].sets == nil, let s = l.sets, let n = Int(s) { d.entries[i].sets = n }
        if (d.entries[i].reps ?? "").isEmpty, let v = l.reps { d.entries[i].reps = v }
      }
    }
    draft = d
    persist()
  }


  // MARK: - Start / discard

  /// Build a fresh draft for `type`, pre-filling each exercise from the
  /// user's last entry for it. Replaces any existing draft.
  ///
  /// The draft entries' `isCardio` flag is taken from the routine's
  /// `kind` — NOT from each exercise's last-entry shape. Without this,
  /// a strength routine like "Upper" could open with cardio inputs if
  /// any of its exercises had ever been logged with a `durationMin`,
  /// which is the bug this fix targets.
  /// Resolve each exercise's category by looking it up in the
  /// `ExerciseDefinitionEntity` catalog. The catalog stores
  /// `type: "strength" | "cardio" | "mobility" | "core"`; we map
  /// those to `SessionKind`. Lookups go by `exerciseKey(_:)` so a
  /// slug like "rowing-machine" matches a definition named "Rowing
  /// Machine".
  ///
  /// Exercises with no matching definition fall back to the routine's
  /// `kind`, preserving the previous routine-wide behaviour for
  /// orphan slugs.
  ///
  /// Fetches the whole catalog once; cheap relative to per-entry
  /// fetches and the catalog is small.
  func exerciseKinds(for exercises: [String],
                     fallback: SessionKind,
                     context: ModelContext) -> [String: SessionKind] {
    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    let byKey: [String: ExerciseDefinitionEntity] = defs.reduce(into: [:]) { acc, def in
      // Index by both id and name keys — routines may store either.
      // First write wins on collision (rare).
      let idKey = exerciseKey(def.id)
      let nameKey = exerciseKey(def.name)
      if acc[idKey] == nil { acc[idKey] = def }
      if acc[nameKey] == nil { acc[nameKey] = def }
    }
    var out: [String: SessionKind] = [:]
    for ex in exercises {
      guard let def = byKey[exerciseKey(ex)] else {
        out[ex] = fallback
        continue
      }
      switch def.type.lowercased() {
      case "cardio":   out[ex] = .cardio
      case "mobility": out[ex] = .mobility
      case "strength": out[ex] = .strength
      case "core":     out[ex] = .strength    // core = strength input shape
      default:         out[ex] = fallback
      }
    }
    return out
  }

  func start(type: SessionTypeConfig, context: ModelContext) {
    let exercises = type.exercises
    let last = ChecklistMirror.loadLastEntries(context: context, exercises: exercises)
    // Per-exercise category, with the routine's `kind` as fallback for
    // orphan exercises (slug exists in the routine but has no
    // `ExerciseDefinitionEntity`). This is what lets an Upper routine
    // mix cardio warm-ups (Elliptical, Rowing) and strength lifts
    // (Chest Press) and render each with its own input shape.
    let kinds = exerciseKinds(for: exercises, fallback: type.kind, context: context)
    let entries = exercises.map { ex -> DraftEntry in
      let k = kinds[ex] ?? type.kind
      return DraftEntry.from(exercise: ex, last: last[ex],
                             cardioOverride: k == .cardio,
                             mobilityOverride: k == .mobility)
    }
    // Snapshot last-entry + PR baselines per exercise. Keyed by the
    // canonical exerciseKey so the card's lookup survives separator
    // drift (chest-press / chest press / Chest_Press all match).
    let lastByExercise = Dictionary(uniqueKeysWithValues: exercises.compactMap { ex -> (String, LastEntryValues)? in
      guard let v = last[ex] else { return nil }
      return (exerciseKey(ex), v)
    })
    let prBaselines = TrainingPRCalculator.baselines(for: exercises, in: context)
    let recents = TrainingPRCalculator.recents(for: exercises, in: context, limit: 3)
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
      label: type.label,
      entries: entries,
      startedAt: isoF.string(from: now),
      updatedAt: isoF.string(from: now),
      lastByExercise: lastByExercise,
      prBaselines: prBaselines,
      recentByExercise: recents
    )
    persist()
    #if os(iOS)
    if let draft {
      TrainingLiveActivityCoordinator.shared.start(for: draft)
    }
    #endif
  }

  func discard(endLiveActivity: Bool = true) {
    #if os(iOS)
    if endLiveActivity {
      TrainingLiveActivityCoordinator.shared.end(from: draft, immediate: true)
    }
    #endif
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
    #if os(iOS)
    TrainingLiveActivityCoordinator.shared.update(from: d)
    #endif
  }

  /// Save one entry locally via CloudKit-backed TrainingMutator. Flips the
  /// row's status to `done` immediately; CK upload is fire-and-forget.
  func markDone(index: Int, mutator: TrainingMutator) {
    guard let d = draft, d.entries.indices.contains(index) else { return }
    update { $0.entries[index].status = .saving }
    let entry = d.entries[index]
    let saved = mutator.addEntry(
      date: d.date,
      time: d.time,
      sessionType: d.sessionType,
      exercise: entry.exercise,
      weight: entry.weight,
      sets: entry.sets.map(String.init),
      reps: entry.reps,
      // Cardio has no difficulty UI in the logger; never persist one even
      // if a value lingers on the draft (legacy drafts, category switch).
      difficulty: (entry.isCardio || entry.difficulty.isEmpty) ? nil : entry.difficulty,
      durationMin: entry.durationMin,
      distanceM: entry.distanceM,
      level: entry.level,
      note: entry.note.isEmpty ? nil : entry.note,
      concludedAt: "\(d.date)T\(d.time.isEmpty ? "00:00" : d.time):00"
    )
    update {
      $0.entries[index].status = .done
      $0.entries[index].savedFile = saved.id
    }
  }

  func markSkipped(index: Int) {
    update {
      guard $0.entries.indices.contains(index) else { return }
      $0.entries[index].status = .skipped
    }
  }

  /// Return a skipped entry to the pending pool (menu "Unskip").
  func unskip(index: Int) {
    update {
      guard $0.entries.indices.contains(index),
            $0.entries[index].status == .skipped else { return }
      $0.entries[index].status = .pending
    }
  }

  // MARK: - Mid-session edits (switch / add / remove)
  //
  // Swapping the machine that's taken, or throwing in an extra exercise,
  // without leaving the logger. Each new entry is pre-filled from history
  // exactly like the ones `start(type:)` seeds — same last-entry / PR /
  // recents snapshots, same per-exercise category resolution.

  /// Build a fully pre-filled entry for `name` and fold its history
  /// snapshots (last-entry, PR baseline, recents) into `d`, keyed by
  /// `exerciseKey`. Category comes from the catalog (strength / cardio /
  /// mobility), falling back to the routine's kind for orphan slugs —
  /// the same resolution `start(type:)` uses, applied to one exercise.
  private func makePrefilledEntry(_ name: String,
                                  into d: inout DraftSession,
                                  context: ModelContext) -> DraftEntry {
    let last = ChecklistMirror.loadLastEntries(context: context, exercises: [name])
    let routineKind = sessionTypes.first { $0.id == d.sessionType }?.kind ?? .mixed
    let kind = exerciseKinds(for: [name], fallback: routineKind, context: context)[name] ?? routineKind
    let key = exerciseKey(name)
    if let v = last[name] { d.lastByExercise[key] = v }
    for (k, v) in TrainingPRCalculator.baselines(for: [name], in: context) { d.prBaselines[k] = v }
    for (k, v) in TrainingPRCalculator.recents(for: [name], in: context, limit: 3) { d.recentByExercise[k] = v }
    return DraftEntry.from(exercise: name,
                           last: last[name],
                           cardioOverride: kind == .cardio,
                           mobilityOverride: kind == .mobility)
  }

  /// Replace the exercise at `index` with `name`, pre-filled from history.
  /// No-op if another slot already holds that exercise — two entries with
  /// the same name would collide on `DraftEntry.id`.
  func switchExercise(at index: Int, to name: String, context: ModelContext) {
    update {
      guard $0.entries.indices.contains(index) else { return }
      let key = exerciseKey(name)
      let clash = $0.entries.enumerated().contains { i, e in
        i != index && exerciseKey(e.exercise) == key
      }
      guard !clash else { return }
      $0.entries[index] = makePrefilledEntry(name, into: &$0, context: context)
    }
  }

  /// Append `name` as a new pre-filled entry. No-op if it's already present.
  func addExercise(_ name: String, context: ModelContext) {
    update {
      let key = exerciseKey(name)
      guard !$0.entries.contains(where: { exerciseKey($0.exercise) == key }) else { return }
      $0.entries.append(makePrefilledEntry(name, into: &$0, context: context))
    }
  }

  /// Add several catalog exercises by definition id. Ids resolve to
  /// canonical names so the cards render and save like any other entry.
  func addExercises(catalogIDs ids: [String], context: ModelContext) {
    guard !ids.isEmpty else { return }
    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    let nameByID = Dictionary(defs.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    for id in ids {
      guard let name = nameByID[id] else { continue }
      addExercise(name, context: context)
    }
  }

  /// Drop the entry at `index` from the in-progress session. An entry
  /// already marked Done keeps its logged history — this only removes the
  /// card; deleting saved history is the history pane's job.
  func removeEntry(at index: Int) {
    update {
      guard $0.entries.indices.contains(index) else { return }
      $0.entries.remove(at: index)
    }
  }

  /// Mean pace (metres per minute) across this exercise's history where
  /// both distance and duration are recorded — the user's "cadence". Drives
  /// the cardio duration→distance auto-preset. Returns nil when there's no
  /// usable history, so we never invent a distance.
  func cardioAvgPace(for exercise: String, context: ModelContext) -> Double? {
    let key = exerciseKey(exercise)
    let all = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    let paces: [Double] = all.compactMap { e in
      guard exerciseKey(e.exercise) == key,
            let d = e.distanceM, d > 0,
            let m = e.durationMin, m > 0 else { return nil }
      return d / m
    }
    guard !paces.isEmpty else { return nil }
    return paces.reduce(0, +) / Double(paces.count)
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
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(TrainingDraftStore.self) private var store
  @Environment(NavigationState.self) private var nav
  @Environment(\.dismiss) private var dismiss

  /// Re-render the elapsed counter once per minute. Cheap and avoids a
  /// timer goroutine flickering the whole sheet.
  @State private var tick = Date()
  /// Snapshot of the just-finished session; populated by `finish()`
  /// just before `discard()`. Driving `SessionCompleteSheet` off
  /// `.sheet(item:)` so the celebration outlives the draft.
  @State private var completionStats: SessionStats?
  /// Presents the catalog picker to add extra exercises to the session.
  @State private var showAdd = false
  /// The one expanded card (single-open accordion). Keyed by exercise name.
  @State private var openExercise: String? = nil

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
      .navigationTitle(store.draft?.label ?? "Start training")
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
      // Always refresh — the catalog carries each routine's `kind`,
      // and a stale cache means a routine edited in Settings (e.g.
      // changed from `.mixed` to `.cardio`) still renders strength
      // inputs because the `start(type:)` lookup matches the old
      // config. SwiftData fetches are cheap.
      store.refreshCatalog(context: modelContext)
      // Bring any persisted draft up to date against the current
      // prefill / muscle-inference / routine-kind rules. Safe to
      // call when no draft exists (no-ops); fills empty weights /
      // sets / reps that were missed when the draft was first built
      // against older code, and re-syncs each entry's category if
      // the routine's `kind` has since changed in Settings.
      store.backfillDraftFromHistory(context: modelContext)
      // Skip the picker when the dashboard's QuickAdd menu pre-selected
      // a type. We wait until after `refreshCatalog` so the lookup can
      // resolve labels → SessionTypeConfig. Cleared immediately so a
      // dismiss-and-reopen doesn't loop.
      if let pending = nav.pendingTrainingType,
         store.draft == nil,
         let match = store.sessionTypes.first(where: {
           $0.id.caseInsensitiveCompare(pending) == .orderedSame ||
           $0.label.caseInsensitiveCompare(pending) == .orderedSame
         }) {
        nav.pendingTrainingType = nil
        store.start(type: match, context: modelContext)
      }
    }
    .sheet(item: $completionStats) { stats in
      SessionCompleteSheet(stats: stats, accent: accent) {
        completionStats = nil
        dismiss()
      }
      #if os(iOS)
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
      #else
      .frame(width: 560, height: 720)
      #endif
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
                Image(systemName: type.kind.icon)
                  .font(.body.weight(.medium))
                  .foregroundStyle(Theme.inkSecondary)
                  .frame(width: 24)
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
              accent: accent,
              openExercise: $openExercise
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
          }
        }
        Section {
          Button {
            showAdd = true
          } label: {
            Label("Add exercise", systemImage: "plus.circle.fill")
              .font(.septenaCardTitle)
              .foregroundStyle(accent)
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #else
      .listStyle(.inset)
      #endif
      .onAppear { tick = Date() }
      .sheet(isPresented: $showAdd) {
        if let current = store.draft {
          ExercisePickerSheet(
            disabledNames: Set(current.entries.map(\.exercise)),
            onDone: { ids in
              store.addExercises(catalogIDs: ids, context: modelContext)
              Haptics.tick()
            }
          )
        }
      }
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
    store.start(type: type, context: modelContext)
  }

  private func finish() {
    // Snapshot the draft *before* discarding — the completion sheet
    // needs its entries, started-at, and PR baselines. Routine kind
    // comes from the catalog (per-routine), not per-exercise, since
    // the celebration shows session-level stats and the totals are
    // already filtered by entry shape internally.
    if let d = store.draft {
      let routineKind = store.sessionTypes
        .first(where: { $0.id == d.sessionType })?.kind ?? .mixed
      completionStats = SessionStats(from: d, kind: routineKind)
      #if os(iOS)
      TrainingLiveActivityCoordinator.shared.end(from: d, immediate: false)
      #endif
    }
    store.discard(endLiveActivity: false)
    // Don't dismiss yet — sheet's onDone handles that, otherwise the
    // celebration vanishes the same beat it appears.
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
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.a11yMotion) private var motion
  @Environment(\.modelContext) private var modelContext

  let index: Int
  let entry: DraftEntry
  let accent: Color
  /// Which exercise's card is open, lifted to the parent so only one
  /// drawer is expanded at a time — opening one closes the others.
  @Binding var openExercise: String?

  /// Presents the catalog picker to swap this slot's exercise.
  @State private var showSwitch = false
  /// Mean pace (m/min) from this exercise's history — seeds the cardio
  /// duration→distance auto-preset. Computed on appear for cardio cards.
  @State private var avgPace: Double? = nil
  /// Bump on a successful Done tap to fire `ConfettiBurst` + a
  /// `symbolEffect` bounce on the status check. Subtle celebration —
  /// no banner, no sound, just the row briefly confirming the rep.
  @State private var celebrate = 0

  /// True when this card is the open one in the single-open accordion.
  private var expanded: Bool { openExercise == entry.exercise }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded { editor }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(expanded ? accent.opacity(0.12) : Theme.cardSurface)
    )
    .overlay(
      // Subtle accent stroke when open — bright-light gym test: bg
      // tint alone can vanish against a sunlit screen, the stroke
      // makes the open card readable at a glance.
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .stroke(accent.opacity(expanded ? 0.45 : 0), lineWidth: 1.5)
    )
    .opacity(opacityFor(entry.status))
    .contentShape(Rectangle())
    .onTapGesture {
      // No animation on expand/collapse — at the gym you want the
      // editor to be there or not, no in-between motion. Opening this
      // card closes whichever other one was open.
      openExercise = expanded ? nil : entry.exercise
    }
    .onAppear {
      if entry.isCardio, avgPace == nil {
        avgPace = store.cardioAvgPace(for: entry.exercise, context: modelContext)
      }
    }
    .sheet(isPresented: $showSwitch) {
      ExercisePickerSheet(
        selectionMode: .single,
        disabledNames: otherSessionNames,
        alternativesTo: entry.exercise,
        onPick: { def in
          store.switchExercise(at: index, to: def.name, context: modelContext)
          Haptics.tick()
        }
      )
    }
  }

  /// Exercise names in the session other than this slot's — disabled in
  /// the switch picker so a swap can't create a duplicate entry.
  private var otherSessionNames: Set<String> {
    guard let entries = store.draft?.entries else { return [] }
    return Set(entries.enumerated()
      .filter { $0.offset != index }
      .map { $0.element.exercise })
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      statusIcon
        .foregroundStyle(statusTint)
        .font(.system(size: 18, weight: .regular))
        .frame(width: 22)
      HStack(spacing: 6) {
        Text(displayName(entry.exercise))
          .font(.septenaCardTitle)
          .foregroundStyle(Theme.inkPrimary)
        if isPR { prPill }
      }
      Spacer()
      // ⋯ menu — switch this slot for a different exercise, or drop it.
      // Lives in the header so it's reachable before expanding the card
      // (the "machine's taken" case). The Menu consumes its own taps, so
      // it doesn't toggle the card's expand gesture.
      Menu {
        Button {
          showSwitch = true
        } label: {
          Label("Switch exercise", systemImage: "arrow.triangle.2.circlepath")
        }
        // Skip (toggles to Unskip), hidden for already-logged entries.
        // Remove is intentionally absent — in a routine session you skip
        // an exercise (keep it greyed on the list), you don't delete it.
        if entry.status == .skipped {
          Button {
            store.unskip(index: index)
            Haptics.tick()
          } label: {
            Label("Unskip", systemImage: "arrow.uturn.left")
          }
        } else if entry.status != .done && entry.status != .saving {
          Button {
            store.markSkipped(index: index)
            openExercise = nil
            Haptics.tick()
          } label: {
            Label("Skip", systemImage: "forward.end")
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Theme.inkSecondary)
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Exercise options")
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
    case .done:
      // `symbolEffect(.bounce, value:)` re-runs whenever `celebrate`
      // bumps — gives the check a small pop on completion. Doesn't
      // fire on the initial render after re-opening the sheet (the
      // status was already `.done`), only on a fresh Done tap.
      Image(systemName: "checkmark.circle.fill")
        .symbolEffect(.bounce, value: celebrate)
    case .failed:  Image(systemName: "exclamationmark.triangle.fill")
    case .skipped: Image(systemName: "minus.circle")
    }
  }

  private var statusTint: Color {
    switch entry.status {
    case .done:    return accent
    case .failed:  return accent.opacity(0.5)
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

  // MARK: - Progression hints

  private var baseline: PRBaseline? {
    store.draft?.prBaselines[exerciseKey(entry.exercise)]
  }

  /// Recent sessions for this exercise — all of them, regardless of
  /// shape. The training history pane shows mixed strength + cardio
  /// rows for the same exercise without complaint (each row renders
  /// whichever metric fields it actually has); the in-session RECENT
  /// table mirrors that. So a "Bike" exercise that was previously
  /// logged as strength (weight only) and is now being logged as
  /// cardio will show both flavours side-by-side, each in its own
  /// row shape.
  private var recents: [RecentExerciseEntry] {
    store.draft?.recentByExercise[exerciseKey(entry.exercise)] ?? []
  }

  private var isPR: Bool {
    guard let baseline else { return false }
    return TrainingPRCalculator.isPR(draft: entry, baseline: baseline)
  }

  /// Compact 3-row table of the user's most recent sessions for this
  /// exercise. Type-aware columns: strength shows date / weight /
  /// sets×reps; cardio shows date / duration / distance / level.
  /// Monospaced digits + accent-tinted column headers so it reads
  /// like a table even in glance-while-resting mode at the gym.
  @ViewBuilder
  private var recentSessionsTable: some View {
    if recents.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text("RECENT")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        VStack(spacing: 2) {
          // Each row renders whichever metric fields it actually has,
          // independent of the current draft entry's category. Matches
          // the training history pane (`detailLine(_:)`): a single
          // row layout that shows weight/sets×reps when present and
          // duration/distance/level when present — so a "Bike"
          // exercise previously logged as strength still shows its
          // weight history alongside fresh cardio rows.
          ForEach(Array(recents.enumerated()), id: \.offset) { _, r in
            recentRow(date: r.date,
                      columns: adaptiveColumns(r),
                      difficulty: r.difficulty)
          }
        }
        .font(.system(.footnote, design: .rounded).monospacedDigit())
      }
      .padding(.bottom, 10)
    }
  }

  /// Build the per-row metric columns from whichever fields are
  /// populated. Strength bits come first (weight, sets×reps), then
  /// cardio (duration, distance, level). Empty rows return an empty
  /// array so the table still shows date + difficulty even when no
  /// metrics were logged (e.g. mobility entries).
  private func adaptiveColumns(_ r: RecentExerciseEntry) -> [String] {
    var parts: [String] = []
    if let w = r.weight, w > 0 {
      parts.append(w.truncatingRemainder(dividingBy: 1) == 0
                   ? "\(Int(w))kg" : String(format: "%.1fkg", w))
    }
    if let s = r.sets, let reps = r.reps {
      parts.append("\(s)×\(reps)")
    } else if let reps = r.reps {
      parts.append(reps)
    }
    if let d = r.durationMin, d > 0 {
      parts.append("\(Int(d))m")
    }
    if let m = r.distanceM, m > 0 {
      parts.append(m >= 1000 ? String(format: "%.1fkm", m/1000) : "\(Int(m))m")
    }
    if let l = r.level, l > 0 {
      parts.append("L\(fmt(l))")
    }
    return parts
  }

  private func recentRow(date: String, columns: [String], difficulty: String?) -> some View {
    // Joined into one summary column (date · metrics · difficulty)
    // because rows now carry variable metric counts — a strength
    // row has weight + sets×reps, a cardio row has duration ±
    // distance ± level, a mobility row has nothing. Forcing them
    // into a fixed grid produced uneven column widths between
    // rows. The history pane's `LogRow` uses the same shape.
    let summary = columns.isEmpty ? "—" : columns.joined(separator: " · ")
    return HStack(spacing: 12) {
      Text(shortDate(date))
        .foregroundStyle(Theme.inkSecondary)
        .frame(width: 64, alignment: .leading)
      Text(summary)
        .foregroundStyle(Theme.inkPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      // Difficulty as accent-opacity dots — same visual vocabulary as
      // the input picker below so the table reads as "what you'll be
      // doing next" rather than a foreign log row.
      DifficultyGlyph(difficulty: difficulty, accent: accent)
        .frame(width: 22, alignment: .leading)
    }
  }

  // Removed: `strengthColumns` / `cardioColumns`. Replaced by
  // `adaptiveColumns(_:)` which picks per-row based on which fields
  // each historical entry actually has. Mixed-shape recents (e.g. a
  // Bike exercise with both old strength rows and new cardio rows)
  // now display cleanly in a single table.

  // "2026-05-23" → "May 23", "2026-05-20" → "May 20". Compact month
  // abbreviation; the year is implicit since recents are recent.
  private func shortDate(_ iso: String) -> String {
    guard let d = SeptenaDate.parse(iso) else { return iso }
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: d)
  }

  private var prPill: some View {
    Text("PR")
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(accent.opacity(0.18), in: Capsule())
      .foregroundStyle(accent)
      .accessibilityLabel("Personal record")
  }


  // MARK: - Editor (expanded)

  @ViewBuilder
  private var editor: some View {
    Divider().padding(.vertical, 10)
    recentSessionsTable
    if entry.isMobility {
      // Yoga / mobility: TIME + difficulty. No weight/reps, no distance
      // or level — those don't apply to a flow-style session.
      mobilityInputs
      difficultyPicker
    } else if entry.isCardio {
      cardioInputs
    } else {
      strengthInputs
      difficultyPicker
    }
    // Primary action, trailing-aligned (right corner). Skip lives in the
    // ⋯ menu, so the footer is just "log this".
    HStack {
      Spacer()
      Button(entry.status == .failed ? "Retry"
             : entry.status == .done ? "Update" : "Done") {
        let wasDone = (entry.status == .done)
        store.markDone(index: index, mutator: trainingMutator)
        // Celebrate only on first completion, not re-saves of an
        // already-done entry. Success haptic + confetti + status-icon
        // bounce — small enough to fit the "you did a set" cadence.
        if !wasDone {
          Haptics.success()
          celebrate += 1
        }
        if entry.status != .failed { openExercise = nil }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(accent)
      .disabled(entry.status == .saving)
      .overlay(alignment: .center) {
        ConfettiBurst(trigger: celebrate, accent: accent)
      }
    }
    .padding(.top, 12)
  }

  // MARK: - Strength fields

  private var strengthInputs: some View {
    VStack(spacing: 10) {
      // Weight gets its own full-width row — it's the value you nudge
      // between sets, so it earns the space (and "27.5 kg" no longer
      // truncates the way it did three-across). Sets/reps, which rarely
      // change, sit two-across below.
      steppedField(label: "Weight", unit: "kg", step: 2.5,
                   value: Binding(
                     get: { entry.weight.map { fmt($0) } ?? "" },
                     set: { setWeight($0) }
                   ))
      HStack(spacing: 8) {
        steppedField(label: "Sets", step: 1,
                     value: Binding(
                       get: { entry.sets.map(String.init) ?? "" },
                       set: { setSets(Int($0)) }
                     ))
        steppedField(label: "Reps", step: 1,
                     value: Binding(
                       get: { entry.reps ?? "" },
                       set: { setReps($0) }
                     ))
      }
    }
  }

  private var difficultyPicker: some View {
    // Three equal-width pills, each ~48pt tall. Big number on top, short
    // label below. Selected pill is filled accent with white text;
    // unselected is clear with a 1.5pt accent stroke. Sized for a
    // glance + thumb tap at the gym, and high-contrast against the
    // expanded card's accent-tinted background.
    let levels: [(id: String, label: String)] = [
      ("easy", "Easy"), ("medium", "Med"), ("hard", "Hard"),
    ]
    return HStack(spacing: 8) {
      ForEach(Array(levels.enumerated()), id: \.element.id) { idx, rung in
        let isSelected = entry.difficulty == rung.id
        Button {
          store.update { $0.entries[index].difficulty = rung.id }
        } label: {
          VStack(spacing: 2) {
            Text("\(idx + 1)")
              .font(.system(.title2, design: .rounded).weight(.bold))
              .monospacedDigit()
            Text(rung.label.uppercased())
              .font(.caption2.weight(.semibold))
              .tracking(0.5)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(isSelected ? accent : Color.clear)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(isSelected ? Color.clear : accent.opacity(0.55),
                      lineWidth: 1.5)
          )
          .foregroundStyle(isSelected ? Color.white : Theme.inkPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rung.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(.top, 8)
  }

  /// Routine slugs come in two flavours — "Chest-Press" (post-edit
  /// canonical) and "chest press" (legacy). Replace any separator
  /// with a space and Title-Case the words for display.
  private func displayName(_ slug: String) -> String {
    slug
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }

  // MARK: - Mobility fields

  /// Yoga / mobility input row: a single Minutes field. Distance and
  /// level don't apply to a flow-style session, and weight/reps are off
  /// the table by definition for mobility work.
  private var mobilityInputs: some View {
    steppedField(label: "Minutes", step: 1,
                 value: Binding(
                   get: { entry.durationMin.map { fmt($0) } ?? "" },
                   set: { setDuration($0) }
                 ))
  }

  // MARK: - Cardio fields

  /// Cardio input row: minutes · distance · level. Matches the webapp
  /// (`app/(app)/septena/training/session/active/page.tsx`) which uses
  /// the same three fields in the same order for cardio entries.
  private var cardioInputs: some View {
    VStack(spacing: 10) {
      // Minutes is the value you set first; on change we preset distance to
      // your average pace for that exercise ("you know my cadence"). So it
      // gets the full-width hero row, with distance/level two-across below.
      steppedField(label: "Minutes", step: 1,
                   value: Binding(
                     get: { entry.durationMin.map { fmt($0) } ?? "" },
                     set: { newVal in
                       setDuration(newVal)
                       presetDistanceFromDuration(newVal)
                     }
                   ))
      HStack(spacing: 8) {
        steppedField(label: "Distance", unit: "m", step: 50,
                     value: Binding(
                       get: { entry.distanceM.map { fmt($0) } ?? "" },
                       set: { setDistance($0) }
                     ))
        steppedField(label: "Level", step: 1,
                     value: Binding(
                       get: { entry.level.map { fmt($0) } ?? "" },
                       set: { setLevel($0) }
                     ))
      }
    }
  }

  /// Preset distance from the just-entered duration using the exercise's
  /// historical average pace (m/min). Rounds to the nearest 10 m. No-op
  /// when there's no pace history — we don't invent a distance. Runs on
  /// every minutes edit/stepper tap; tweak the result with distance's own
  /// ± buttons afterward.
  private func presetDistanceFromDuration(_ durationStr: String) {
    guard let pace = avgPace,
          let mins = Double(durationStr.replacingOccurrences(of: ",", with: ".")),
          mins > 0 else { return }
    let meters = ((pace * mins) / 10).rounded() * 10
    setDistance(String(Int(meters)))
  }

  // MARK: - Field helpers

  /// Numeric input with big −/＋ targets flanking the value, so weight /
  /// sets / reps can be bumped without summoning the keyboard mid-set —
  /// the centered field still accepts direct entry for arbitrary numbers.
  private func steppedField(label: String,
                            unit: String? = nil,
                            step: Double,
                            value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        stepButton("minus") { bump(value, by: -step) }
        HStack(spacing: 2) {
          TextField("", text: value)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .font(.system(.title3, design: .rounded).weight(.medium))
          if let unit {
            Text(unit).font(.caption2).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        // Card-surface (white in light mode, dark-mode safe) so the field
        // pops against the expanded tile's accent-tinted background — the
        // grey muted surface washed out against the accent.
        .background(Theme.cardSurface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        stepButton("plus") { bump(value, by: step) }
      }
    }
  }

  private func stepButton(_ systemName: String, action: @escaping () -> Void) -> some View {
    Button {
      action()
      Haptics.tick()
    } label: {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .bold))
        .frame(width: 30, height: 40)
        .background(accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(accent)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Parse → clamp at zero → re-write the bound string. Non-numeric values
  /// (e.g. "AMRAP") are left untouched so the steppers can't clobber them;
  /// an empty field starts from the step.
  private func bump(_ value: Binding<String>, by delta: Double) {
    let raw = value.wrappedValue
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: ",", with: ".")
    if !raw.isEmpty, Double(raw) == nil { return }
    let next = max(0, (Double(raw) ?? 0) + delta)
    value.wrappedValue = next.truncatingRemainder(dividingBy: 1) == 0
      ? String(Int(next))
      : String(format: "%.1f", next)
  }

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
  private func setLevel(_ s: String) {
    store.update { $0.entries[index].level = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
}
