import SwiftUI
import SwiftData
import Charts
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
// Training mini-app — historical log of exercise entries grouped by
// session (date + session-type pair). Uses the new LogRow since entries
// aren't checklist items; they're records of what already happened.
// Header summary: this week's session count + Z2 minutes vs target.

struct TrainingDestinationView: View {
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }
  @Environment(DayClock.self) private var clock
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
  @State private var windowDays: Int = 90

  /// Day the drawer's time-travel control is pointing at. On today (the
  /// default) the drawer shows the charts + this week's sessions; on a past
  /// day it drops the dashboard and shows just that day's session log.
  /// Mirrors `NutritionDestinationView.viewingDate`.
  @State private var viewingDate: String = ""
  // Training is an editable dual section: Log = active draft + session list
  // (time-travelable); Patterns = the cardio / strength / muscle / progression
  // dashboard. Default Log; remembered per section.
  @State private var mode: DrawerMode = .remembered(for: "training", default: .log)
  /// Whether the one-shot empty-state nudge has run for this appearance.
  @State private var didNudge = false
  /// Session whose editor (category + start/end + exercises) is open.
  @State private var editingSession: SessionEditContext?

  private var accent: Color { theme.color(for: "training") }

  private var isViewingToday: Bool { viewingDate == clock.today }

  /// How many trailing days of sessions the default view shows. A rolling
  /// 14-day window (not the calendar week) so last week's sessions stay
  /// visible early in a new week instead of vanishing the moment Monday
  /// ticks over. Older history is reachable through the time-travel control.
  private static let defaultWindowDays = 14

  // Hoisted formatters — these were previously re-allocated inside chart and
  // row render paths on every render. DateFormatter init parses locale data,
  // so hoisting to shared statics avoids that cost. Configs are identical to
  // the original inline ones.
  private static let ymdFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
  }()
  private static let ymdLocalFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
  }()
  private static let monthDayFormatter: DateFormatter = {
    let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f
  }()
  private static let weekdayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEE"; return f
  }()
  private static let narrowWeekdayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEEE"; return f
  }()
  private static let hhmmFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .current; return f
  }()

  /// Sessions shown in the default (today) view: the trailing
  /// `defaultWindowDays`, newest first. Falls back to the single most recent
  /// session when the window is empty so the list never goes blank.
  private var defaultSessions: [SessionBlock] {
    let cutoff = sinceDate(daysBack: Self.defaultWindowDays)
    let recent = sessions.filter { $0.date >= cutoff }
    return recent.isEmpty ? Array(sessions.prefix(1)) : recent
  }

  /// Sessions on the time-traveled day.
  private var viewingSessions: [SessionBlock] {
    sessions.filter { $0.date == viewingDate }
  }

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
                  quickAdd: DrawerQuickAdd("Start session", systemImage: "play.fill") { nav.showTrainingSession = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
      if isViewingToday {
        // Active draft + the rolling session list. Older sessions live
        // behind the time-travel control, not dumped inline; the trend
        // charts moved to Patterns.
        if let d = draftStore.draft {
          activeSessionSection(d)
        }
        ForEach(defaultSessions, id: \.key) { block in
          sessionBlockView(block)
        }
        if !loading && entries.isEmpty {
          ContentUnavailableView("No sessions yet",
                                 systemImage: theme.icon(for: "training"),
                                 description: Text("Tap + to log a session."))
        }
      } else {
        // Time-travel view: just the picked day's sessions.
        if viewingSessions.isEmpty {
          Text("Nothing logged on this day.")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
          ForEach(viewingSessions, id: \.key) { block in
            sessionBlockView(block)
          }
        }
      }
    }, patterns: {
      z2CardioSection
      strengthVolumeSection   // merged headline + 8-week trend in one card
      muscleLoadSection       // per-muscle sets, trailing 7 days
      progressionSection      // always renders its card (pills + chart/empty)
    })
    .tint(accent)
    .task {
      if viewingDate.isEmpty { viewingDate = clock.today }
      paintFromCache()
      draftStore.refreshCatalog(context: modelContext, today: clock.today, now: clock.now)
    }
    .onChange(of: clock.today) { _, newToday in
      if isViewingToday { viewingDate = newToday }
      Task { await load() }
    }
    .sectionReload(on: viewingDate, onDataChange: true, forSections: ["training"]) {
      await load()
    }
    .adaptiveDetail(item: $editing) { entry in
      EditExerciseEntrySheet(
        original: entry,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
    .adaptiveDetail(item: $editingSession) { ctx in
      EditSessionSheet(
        context: ctx,
        title: exerciseTitle,
        detail: { detailLine($0) ?? "" },
        onSave: { newType in applySessionRetag(date: ctx.date, to: newType) },
        onEntryUpdated: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  /// One day+session block: a tappable session-type header with the
  /// friendly date, then the session's exercise rows. Shared by the default
  /// (this-week) and time-travel (single-day) branches of the body.
  @ViewBuilder
  private func sessionBlockView(_ block: SessionBlock) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        sessionHeaderButton(for: block)
        Spacer()
        Text(friendlyDate(block.date))
          .foregroundStyle(.secondary)
      }
      .font(.subheadline)
      .padding(.horizontal, 16)
      if let note = block.entries.compactMap(\.note).first(where: { !$0.isEmpty }) {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "note.text").font(.caption2)
          Text(note).font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
      }
      DrawerSection(padding: .none) {
        ForEach(block.entries) { entry in
          if entry.file != nil {
            LogEntryRow(
              title: exerciseTitle(entry),
              detail: detailLine(entry),
              trailing: entry.loggedAt.map(timeOnly),
              accessory: glyphAccessory(for: entry),
              tint: accent,
              isSelected: editing?.id == entry.id,
              onEdit: { editing = entry },
              onDelete: { delete(entry) }
            )
          } else {
            LogEntryRow(
              title: exerciseTitle(entry),
              detail: detailLine(entry),
              trailing: entry.loggedAt.map(timeOnly),
              accessory: glyphAccessory(for: entry)
            )
          }
        }
      }
    }
  }

  /// Canonical, title-cased name for a logged entry. Resolves the stored
  /// label through the user's catalog + curated library so the history list
  /// reads coherently regardless of how the name was originally written.
  private func exerciseTitle(_ entry: ExerciseEntry) -> String {
    guard let raw = entry.exercise, !raw.isEmpty else { return "—" }
    return CanonicalExerciseName.display(raw, catalog: draftStore.exerciseNameByKey)
  }

  private func applyLocalUpdate(_ updated: ExerciseEntry) {
    guard let idx = entries.firstIndex(where: { $0.id == updated.id }) else { return }
    entries[idx] = updated
    ResponseCache.save(entries, forKey: CacheKey.entries)
  }

  /// Each day's section header. Tapping opens the session editor (category,
  /// start / end, and the session's exercises) rather than the old retag-only
  /// dropdown — one tap target, one place to change everything about a session.
  @ViewBuilder
  private func sessionHeaderButton(for block: SessionBlock) -> some View {
    let current = block.session
    let activeType = draftStore.sessionTypes.first { $0.id == current }
    let label = activeType?.label ?? (current.isEmpty ? "Untagged" : current.capitalized)
    let icon = activeType?.kind.icon ?? (current.isEmpty ? "questionmark.circle" : nil)
    Button {
      editingSession = SessionEditContext(
        date: block.date, session: block.session, entries: block.entries)
    } label: {
      HStack(spacing: 4) {
        if let icon { Image(systemName: icon) }
        Text(label)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .tint(accent)
  }

  /// Patch a session-type change into the local `entries` array after the
  /// editor has written it through `trainingMutator.retagSession`, so the
  /// daily list and chart series re-bucket without waiting for a reload.
  private func applySessionRetag(date: String, to newSessionType: String) {
    for idx in entries.indices where entries[idx].date == date {
      entries[idx].session = newSessionType
    }
    ResponseCache.save(entries, forKey: CacheKey.entries)
  }

  private func delete(_ entry: ExerciseEntry) {
    guard let id = entry.file else { return }
    trainingMutator.deleteEntry(id: id)
    entries.removeAll { $0.file == id }
    ResponseCache.save(entries, forKey: CacheKey.entries)
    Haptics.warning()
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
        .tint(AdaptiveColor.fillForWhiteInk(accent))
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
    // Off-main: the two history reads run on MirrorReader's background
    // context so opening the Training pane doesn't hitch on the main thread.
    let r = await MirrorReader.shared.read { ctx in
      (entries: ChecklistMirror.loadTrainingEntries(context: ctx, since: since),
       cardio: ChecklistMirror.loadTrainingCardioHistory(context: ctx, days: 30, today: clock.today))
    }
    entries = r.entries
    ResponseCache.save(r.entries, forKey: CacheKey.entries)
    cardio = r.cardio
    ResponseCache.save(r.cardio, forKey: CacheKey.cardio)
    loading = false
    applyEmptyStateNudgeIfNeeded()
  }

  /// Training's "empty" is "no session logged today" — for a chart-forward
  /// section the dashboard is the natural greeting on a rest morning.
  private func applyEmptyStateNudgeIfNeeded() {
    DrawerMode.nudgeEmptyDayToPatterns(mode: $mode, didNudge: $didNudge,
                                       isViewingToday: isViewingToday,
                                       isEmpty: !entries.contains { $0.date == today })
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
      // Goal-aware: a `training.cardio_minutes_week` goal overrides the ~150
      // default that `loadTrainingCardioHistory` stamps off-main.
      let target = Int(TrainingMetrics.cardioMinutesTarget(context: modelContext).rounded())
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
              .font(.septenaMetaSmall)
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
  /// The target/ceiling band now lives in goals (a `training.hard_sets_week`
  /// range goal); `TrainingMetrics.hardSetsBand` resolves it with a 12–20
  /// fallback so an unset user sees the productive default.

  private func effectiveHardSets(in days: Int) -> Double {
    let cutoff = sinceDate(daysBack: days)
    var total: Double = 0
    for e in entries where isStrengthEntry(e) && e.date >= cutoff {
      guard let s = e.sets.flatMap(Int.init), s > 0 else { continue }
      let weight: Double
      switch TrainingEffort.canonicalKey(e.difficulty) {
      case "hard", "max": weight = 1.0
      case "moderate":    weight = 0.5
      default:            weight = 0   // easy / unrated → no stimulus credit
      }
      total += Double(s) * weight
    }
    return total
  }

  /// Strength-volume card — one widget that answers both "enough this week?"
  /// and "trending up or coasting?". The header carries this week's effective
  /// hard sets vs target (trailing 7 days) plus the productive-band guidance;
  /// below it an 8-week trailing trend (bars + target line + shaded ceiling
  /// band) and a mean-intensity sparkline. Replaces the former split of a
  /// progress-bar card + a separate trend card. See `effectiveHardSets(in:)`.
  @ViewBuilder
  private var strengthVolumeSection: some View {
    let series = weeklyVolumeTrend
    // Trailing 7 days (today + prev 6) — the app-wide week, matching the
    // `training.hard_sets_week` goal and the watch ring.
    let thisWeekRaw = effectiveHardSets(in: 6)
    let hasData = series.contains { $0.hardSets > 0 } || thisWeekRaw > 0
    if hasData {
      let band = TrainingMetrics.hardSetsBand(context: modelContext)
      let target = band.target
      let ceiling = band.ceiling
      let thisWeekValue = Int(thisWeekRaw.rounded())
      let overTarget = thisWeekRaw > target
      let overCeiling = thisWeekRaw > ceiling
      let bandText = overCeiling
        ? "Past the \(Int(ceiling))-set ceiling — consider a deload."
        : overTarget
          ? "In the productive \(Int(target))–\(Int(ceiling)) hard-set band."
          : "Target \(Int(target)) hard sets/week to drive hypertrophy."

      let maxBar = series.map(\.hardSets).max() ?? 0
      let yMax = max(maxBar, ceiling) * 1.15
      let lastWeek = series.last?.hardSets ?? 0
      let prevWeek = series.dropLast().last?.hardSets ?? 0
      let delta = lastWeek - prevWeek
      let deltaText = delta == 0
        ? "flat vs last week"
        : "\(delta > 0 ? "+" : "")\(Int(delta)) vs last week"
      let avgIntensity: Double = {
        let vals = series.compactMap(\.meanIntensity)
        return vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
      }()
      let weekFmt: (Date) -> String = { d in
        Self.monthDayFormatter.string(from: d)
      }
      let summary = "Strength volume. This week \(thisWeekValue) hard sets, target \(Int(target)). \(bandText) 8-week trend \(deltaText). Average intensity \(avgIntensity.decimalString()) out of 4."

      DrawerSection("Strength") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Strength volume").font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(thisWeekValue)/\(Int(target)) hard sets")
              .font(.septenaMetaSmall)
              .foregroundStyle(.secondary)
          }
          HStack(alignment: .firstTextBaseline) {
            Text(bandText).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(deltaText)
              .font(.septenaMetaMicro)
              .foregroundStyle(.secondary)
              .layoutPriority(1)
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

  // MARK: - Muscle load (per-muscle sets, trailing 7 days)

  /// Weekly per-muscle set target. ~10–12 direct sets/muscle/week is the
  /// hypertrophy meta-analysis sweet spot; 12 matches the strength-volume
  /// card's whole-body target and the reference "growth zone" tools.
  private static let muscleSetsTarget = 12

  /// Sets logged per muscle over the trailing 7 days. Counts an entry's
  /// `sets` toward its exercise's **primary** muscle only (secondary muscles
  /// excluded in v1). Exercises with no muscle tag (cardio, mobility) drop
  /// out naturally, so this is implicitly strength + core. Resolution:
  /// entry name → ExerciseDefinitionEntity (by `exerciseKey`) → primaryMuscle.
  private func muscleSetsThisWeek() -> [Muscle: Int] {
    let defs = (try? modelContext.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    var muscleByKey: [String: Muscle] = [:]
    for def in defs {
      guard let m = Muscle.resolve(def.primaryMuscle) else { continue }
      // Index by both id and name so either form of a logged name resolves.
      let idKey = exerciseKey(def.id), nameKey = exerciseKey(def.name)
      if muscleByKey[idKey] == nil { muscleByKey[idKey] = m }
      if muscleByKey[nameKey] == nil { muscleByKey[nameKey] = m }
    }
    let cutoff = sinceDate(daysBack: 6)   // today + previous 6 = trailing 7
    var totals: [Muscle: Int] = [:]
    for e in entries where e.date >= cutoff {
      guard let name = e.exercise,
            let muscle = muscleByKey[exerciseKey(name)],
            let s = e.sets.flatMap(Int.init), s > 0 else { continue }
      totals[muscle, default: 0] += s
    }
    return totals
  }

  /// Per-muscle "sets this week" card — every muscle group as a row with a
  /// bar toward the weekly target, so under-trained groups (empty bars) are
  /// as legible as the worked ones. Anatomical order (`Muscle.allCases`)
  /// clusters push / pull / legs / core. Hidden until there's any data.
  @ViewBuilder
  private var muscleLoadSection: some View {
    let totals = muscleSetsThisWeek()
    if totals.values.contains(where: { $0 > 0 }) {
      let target = Self.muscleSetsTarget
      let worked = totals.values.filter { $0 > 0 }.count
      let summary = "Muscle load, trailing 7 days. \(worked) of 16 muscle groups worked. "
        + Muscle.allCases.map { "\($0.label) \(totals[$0] ?? 0) sets" }.joined(separator: ", ")
      DrawerSection("Muscle load") {
        VStack(alignment: .leading, spacing: 10) {
          NavigationLink {
            MuscleBalanceView()
          } label: {
            HStack {
              Text("Sets per muscle").font(.subheadline.weight(.semibold))
              Spacer()
              Text("last 7 days").font(.caption2).foregroundStyle(.secondary)
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          ForEach(Muscle.allCases) { muscle in
            muscleRow(muscle, sets: totals[muscle] ?? 0, target: target)
          }
        }
        .a11yCombineKeepingChildren(summary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
    }
  }

  private func muscleRow(_ muscle: Muscle, sets: Int, target: Int) -> some View {
    let fraction = min(1, Double(sets) / Double(target))
    // Untrained groups read muted; worked-but-under-target use a softened
    // accent; at/over target use full accent — the at-a-glance "gap" cue.
    let barColor: Color = sets == 0 ? Theme.inkSecondary.opacity(0.18)
                        : sets >= target ? accent
                        : accent.opacity(0.55)
    return HStack(spacing: 10) {
      Text(muscle.label)
        .font(.caption)
        .foregroundStyle(sets == 0 ? Theme.inkSecondary : Theme.inkPrimary)
        .frame(width: 88, alignment: .leading)
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Theme.inkSecondary.opacity(0.10))
          Capsule().fill(barColor)
            .frame(width: max(sets > 0 ? 6 : 0, geo.size.width * fraction))
        }
      }
      .frame(height: 8)
      Text("\(sets)")
        .font(.septenaMetaSmall)
        .foregroundStyle(sets == 0 ? Theme.inkSecondary : Theme.inkPrimary)
        .frame(width: 24, alignment: .trailing)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(muscle.label): \(sets) of \(target) sets")
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
    let fmt = Self.ymdFormatter
    // Anchor to this week's start (week-start per the user's locale).
    let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: clock.now)
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
        switch TrainingEffort.canonicalKey(e.difficulty) {
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

  @ViewBuilder
  private func intensitySparkline(_ series: [WeekVolumePoint], avg: Double) -> some View {
    let weekFmt: (Date) -> String = { d in
      Self.monthDayFormatter.string(from: d)
    }
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Intensity").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Text("avg \(avg.decimalString())/4")
          .font(.septenaMetaMicro).foregroundStyle(.secondary)
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
            .accessibilityValue("intensity \(v.decimalString())")
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
    let fmt = Self.ymdFormatter
    let cal = Calendar.current
    return (0..<7).reversed().compactMap { off in
      cal.date(byAdding: .day, value: -off, to: clock.now).map(fmt.string(from:))
    }
  }

  /// Per-exercise progression line chart. Pills above the chart switch
  /// the selected exercise (or one of the two meta aggregates).
  private var progressionSection: some View {
    let pills = pillOptions
    let line = lineData
    // Strength weight/volume are stored in kg; scale the whole chart (domain,
    // marks, axis labels, average) into the user's unit in one place.
    let scale = metricScale
    let yMax: Double = {
      let vals = line.compactMap(\.value)
      guard let m = vals.max(), m > 0 else { return 1 }
      return m * scale * 1.15
    }()
    let vals = line.compactMap(\.value).map { $0 * scale }
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
          DrawerRangePicker(days: $windowDays, options: [.month, .sixty, .ninety])
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
                    y: .value("Metric", v * scale),
                    series: .value("Group", s)
                  )
                  .interpolationMethod(.linear)
                  .foregroundStyle(by: .value("Group", s))
                  .accessibilityHidden(true)
                  PointMark(
                    x: .value("Date", p.day),
                    y: .value("Metric", v * scale)
                  )
                  .symbolSize(28)
                  .foregroundStyle(by: .value("Group", s))
                  .accessibilityLabel(weekdayFull(p.id))
                  .accessibilityValue("\(s), \(yLabel(v * scale))")
                } else {
                  LineMark(
                    x: .value("Date", p.day),
                    y: .value("Metric", v * scale)
                  )
                  .interpolationMethod(.linear)
                  .foregroundStyle(accent)
                  .accessibilityHidden(true)
                  PointMark(
                    x: .value("Date", p.day),
                    y: .value("Metric", v * scale)
                  )
                  .symbolSize(28)
                  .foregroundStyle(accent)
                  .accessibilityLabel(weekdayFull(p.id))
                  .accessibilityValue(yLabel(v * scale))
                }
              }
            }
          }
          .chartForegroundStyleScale(domain: strengthSeriesScale.domain,
                                     range: strengthSeriesScale.range)
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
            SelectableChip(isSelected: isSelected, tint: accent) {
              selectedExercise = item.name
            } label: {
              HStack(spacing: Theme.Spacing.xs) {
                Text(item.label)
                Text("\(item.count)")
                  .font(.septenaMeta)
                  .opacity(isSelected ? 1.0 : 0.65)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Strength series color scale
  //
  // The split "All strength" chart draws one line per session category
  // (Upper, Lower, …). Two rules the user cares about:
  //   1. A category keeps the SAME color and the SAME legend position no
  //      matter which window (30/60/90) is selected — so the domain is built
  //      from ALL loaded entries (not the windowed subset) and sorted, then
  //      pinned via `chartForegroundStyleScale`.
  //   2. Colors are DERIVED from the section accent, not SwiftUI's guessed
  //      default palette — each series is a deterministic hue-rotated shade of
  //      the accent (see `seriesColor`).

  /// All strength session-category labels across loaded history, stably
  /// sorted. Independent of `windowDays`, so colors/positions never reshuffle.
  private var strengthSeriesDomain: [String] {
    var set = Set<String>()
    for e in entries where isStrengthEntry(e) && volumeValue(e) != nil {
      set.insert((e.session.isEmpty ? "other" : e.session).capitalized)
    }
    return set.sorted()
  }

  /// Fixed (domain, range) for the chart's foreground-style scale: each
  /// series name mapped to its accent-derived color by stable index.
  private var strengthSeriesScale: (domain: [String], range: [Color]) {
    let domain = strengthSeriesDomain
    return (domain, domain.indices.map { seriesColor($0) })
  }

  /// Accent-derived series color — a monochromatic ramp, NOT a hue rotation.
  /// Every series keeps the accent's hue and only its brightness/saturation
  /// step, so lines read as clear shades of the section color (accent, a
  /// lighter tint, a deeper shade) rather than unrelated colors. Index 0 is
  /// the accent itself. Deterministic per index.
  private func seriesColor(_ index: Int) -> Color {
    let base = accent.hsbComponents
    let steps: [(s: Double, b: Double)] = [
      (1.00, 1.00),   // accent as-is
      (0.48, 1.24),   // lighter, softer tint
      (1.00, 0.68),   // deeper shade
      (0.34, 1.42),   // pale
      (0.85, 0.52),   // darkest
      (0.62, 1.32),
    ]
    let i = index % steps.count
    let s = min(1.0, max(0.0, base.s * steps[i].s))
    let b = min(1.0, max(0.12, base.b * steps[i].b))
    return Color(hue: base.h, saturation: s, brightness: b)
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
    let fmt = Self.ymdFormatter

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
    let fmt = Self.ymdFormatter
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
    // Group by `exerciseKey` so divergent spellings of one movement collapse
    // into a single pill ("leg press" / "leg-press" / "Leg Press" → one).
    // The pill's identity + label is the canonical display name, so selecting
    // it filters the chart by the same key (see `metricKind` /
    // `loadTrainingProgression`).
    var counts: [String: Int] = [:]            // key -> entry count
    var hasCardio: [String: Bool] = [:]        // key -> any cardio entry
    var display: [String: String] = [:]        // key -> canonical display name
    for e in entries {
      guard let raw = e.exercise, !raw.isEmpty else { continue }
      let key = exerciseKey(raw)
      guard !key.isEmpty else { continue }
      counts[key, default: 0] += 1
      if display[key] == nil {
        display[key] = CanonicalExerciseName.display(raw, catalog: draftStore.exerciseNameByKey)
      }
      if isCardioEntry(e) { hasCardio[key] = true }
    }
    let keys = counts.keys.sorted { (a, b) in
      let ca = counts[a] ?? 0; let cb = counts[b] ?? 0
      if ca != cb { return ca > cb }
      return (display[a] ?? a) < (display[b] ?? b)
    }
    var strength: [PillItem] = []
    var cardio: [PillItem] = []
    for k in keys {
      let name = display[k] ?? k
      let item = PillItem(name: name, label: name, count: counts[k] ?? 0)
      if hasCardio[k] == true { cardio.append(item) } else { strength.append(item) }
    }
    let metaS = PillItem(name: MetaExercise.strength, label: "All strength", count: strength.count)
    let metaC = PillItem(name: MetaExercise.cardio,   label: "All cardio",   count: cardio.count)
    return (strength: [metaS] + strength, cardio: [metaC] + cardio)
  }

  private var today: String { clock.today }

  private enum MetricKind { case weight, duration, pace, volume, cardioTotal }

  /// Pick a metric kind from the entry shape — same idea as the webapp's
  /// `metricKind()` but driven entirely off the data we've already loaded.
  private func metricKind(for exercise: String) -> MetricKind {
    if exercise == MetaExercise.strength { return .volume }
    if exercise == MetaExercise.cardio { return .cardioTotal }
    // `exercise` is now a canonical display name; match entries by key so
    // every spelling variant of the selected movement is considered.
    let key = exerciseKey(exercise)
    let rel = entries.filter { exerciseKey($0.exercise ?? "") == key }
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
    let u = WeightUnit.current.suffix
    switch metricKind(for: selectedExercise) {
    case .volume: return "Total volume per session (\(u))"
    case .cardioTotal: return "Total cardio minutes per session"
    case .pace: return "Pace (m/min) per session"
    case .duration: return "Duration (min) per session"
    case .weight: return "Weight (\(u)) over time"
    }
  }

  /// Multiplier turning the chart's stored-kg strength values (weight, volume)
  /// into the user's display unit. Non-weight metrics stay 1.
  private var metricScale: Double {
    switch metricKind(for: selectedExercise) {
    case .weight, .volume: return WeightUnit.current.displayFactor
    default: return 1
    }
  }

  /// Format an axis value. The chart pre-scales weight/volume into the display
  /// unit, so this only appends the suffix — it must not convert again.
  private func yLabel(_ v: Double) -> String {
    switch metricKind(for: selectedExercise) {
    case .volume, .cardioTotal: return "\(Int(v))"
    case .pace: return v.decimalString(0)
    case .duration: return "\(Int(v))m"
    case .weight: return "\(Int(v))\(WeightUnit.current.suffix)"
    }
  }

  private func shortMonthDay(_ d: Date) -> String {
    return Self.monthDayFormatter.string(from: d)
  }

  // Full weekday name for VoiceOver — visual axis uses narrow initials.
  private func weekdayFull(_ iso: String) -> String {
    guard let d = Self.ymdFormatter.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return Self.weekdayFormatter.string(from: d)
  }

  private func weekdayInitial(_ iso: String) -> String {
    guard let d = Self.ymdFormatter.date(from: iso) else { return "" }
    return Self.narrowWeekdayFormatter.string(from: d)
  }

  private func loadProgression() async {
    if MetaExercise.isMeta(selectedExercise) {
      progression = []
      return
    }
    progressionLoading = true
    let exercise = selectedExercise
    progression = await MirrorReader.shared.read {
      ChecklistMirror.loadTrainingProgression(context: $0, exercise: exercise)
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

  private func formatWeight(_ kg: Double) -> String {
    let u = WeightUnit.current
    let w = u.display(kg)
    return w.truncatingRemainder(dividingBy: 1) == 0
      ? "\(Int(w))\(u.suffix)"
      : "\(w.decimalString(1))\(u.suffix)"
  }

  private func formatDistance(_ m: Double) -> String {
    DistanceUnit.current.format(meters: m)
  }

  private func timeOnly(_ ts: String) -> String {
    // `loggedAt` is written as UTC ISO8601 ("…Z"); display in the user's zone.
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: ts) {
      return Self.hhmmFormatter.string(from: d)
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
    guard let d = Self.ymdLocalFormatter.date(from: iso) else { return iso }
    let cal = Calendar.current
    if iso == clock.today { return "Today" }
    if let todayDate = SeptenaDate.parse(clock.today),
       let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayDate),
       iso == SeptenaDate.format(yesterday) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: clock.now).day ?? 0
    if days < 7 {
      return Self.weekdayFormatter.string(from: d)
    }
    return Self.monthDayFormatter.string(from: d)
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: clock.now) ?? clock.now
    return Self.ymdFormatter.string(from: d)
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
    default:       return CanonicalExerciseName.display(name)
    }
  }
}

// MARK: - Accent → HSB (cross-platform)

private extension Color {
  /// Hue/saturation/brightness components, used to derive the strength
  /// series palette from the section accent. Resolves through the platform
  /// color type so it works on both iOS and macOS.
  var hsbComponents: (h: Double, s: Double, b: Double) {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    #if canImport(UIKit)
    UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    #elseif canImport(AppKit)
    let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
    ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    #endif
    return (Double(h), Double(s), Double(b))
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

  // Hoisted formatter — was re-allocated per session start.
  private static let hhmmPosixFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Cached session-types from the server. Empty until first fetch.
  var sessionTypes: [SessionTypeConfig] = []
  /// Days since the last session of each type — feeds the palette's
  /// "Last 2d ago" badges. Keyed by type id ("upper", "cardio", ...).
  var daysAgo: [String: Int] = [:]
  /// Server-suggested next type, if any.
  var suggested: String? = nil

  /// Cached `exerciseKey → display name` map from the user's catalog, used
  /// to resolve stored entry labels to canonical names at render time.
  /// Refreshed alongside the rest of the catalog; empty until first fetch
  /// (display falls back to the curated library + title-case meanwhile).
  var exerciseNameByKey: [String: String] = [:]

  /// Currently active draft. Nil when no session is in flight.
  var draft: DraftSession?

  /// After logging a set, open the next pending exercise automatically.
  /// Device-local presentation pref — default on (historical behavior).
  static let autoAdvanceKey = "training.autoAdvanceNextExercise"
  static let defaultAutoAdvance = true

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
       var decoded = try? JSONDecoder().decode(DraftSession.self, from: data) {
      Self.backfillDoneOrderIfNeeded(&decoded)
      draft = decoded
    }
  }

  /// Older persisted drafts have no `doneOrder`; seed it from routine order
  /// of already-done entries so resumed sessions list correctly.
  private static func backfillDoneOrderIfNeeded(_ d: inout DraftSession) {
    guard d.doneOrder.isEmpty else { return }
    d.doneOrder = d.entries.filter { $0.status == .done }.map(\.exercise)
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
  func refreshCatalog(context: ModelContext, today: String, now: Date) {
    sessionTypes = ChecklistMirror.loadSessionTypes(context: context)
    let s = ChecklistMirror.loadSuggestedWorkout(context: context, today: today, now: now)
    daysAgo = s.daysAgo
    suggested = s.suggested?.type
    exerciseNameByKey = CanonicalExerciseName.catalogMap(context: context)
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
    Self.backfillDoneOrderIfNeeded(&d)
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

  func start(type: SessionTypeConfig, context: ModelContext, today: String) {
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
    let timeF = Self.hhmmPosixFormatter
    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime]
    draft = DraftSession(
      date: today,
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
    let entry = d.entries[index]
    // Cardio has no difficulty UI in the logger; never persist one even if a
    // value lingers on the draft (legacy drafts, category switch).
    let difficulty = (entry.isCardio || entry.difficulty.isEmpty) ? nil : entry.difficulty
    let note: String? = entry.note.isEmpty ? nil : entry.note

    // Re-saving an entry that's already been logged (the "Update" button) is
    // an EDIT, not a new set: mutate the existing record in place. Without
    // this branch every Update inserted a fresh row with a new id, silently
    // duplicating the set.
    if let savedID = entry.savedFile {
      update { $0.entries[index].status = .saving }
      mutator.updateEntry(
        id: savedID,
        weight: .some(entry.weight),
        sets: .some(entry.sets.map(String.init)),
        reps: .some(entry.reps),
        difficulty: .some(difficulty),
        durationMin: .some(entry.durationMin),
        distanceM: .some(entry.distanceM),
        level: .some(entry.level),
        note: .some(note)
      )
      update { $0.entries[index].status = .done }
      return
    }

    update {
      $0.noteExerciseCompleted(entry.exercise)
      $0.entries[index].status = .saving
    }
    let saved = mutator.addEntry(
      date: d.date,
      time: d.time,
      sessionType: d.sessionType,
      exercise: entry.exercise,
      weight: entry.weight,
      sets: entry.sets.map(String.init),
      reps: entry.reps,
      difficulty: difficulty,
      durationMin: entry.durationMin,
      distanceM: entry.distanceM,
      level: entry.level,
      note: note,
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
      let old = $0.entries[index].exercise
      let key = exerciseKey(name)
      let clash = $0.entries.enumerated().contains { i, e in
        i != index && exerciseKey(e.exercise) == key
      }
      guard !clash else { return }
      $0.doneOrder.removeAll { $0 == old }
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

  /// Move the entry at `index` to the end of the session — "I'll do this one
  /// last" (e.g. splitting cardio across the start and end of a workout).
  /// Reorders the underlying entries; the completed-first list sort then
  /// keeps it at the bottom of the remaining work.
  func moveToEnd(at index: Int) {
    update {
      guard $0.entries.indices.contains(index) else { return }
      let e = $0.entries.remove(at: index)
      $0.entries.append(e)
    }
  }

  /// Drop the entry at `index` from the in-progress session. When the entry
  /// was already logged (status `done`), its saved record is deleted too —
  /// this is the "undo an accidental save" path. Distinct from Skip, which
  /// keeps the slot greyed on the list for later.
  func removeEntry(at index: Int, mutator: TrainingMutator) {
    guard let d = draft, d.entries.indices.contains(index) else { return }
    let exercise = d.entries[index].exercise
    if let savedID = d.entries[index].savedFile {
      mutator.deleteEntry(id: savedID)
    }
    update {
      guard $0.entries.indices.contains(index) else { return }
      $0.doneOrder.removeAll { $0 == exercise }
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
  @Environment(DayClock.self) private var clock
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
  /// The exercise whose editor drawer is open (tap-to-drill). nil = the
  /// session's exercise list. Driving the editor off `.adaptiveDetail`.
  @State private var editing: EditingExercise? = nil

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
    #if os(iOS)
    // Keep the screen awake while a session is in flight — nobody wants to
    // re-unlock with chalked/sweaty hands between sets. Released the moment
    // the logger closes or the draft clears.
    .onAppear { UIApplication.shared.isIdleTimerDisabled = store.draft != nil }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    .onChange(of: store.draft != nil) { _, active in
      UIApplication.shared.isIdleTimerDisabled = active
    }
    #endif
    .task {
      // Always refresh — the catalog carries each routine's `kind`,
      // and a stale cache means a routine edited in Settings (e.g.
      // changed from `.mixed` to `.cardio`) still renders strength
      // inputs because the `start(type:)` lookup matches the old
      // config. SwiftData fetches are cheap.
      store.refreshCatalog(context: modelContext, today: clock.today, now: clock.now)
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
      if let pending = nav.pendingTrainingType, store.draft == nil {
        let match = store.sessionTypes.first { type in
          let byID = type.id.caseInsensitiveCompare(pending) == .orderedSame
          let byLabel = type.label.caseInsensitiveCompare(pending) == .orderedSame
          return byID || byLabel
        }
        if let match {
          nav.pendingTrainingType = nil
          store.start(type: match, context: modelContext, today: clock.today)
        }
      }
    }
    .sheet(item: $completionStats) { stats in
      SessionCompleteSheet(
        stats: stats,
        accent: accent,
        onFinish: { text, finishedAt in
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            SeptenaServices.shared.trainingMutator.setSessionNote(
              date: stats.date, sessionType: stats.sessionType, note: trimmed)
          }
          SeptenaServices.shared.trainingMutator.setSessionEndedAt(
            date: stats.date, sessionType: stats.sessionType,
            endedAt: EventTimestamp.localISO(from: finishedAt))
        },
        onDone: {
          completionStats = nil
          dismiss()
        })
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
        // Each row is a free-standing pill on a plain list: clear row
        // backgrounds + hidden separators stop the list chrome from fusing
        // the pills into one grouped slab.
        statsHeader(d)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        ForEach(d.entriesForActiveList, id: \.exercise) { e in
          // `index` must be the entry's real slot in `draft.entries`
          // (store mutations key off it), even though the rows render
          // in completed-first order.
          let idx = d.entries.firstIndex { $0.exercise == e.exercise } ?? 0
          TrainingExerciseRow(
            index: idx,
            entry: e,
            accent: accent,
            onTap: { editing = EditingExercise(exercise: e.exercise) }
          )
          .id(e.exercise)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
        }
        Button {
          showAdd = true
        } label: {
          Label("Add exercise", systemImage: "plus.circle.fill")
            .font(.septenaCardTitle)
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
      }
      .listStyle(.plain)
      // Plain list defaults to a white scroll background, which left the
      // white pills with zero contrast. Swap in the grouped grey canvas so
      // each pill reads as raised.
      .scrollContentBackground(.hidden)
      .background(Theme.groupedBackground)
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
      // Tap a row → drill into a focused editor for that one exercise. On
      // iPhone this is a sheet; on iPad/Mac a docked inspector beside the list
      // (via `.adaptiveDetail`). Logging "Done" auto-advances to the next
      // still-pending exercise.
      .adaptiveDetail(item: $editing) { ed in
        TrainingExerciseEditor(exercise: ed.exercise, accent: accent, selection: $editing)
      }
    }
  }

  private func statsHeader(_ d: DraftSession) -> some View {
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
    let done = d.doneCount
    let total = max(d.totalCount, 1)
    return VStack(alignment: .leading, spacing: 12) {
      // Spread the three stats edge-to-edge rather than clustering them on
      // the left — Spacers between each give the even, full-width spacing.
      HStack(alignment: .top) {
        liveElapsedStat(startedAt: d.startedAt)
        Spacer()
        stat(value: "\(Int(cardio))", label: "cardio", unit: "m")
        Spacer()
        stat(value: "\(Int(WeightUnit.current.display(lifted)))", label: "lifted",
             unit: WeightUnit.current.suffix)
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("PROGRESS")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(done)/\(total)")
            .font(.septenaMetaSmall)
            .foregroundStyle(.secondary)
        }
        ProgressView(value: Double(done), total: Double(total))
          .tint(accent)
      }
    }
    // Own card surface — on a plain list the grouped-section background is
    // gone, so the header has to draw its own pill like the exercise rows.
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.cardSurface)
    )
  }

  private func stat(value: String, label: String, unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.septenaHeroMetric())
          .foregroundStyle(accent)
        if let unit {
          Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  /// Live session clock — ticks every second via `TimelineView` so only
  /// this stat re-renders, not the whole list. Shows M:SS, or H:MM:SS once
  /// past an hour. Driven off the absolute `startedAt`, so it stays
  /// accurate across backgrounding.
  private func liveElapsedStat(startedAt iso: String) -> some View {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    let start = f.date(from: iso)
    return TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let secs = start.map { max(0, Int(ctx.date.timeIntervalSince($0))) } ?? 0
      VStack(alignment: .leading, spacing: 2) {
        Text(clock(secs))
          .font(.septenaHeroMetric())
          .foregroundStyle(accent)
        Text("elapsed").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func clock(_ totalSeconds: Int) -> String {
    let h = totalSeconds / 3600
    let m = (totalSeconds % 3600) / 60
    let s = totalSeconds % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }

  // MARK: - Actions

  private func start(_ type: SessionTypeConfig) {
    store.start(type: type, context: modelContext, today: clock.today)
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
      // Concluding the session must clear the Live Activity, not leave it
      // frozen on the Lock Screen / Dynamic Island. `.default` would linger
      // up to 4h; the in-app completion sheet already shows the final stats,
      // so dismiss immediately.
      TrainingLiveActivityCoordinator.shared.end(from: d, immediate: true)
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

// MARK: - Editor selection token

/// Identifies which exercise's editor drawer is open (tap-to-drill). Keyed by
/// the exercise name, which is unique within a session (the switch/add pickers
/// disable duplicates), so it stays stable across mid-session reorders.
struct EditingExercise: Identifiable, Equatable {
  let exercise: String
  var id: String { exercise }
}

// MARK: - Exercise row

/// One exercise as a tappable pill in the active session list. Shows the
/// status, name, a PR flag, and the planned (or logged) numbers so the whole
/// session is scannable without drilling in. Tapping opens the focused editor
/// drawer, which owns the per-exercise actions (switch / skip / move / remove /
/// note) in its ⋯ menu.
struct TrainingExerciseRow: View {
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock

  let index: Int
  let entry: DraftEntry
  let accent: Color
  /// Drill into this exercise's editor drawer.
  var onTap: () -> Void

  /// The same trailing-90-day progress series the editor drawer charts, shown
  /// here as a tiny trailing sparkline so the trend reads without drilling in.
  /// Loaded lazily on appear (one query per row) and only drawn at 2+ points.
  @State private var spark: TrainingProgressSeries? = nil

  // Presentation state for the long-press menu's sheet-backed actions, hosted by
  // `.trainingExerciseActionSheets` below (shared with the editor drawer).
  @State private var showSwitch = false
  @State private var showNote = false
  @State private var noteDraft = ""
  @State private var showRemoveConfirm = false

  var body: some View {
    header
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .fill(Theme.cardSurface)
      )
      .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
      .opacity(opacityFor(entry.status))
      .contentShape(Rectangle())
      .tileHover()
      .onTapGesture { onTap() }
      // Long-press (right-click on Mac) surfaces the same per-exercise actions as
      // the drawer's ⋯ menu, without drilling in first. Same builder, so the two
      // menus can't drift.
      .contextMenu {
        trainingExerciseMenuButtons(
          index: index, entry: entry, store: store,
          showNote: $showNote, noteDraft: $noteDraft,
          showSwitch: $showSwitch, showRemoveConfirm: $showRemoveConfirm,
          onDismiss: {}, removeNow: removeThisEntry)
      }
      .trainingExerciseActionSheets(
        exercise: entry.exercise, index: index, accent: accent,
        showNote: $showNote, noteDraft: $noteDraft,
        showSwitch: $showSwitch, showRemoveConfirm: $showRemoveConfirm,
        onSwitched: { _ in }, removeNow: removeThisEntry)
      .task(id: entry.exercise) { loadSpark() }
  }

  private func removeThisEntry() {
    store.removeEntry(at: index, mutator: SeptenaServices.shared.trainingMutator)
    Haptics.tick()
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      statusIcon
        .foregroundStyle(statusTint)
        .scaledFont(size: 18, weight: .regular)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(displayName(entry.exercise))
            .font(.septenaCardTitle)
            .foregroundStyle(Theme.inkPrimary)
          if isPR { prPill }
        }
        // The planned (or logged) numbers, so the whole session is scannable
        // at a glance without drilling into each exercise.
        if let summary = plannedSummary {
          Text(summary)
            .font(.caption)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      Spacer(minLength: 8)
      // A glance at this exercise's recent trajectory — the same 90-day series
      // the editor drawer charts, stripped to a bare trend line.
      if let s = spark, s.points.count >= 2 {
        // Same footprint and treatment as the dashboard tile sparkline (84×28).
        TrainingProgressChart(series: s, accent: accent, height: 28,
                              weightFactor: WeightUnit.current.displayFactor,
                              sparkline: true)
          .frame(width: 84)
          .opacity(entry.status == .skipped ? 0.4 : 0.9)
          .accessibilityHidden(true)
      }
      // Drill-in affordance — per-exercise actions (switch / skip / note / …)
      // now live in the drawer's ⋯ menu once you open it.
      Image(systemName: "chevron.right")
        .scaledFont(size: 12, weight: .semibold)
        .foregroundStyle(Theme.inkSecondary)
    }
  }

  /// Which progression number to sparkline, from the entry's shape — matches
  /// the editor drawer's `progressMetric` so the row and drawer agree.
  private var progressMetric: TrainingProgressMetric {
    if entry.isMobility { return .duration }
    if entry.isCardio   { return .pace }
    return .oneRepMax
  }

  private func loadSpark() {
    spark = TrainingMetrics.progressSeries(
      for: entry.exercise, metric: progressMetric, in: modelContext, today: clock.today)
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

  private var baseline: PRBaseline? {
    store.draft?.prBaselines[exerciseKey(entry.exercise)]
  }

  private var isPR: Bool {
    guard let baseline else { return false }
    return TrainingPRCalculator.isPR(draft: entry, baseline: baseline)
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

  /// One-line plan/result summary — adapts to the entry's shape (strength
  /// weight·sets×reps, cardio min·dist·level, mobility minutes).
  private var plannedSummary: String? {
    var parts: [String] = []
    if entry.isMobility {
      if let d = entry.durationMin, d > 0 { parts.append("\(Int(d)) min") }
    } else if entry.isCardio {
      if let d = entry.durationMin, d > 0 { parts.append("\(Int(d)) min") }
      if let m = entry.distanceM, m > 0 {
        parts.append(DistanceUnit.current.format(meters: m))
      }
      if let l = entry.level, l > 0 { parts.append("L\(fmt(l))") }
    } else {
      if let w = entry.weight, w > 0 { parts.append("\(fmt(WeightUnit.current.display(w))) \(WeightUnit.current.suffix)") }
      if let s = entry.sets, let r = entry.reps { parts.append("\(s)×\(r)") }
      else if let s = entry.sets { parts.append("\(s) sets") }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func displayName(_ slug: String) -> String {
    CanonicalExerciseName.display(slug, catalog: store.exerciseNameByKey)
  }

  private func fmt(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : d.decimalString()
  }
}

// MARK: - Shared per-exercise menu + action sheets

/// The per-exercise action set — add/edit note, switch, skip / unskip / move to
/// end, remove — emitted as bare `Button`s so the SAME menu can sit inside both
/// the drawer's ⋯ toolbar `Menu` and the row's long-press (right-click on Mac)
/// `.contextMenu`. One builder, so the two surfaces can't drift. The actions
/// that need a sheet/dialog (note, switch, remove-when-logged) are hosted by
/// `.trainingExerciseActionSheets(...)`, which this drives through bindings.
/// `onDismiss` closes an open drawer after a reordering action (a no-op for the
/// row, which has none).
@MainActor @ViewBuilder
func trainingExerciseMenuButtons(
  index: Int?,
  entry: DraftEntry?,
  store: TrainingDraftStore,
  showNote: Binding<Bool>,
  noteDraft: Binding<String>,
  showSwitch: Binding<Bool>,
  showRemoveConfirm: Binding<Bool>,
  onDismiss: @escaping () -> Void,
  removeNow: @escaping () -> Void
) -> some View {
  Button {
    noteDraft.wrappedValue = entry?.note ?? ""
    showNote.wrappedValue = true
  } label: {
    Label((entry?.note.isEmpty == false) ? "Edit note" : "Add note",
          systemImage: "note.text")
  }
  Button { showSwitch.wrappedValue = true } label: {
    Label("Switch exercise", systemImage: "arrow.triangle.2.circlepath")
  }
  if let st = entry?.status {
    if st == .skipped {
      Button { if let index { store.unskip(index: index); Haptics.tick() } } label: {
        Label("Unskip", systemImage: "arrow.uturn.left")
      }
    } else if st != .done && st != .saving {
      Button {
        if let index { store.markSkipped(index: index) }
        onDismiss(); Haptics.tick()
      } label: {
        Label("Skip", systemImage: "forward.end")
      }
    }
    let isLast: Bool = {
      guard let entries = store.draft?.entries, let index else { return true }
      return index == entries.count - 1
    }()
    if st != .done && st != .saving && !isLast {
      Button {
        if let index { store.moveToEnd(at: index) }
        onDismiss(); Haptics.tick()
      } label: {
        Label("Move to end", systemImage: "arrow.down.to.line")
      }
    }
    if st != .saving {
      Divider()
      Button(role: .destructive) {
        if st == .done { showRemoveConfirm.wrappedValue = true } else { removeNow() }
      } label: {
        Label("Remove", systemImage: "trash")
      }
    }
  }
}

/// Hosts the sheets/dialog the per-exercise menu drives — the note editor, the
/// switch-exercise picker, and the remove-when-logged confirmation — so the
/// drawer and the row present them identically. Attach once per surface; the
/// menu buttons flip the bindings. `onSwitched` re-points an open drawer at the
/// swapped-in exercise (no-op for the row).
private struct TrainingExerciseActionSheets: ViewModifier {
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.modelContext) private var modelContext

  let exercise: String
  let index: Int?
  let accent: Color
  @Binding var showNote: Bool
  @Binding var noteDraft: String
  @Binding var showSwitch: Bool
  @Binding var showRemoveConfirm: Bool
  var onSwitched: (String) -> Void
  var removeNow: () -> Void

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $showSwitch) {
        ExercisePickerSheet(
          selectionMode: .single,
          disabledNames: otherSessionNames,
          alternativesTo: exercise,
          onPick: { def in
            guard let index else { return }
            store.switchExercise(at: index, to: def.name, context: modelContext)
            onSwitched(def.name)
            Haptics.tick()
          }
        )
      }
      .sheet(isPresented: $showNote) { noteEditor }
      .confirmationDialog(
        "Remove \(displayName)?",
        isPresented: $showRemoveConfirm,
        titleVisibility: .visible
      ) {
        Button("Remove and delete log", role: .destructive) { removeNow() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This exercise is already logged. Removing it deletes the saved entry.")
      }
  }

  private var displayName: String {
    CanonicalExerciseName.display(exercise, catalog: store.exerciseNameByKey)
  }

  private var otherSessionNames: Set<String> {
    guard let entries = store.draft?.entries else { return [] }
    return Set(entries.enumerated()
      .filter { $0.offset != index }
      .map { $0.element.exercise })
  }

  private var noteEditor: some View {
    NavigationStack {
      Form {
        TextField("Note", text: $noteDraft, axis: .vertical)
          .lineLimit(3...8)
      }
      .formStyle(.grouped)
      .navigationTitle("Note")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showNote = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            if let index { store.update { $0.entries[index].note = noteDraft } }
            showNote = false
          }
          .tint(accent)
        }
      }
    }
    #if os(iOS)
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    #else
    .frame(width: 440, height: 300)
    #endif
  }
}

extension View {
  /// Attaches the per-exercise note / switch / remove-confirm presentations that
  /// `trainingExerciseMenuButtons` drives. See `TrainingExerciseActionSheets`.
  func trainingExerciseActionSheets(
    exercise: String,
    index: Int?,
    accent: Color,
    showNote: Binding<Bool>,
    noteDraft: Binding<String>,
    showSwitch: Binding<Bool>,
    showRemoveConfirm: Binding<Bool>,
    onSwitched: @escaping (String) -> Void,
    removeNow: @escaping () -> Void
  ) -> some View {
    modifier(TrainingExerciseActionSheets(
      exercise: exercise, index: index, accent: accent,
      showNote: showNote, noteDraft: noteDraft,
      showSwitch: showSwitch, showRemoveConfirm: showRemoveConfirm,
      onSwitched: onSwitched, removeNow: removeNow))
  }
}

// MARK: - Exercise editor (drawer)

/// Focused editor for a single exercise, presented as a drawer (sheet on
/// iPhone, docked inspector on iPad/Mac via `.adaptiveDetail`) when its row is
/// tapped. The slot index + entry are resolved live from the exercise name, so
/// the editor survives mid-session reorders and slot removals. "Done" logs the
/// set and auto-advances to the next still-pending exercise; closing keeps the
/// draft edits without logging.
struct TrainingExerciseEditor: View {
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @AppStorage(TrainingDraftStore.autoAdvanceKey) private var autoAdvanceNext = TrainingDraftStore.defaultAutoAdvance

  let exercise: String
  let accent: Color
  @Binding var selection: EditingExercise?

  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }

  /// Catalog picker to swap this slot's exercise.
  @State private var showSwitch = false
  /// Confirm before removing an already-logged entry (deletes the saved record).
  @State private var showRemoveConfirm = false
  /// Note editor sheet + its working text (note lives behind the ⋯ menu, not
  /// always-on, since most sets don't carry one).
  @State private var showNote = false
  @State private var noteDraft = ""

  private var index: Int? { store.draft?.entries.firstIndex { $0.exercise == exercise } }
  private var entry: DraftEntry? { index.flatMap { store.draft?.entries[$0] } }

  var body: some View {
    AdaptiveEditScaffold(
      title: displayName(exercise),
      cancelTitle: "Close",
      showsSave: false,
      accent: accent,
      onSave: {},
      trailing: AnyView(contextMenu)
    ) {
      Group {
        if let index, let entry {
          TrainingExerciseEditorBody(
            index: index,
            entry: entry,
            accent: accent,
            onLogged: handleLogged
          )
          // Keyed by exercise so the per-exercise @State (avg pace, progress
          // chart) resets when we auto-advance to the next slot, but persists
          // across the field edits of the current one.
          .id(exercise)
        } else {
          // The slot was removed out from under us (e.g. via another surface).
          Color.clear
        }
      }
    }
    // Grabber on the iPhone sheet so it reads as swipe-to-dismiss; ignored by
    // the iPad/Mac docked inspector.
    .presentationDragIndicator(.visible)
    // The note / switch / remove-confirm presentations are shared with the row's
    // long-press menu (see `trainingExerciseActionSheets`), so they can't drift.
    .trainingExerciseActionSheets(
      exercise: exercise, index: index, accent: accent,
      showNote: $showNote, noteDraft: $noteDraft,
      showSwitch: $showSwitch, showRemoveConfirm: $showRemoveConfirm,
      onSwitched: { selection = EditingExercise(exercise: $0) },
      removeNow: removeThisEntry)
  }

  // MARK: Contextual ⋯ menu

  /// Per-exercise actions, top-right of the drawer: add/edit note, switch the
  /// exercise, skip / move / remove. (Mirrors what used to live on the row,
  /// now that the row is a plain drill-in summary.)
  @ViewBuilder
  private var contextMenu: some View {
    Menu {
      trainingExerciseMenuButtons(
        index: index, entry: entry, store: store,
        showNote: $showNote, noteDraft: $noteDraft,
        showSwitch: $showSwitch, showRemoveConfirm: $showRemoveConfirm,
        onDismiss: { selection = nil }, removeNow: removeThisEntry)
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel("Exercise options")
    }
    .tint(accent)
  }

  private func removeThisEntry() {
    if let index { store.removeEntry(at: index, mutator: trainingMutator) }
    selection = nil
    Haptics.tick()
  }

  /// After logging: a fresh completion advances to the next still-pending
  /// exercise when auto-advance is on; re-saving an already-logged one just
  /// closes the drawer either way.
  private func handleLogged(wasDone: Bool) {
    if wasDone || !autoAdvanceNext {
      selection = nil
      return
    }
    if let nextIdx = store.draft?.nextPendingIndex,
       let next = store.draft?.entries[nextIdx] {
      selection = EditingExercise(exercise: next.exercise)
    } else {
      selection = nil
    }
  }

  private func displayName(_ slug: String) -> String {
    CanonicalExerciseName.display(slug, catalog: store.exerciseNameByKey)
  }
}

/// The inputs + progress chart + Done action for one exercise. Split from the
/// row so the list stays lightweight and the editor only materializes inside
/// the drawer. Receives a concrete slot index + entry snapshot (refreshed each
/// render as the draft mutates); keyed by exercise upstream so its `@State`
/// resets per slot.
struct TrainingExerciseEditorBody: View {
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }
  @Environment(TrainingDraftStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  @AppStorage(EffortScale.storageKey) private var effortScaleRaw = EffortScale.difficulty.rawValue
  /// Which strength history line the chart draws: false = estimated 1RM
  /// (weight×reps), true = top weight actually lifted. Tapping the chart flips
  /// it; remembered app-wide like the effort scale. No effect on cardio/mobility.
  @AppStorage("training.strength.chartTopWeight") private var strengthTopWeight = false
  @AppStorage(TrainingProgression.enabledKey)
  private var progressionHintsOn = TrainingProgression.defaultEnabled

  let index: Int
  let entry: DraftEntry
  let accent: Color
  /// Called after a successful log — `wasDone` is true when re-saving an
  /// already-logged entry (the editor should close) vs. a first completion
  /// (advance to the next pending exercise).
  var onLogged: (Bool) -> Void

  /// Mean pace (m/min) from this exercise's history — seeds the cardio
  /// duration→distance auto-preset. Computed on appear for cardio entries.
  @State private var avgPace: Double? = nil
  /// Trailing-90-day progress series for this exercise — drives the small
  /// history chart. Loaded once on appear.
  @State private var progress: TrainingProgressSeries? = nil
  /// Primary (first) + secondary muscles this exercise works, resolved from its
  /// catalog definition. Loaded on appear; empty for cardio / untagged slugs.
  @State private var muscles: [Muscle] = []

  /// Drives the keyboard "Done" bar — the numeric steppers use `.decimalPad`,
  /// which has no return key to dismiss it.
  @FocusState private var fieldFocused: Bool

  // Hoisted formatter — was re-allocated per recents-row render.
  private static let monthDayPosixFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  var body: some View {
    ScrollView {
      // Each block sits in its own bordered panel so the drawer reads as
      // structured sections rather than free-floating controls on a flat
      // background — and the panels are spaced apart, not stacked tight.
      VStack(alignment: .leading, spacing: 18) {
        // Which muscles this exercise hits — orientation tags above the graph.
        musclePills
        if hasHistory {
          panel { progressHistory }
        }
        panel {
          VStack(alignment: .leading, spacing: 20) {
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
          }
        }
        // Primary action — solid accent, centered, ~two-thirds width. Logs this
        // set; contextual actions live in the drawer's ⋯ menu. Spacers center
        // the 66%-wide button within the full content width.
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          Button {
            let wasDone = (entry.status == .done)
            store.markDone(index: index, mutator: trainingMutator)
            // Confirm only on first completion, not re-saves of an already-done
            // entry. Success haptic — a set is a step, not a moment; the
            // session-complete sheet owns the celebration.
            if !wasDone {
              Haptics.success()
            }
            // A first completion advances to the next pending exercise; a
            // re-save closes. Retrying a failed save leaves the editor open.
            if entry.status != .failed {
              onLogged(wasDone)
            }
          } label: {
            Text(entry.status == .failed ? "Retry"
                 : entry.status == .done ? "Update" : "Save")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderedProminent)
          .tint(AdaptiveColor.fillForWhiteInk(accent))
          .disabled(entry.status == .saving)
          .containerRelativeFrame(.horizontal) { length, _ in length * 0.66 }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
      }
      .padding(20)
    }
    // Grouped-grey canvas so the panels above read as raised cards (the editor
    // is hosted on a plain sheet / inspector whose default surface is white).
    .scrollContentBackground(.hidden)
    .background(Theme.groupedBackground)
    // Floating "Done" above the keyboard — the decimal pad has no return key.
    .keyboardDoneBar($fieldFocused)
    .onAppear {
      if entry.isCardio, avgPace == nil {
        avgPace = store.cardioAvgPace(for: entry.exercise, context: modelContext)
      }
      loadProgress()
      loadMuscles()
    }
  }

  // MARK: - Muscles

  private func loadMuscles() {
    let key = exerciseKey(entry.exercise)
    let defs = (try? modelContext.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    guard let def = defs.first(where: {
      exerciseKey($0.id) == key || exerciseKey($0.name) == key
    }) else { muscles = []; return }
    var out: [Muscle] = []
    if let p = Muscle.resolve(def.primaryMuscle) { out.append(p) }
    for s in def.secondaryMuscles {
      if let m = Muscle.resolve(s), !out.contains(m) { out.append(m) }
    }
    muscles = out
  }

  /// Muscle tags — the first (primary) gets an accent fill; the rest are white
  /// pills with a hairline, so the primary reads as the headline target. Wraps
  /// onto extra rows for exercises that hit several groups.
  @ViewBuilder
  private var musclePills: some View {
    if !muscles.isEmpty {
      FlowLayout(spacing: 8) {
        ForEach(Array(muscles.enumerated()), id: \.offset) { i, m in
          Text(m.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
              Capsule().fill(i == 0 ? accent.opacity(0.18) : Theme.cardSurface)
            )
            .overlay(
              Capsule().stroke(i == 0 ? Color.clear : Color.primary.opacity(0.12),
                               lineWidth: 1)
            )
            .foregroundStyle(i == 0 ? accent : Theme.inkSecondary)
        }
      }
    }
  }


  // MARK: - Progression hints

  private var recents: [RecentExerciseEntry] {
    store.draft?.recentByExercise[exerciseKey(entry.exercise)] ?? []
  }

  /// Which progression number this card charts, from the entry's shape.
  private var progressMetric: TrainingProgressMetric {
    if entry.isMobility { return .duration }
    if entry.isCardio   { return .pace }
    return strengthTopWeight ? .topWeight : .oneRepMax
  }

  /// True when the chart can flip metrics — strength only; cardio/mobility have
  /// a single meaningful axis, so a tap there is a no-op.
  private var canToggleMetric: Bool {
    !entry.isCardio && !entry.isMobility
  }

  /// The value of the set being entered right now, under the chart's metric —
  /// plotted as a distinct "today" marker so you can see where the current set
  /// lands against your trend. Nil until enough fields are filled; updates live
  /// as you type. Falls back to nil (no marker) rather than 0.
  private var todayValue: Double? {
    TrainingMetrics.progressValue(
      metric: progressMetric, weight: entry.weight, reps: entry.reps,
      distanceM: entry.distanceM, durationMin: entry.durationMin)
  }

  /// The number shown in the history header: today's in-progress set if one is
  /// entered, otherwise the most recent logged value.
  private var headerValue: Double? { todayValue ?? progress?.latest }

  private func loadProgress() {
    progress = TrainingMetrics.progressSeries(
      for: entry.exercise, metric: progressMetric, in: modelContext, today: clock.today)
  }

  typealias ProgressionHint = TrainingProgression.Hint

  /// Today's target off the frozen "last time" values (`lastByExercise` /
  /// `recentByExercise`, captured at session start so they can't shift
  /// mid-set). The rule itself lives in `TrainingProgression` so it stays a
  /// pure function of that snapshot. Strength only; nil when there's no
  /// comparable weighted history, or when the user turned hints off.
  private var progressionHint: ProgressionHint? {
    guard progressionHintsOn,
          !entry.isCardio, !entry.isMobility,
          let last = store.draft?.lastByExercise[exerciseKey(entry.exercise)],
          let w = last.weight,
          let repsStr = last.reps, let reps = Int(repsStr)
    else { return nil }
    return TrainingProgression.hint(exercise: entry.exercise,
                                    lastWeightKg: w,
                                    lastReps: reps,
                                    lastDifficulty: last.difficulty,
                                    recents: recents)
  }

  /// The suggested target as a compact "62.5 kg × 5" string in the user's unit.
  private func hintTargetText(_ h: ProgressionHint) -> String {
    let u = WeightUnit.current
    let dw = u.display(h.weightKg)
    let wStr = dw.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(dw))" : dw.decimalString(1)
    return "\(wStr) \(u.suffix) × \(h.reps)"
  }

  /// True when the current entry already matches the suggestion — then the
  /// nudge is informational and the Apply button is redundant.
  private func hintAlreadyApplied(_ h: ProgressionHint) -> Bool {
    let wMatches = (entry.weight.map { abs($0 - h.weightKg) < 0.01 }) ?? false
    return wMatches && (entry.reps ?? "") == h.reps
  }

  /// The proactive "coach" nudge above the weight field: what to aim for, why,
  /// and a one-tap Apply. Non-destructive — never auto-fills an aspirational
  /// load into a log the user might Save unchanged; the bump is a deliberate tap.
  @ViewBuilder
  private func progressionHintRow(_ h: ProgressionHint) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.up.forward")
        .font(.footnote.weight(.bold))
        .foregroundStyle(accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("Aim \(hintTargetText(h))")
          .font(.subheadline.weight(.semibold).monospacedDigit())
        Text(h.reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if !hintAlreadyApplied(h) {
        Button("Apply") {
          setWeight(fmt(WeightUnit.current.display(h.weightKg)))
          setReps(h.reps)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(accent)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(accent.opacity(0.10))
    )
  }

  /// True when there's anything to draw in the history panel — a 2+ point
  /// chart or at least one recent session. Gates the panel so we never render
  /// an empty bordered card.
  private var hasHistory: Bool {
    (progress?.points.count ?? 0) >= 2 || !recents.isEmpty
  }

  /// A bordered section card. Gives the drawer's blocks structure on the flat
  /// drawer background — a faint fill plus a hairline border, padded inside.
  @ViewBuilder
  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      // Raised card surface on the editor's grouped-grey canvas — the same
      // contrast the active-session logger and every section drawer use, instead
      // of a near-invisible 4%-over-white fill that read white-on-white.
      .background(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .fill(Theme.cardSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      )
  }

  /// 90-day progress chart for this exercise — the shared
  /// `TrainingProgressChart`, drawing the daily best value, PR rings, and a
  /// cardio average-speed rule. Falls back to the compact RECENT table when
  /// there's only one session to plot.
  @ViewBuilder
  private var progressHistory: some View {
    if let s = progress, s.points.count >= 2 {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
              Text(TrainingProgressFormat.title(progressMetric))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              // Affordance: strength charts flip between est. 1RM and top weight.
              if canToggleMetric {
                Image(systemName: "arrow.left.arrow.right")
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(.tertiary)
              }
            }
            // The visible number — today's set if it's being entered, else the
            // latest logged value. Makes the metric's *reading* legible even
            // when fixed reps leave the two lines the same shape.
            if let v = headerValue {
              HStack(spacing: 5) {
                Text(TrainingProgressFormat.value(v, metric: progressMetric))
                  .font(.title3.weight(.semibold).monospacedDigit())
                  .foregroundStyle(Theme.inkPrimary)
                if todayValue != nil {
                  Text("now")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                }
              }
            }
          }
          Spacer()
          if let t = TrainingProgressFormat.trend(s) {
            Text(t.text)
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(t.steady ? Color.secondary
                                        : (t.up ? accent : Theme.inkSecondary))
          }
        }
        TrainingProgressChart(series: s, accent: accent, height: 108, weeklyGrid: true,
                              weightFactor: WeightUnit.current.displayFactor,
                              todayValue: todayValue,
                              todayDate: SeptenaDate.parse(clock.today))
      }
      // Tap anywhere on the header+chart to flip the strength metric. Whole
      // block is the target (charts are hard to hit), no-op for cardio/mobility
      // — hover is gated the same way so a non-toggleable chart never signals
      // an affordance it doesn't have.
      .contentShape(Rectangle())
      .tileHover(enabled: canToggleMetric)
      .onTapGesture {
        guard canToggleMetric else { return }
        strengthTopWeight.toggle()
        loadProgress()
      }
    } else {
      recentSessionsTable
    }
  }

  /// Compact table of the user's most recent sessions for this exercise.
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
          ForEach(Array(recents.enumerated()), id: \.offset) { _, r in
            recentRow(date: r.date,
                      columns: adaptiveColumns(r),
                      difficulty: r.difficulty)
          }
        }
        .font(.septenaMeta)
      }
    }
  }

  /// Build the per-row metric columns from whichever fields are populated.
  private func adaptiveColumns(_ r: RecentExerciseEntry) -> [String] {
    var parts: [String] = []
    if let w = r.weight, w > 0 {
      let u = WeightUnit.current
      let dw = u.display(w)
      parts.append(dw.truncatingRemainder(dividingBy: 1) == 0
                   ? "\(Int(dw))\(u.suffix)" : "\(dw.decimalString(1))\(u.suffix)")
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
      parts.append(DistanceUnit.current.format(meters: m))
    }
    if let l = r.level, l > 0 {
      parts.append("L\(fmt(l))")
    }
    return parts
  }

  private func recentRow(date: String, columns: [String], difficulty: String?) -> some View {
    let summary = columns.isEmpty ? "—" : columns.joined(separator: " · ")
    return HStack(spacing: 12) {
      Text(shortDate(date))
        .foregroundStyle(Theme.inkSecondary)
        .frame(width: 64, alignment: .leading)
      Text(summary)
        .foregroundStyle(Theme.inkPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      DifficultyGlyph(difficulty: difficulty, accent: accent)
        .frame(width: 22, alignment: .leading)
    }
  }

  // "2026-05-23" → "May 23". Compact month abbreviation; the year is implicit.
  private func shortDate(_ iso: String) -> String {
    guard let d = SeptenaDate.parse(iso) else { return iso }
    return Self.monthDayPosixFormatter.string(from: d)
  }

  // MARK: - Strength fields

  private var strengthInputs: some View {
    VStack(spacing: 18) {
      if let hint = progressionHint {
        progressionHintRow(hint)
      }
      // Field shows / steps in the user's unit; `setWeight` converts back to
      // the kg the model stores. Step by the equipment's natural cadence
      // (barbell 2.5/5, machine 5/10, …), inferred from the exercise name.
      steppedField(label: "Weight (\(WeightUnit.current.suffix))",
                   step: WeightCadence.resolve(forExercise: entry.exercise).step(WeightUnit.current),
                   value: Binding(
                     get: { entry.weight.map { fmt(WeightUnit.current.display($0)) } ?? "" },
                     set: { setWeight($0) }
                   ))
      HStack(spacing: 8) {
        steppedField(label: "Sets", step: 1, buttonWidth: 40,
                     value: Binding(
                       get: { entry.sets.map(String.init) ?? "" },
                       set: { setSets(Int($0)) }
                     ))
        steppedField(label: "Reps", step: 1, buttonWidth: 40,
                     value: Binding(
                       get: { entry.reps ?? "" },
                       set: { setReps($0) }
                     ))
      }
    }
  }

  private var difficultyPicker: some View {
    let scale = EffortScale(rawValue: effortScaleRaw) ?? .difficulty
    // Title reflects the chosen effort scale (Settings ▸ RIR vs Difficulty);
    // in RIR mode it also replaces the per-pill "RIR" repetition.
    return VStack(alignment: .leading, spacing: 6) {
      Text((scale == .rir ? "RIR" : "Difficulty").uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
      ForEach(TrainingEffort.levels) { rung in
        let isSelected = TrainingEffort.canonicalKey(entry.difficulty) == rung.key
        // Grid-packed segments, so `.roundedRect` rather than a capsule — but
        // the same canonical chip fill/ink. This used to fill solid accent with
        // WHITE text, which is invisible in dark mode wherever no section hue
        // is in scope (the app accent is adaptive ink). See SelectionLanguage.
        SelectableChip(isSelected: isSelected,
                       tint: accent,
                       shape: .roundedRect,
                       fillsWidth: true) {
          store.update { $0.entries[index].difficulty = rung.key }
        } label: {
          VStack(spacing: 2) {
            Text(TrainingEffort.pillNumber(for: rung, scale: scale))
              .font(.septenaHeroMetric())
            if scale != .rir {
              Text(rung.short.uppercased())
                .font(.septenaBadge)
                .tracking(0.5)
            }
          }
        }
        .accessibilityLabel(rung.label)
      }
      }
    }
  }

  private func displayName(_ slug: String) -> String {
    CanonicalExerciseName.display(slug, catalog: store.exerciseNameByKey)
  }

  // MARK: - Mobility fields

  private var mobilityInputs: some View {
    steppedField(label: "Minutes", step: 1,
                 value: Binding(
                   get: { entry.durationMin.map { fmt($0) } ?? "" },
                   set: { setDuration($0) }
                 ))
  }

  // MARK: - Cardio fields

  private var cardioInputs: some View {
    VStack(spacing: 18) {
      steppedField(label: "Minutes", step: 5,
                   value: Binding(
                     get: { entry.durationMin.map { fmt($0) } ?? "" },
                     set: { newVal in
                       setDuration(newVal)
                       presetDistanceFromDuration(newVal)
                     }
                   ))
      HStack(spacing: 8) {
        steppedField(label: DistanceUnit.current == .mi ? "Miles" : "Meters",
                     step: DistanceUnit.current == .mi ? 0.1 : 50, buttonWidth: 40,
                     value: Binding(
                       get: { entry.distanceM.map { fmt(DistanceUnit.current.inputFromMeters($0)) } ?? "" },
                       set: { setDistance($0) }
                     ))
        steppedField(label: "Level", step: 1, buttonWidth: 40,
                     value: Binding(
                       get: { entry.level.map { fmt($0) } ?? "" },
                       set: { setLevel($0) }
                     ))
      }
    }
  }

  /// Preset distance from the just-entered duration using the exercise's
  /// historical average pace (m/min). Rounds to the nearest 10 m. No-op when
  /// there's no pace history.
  private func presetDistanceFromDuration(_ durationStr: String) {
    guard let pace = avgPace,
          let mins = Double(durationStr.replacingOccurrences(of: ",", with: ".")),
          mins > 0 else { return }
    let meters = ((pace * mins) / 10).rounded() * 10
    setDistance(String(Int(meters)))
  }

  // MARK: - Field helpers

  /// Numeric input with big −/＋ targets flanking the value, so weight / sets /
  /// reps can be bumped without summoning the keyboard mid-set.
  private func steppedField(label: String,
                            unit: String? = nil,
                            step: Double,
                            buttonWidth: CGFloat = 60,
                            value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        stepButton("minus", width: buttonWidth) { bump(value, by: -step) }
        HStack(spacing: 2) {
          TextField("", text: value)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .focused($fieldFocused)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .font(.septenaHeroMetric(.title3))
          if let unit {
            Text(unit).font(.caption2).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        // White (elevated) field against the gray panel it sits in.
        .background(Theme.cardSurface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        stepButton("plus", width: buttonWidth) { bump(value, by: step) }
      }
    }
  }

  private func stepButton(_ systemName: String, width: CGFloat = 60, action: @escaping () -> Void) -> some View {
    Button {
      action()
      Haptics.tick()
    } label: {
      Image(systemName: systemName)
        .scaledFont(size: 13, weight: .bold)
        .frame(width: width, height: 40)
        .background(accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(accent)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Parse → clamp at zero → re-write the bound string. Non-numeric values
  /// (e.g. "AMRAP") are left untouched so the steppers can't clobber them.
  private func bump(_ value: Binding<String>, by delta: Double) {
    let raw = value.wrappedValue
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: ",", with: ".")
    if !raw.isEmpty, Double(raw) == nil { return }
    let next = max(0, (Double(raw) ?? 0) + delta)
    value.wrappedValue = next.truncatingRemainder(dividingBy: 1) == 0
      ? String(Int(next))
      : next.decimalString()
  }

  private func fmt(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0
      ? String(Int(d)) : d.decimalString()
  }

  private func setWeight(_ s: String) {
    // Field is in the user's unit; store kg.
    let parsed = Double(s.replacingOccurrences(of: ",", with: "."))
    store.update { $0.entries[index].weight = parsed.map { WeightUnit.current.toKilograms($0) } }
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
    // Field is in m or mi; store meters.
    let v = Double(s.replacingOccurrences(of: ",", with: "."))
    store.update { $0.entries[index].distanceM = v.map { DistanceUnit.current.metersFromInput($0) } }
  }
  private func setLevel(_ s: String) {
    store.update { $0.entries[index].level = Double(s.replacingOccurrences(of: ",", with: ".")) }
  }
}

// MARK: - Shared progress chart

/// One exercise's trailing-90-day progress line, shared by the in-session
/// card (compact, `height: 72`) and the per-exercise stats detail (taller).
/// Plots the daily best value, enlarges the dots on days that set a new
/// running record (PR), and — for cardio — overlays a dashed average-speed
/// rule. Cardio values render as km/h (m/min × 0.06) so the axis matches what
/// a treadmill/bike shows; strength plots kg, mobility plots minutes.
struct TrainingProgressChart: View {
  let series: TrainingProgressSeries
  let accent: Color
  var height: CGFloat = 72
  /// Draw a faint vertical gridline every 7 days (used by the in-session
  /// editor's taller mini-graph so the trend reads against weekly cadence).
  var weeklyGrid: Bool = false
  /// Multiplier applied to strength (oneRepMax, stored in kg) values so the
  /// line plots in the user's chosen weight unit. 1 = kg; pass
  /// `WeightUnit.current.displayFactor`. Non-weight metrics ignore it.
  var weightFactor: Double = 1
  /// Strip the chart down to a bare trend line — no axes, dots, or rules — for
  /// the in-session exercise rows, where it sits as a tiny trailing glance.
  var sparkline: Bool = false
  /// The in-progress set's value (pre-scale, same units as `series`), plotted as
  /// a distinct ringed "today" marker so the current set reads against the
  /// trend. Ignored in sparkline mode; needs `todayDate` to place on the x-axis.
  var todayValue: Double? = nil
  var todayDate: Date? = nil

  private var scale: Double {
    switch series.metric {
    case .pace:                 return DistanceUnit.current.speed(1)   // m/min → km/h or mi/h
    case .oneRepMax, .topWeight: return weightFactor
    case .duration:             return 1.0
    }
  }

  /// Y range padded a little beyond the data's own min/max — so the line uses
  /// the full height and the trend reads, instead of being squashed against a
  /// zero baseline. Falls back to a small band when the values are flat.
  private var yDomain: ClosedRange<Double> {
    var vals = series.points.map { $0.value * scale }
    // Fold today's provisional value in so its marker never clips off-axis.
    if !sparkline, let tv = todayValue { vals.append(tv * scale) }
    guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
    if lo == hi {
      let pad = max(abs(lo) * 0.1, 1)
      return (lo - pad)...(hi + pad)
    }
    let pad = (hi - lo) * 0.15
    return (lo - pad)...(hi + pad)
  }

  var body: some View {
    Chart {
      // Shaded area under the line — matches the dashboard tile sparkline
      // (`DomainSparkline`, accent at 22%). Floors at the visible band's bottom
      // so the autoscaled trend fills the plot rather than hugging zero.
      if sparkline {
        ForEach(series.points, id: \.date) { p in
          AreaMark(x: .value("Date", p.date),
                   yStart: .value("Floor", yDomain.lowerBound),
                   yEnd: .value("Value", p.value * scale))
            .interpolationMethod(.monotone)
            .foregroundStyle(accent.opacity(0.22))
        }
      }
      ForEach(series.points, id: \.date) { p in
        LineMark(x: .value("Date", p.date), y: .value("Value", p.value * scale))
          .interpolationMethod(.monotone)
          .lineStyle(StrokeStyle(lineWidth: sparkline ? 1.5 : 2,
                                 lineCap: .round, lineJoin: .round))
          .foregroundStyle(accent)
      }
      if !sparkline {
        ForEach(series.points, id: \.date) { p in
          PointMark(x: .value("Date", p.date), y: .value("Value", p.value * scale))
            .foregroundStyle(accent)
            .symbolSize(14)
        }
      }
      if series.metric == .pace, let avg = series.average, !sparkline {
        RuleMark(y: .value("Average", avg * scale))
          .foregroundStyle(accent.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .annotation(position: .top, alignment: .trailing) {
            Text("avg \(TrainingProgressFormat.pace(avg))")
              .font(.caption2).foregroundStyle(.secondary)
          }
      }
      // "You are here" — the set being entered now, a ringed dot with a TODAY
      // tag, plotted at today's x so it stands apart from the logged history.
      if !sparkline, let tv = todayValue, let td = todayDate {
        PointMark(x: .value("Date", td), y: .value("Value", tv * scale))
          .symbol {
            Circle()
              .fill(accent)
              .frame(width: 9, height: 9)
              .overlay(Circle().stroke(Theme.paperBackground, lineWidth: 2))
          }
          .annotation(position: .top, spacing: 2) {
            Text("TODAY")
              .font(.system(size: 8, weight: .heavy))
              .foregroundStyle(accent)
          }
      }
    }
    .chartYScale(domain: yDomain)
    .chartPlotStyle { plot in
      // A sparkline is just the line — no plot border, axes, or grid chrome.
      sparkline ? AnyView(plot.padding(.vertical, 2)) : AnyView(plot)
    }
    .chartYAxis {
      if !sparkline {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
          AxisValueLabel {
            if let d = v.as(Double.self) {
              Text(d.truncatingRemainder(dividingBy: 1) == 0
                   ? String(Int(d)) : d.decimalString()).font(.caption2)
            }
          }
          AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
        }
      }
    }
    .chartXAxis {
      if !sparkline {
        // Weekly vertical gridlines (no labels) for cadence.
        if weeklyGrid {
          AxisMarks(values: .stride(by: .day, count: 7)) { _ in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
          }
        }
        AxisMarks(values: .automatic(desiredCount: 3)) { v in
          AxisValueLabel {
            if let d = v.as(Date.self) {
              Text(d, format: .dateTime.month(.abbreviated).day()).font(.caption2)
            }
          }
        }
      }
    }
    .frame(height: height)
  }
}

/// Display formatting for the training progress chart — kept in one place so
/// the card header and the stats-detail card label it identically.
enum TrainingProgressFormat {
  /// "EST. 1RM · 90 DAYS" / "SPEED · 90 DAYS" / "DURATION · 90 DAYS".
  static func title(_ m: TrainingProgressMetric) -> String {
    switch m {
    case .oneRepMax: return "EST. 1RM · 90 DAYS"
    case .topWeight: return "TOP WEIGHT · 90 DAYS"
    case .pace:      return "SPEED · 90 DAYS"
    case .duration:  return "DURATION · 90 DAYS"
    }
  }

  /// A single metric value as a readable, unit-suffixed string — the header
  /// readout ("126 kg", "12.4 km/h", "20 min"). Weight metrics convert kg into
  /// the user's chosen unit; pace/duration pass through.
  static func value(_ v: Double, metric: TrainingProgressMetric) -> String {
    switch metric {
    case .oneRepMax, .topWeight:
      let u = WeightUnit.current
      let d = v * u.displayFactor
      return "\(d.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(d))" : d.decimalString(1)) \(u.suffix)"
    case .pace:     return pace(v)
    case .duration: return "\(Int(v.rounded())) min"
    }
  }

  /// m/min → "12.4 km/h" / "7.7 mi/h" (matches what cardio machines show).
  static func pace(_ mPerMin: Double) -> String {
    let u = DistanceUnit.current
    return "\(u.speed(mPerMin).decimalString(1)) \(u.speedSuffix)"
  }

  /// Trend over the window: first point → last point. `steady` when the
  /// change rounds away to nothing. Used both as the card's title-row delta
  /// and the stats-detail card subtitle.
  static func trend(_ s: TrainingProgressSeries)
    -> (text: String, up: Bool, steady: Bool)? {
    guard s.points.count >= 2,
          let first = s.points.first?.value,
          let last = s.points.last?.value else { return nil }
    let delta = last - first
    let up = delta >= 0
    let mag: String
    switch s.metric {
    case .oneRepMax, .topWeight:
      let u = WeightUnit.current
      let d = abs(delta) * u.displayFactor
      mag = "\(d.decimalString(d < 10 ? 1 : 0)) \(u.suffix)"
    case .pace:
      let u = DistanceUnit.current
      mag = "\(u.speed(abs(delta)).decimalString(1)) \(u.speedSuffix)"
    case .duration:  mag = "\(Int(abs(delta).rounded())) min"
    }
    // "+0 kg" reads as noise; collapse a rounding-zero delta to "steady".
    let isZero = mag.hasPrefix("0 ") || mag.hasPrefix("0.0 ")
    if isZero { return ("steady", true, true) }
    return ("\(up ? "▲" : "▼") \(mag)", up, false)
  }
}
