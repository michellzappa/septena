import SwiftUI
import Charts

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
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(DayClock.self) private var clock

  @State private var entries: [NutritionEntry] = []
  @State private var stats: NutritionStatsResponse? = nil
  @State private var macros: MacrosConfig? = nil
  @State private var macroColors: MacroColors? = nil
  @State private var loading = true
  @State private var editing: NutritionEntry? = nil

  /// Live "now" for the fasting row + relative time labels. Sourced from
  /// the shared DayClock (single 60s tick app-wide) instead of a per-view
  /// Timer.publish — same value the DayTimeline cursor reads.
  private var now: Date { clock.now }

  // MARK: - Colors
  //
  // Resolved from `settings.nutrition.macro_colors` (mirrors the webapp's
  // `useMacroColors`). Per-key fallbacks match the webapp defaults in
  // `lib/macro-targets.ts:FALLBACK_MACRO_COLORS` so partial server patches
  // never leave a macro uncolored, and first paint isn't monochrome while
  // settings are loading.

  private static let proteinFallback = Color(hex: 0xef4444)
  private static let fatFallback     = Color(hex: 0xf59e0b)
  private static let carbsFallback   = Color(hex: 0x3b82f6)
  private static let fiberFallback   = Color(hex: 0x10b981)
  private static let kcalFallback    = Color(hex: 0xeab308)
  private static let fastingFallback = Color(hex: 0x8b5cf6)

  private var proteinColor: Color { resolve(macroColors?.protein, fallback: Self.proteinFallback) }
  private var fatColor: Color     { resolve(macroColors?.fat,     fallback: Self.fatFallback) }
  private var carbsColor: Color   { resolve(macroColors?.carbs,   fallback: Self.carbsFallback) }
  private var fiberColor: Color   { resolve(macroColors?.fiber,   fallback: Self.fiberFallback) }
  private var kcalColor: Color    { resolve(macroColors?.kcal,    fallback: Self.kcalFallback) }
  private var fastingColor: Color { resolve(macroColors?.fasting, fallback: Self.fastingFallback) }

  private func resolve(_ hex: String?, fallback: Color) -> Color {
    Color(hexString: hex) ?? fallback
  }

  private var today: String { SeptenaDate.today }

  // MARK: - Derived

  private var todayEntries: [NutritionEntry] {
    entries.filter { $0.date == today }.sorted { $0.time > $1.time }
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
    ScrollView {
      LazyVStack(spacing: 12) {
        statsGrid
        chartsGrid
        entriesList
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .background(Theme.groupedBackground)
    .navigationTitle("Nutrition")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(kcalColor)
    .task {
      paintFromCache()
      await load()
    }
    // Day rollover: reload so the fasting row, today's totals, and the
    // "earlier days" grouping all reflect the new day's data.
    .onChange(of: clock.today) { _, _ in
      Task { await load() }
    }
    .sheet(item: $editing) { entry in
      EditNutritionEntrySheet(
        original: entry,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  // MARK: - Edit / delete

  private func applyLocalUpdate(_ updated: NutritionEntry) {
    guard let idx = entries.firstIndex(where: { $0.file == updated.file }) else { return }
    entries[idx] = updated
    ResponseCache.save(entries, forKey: CacheKey.entries)
  }

  /// Re-log an existing meal at the current moment. POSTs a new entry with
  /// the same macros/foods/emoji but `date`+`time` stamped to now. The
  /// server allocates a fresh file id; we kick a refresh so the new row
  /// appears once the outbox drains.
  private func logAgainNow(_ entry: NutritionEntry) {
    let now = Date()
    let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
    var body: [String: Any] = [
      "date": dateFmt.string(from: now),
      "time": timeFmt.string(from: now),
      "foods": entry.foods,
      "protein_g": entry.proteinG,
      "fat_g": entry.fatG,
      "carbs_g": entry.carbsG,
      "fiber_g": entry.fiberG ?? 0,
      "kcal": entry.kcal,
    ]
    if let emoji = entry.emoji, !emoji.isEmpty { body["emoji"] = emoji }
    if let ing = entry.ingredients, !ing.isEmpty { body["ingredients"] = ing }
    outbox.enqueue(
      method: "POST",
      path: "/api/nutrition/entries",
      body: body,
      kind: "nutrition.add"
    )
    Haptics.success()
    Task { await load() }
  }

  private func delete(_ entry: NutritionEntry) {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/nutrition/entries",
      body: ["file": entry.file],
      kind: "nutrition.delete"
    )
    entries.removeAll { $0.file == entry.file }
    ResponseCache.save(entries, forKey: CacheKey.entries)
    Haptics.warning()
  }

  // MARK: - Stat tiles

  private var statsGrid: some View {
    let t = todayTotals
    let m = macros
    return LazyVGrid(columns: tileColumns, spacing: 8) {
      statTile(label: "Protein", value: t.protein, unit: "g",
               target: m?.protein, color: proteinColor)
      statTile(label: "Fat", value: t.fat, unit: "g",
               target: m?.fat, color: fatColor)
      statTile(label: "Carbs", value: t.carbs, unit: "g",
               target: m?.carbs, color: carbsColor)
      statTile(label: "Fiber", value: t.fiber, unit: "g",
               target: m?.fiber ?? MacroRange(min: 25, max: 35, unit: "g"),
               color: fiberColor)
      statTile(label: "Kcal", value: t.kcal, unit: "",
               target: m?.kcal, color: kcalColor)
      fastingTile
    }
  }

  private var tileColumns: [GridItem] {
    [GridItem(.flexible(), spacing: 8),
     GridItem(.flexible(), spacing: 8),
     GridItem(.flexible(), spacing: 8)]
  }

  private func statTile(label: String, value: Double, unit: String,
                        target: MacroRange?, color: Color) -> some View {
    let displayed = value > 0 ? Int(value.rounded()) : nil
    let progress = target.map { progressTowardRange(value, min: $0.min, max: $0.max) } ?? 0
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(displayed.map { "\($0)" } ?? "—")
          .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
          .foregroundStyle(displayed != nil ? color : Color.secondary)
        if !unit.isEmpty {
          Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
      }
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      progressBar(value: progress, color: color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14))
  }

  private var fastingTile: some View {
    let target = macros?.fasting ?? MacroRange(min: 14, max: 16, unit: "h")
    let liveHours = liveFastingHours()
    let recordedHours = (stats?.fasting ?? []).first(where: { $0.date == today })?.hours
    let displayHours = liveHours ?? recordedHours
    let mid = (target.min + target.max) / 2
    let progress = displayHours.map { min(1.0, $0 / mid) } ?? 0
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(displayHours.map { String(format: "%.1f", $0) } ?? "—")
          .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
          .foregroundStyle(displayHours != nil ? fastingColor : Color.secondary)
        Text("h").font(.caption2).foregroundStyle(.secondary)
      }
      Text("FASTING")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      progressBar(value: progress, color: fastingColor)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14))
  }

  private func progressBar(value: Double, color: Color) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.18))
        Capsule().fill(color).frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
      }
    }
    .frame(height: 4)
  }

  // MARK: - Charts grid

  private var chartsGrid: some View {
    LazyVGrid(columns: tileColumns, spacing: 8) {
      if let m = macros {
        macroChart(label: "Protein", unit: "g", color: proteinColor,
                   target: m.protein,
                   series: dailySeries { $0.proteinG },
                   todayValue: todayTotals.protein)
        macroChart(label: "Fat", unit: "g", color: fatColor,
                   target: m.fat,
                   series: dailySeries { $0.fatG },
                   todayValue: todayTotals.fat)
        macroChart(label: "Carbs", unit: "g", color: carbsColor,
                   target: m.carbs,
                   series: dailySeries { $0.carbsG },
                   todayValue: todayTotals.carbs)
        macroChart(label: "Fiber", unit: "g", color: fiberColor,
                   target: m.fiber ?? MacroRange(min: 25, max: 35, unit: "g"),
                   series: dailySeries { $0.fiberG ?? 0 },
                   todayValue: todayTotals.fiber)
        macroChart(label: "Kcal", unit: "", color: kcalColor,
                   target: m.kcal,
                   series: dailySeries { $0.kcal },
                   todayValue: todayTotals.kcal)
        fastingChart
      } else {
        ForEach(0..<6, id: \.self) { _ in placeholderChart }
      }
    }
  }

  private var placeholderChart: some View {
    RoundedRectangle(cornerRadius: 14)
      .fill(Theme.secondaryGroupedBackground)
      .frame(height: 180)
  }

  private struct DailyPoint: Hashable { let date: String; let value: Double }

  private func dailySeries(_ pick: (NutritionDailyPoint) -> Double) -> [DailyPoint] {
    (stats?.daily ?? []).suffix(7).map { DailyPoint(date: $0.date, value: pick($0)) }
  }

  private func macroChart(label: String, unit: String, color: Color,
                          target: MacroRange,
                          series: [DailyPoint],
                          todayValue: Double) -> some View {
    let yMax = ceil(target.max * 1.2)
    let avg: Double = {
      let past = series.filter { $0.date != today }
      guard !past.isEmpty else { return 0 }
      return (past.map(\.value).reduce(0, +) / Double(past.count)).rounded()
    }()
    let consumed = Int(todayValue.rounded())
    let left = max(0, Int(target.max.rounded()) - consumed)
    let over = max(0, consumed - Int(target.max.rounded()))
    let caption = over > 0
      ? "\(consumed)\(unit) · \(over)\(unit) over"
      : "\(consumed)\(unit) · \(left)\(unit) left"

    return VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.subheadline.weight(.semibold))
      Text(caption)
        .font(.caption.monospacedDigit())
        .foregroundStyle(color)
      Chart {
        RectangleMark(xStart: nil, xEnd: nil,
                      yStart: .value("Min", target.min),
                      yEnd: .value("Max", target.max))
          .foregroundStyle(color.opacity(0.12))
        RuleMark(y: .value("Min", target.min))
          .foregroundStyle(color.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        RuleMark(y: .value("Max", target.max))
          .foregroundStyle(color.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        if avg > 0 {
          RuleMark(y: .value("Avg", avg))
            .foregroundStyle(color.opacity(0.85))
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        ForEach(series, id: \.date) { p in
          BarMark(
            x: .value("Day", weekdayInitial(p.date)),
            y: .value(label, p.value),
            width: .ratio(0.6)
          )
          .foregroundStyle(p.value == 0
                           ? Color.secondary.opacity(0.2)
                           : color.opacity(p.value < target.min ? 0.55 : 1))
          .cornerRadius(2)
        }
      }
      .chartYScale(domain: 0...yMax)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
          AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))\(unit)").font(.caption2) } }
          AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic) { _ in
          AxisValueLabel().font(.caption2)
        }
      }
      .frame(height: 110)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14))
  }

  private var fastingChart: some View {
    let target = macros?.fasting ?? MacroRange(min: 14, max: 16, unit: "h")
    let yMax = ceil(target.max / 0.85)

    var data: [DailyPoint] = (stats?.fasting ?? []).suffix(7).map {
      DailyPoint(date: $0.date, value: $0.hours ?? 0)
    }
    // Inject the live creeping bar for today when actively fasting.
    if let live = liveFastingHours() {
      if let idx = data.firstIndex(where: { $0.date == today }) {
        data[idx] = DailyPoint(date: today, value: live)
      } else {
        data.append(DailyPoint(date: today, value: live))
      }
    }

    let past = data.filter { $0.date != today && $0.value > 0 }
    let avg = past.isEmpty ? 0 : (past.map(\.value).reduce(0, +) / Double(past.count))
    let mid = (target.min + target.max) / 2
    let deltaCaption: String? = avg > 0
      ? String(format: "%+.1fh vs target", avg - mid)
      : nil

    return VStack(alignment: .leading, spacing: 4) {
      Text("Fasting").font(.subheadline.weight(.semibold))
      Text(deltaCaption ?? " ")
        .font(.caption.monospacedDigit())
        .foregroundStyle(fastingColor)
      Chart {
        RectangleMark(xStart: nil, xEnd: nil,
                      yStart: .value("Min", target.min),
                      yEnd: .value("Max", target.max))
          .foregroundStyle(fastingColor.opacity(0.12))
        RuleMark(y: .value("Min", target.min))
          .foregroundStyle(fastingColor.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        RuleMark(y: .value("Max", target.max))
          .foregroundStyle(fastingColor.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        if avg > 0 {
          RuleMark(y: .value("Avg", avg))
            .foregroundStyle(fastingColor.opacity(0.85))
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        ForEach(data, id: \.date) { p in
          BarMark(
            x: .value("Day", weekdayInitial(p.date)),
            y: .value("Hours", p.value),
            width: .ratio(0.6)
          )
          .foregroundStyle(p.value <= 0
                           ? Color.secondary.opacity(0.2)
                           : fastingColor.opacity(p.value >= target.min ? 1 : 0.55))
          .cornerRadius(2)
        }
      }
      .chartYScale(domain: 0...yMax)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
          AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))h").font(.caption2) } }
          AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic) { _ in
          AxisValueLabel().font(.caption2)
        }
      }
      .frame(height: 110)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14))
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
    } else {
      VStack(alignment: .leading, spacing: 12) {
        VStack(spacing: 6) {
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
    }
  }

  private func dayGroup(date: String, items: [NutritionEntry]) -> some View {
    let totals = totalsByDate[date]
    let fast = fastingByDate[date]
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(friendlyDate(date))
          .font(.subheadline.weight(.semibold))
        Spacer()
        if let totals { Text("\(Int(totals.kcal.rounded())) kcal")
            .font(.caption.monospacedDigit())
            .foregroundStyle(kcalColor)
        }
      }
      .padding(.horizontal, 4)
      ForEach(items) { e in mealRow(e) }
      if let fast { fastingGapRow(fast) }
    }
  }

  private func mealRow(_ e: NutritionEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Circle().fill(kcalColor).frame(width: 6, height: 6).padding(.top, 7)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          if let emoji = e.emoji, !emoji.isEmpty {
            Text(emoji)
          }
          Text(e.foods.first ?? "—")
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          Spacer()
          Text(e.time)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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
    let target = macros?.fasting ?? MacroRange(min: 14, max: 16, unit: "h")
    let mealsToday = stats.todayMealCount ?? todayEntries.count
    guard mealsToday == 0 else { return nil }
    // Need yesterday's last meal to anchor the window.
    guard let last = stats.yesterdayLastMeal, let lastH = hoursFromHHMM(last) else { return nil }
    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute], from: now)
    let nowH = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
    let hours = (24 - lastH) + nowH
    // Sanity gate — show only after we're at least halfway to the min target.
    return hours >= target.min * 0.5 ? hours : nil
  }

  private func hoursFromHHMM(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    return Double(h) + Double(m) / 60
  }

  // MARK: - Range progress
  //
  // Mirrors `progressTowardRange` from lib/macro-targets.ts: 0 below min,
  // ramps to 1.0 at min, holds 1.0 inside band, drops gently above max.

  private func progressTowardRange(_ value: Double, min lo: Double, max hi: Double) -> Double {
    guard value > 0 else { return 0 }
    if value < lo { return value / lo * 0.95 }
    if value <= hi { return 1.0 }
    let over = (value - hi) / max(1, hi)
    return Swift.max(0.5, 1.0 - over * 0.5)
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

  // MARK: - Loading

  private enum CacheKey {
    static let entries = "nutrition.entries14"
    static let stats   = "nutrition.stats"
    static let macros  = "nutrition.macros"
    static let colors  = "nutrition.macroColors"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load([NutritionEntry].self, forKey: CacheKey.entries) { entries = v }
    if let v = ResponseCache.load(NutritionStatsResponse.self, forKey: CacheKey.stats) { stats = v }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.macros) { macros = v }
    if let v = ResponseCache.load(MacroColors.self, forKey: CacheKey.colors) { macroColors = v }
    loading = false
  }

  private func load() async {
    loading = true
    let since = sinceDate(daysBack: 14)
    async let e: [NutritionEntry]? = try? await client.nutritionEntries(since: since)
    async let s: NutritionStatsResponse? = try? await client.nutritionStats(days: 30)
    async let m: MacrosConfig? = try? await client.nutritionMacrosConfig()
    async let settings: AppSettings? = try? await client.settings()
    let (entriesRes, statsRes, macrosRes, settingsRes) = await (e, s, m, settings)
    if let entriesRes {
      entries = entriesRes
      ResponseCache.save(entriesRes, forKey: CacheKey.entries)
    }
    if let statsRes {
      stats = statsRes
      ResponseCache.save(statsRes, forKey: CacheKey.stats)
    }
    if let macrosRes {
      macros = macrosRes
      ResponseCache.save(macrosRes, forKey: CacheKey.macros)
    }
    if let colors = settingsRes?.nutrition?.macroColors {
      macroColors = colors
      ResponseCache.save(colors, forKey: CacheKey.colors)
    }
    loading = false
  }

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
