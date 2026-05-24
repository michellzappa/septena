import SwiftUI
import SwiftData
import Charts

// Insights — full-page, dense, multi-section correlation explorer.
//
// Mirrors the septena-app /insights surface (curated + auto-derived
// pairs, supplement-vs-sleep table, copy-report markdown export). All
// math runs in CorrelationEngine, sourced from local SwiftData (the
// CloudKit-mirrored cache) plus the existing /api/health/oura read.
//
// Sections, top-to-bottom:
//   1. Header: window summary, filters, copy-report button
//   2. Supplements → Sleep score (taken-vs-off Δ, only if any row)
//   3. Trusted signals (|r|≥0.35, p<0.05, monotonic, no confound)
//   4. Exploratory (n≥15 but didn't clear one of the trusted gates)
//   5. Insufficient data (1 ≤ n < 15), collapsible
struct InsightsDestinationView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  @State private var result: CorrelationEngine.Result? = nil
  @State private var loading = true
  @State private var loadError: String? = nil
  @State private var trustedOnly = false
  @State private var sectionFilter: String = "all"
  @AppStorage("insights.windowDays") private var windowDays: Int = 365
  @State private var focused: CorrelationEngine.EvaluatedPair? = nil
  @State private var insufficientExpanded = false

  private var accent: Color { theme.color(for: "activity") }

  private let sectionOptions: [(key: String, label: String)] = [
    ("all",         "All"),
    ("habits",      "Habits"),
    ("supplements", "Supplements"),
    ("training",    "Training"),
    ("nutrition",   "Nutrition"),
    ("caffeine",    "Caffeine"),
    ("cannabis",    "Cannabis"),
    ("air",         "Air"),
    ("gut",         "Gut"),
    ("sleep",       "Sleep"),
  ]

  private var columns: [GridItem] {
    #if os(iOS)
    let count = (hSize == .regular) ? 3 : 2
    return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    #else
    return [GridItem(.adaptive(minimum: 260), spacing: 12)]
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header
          if loading && result == nil {
            ProgressView("Crunching the last year of data…")
              .frame(maxWidth: .infinity, minHeight: 240)
          } else if let err = loadError {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else if let r = result {
            content(for: r)
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 8)
        .padding(.bottom, 40)
      }
      .background(Theme.groupedBackground)
      .navigationTitle("Insights")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
      #endif
      .toolbar { toolbarItems }
      .tint(accent)
      .task { await recompute() }
      .sheet(item: $focused) { pair in
        DetailSheet(pair: pair)
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(minWidth: 560, minHeight: 520)
          #endif
      }
    }
  }

  @ToolbarContentBuilder
  private var toolbarItems: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Done") { dismiss() }
    }
    ToolbarItem(placement: .primaryAction) {
      if let r = result {
        ShareLink(item: CorrelationEngine.markdownReport(from: r),
                  preview: SharePreview("Septena Insights")) {
          Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Copy report")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        Task { await recompute() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .disabled(loading)
      .accessibilityLabel("Recompute")
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(headerExplainer)
        .font(.footnote)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Toggle("Trusted only", isOn: $trustedOnly)
          .toggleStyle(.switch)
          .font(.subheadline)
          .fixedSize()
        Spacer()
        Picker("Window", selection: $windowDays) {
          Text("30 days").tag(30)
          Text("90 days").tag(90)
          Text("6 months").tag(180)
          Text("1 year").tag(365)
          Text("2 years").tag(730)
        }
        .pickerStyle(.menu)
        Picker("Section", selection: $sectionFilter) {
          ForEach(sectionOptions, id: \.key) { Text($0.label).tag($0.key) }
        }
        .pickerStyle(.menu)
      }
      .onChange(of: windowDays) { _, _ in
        Task { await recompute() }
      }
    }
  }

  private var headerExplainer: String {
    let r = result
    let covered = r?.coveredDays ?? 0
    let range: String = {
      guard let dr = r?.dateRange else { return "" }
      return " · \(dr.lowerBound) → \(dr.upperBound)"
    }()
    let windowLabel: String = {
      switch windowDays {
      case 30:  return "30 days"
      case 90:  return "90 days"
      case 180: return "6 months"
      case 365: return "1 year"
      case 730: return "2 years"
      default:  return "\(windowDays) days"
      }
    }()
    return "Cross-section correlations over the past \(windowLabel)\(range) (\(covered) days with logged data). Each pair tested at lag 0/1/2 — best |r| wins. Trusted = |r| ≥ \(String(format: "%.2f", CorrelationEngine.strongR)), p < \(String(format: "%.2f", CorrelationEngine.strongP)), monotonic buckets, no physiology contradiction. Computed locally from your CloudKit data."
  }

  // MARK: - Content

  @ViewBuilder
  private func content(for r: CorrelationEngine.Result) -> some View {
    let filtered = filter(r.evaluated)
    let trusted = filtered.filter { $0.tier == .trusted }
    let exploratory = filtered.filter { $0.tier == .exploratory }

    if !r.supplementsTable.isEmpty && (sectionFilter == "all" || sectionFilter == "supplements" || sectionFilter == "sleep") {
      supplementsSection(rows: r.supplementsTable)
    }

    if trusted.isEmpty && exploratory.isEmpty && r.insufficient.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("No correlations match these filters yet.")
          .font(.subheadline.weight(.medium))
        Text("Keep logging — pairs unlock at n ≥ \(CorrelationEngine.minN) overlapping days.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }

    if !trusted.isEmpty {
      sectionHeader("Trusted signals", subtitle: "n ≥ \(CorrelationEngine.minN), |r| ≥ \(String(format: "%.2f", CorrelationEngine.strongR)), p < 0.05, monotonic, sign matches physiology")
      grid(trusted)
    }
    if !exploratory.isEmpty && !trustedOnly {
      sectionHeader("Exploratory", subtitle: "n ≥ \(CorrelationEngine.minN) but weak r, non-monotonic, or contradicts physiology")
      grid(exploratory)
    }
    if !r.insufficient.isEmpty && !trustedOnly {
      insufficientSection(r.insufficient)
    }
  }

  private func filter(_ rows: [CorrelationEngine.EvaluatedPair]) -> [CorrelationEngine.EvaluatedPair] {
    rows.filter { e in
      if sectionFilter != "all"
        && e.spec.predictor.section != sectionFilter
        && e.spec.target.section != sectionFilter {
        return false
      }
      return true
    }
  }

  // MARK: - Section header

  private func sectionHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.title3.weight(.semibold))
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 4)
  }

  // MARK: - Tile grid

  private func grid(_ items: [CorrelationEngine.EvaluatedPair]) -> some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(items) { e in
        TileView(pair: e, color: theme.color(for: e.spec.predictor.section))
          .contentShape(Rectangle())
          .onTapGesture { focused = e }
      }
    }
  }

  // MARK: - Supplements section

  private func supplementsSection(rows: [CorrelationEngine.SupplementSleepRow]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionHeader("Supplements → Sleep score", subtitle: "Δ = taken mean − off mean. Above bar: |Δ| ≥ 3 with ≥10 days in each state.")
      VStack(spacing: 0) {
        ForEach(rows) { row in
          HStack(spacing: 8) {
            Circle()
              .fill(supplementColor(row))
              .frame(width: 8, height: 8)
            Text("\(row.emoji.isEmpty ? "" : row.emoji + " ")\(row.label)")
              .font(.subheadline)
              .lineLimit(1)
            Spacer()
            Text("Δ \(row.delta >= 0 ? "+" : "")\(String(format: "%.1f", row.delta))")
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(supplementColor(row))
            Text("\(String(format: "%.1f", row.takenMean)) (\(row.takenN)d) vs \(String(format: "%.1f", row.offMean)) (\(row.offN)d)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(row.strength)
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(supplementColor(row).opacity(0.15), in: Capsule())
              .foregroundStyle(supplementColor(row))
          }
          .padding(.vertical, 8)
          .padding(.horizontal, 12)
          if row.id != rows.last?.id {
            Divider().padding(.leading, 28)
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
      )
    }
  }

  private func supplementColor(_ row: CorrelationEngine.SupplementSleepRow) -> Color {
    if !row.meetsBar { return .gray }
    return row.delta >= 0 ? .green : .red
  }

  // MARK: - Insufficient section

  private func insufficientSection(_ items: [CorrelationEngine.InsufficientPair]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      DisclosureGroup(isExpanded: $insufficientExpanded) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(items) { i in
            HStack {
              Text(i.spec.title)
                .font(.caption)
                .lineLimit(1)
              Spacer()
              Text("n=\(i.n)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }
        .padding(.top, 4)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Not enough data yet (\(items.count))")
            .font(.title3.weight(.semibold))
          Text("n < \(CorrelationEngine.minN) — too noisy to plot")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - Loading

  private func recompute() async {
    loading = true
    defer { loading = false }
    let oura = (try? await client.ouraHistory(days: windowDays)) ?? []
    let r = CorrelationEngine.runEverything(
      context: modelContext,
      ouraNights: oura,
      days: windowDays
    )
    result = r
    if r.evaluated.isEmpty && r.insufficient.isEmpty && r.supplementsTable.isEmpty {
      loadError = "No logged data found in the last \(windowDays) days. Once you log training, sleep, or nutrition entries, pairs will appear here."
    } else {
      loadError = nil
    }
  }
}

// MARK: - Tile

private struct TileView: View {
  let pair: CorrelationEngine.EvaluatedPair
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 6, height: 6)
        Text(pair.spec.predictor.label)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer()
        TierBadge(pair: pair)
      }
      HStack(spacing: 4) {
        Image(systemName: "arrow.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(pair.spec.target.label)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer()
        if pair.confound {
          Label("confound", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Direction contradicts physiology — likely confound")
        }
      }
      MiniChart(pair: pair, color: color)
        .frame(height: 90)
      VStack(alignment: .leading, spacing: 1) {
        Text(slopeLine)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack {
          Text("lag \(pair.lag)d · n=\(pair.n)")
          Spacer()
          Text("p=\(String(format: "%.3f", pair.p))")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(pair.confound ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06),
                      lineWidth: pair.confound ? 1 : 0.5)
    )
  }

  private var slopeLine: String {
    let xUnit = pair.spec.predictor.unit
    let yUnit = pair.spec.target.unit
    let sign  = pair.slope >= 0 ? "+" : ""
    let value = abs(pair.slope) >= 100
      ? String(format: "%.0f", pair.slope)
      : String(format: "%.2f", pair.slope)
    let perUnit = xUnit.isEmpty ? "unit" : xUnit
    let yLabel  = yUnit.isEmpty ? "pts" : yUnit
    return "per +1 \(perUnit): \(sign)\(value) \(yLabel)"
  }
}

// MARK: - Mini chart with bucket line

private struct MiniChart: View {
  let pair: CorrelationEngine.EvaluatedPair
  let color: Color

  var body: some View {
    if pair.points.isEmpty {
      Text("no data")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let ys = pair.points.map(\.y)
      Chart {
        ForEach(pair.points, id: \.date) { pt in
          PointMark(x: .value("x", pt.x), y: .value("y", pt.y))
            .foregroundStyle(color.opacity(0.55))
            .symbolSize(22)
        }
        // Tertile bucket line (Low → Mid → High of mean Y).
        ForEach(Array(pair.buckets.enumerated()), id: \.offset) { _, b in
          LineMark(x: .value("bx", b.centerX),
                   y: .value("by", b.meanY),
                   series: .value("series", "buckets"))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.linear)
          PointMark(x: .value("bx", b.centerX),
                    y: .value("by", b.meanY))
            .foregroundStyle(color)
            .symbolSize(50)
            .symbol(.diamond)
        }
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartYScale(domain: yDomain(target: pair.spec.target.label, values: ys))
    }
  }

  private func yDomain(target: String, values: [Double]) -> ClosedRange<Double> {
    let lower = target.lowercased()
    if lower.contains("score") || lower.contains("readiness") { return 50...100 }
    if lower.contains("bristol") { return 1...7 }
    guard let lo = values.min(), let hi = values.max() else { return 0...1 }
    if lo == hi { return (lo - 1)...(hi + 1) }
    let pad = (hi - lo) * 0.1
    return (lo - pad)...(hi + pad)
  }
}

// MARK: - Tier badge

private struct TierBadge: View {
  let pair: CorrelationEngine.EvaluatedPair
  var body: some View {
    let color: Color = {
      if pair.confound { return .orange }
      if pair.absR < 0.2 { return .gray }
      if pair.tier != .trusted { return .yellow }
      return pair.r >= 0 ? .green : .red
    }()
    Text(CorrelationEngine.formatR(pair.r))
      .font(.caption2.monospacedDigit().weight(.semibold))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.18), in: Capsule())
      .foregroundStyle(color)
  }
}

// MARK: - Detail sheet

private struct DetailSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SectionTheme.self) private var theme
  let pair: CorrelationEngine.EvaluatedPair

  @State private var selected: CorrelationPairPoint? = nil

  private var color: Color { theme.color(for: pair.spec.predictor.section) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          summary
          fullChart
          buckets
          stats
        }
        .padding()
      }
      .navigationTitle(pair.spec.title)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        TierBadge(pair: pair)
        Text("\(CorrelationEngine.strengthLabel(pair.r)) · lag \(pair.lag)d · n=\(pair.n) · p=\(String(format: "%.3f", pair.p))")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(pair.tier.rawValue.capitalized)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(tierBackground, in: Capsule())
      }
      if pair.confound {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Direction contradicts physiology — likely confound or reverse causation. Demoted to exploratory.")
            .font(.caption)
        }
      }
      Text(slopeLine)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var tierBackground: Color {
    switch pair.tier {
    case .trusted:      return .green.opacity(0.18)
    case .exploratory:  return .yellow.opacity(0.18)
    case .insufficient: return .gray.opacity(0.18)
    }
  }

  private var fullChart: some View {
    let ys = pair.points.map(\.y)
    return Chart {
      ForEach(pair.points, id: \.date) { pt in
        PointMark(x: .value(pair.spec.predictor.label, pt.x),
                  y: .value(pair.spec.target.label, pt.y))
          .foregroundStyle(color.opacity(0.65))
          .symbolSize(60)
      }
      ForEach(Array(pair.buckets.enumerated()), id: \.offset) { _, b in
        LineMark(x: .value("bx", b.centerX),
                 y: .value("by", b.meanY),
                 series: .value("series", "bucket"))
          .foregroundStyle(color)
          .lineStyle(StrokeStyle(lineWidth: 2))
        PointMark(x: .value("bx", b.centerX), y: .value("by", b.meanY))
          .foregroundStyle(color)
          .symbolSize(120)
          .symbol(.diamond)
      }
      RuleMark(y: .value("mean", pair.meanY))
        .foregroundStyle(.secondary.opacity(0.35))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      if let s = selected {
        RuleMark(x: .value("sel", s.x))
          .foregroundStyle(color.opacity(0.3))
      }
    }
    .frame(height: 280)
    .chartYScale(domain: chartYDomain(values: ys))
    .chartOverlay { proxy in
      GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            updateSelection(at: value.location, proxy: proxy, geo: geo)
          }.onEnded { _ in selected = nil })
      }
    }
    .overlay(alignment: .topLeading) {
      if let s = selected {
        VStack(alignment: .leading, spacing: 1) {
          Text(s.date).font(.caption2.weight(.semibold))
          Text("x = \(format(s.x))\(pair.spec.predictor.unit.isEmpty ? "" : " \(pair.spec.predictor.unit)")")
            .font(.caption2)
          Text("y = \(format(s.y))\(pair.spec.target.unit.isEmpty ? "" : " \(pair.spec.target.unit)")")
            .font(.caption2)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
      }
    }
  }

  private var buckets: some View {
    Group {
      if !pair.buckets.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Buckets (tertiles, sorted by x)")
            .font(.caption.weight(.medium))
          ForEach(Array(zip(["Low", "Mid", "High"], pair.buckets)), id: \.0) { name, b in
            Text("\(name): x̄=\(format(b.centerX))\(unit(pair.spec.predictor.unit))  ·  ȳ=\(format(b.meanY))\(unit(pair.spec.target.unit))  ·  n=\(b.n)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          if !pair.monotonic {
            Text("Buckets are not monotonic — relationship may be threshold-shaped or U-shaped.")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
      }
    }
  }

  private var stats: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Stats")
        .font(.caption.weight(.medium))
      Text("r = \(CorrelationEngine.formatR(pair.r))  ·  p = \(String(format: "%.3f", pair.p))  ·  permutations = \(CorrelationEngine.permutations)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Text("x̄ = \(format(pair.meanX))\(unit(pair.spec.predictor.unit))  ·  ȳ = \(format(pair.meanY))\(unit(pair.spec.target.unit))")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Text("slope = \(pair.slope >= 0 ? "+" : "")\(format(pair.slope)) \(pair.spec.target.unit.isEmpty ? "pts" : pair.spec.target.unit) per +1 \(pair.spec.predictor.unit.isEmpty ? "unit" : pair.spec.predictor.unit) of \(pair.spec.predictor.label)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      if pair.binary {
        Text("Binary predictor — \(pair.stateMinority) minority days vs \(pair.stateMajority) majority days")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let exp = pair.expectedSign.symbol {
        Text("Expected direction: \(exp == "+" ? "positive" : "negative")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var slopeLine: String {
    let sign = pair.slope >= 0 ? "+" : ""
    let yUnit = pair.spec.target.unit.isEmpty ? "pts" : pair.spec.target.unit
    let xUnit = pair.spec.predictor.unit.isEmpty ? "unit" : pair.spec.predictor.unit
    return "per +1 \(xUnit) of \(pair.spec.predictor.label): \(sign)\(format(pair.slope)) \(yUnit)"
  }

  private func chartYDomain(values: [Double]) -> ClosedRange<Double> {
    let lower = pair.spec.target.label.lowercased()
    if lower.contains("score") || lower.contains("readiness") { return 50...100 }
    if lower.contains("bristol") { return 1...7 }
    guard let lo = values.min(), let hi = values.max() else { return 0...1 }
    if lo == hi { return (lo - 1)...(hi + 1) }
    let pad = (hi - lo) * 0.1
    return (lo - pad)...(hi + pad)
  }

  private func format(_ d: Double) -> String {
    abs(d) >= 100 ? String(format: "%.0f", d) : String(format: "%.2f", d)
  }
  private func unit(_ u: String) -> String { u.isEmpty ? "" : " \(u)" }

  private func updateSelection(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
    #if os(iOS)
    let origin = geo[proxy.plotAreaFrame].origin
    #else
    let origin = CGPoint.zero
    #endif
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard let xVal: Double = proxy.value(atX: local.x) else { return }
    // Find nearest point by x.
    var bestDist = Double.infinity
    var best: CorrelationPairPoint? = nil
    for p in pair.points {
      let d = abs(p.x - xVal)
      if d < bestDist { bestDist = d; best = p }
    }
    selected = best
  }
}
