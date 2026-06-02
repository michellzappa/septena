import SwiftUI
import Charts
import PhotosUI
import Photos

// Nutrition mini-app — mirrors the webapp's NutritionDashboard.
//
// Layout (top → bottom):
//   1. Six dense stat tiles: Protein · Fat · Carbs · Fiber · Kcal · Fasting
//      Each shows value + unit + a tiny progress bar tinted with the macro's
//      accent. Progress is computed from the target range — under min reads
//      muted, in-range is full, over-max keeps tint at full (over isn't
//      "wrong", just over).
//   2. Six 7-day bar charts (one per stat) with target band, dashed
//      min/max lines, and the 7d-average line. Bars under the min are
//      drawn at 0.55 opacity.
//   3. Meal log grouped by day, newest day first. Each entry: emoji,
//      first food line, summary detail, a small stacked MiniMacroBar, and
//      the per-macro counts. Fasting gap row sits between days; a live
//      "currently fasting" row sits at the top of today when applicable.
//
// Macro colors come from `settings.nutrition.macro_colors` (same source
// as the webapp's `useMacroColors`), with per-key fallbacks matching
// lib/macro-targets.ts:FALLBACK_MACRO_COLORS so the two clients read as
// the same product.

struct NutritionDestinationView: View {
  @Environment(DayClock.self) private var clock
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext

  @State private var entries: [NutritionEntry] = []
  @State private var stats: NutritionStatsResponse? = nil
  @State private var macros: MacrosConfig? = nil
  @State private var tilePrefs: [MacroTilePref] = MacroCatalog.defaultTilePrefs()
  @State private var loading = true
  @State private var editing: NutritionEntry? = nil
  @State private var creating = false
  @State private var photoPickerEntry: NutritionEntry? = nil
  @State private var photoPickerItem: PhotosPickerItem? = nil
  @State private var photoPickerPresented = false
  /// Day the drawer's date strip is pointing at. Drives the entries list
  /// and the heatmap's selected cell. Defaults to today; heatmap taps
  /// and the prev/next/calendar controls update it. The macro tiles +
  /// 7-day charts stay anchored to *actual* today (live dashboard) —
  /// browsing back through history is for reviewing logged meals, not
  /// for retro-targeting macros.
  @State private var viewingDate: String = SeptenaDate.today

  /// Live "now" for the fasting row + relative time labels. Sourced from
  /// the shared DayClock (single 60s tick app-wide) instead of a per-view
  /// Timer.publish — same value the DayTimeline cursor reads.
  private var now: Date { clock.now }

  // MARK: - Colors
  //
  // Resolved from `NutritionSettings.macroTiles` (per-id override) with a
  // fallback to `MacroCatalog.byID[id].defaultColorHex`. The catalog defaults
  // mirror the webapp's `FALLBACK_MACRO_COLORS` so first paint isn't monochrome
  // and partial settings never leave a macro uncolored.

  private func color(for macroID: String) -> Color {
    let override = tilePrefs.first(where: { $0.id == macroID })?.colorHex
    let fallback = MacroCatalog.byID[macroID]?.defaultColorHex
    return Color(hexString: override ?? fallback) ?? .gray
  }

  private var proteinColor: Color { color(for: "protein") }
  private var fatColor: Color     { color(for: "fat") }
  private var carbsColor: Color   { color(for: "carbs") }
  private var fiberColor: Color   { color(for: "fiber") }
  private var kcalColor: Color    { color(for: "kcal") }
  private var fastingColor: Color { color(for: "fasting") }

  private var today: String { SeptenaDate.today }

  private var isViewingToday: Bool { viewingDate == today }

  private var accent: Color { theme.color(for: "nutrition") }

  // MARK: - Derived

  private var todayEntries: [NutritionEntry] {
    entries.filter { $0.date == today }.sorted { $0.time > $1.time }
  }

  /// Entries on the date the user is currently browsing via the date strip.
  /// Same shape as `todayEntries` but anchored to `viewingDate`.
  private var viewingEntries: [NutritionEntry] {
    entries.filter { $0.date == viewingDate }.sorted { $0.time > $1.time }
  }

  /// Counts per day across the loaded window. Feeds the heatmap so the
  /// user can see at a glance which days have logs and tap to jump.
  /// Struct (not tuple) because `ActivityHeatmapSection` requires
  /// `Hashable` Points.
  struct DayCount: Hashable { let date: String; let count: Int }

  private var entryCountsByDate: [DayCount] {
    Dictionary(grouping: entries, by: \.date)
      .map { DayCount(date: $0.key, count: $0.value.count) }
      .sorted { $0.date < $1.date }
  }

  private struct DayTotals { var protein = 0.0; var fat = 0.0; var carbs = 0.0; var fiber = 0.0; var kcal = 0.0 }

  private var todayTotals: DayTotals {
    todayEntries.reduce(into: DayTotals()) { t, e in
      t.protein += e.proteinG; t.fat += e.fatG; t.carbs += e.carbsG
      t.fiber += e.fiberG ?? 0; t.kcal += e.kcal
    }
  }

  private var totalsByDate: [String: DayTotals] {
    var out: [String: DayTotals] = [:]
    for e in entries {
      var t = out[e.date] ?? DayTotals()
      t.protein += e.proteinG; t.fat += e.fatG; t.carbs += e.carbsG
      t.fiber += e.fiberG ?? 0; t.kcal += e.kcal
      out[e.date] = t
    }
    return out
  }

  private var fastingByDate: [String: FastingWindow] {
    Dictionary(uniqueKeysWithValues: (stats?.fasting ?? []).map { ($0.date, $0) })
  }

  /// Days other than today, newest first, capped at one week.
  private var earlierDays: [(date: String, items: [NutritionEntry])] {
    let grouped = Dictionary(grouping: entries.filter { $0.date < today }, by: \.date)
    return grouped.keys.sorted(by: >).prefix(7).map { d in
      (d, (grouped[d] ?? []).sorted { $0.time > $1.time })
    }
  }

  private var maxMealKcal: Double {
    max(1, entries.map(\.kcal).max() ?? 1)
  }

  // MARK: - Body

  var body: some View {
    SectionDrawer(sectionKey: "nutrition",
                  title: "Nutrition",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      // Time-travel mode: when the date strip is on a past day we drop
      // the macro tiles + heatmap and show just the day's logs. The
      // macros tiles read "today" status (in range / over / left) so
      // they're meaningless retro; the heatmap is a "where do I want
      // to go" picker which the user already used to get here.
      if isViewingToday {
        macroTilesGrid
      }
      entriesList
      if isViewingToday {
        heatmapSection
      }
    }
    .trackScreen("nutrition")
    .task { reload() }
    // Day rollover: reload so the fasting row, today's totals, and the
    // "earlier days" grouping all reflect the new day's data.
    .onChange(of: clock.today) { _, newToday in
      // Roll the viewing pointer forward only if the user was already
      // looking at "today" — otherwise leave their selection alone.
      if isViewingToday { viewingDate = newToday }
      reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .adaptiveDetail(item: $editing) { entry in
      EditNutritionEntrySheet(original: entry, onDone: { })
    }
    .adaptiveDetail(isPresented: $creating) {
      EditNutritionEntrySheet(original: nil, onDone: { })
    }
    .photosPicker(
      isPresented: $photoPickerPresented,
      selection: $photoPickerItem,
      matching: .images,
      photoLibrary: .shared()
    )
    .onChange(of: photoPickerItem) { _, new in
      guard let new, let entry = photoPickerEntry else { return }
      photoPickerEntry = nil
      Task { await attachPhoto(new, to: entry) }
    }
  }

  // MARK: - Edit / delete

  private func reload() {
    let ctx = modelContext
    // 365-day window — the heatmap and date-strip browsing need the
    // historical archive (FastAPI backfill restored ~50 days; this
    // covers a full year so the user can scroll back across season
    // changes without per-day refetches).
    entries = ChecklistMirror.loadNutritionEntries(context: ctx, since: sinceDate(daysBack: 365))
    stats = ChecklistMirror.buildNutritionStatsResponse(context: ctx, days: 90)
    macros = NutritionPrefs.loadMacrosConfig()
    let settingsRes = SettingsMirror.loadSettings(context: ctx)
    tilePrefs = MacroCatalog.reconcile(
      settingsRes?.nutrition?.macroTiles
        ?? legacyPrefs(from: settingsRes?.nutrition?.macroColors)
        ?? MacroCatalog.defaultTilePrefs())
    loading = false
  }

  /// Bridges the legacy `MacroColors` shape (color-only, no order or
  /// visibility) into the new `MacroTilePref` array. Nil if no legacy colors
  /// were stored — callers then fall back to catalog defaults.
  private func legacyPrefs(from colors: MacroColors?) -> [MacroTilePref]? {
    guard let colors else { return nil }
    let map: [String: String?] = [
      "protein": colors.protein, "fat": colors.fat, "carbs": colors.carbs,
      "fiber": colors.fiber, "kcal": colors.kcal, "fasting": colors.fasting,
    ]
    return MacroCatalog.all.map { m in
      MacroTilePref(id: m.id, colorHex: map[m.id] ?? nil, visible: m.defaultVisible)
    }
  }

  /// Re-log an existing meal at the current moment.
  private func logAgainNow(_ entry: NutritionEntry) {
    SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: Date.now,
      emoji: entry.emoji,
      foods: entry.foods,
      proteinG: entry.proteinG,
      fatG: entry.fatG,
      carbsG: entry.carbsG,
      fiberG: entry.fiberG,
      sugarG: entry.sugarG,
      saturatedFatG: entry.saturatedFatG,
      alcoholG: entry.alcoholG,
      kcal: entry.kcal == 0 ? nil : entry.kcal,
      sodiumMg: entry.sodiumMg,
      cholesterolMg: entry.cholesterolMg,
      potassiumMg: entry.potassiumMg,
      waterMl: entry.waterMl
    )
    Haptics.success()
  }

  private func delete(_ entry: NutritionEntry) {
    SeptenaServices.shared.nutritionMutator.deleteEntry(id: entry.file)
    entries.removeAll { $0.file == entry.file }
    Haptics.warning()
  }

  private func attachPhoto(_ item: PhotosPickerItem, to entry: NutritionEntry) async {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
      _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
    guard let assetID = item.itemIdentifier else { return }
    await MainActor.run {
      SeptenaServices.shared.nutritionMutator.updateEntry(
        id: entry.file,
        photoAssetID: .some(assetID)
      )
      photoPickerItem = nil
      reload()
      Haptics.tick()
    }
  }

  // MARK: - Unified macro tiles
  //
  // Each enabled macro renders as a single tile that combines today's value,
  // a "what's left vs. target" status line, and a 7-day mini histogram with
  // target band. The specs array drives the grid — when macro tiles move to
  // user settings, this is the only thing that changes.

  private struct MacroTileSpec: Identifiable {
    let id: String
    let label: String
    let unit: String          // displayed next to the value: "g", "h", "kcal"
    let color: Color
    let target: MacroRange
    let todayValue: Double
    let series: [DailyPoint]  // exactly 7 days, oldest → newest
    let formatValue: (Double) -> String
  }

  private var macroTileSpecs: [MacroTileSpec] {
    tilePrefs.compactMap { pref in
      guard pref.visible, let macro = MacroCatalog.byID[pref.id] else { return nil }
      return makeSpec(for: macro)
    }
  }

  private func makeSpec(for macro: MacroCatalog.Macro) -> MacroTileSpec {
    let formatter: (Double) -> String = macro.id == "fasting"
      ? { $0 <= 0 ? "—" : String(format: "%.1f", $0) }
      : { $0 <= 0 ? "—" : String(Int($0.rounded())) }
    return .init(
      id: macro.id,
      label: macro.label,
      unit: macro.unit,
      color: color(for: macro.id),
      target: target(for: macro),
      todayValue: todayValue(for: macro),
      series: series(for: macro),
      formatValue: formatter)
  }

  /// Pulls a target range from `MacrosConfig` when available, otherwise uses
  /// the catalog's built-in default. Fasting + the 7 "new" macros (sat fat,
  /// sugar, alcohol, sodium, …) always go through the catalog defaults until
  /// `macros-config` learns about them.
  private func target(for macro: MacroCatalog.Macro) -> MacroRange {
    if let m = macros {
      switch macro.id {
      case "protein": return m.protein
      case "fat":     return m.fat
      case "carbs":   return m.carbs
      case "kcal":    return m.kcal
      case "fiber":   if let v = m.fiber   { return v }
      case "fasting": if let v = m.fasting { return v }
      default: break
      }
    }
    return MacroRange(min: macro.defaultMin, max: macro.defaultMax, unit: macro.unit)
  }

  private func todayValue(for macro: MacroCatalog.Macro) -> Double {
    switch macro.source {
    case .entrySum(let field):
      return todayEntries.reduce(0) { $0 + $1.value(for: field) }
    case .fasting:
      if let live = liveFastingHours() { return live }
      return (stats?.fasting ?? []).first(where: { $0.date == today })?.hours ?? 0
    }
  }

  private func series(for macro: MacroCatalog.Macro) -> [DailyPoint] {
    switch macro.source {
    case .entrySum(let field):
      // Group all loaded entries by date and sum the chosen field. Days with
      // no entries fall through as 0, matching the legacy chart behavior.
      var byDate: [String: Double] = [:]
      for e in entries {
        byDate[e.date, default: 0] += e.value(for: field)
      }
      return last7Dates.map { DailyPoint(date: $0, value: byDate[$0] ?? 0) }
    case .fasting:
      let fastByDate = Dictionary(uniqueKeysWithValues:
        (stats?.fasting ?? []).map { ($0.date, $0) })
      var data: [DailyPoint] = last7Dates.map {
        DailyPoint(date: $0, value: fastByDate[$0]?.hours ?? 0)
      }
      if let live = liveFastingHours(),
         let idx = data.firstIndex(where: { $0.date == today }) {
        data[idx] = DailyPoint(date: today, value: live)
      }
      return data
    }
  }

  private var macroTilesGrid: some View {
    LazyVGrid(columns: macroTileColumns, spacing: 8) {
      ForEach(macroTileSpecs) { spec in unifiedMacroTile(spec) }
    }
  }

  private var macroTileColumns: [GridItem] {
    [GridItem(.flexible(), spacing: 8),
     GridItem(.flexible(), spacing: 8)]
  }

  private struct DailyPoint: Hashable { let date: String; let value: Double }

  // MARK: - Unified tile view

  @ViewBuilder
  private func unifiedMacroTile(_ spec: MacroTileSpec) -> some View {
    let consumed = spec.todayValue
    let lo = spec.target.min
    let hi = spec.target.max
    let unit = spec.unit
    let color = spec.color

    let avg: Double = {
      let past = spec.series.filter { $0.date != today && $0.value > 0 }
      guard !past.isEmpty else { return 0 }
      return past.map(\.value).reduce(0, +) / Double(past.count)
    }()

    // yMax keeps the bar always inside the chart even if today blew past max.
    // Floor at 1 so an empty all-zero week still renders the target band.
    let dataMax = spec.series.map(\.value).max() ?? 0
    let yMax = ceil(Swift.max(hi * 1.2, Swift.max(consumed * 1.1, dataMax * 1.1, 1)))

    let summary = a11ySummary(spec: spec, consumed: consumed,
                              avg: avg, lo: lo, hi: hi)

    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(spec.label.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(spec.formatValue(consumed))
          .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
          .foregroundStyle(consumed > 0 ? color : Color.secondary)
        Text(unit).font(.caption2).foregroundStyle(.secondary)
      }
      tileStatusLine(consumed: consumed, lo: lo, hi: hi,
                     unit: unit, color: color, formatValue: spec.formatValue)
      Chart {
        RectangleMark(xStart: nil, xEnd: nil,
                      yStart: .value("Min", lo),
                      yEnd: .value("Max", hi))
          .foregroundStyle(color.opacity(0.12))
          .accessibilityHidden(true)
        RuleMark(y: .value("Min", lo))
          .foregroundStyle(color.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
          .accessibilityHidden(true)
        RuleMark(y: .value("Max", hi))
          .foregroundStyle(color.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
          .accessibilityHidden(true)
        if avg > 0 {
          RuleMark(y: .value("Avg", avg))
            .foregroundStyle(color.opacity(0.85))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .accessibilityHidden(true)
        }
        ForEach(spec.series, id: \.date) { p in
          BarMark(
            // Full ISO date as the category — see prior comment: collapsing
            // by weekday-letter would merge same-letter days (S/S, T/T).
            x: .value("Day", p.date),
            y: .value(spec.label, p.value),
            width: .ratio(0.6)
          )
          .foregroundStyle(barFill(value: p.value, isToday: p.date == today,
                                   lo: lo, color: color))
          .cornerRadius(2)
          .accessibilityLabel(weekdayFull(p.date))
          .accessibilityValue(p.value <= 0
                              ? "no data"
                              : "\(spec.formatValue(p.value)) \(unit)")
        }
      }
      .chartXScale(domain: spec.series.map(\.date))
      .chartYScale(domain: 0...yMax)
      .chartYAxis(.hidden)
      .chartXAxis {
        AxisMarks(values: spec.series.map(\.date)) { v in
          AxisValueLabel {
            if let iso = v.as(String.self) {
              Text(verbatim: weekdayInitial(iso))
                .scaledFont(size: 9)
                .foregroundStyle(iso == today ? color : .secondary)
            }
          }
        }
      }
      .frame(height: 72)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14))
    .a11yCombineKeepingChildren(summary)
  }

  /// Today's status line — "12 g left to target", "in range", "8 g over", …
  /// Color encodes urgency: muted below min, full at and above min, full above max.
  private func tileStatusLine(consumed: Double, lo: Double, hi: Double,
                              unit: String, color: Color,
                              formatValue: (Double) -> String) -> some View {
    let text: String
    let tone: Color
    if consumed <= 0 {
      text = "no data today"
      tone = .secondary
    } else if consumed < lo {
      text = "\(formatValue(lo - consumed)) \(unit) to target"
      tone = color.opacity(0.7)
    } else if consumed <= hi {
      let room = hi - consumed
      text = room > 0
        ? "in range · \(formatValue(room)) \(unit) left"
        : "in range"
      tone = color
    } else {
      text = "\(formatValue(consumed - hi)) \(unit) over"
      tone = color
    }
    return Text(text)
      .font(.caption.monospacedDigit())
      .foregroundStyle(tone)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
  }

  private func barFill(value: Double, isToday: Bool, lo: Double, color: Color) -> Color {
    if value <= 0 { return isToday ? color.opacity(0.18) : Color.secondary.opacity(0.2) }
    return color.opacity(value < lo ? 0.55 : 1)
  }

  private func a11ySummary(spec: MacroTileSpec, consumed: Double, avg: Double,
                           lo: Double, hi: Double) -> String {
    let unit = spec.unit
    let status: String
    if consumed <= 0 {
      status = "no data today"
    } else if consumed < lo {
      status = "\(spec.formatValue(lo - consumed)) \(unit) to target"
    } else if consumed <= hi {
      status = "in target"
    } else {
      status = "\(spec.formatValue(consumed - hi)) \(unit) over target"
    }
    let avgText = avg > 0
      ? "Seven-day average \(spec.formatValue(avg)) \(unit)."
      : ""
    return "\(spec.label). Today \(spec.formatValue(consumed)) \(unit), \(status). "
         + "Target \(spec.formatValue(lo)) to \(spec.formatValue(hi)) \(unit). \(avgText)"
  }

  /// The seven ISO dates ending today (oldest → newest). Used to render an
  /// exact 7-bar window — `stats.daily` omits days with no entries, so a
  /// naive `.suffix(7)` would silently render fewer (or stale) bars.
  private var last7Dates: [String] {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let cal = Calendar.current
    return (0..<7).reversed().compactMap { off in
      cal.date(byAdding: .day, value: -off, to: Date()).map(fmt.string(from:))
    }
  }

  // MARK: - Entries list

  @ViewBuilder
  private var entriesList: some View {
    if loading && entries.isEmpty {
      ProgressView().frame(maxWidth: .infinity).padding()
    } else if entries.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "fork.knife").font(.title2).foregroundStyle(.secondary)
        Text("No entries yet").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity).padding(.vertical, 24)
    } else if isViewingToday {
      // Today view — the default: today's entries + a tail of recent days
      // for at-a-glance context. Date strip / heatmap let the user dive
      // deeper.
      VStack(alignment: .leading, spacing: 12) {
        VStack(spacing: 6) {
          dayHeader(date: today, totals: todayTotals)
          fastingNowRow()
          ForEach(todayEntries) { e in mealRow(e) }
          if let f = fastingByDate[today], todayEntries.isEmpty == false {
            fastingGapRow(f)
          }
          if todayEntries.isEmpty {
            Text("No entries logged today")
              .font(.caption).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.leading, 8)
          }
        }
        ForEach(earlierDays, id: \.date) { day in
          dayGroup(date: day.date, items: day.items)
        }
      }
    } else {
      // History view — focused on `viewingDate`. Shows just that day's
      // entries so the macros + fasting status read cleanly without the
      // surrounding noise of "earlier days". The date strip handles
      // prev/next; the heatmap below handles random-access jumps.
      VStack(alignment: .leading, spacing: 6) {
        dayHeader(date: viewingDate, totals: totalsByDate[viewingDate])
        if viewingEntries.isEmpty {
          Text("No entries logged on this day")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.vertical, 12)
        } else {
          ForEach(viewingEntries) { e in mealRow(e) }
          if let f = fastingByDate[viewingDate] { fastingGapRow(f) }
        }
      }
    }
  }

  /// Year-scale heatmap of logged-meal density. Tap any cell to jump
  /// the date strip to that day. Empty cells are tappable too so the
  /// user can intentionally pick a day they suspect they forgot to log
  /// (and then add a backdated entry from the + menu).
  @ViewBuilder
  private var heatmapSection: some View {
    if !entryCountsByDate.isEmpty {
      ActivityHeatmapSection(
        title: "Logged days",
        accent: accent,
        daily: entryCountsByDate,
        date: { $0.date },
        value: { Double($0.count) },
        levelFor: { v in
          let n = Int(v)
          if n <= 0 { return 0 }
          if n == 1 { return 1 }
          if n == 2 { return 2 }
          if n <= 4 { return 3 }
          return 4
        },
        labelFor: { v in
          let n = Int(v)
          return "\(n) \(n == 1 ? "meal" : "meals")"
        },
        subtitleFor: { active, total, sum in
          "\(active) of \(total) days · \(Int(sum)) meals"
        },
        onTapDay: { iso in viewingDate = iso }
      )
    }
  }

  private func dayGroup(date: String, items: [NutritionEntry]) -> some View {
    let fast = fastingByDate[date]
    return VStack(alignment: .leading, spacing: 6) {
      dayHeader(date: date, totals: totalsByDate[date])
      ForEach(items) { e in mealRow(e) }
      if let fast { fastingGapRow(fast) }
    }
  }

  @ViewBuilder
  private func dayHeader(date: String, totals: DayTotals?) -> some View {
    HStack {
      Text(friendlyDate(date))
        .font(.subheadline.weight(.semibold))
      Spacer()
      if let totals {
        Text("\(Int(totals.kcal.rounded())) kcal")
          .font(.caption.monospacedDigit())
          .foregroundStyle(kcalColor)
      }
    }
    .padding(.horizontal, 4)
  }

  private func mealRow(_ e: NutritionEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          if let emoji = e.emoji, !emoji.isEmpty {
            Text(emoji)
          }
          Text(e.foods.first ?? "—")
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        if e.foods.count > 1 {
          Text(e.foods.dropFirst().joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let ing = e.ingredients, !ing.isEmpty {
          Text(ing.joined(separator: " · "))
            .font(.caption2).foregroundStyle(.secondary.opacity(0.8))
            .lineLimit(1)
        }
        HStack(spacing: 6) {
          MiniMacroBar(
            protein: e.proteinG, fat: e.fatG, carbs: e.carbsG,
            fiber: e.fiberG ?? 0, kcal: e.kcal, maxKcal: maxMealKcal,
            colors: (proteinColor, fatColor, carbsColor, fiberColor)
          )
          Group {
            Text("\(Int(e.proteinG.rounded()))P").foregroundStyle(proteinColor)
            Text("·").foregroundStyle(.secondary.opacity(0.5))
            Text("\(Int(e.fatG.rounded()))F").foregroundStyle(fatColor)
            Text("·").foregroundStyle(.secondary.opacity(0.5))
            Text("\(Int(e.carbsG.rounded()))C").foregroundStyle(carbsColor)
            Text("·").foregroundStyle(.secondary.opacity(0.5))
            Text("\(Int((e.fiberG ?? 0).rounded()))Fb").foregroundStyle(fiberColor)
            Text("·").foregroundStyle(.secondary.opacity(0.5))
            Text("\(Int(e.kcal.rounded()))kcal").foregroundStyle(kcalColor)
          }
          .font(.caption.monospacedDigit().weight(.semibold))
        }
      }
      VStack(alignment: .trailing, spacing: 4) {
        Text(e.time)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if let pid = e.photoAssetID, !pid.isEmpty {
          MealPhotoThumbnail(assetID: pid, size: 36)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 10))
    // Not inside a SwiftUI `List` — so `.swipeActions` doesn't apply.
    // The native equivalents on free-form rows are: tap → present sheet,
    // long-press / right-click → `.contextMenu`. Both are documented
    // SwiftUI affordances.
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .onTapGesture { editing = e }
    .contextMenu {
      Button { editing = e } label: { Label("Edit", systemImage: "pencil") }
      Button { photoPickerEntry = e; photoPickerPresented = true } label: {
        Label(e.photoAssetID != nil ? "Change photo" : "Attach photo",
              systemImage: "photo.badge.plus")
      }
      Button { logAgainNow(e) } label: {
        Label("Log again now", systemImage: "arrow.clockwise")
      }
      Button(role: .destructive) { delete(e) } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  @ViewBuilder
  private func fastingNowRow() -> some View {
    if let live = liveFastingHours(), let since = stats?.yesterdayLastMeal ?? stats?.todayLatestMeal {
      let target = macros?.fasting ?? MacroRange(min: 14, max: 16, unit: "h")
      let hours = Int(live)
      let mins = Int((live - Double(hours)) * 60)
      let label = mins == 0 ? "\(hours)h fasting" : "\(hours)h \(mins)m fasting"
      HStack(alignment: .top, spacing: 10) {
        Circle().fill(fastingColor).frame(width: 6, height: 6).padding(.top, 7)
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text("⏳ \(label)")
              .font(.subheadline.weight(.semibold).monospacedDigit())
              .foregroundStyle(fastingColor)
            Spacer()
          }
          Text("Since \(since) · target \(Int(target.min))–\(Int(target.max))h")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private func fastingGapRow(_ f: FastingWindow) -> some View {
    Group {
      if let h = f.hours {
        let totalMin = Int((h * 60).rounded())
        let hh = totalMin / 60
        let mm = totalMin % 60
        let label = mm == 0 ? "\(hh)h fasted" : "\(hh)h \(mm)m fasted"
        HStack(spacing: 10) {
          Circle().fill(fastingColor).frame(width: 6, height: 6)
          Text(label)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(fastingColor)
          Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
      } else if f.note == "gap" {
        HStack(spacing: 10) {
          Circle().fill(fastingColor.opacity(0.4)).frame(width: 6, height: 6)
          Text("Incomplete logs")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
      }
    }
  }

  // MARK: - Live fasting

  /// Approximates the webapp's `computeFastingState` — if today has no
  /// meals yet and yesterday had a late one, the user is fasting since
  /// then. Otherwise nil.
  private func liveFastingHours() -> Double? {
    _ = now  // tie to timer
    guard let stats else { return nil }
    let mealsToday = stats.todayMealCount ?? todayEntries.count
    guard mealsToday == 0 else { return nil }
    // Need yesterday's last meal to anchor the window.
    guard let last = stats.yesterdayLastMeal, let lastH = hoursFromHHMM(last) else { return nil }
    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute], from: now)
    let nowH = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
    let hours = (24 - lastH) + nowH
    return hours >= 2 ? hours : nil
  }

  private func hoursFromHHMM(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    return Double(h) + Double(m) / 60
  }

  // MARK: - Format helpers

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
      let w = DateFormatter(); w.dateFormat = "EEEE"
      return w.string(from: d)
    }
    let p = DateFormatter(); p.dateFormat = "MMM d"
    return p.string(from: d)
  }

  private func weekdayInitial(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return "" }
    let w = DateFormatter(); w.dateFormat = "EEEEE"  // narrow weekday
    return w.string(from: d)
  }

  /// Full weekday name for VoiceOver. The visual axis uses narrow initials
  /// ("M") which read as a single letter and lose meaning — screen readers
  /// hear the per-bar label, which uses the full form ("Monday").
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

  // MARK: - Loading

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }
}

// MARK: - Mini macro bar
//
// Compact stacked bar — proportional widths of protein/fat/carbs calories
// plus a fixed-width fiber tip on the right. Total width scales with the
// entry's kcal vs the day's biggest meal so the eye reads "big meal" at a
// glance.

private struct MiniMacroBar: View {
  let protein: Double
  let fat: Double
  let carbs: Double
  let fiber: Double
  let kcal: Double
  let maxKcal: Double
  let colors: (Color, Color, Color, Color)  // P · F · C · Fb

  var body: some View {
    let pCal = protein * 4
    let fCal = fat * 9
    let cCal = carbs * 4
    let fbCal = fiber * 2
    let total = kcal > 0 ? kcal : (pCal + fCal + cCal + fbCal)
    let width: CGFloat = total > 0
      ? max(8, CGFloat(total / maxKcal) * 64)
      : 4
    if total <= 0 {
      Capsule().fill(Color.secondary.opacity(0.25))
        .frame(width: 4, height: 8)
    } else {
      let pw = CGFloat(pCal / total)
      let fw = CGFloat(fCal / total)
      let cw = CGFloat(cCal / total)
      let fbPx: CGFloat = fiber > 0 ? max(2, CGFloat(fbCal / total) * width) : 0
      let macroW = width - fbPx
      HStack(spacing: 0) {
        Rectangle().fill(colors.0).frame(width: macroW * pw, height: 8)
        Rectangle().fill(colors.1).frame(width: macroW * fw, height: 8)
        Rectangle().fill(colors.2).frame(width: macroW * cw, height: 8)
        if fbPx > 0 {
          Rectangle().fill(colors.3).frame(width: fbPx, height: 8)
        }
      }
      .clipShape(Capsule())
    }
  }
}

// MARK: - Color hex helper

extension Color {
  init(hex: UInt32) {
    self.init(
      red:   Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8)  & 0xff) / 255,
      blue:  Double( hex        & 0xff) / 255
    )
  }

  /// Parses "#rrggbb" or "rrggbb". Returns nil on bad input so callers can
  /// fall through to a typed default rather than silently rendering black.
  init?(hexString: String?) {
    guard let s = hexString else { return nil }
    let trimmed = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard trimmed.count == 6, let v = UInt32(trimmed, radix: 16) else { return nil }
    self.init(hex: v)
  }
}
