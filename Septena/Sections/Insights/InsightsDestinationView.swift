import SwiftUI
import SwiftData
import Charts

// Insights — full-page cross-section correlation explorer rendered as a
// dense grid of mini scatter charts (one tile per predictor → target
// pair), mirroring the layout shape of the Week dashboard tiles.
//
// All math runs client-side over the last 30 days, sourced from local
// SwiftData (the CloudKit-mirrored cache) plus the existing
// /api/health/oura read endpoint for sleep / HRV / readiness. No new
// backend endpoint — keeps us aligned with the CloudKit migration
// posture (see memory: project_cloudkit_migration).
struct InsightsDestinationView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  @State private var rows: [CorrelationRow] = []
  @State private var pointsByID: [String: [CorrelationPairPoint]] = [:]
  @State private var loading = true
  @State private var loadError: String? = nil
  @State private var trustedOnly = false
  @State private var sectionFilter: String = "all"
  @State private var coveredDays: Int = 0
  @State private var focusedRowID: String? = nil

  private var accent: Color { theme.color(for: "activity") }

  private let sectionOptions: [(key: String, label: String)] = [
    ("all",         "All"),
    ("habits",      "Habits"),
    ("training",    "Training"),
    ("nutrition",   "Nutrition"),
    ("caffeine",    "Caffeine"),
    ("cannabis",    "Cannabis"),
    ("air",         "Air"),
    ("gut",         "Gut"),
    ("sleep",       "Sleep"),
  ]

  /// 2 cols on iPhone compact, 3 on iPad regular, adaptive on macOS so
  /// wider windows pack in 4–5 tiles per row. Same shape as the Week
  /// dashboard's tile grid.
  private var columns: [GridItem] {
    #if os(iOS)
    let count = (hSize == .regular) ? 3 : 2
    return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    #else
    return [GridItem(.adaptive(minimum: 240), spacing: 12)]
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          if loading && rows.isEmpty {
            ProgressView("Crunching 30 days of data…")
              .frame(maxWidth: .infinity, minHeight: 240)
          } else if let err = loadError, rows.isEmpty {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else if filteredRows.isEmpty {
            Text("No correlations match these filters yet. Keep logging — pairs unlock at n ≥ \(CorrelationEngine.minN) overlapping days.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            tilesGrid
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
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await recompute() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Recompute")
        }
      }
      .tint(accent)
      .task { await recompute() }
      .sheet(item: Binding(get: {
        focusedRowID.flatMap { id in rows.first { $0.id == id } }
      }, set: { newVal in
        focusedRowID = newVal?.id
      })) { row in
        DetailScatterSheet(row: row, points: pointsByID[row.id] ?? [])
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(minWidth: 560, minHeight: 480)
          #endif
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Auto-discovered correlations across your last \(coveredDays > 0 ? coveredDays : 30) logged days. Each pair is tested at same-day, 1-day and 2-day lags — the strongest |r| wins. Trusted = |r| ≥ \(CorrelationEngine.strongR, specifier: "%.2f"), n ≥ \(CorrelationEngine.minN). Computed locally from CloudKit data.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Toggle("Trusted only", isOn: $trustedOnly)
          .toggleStyle(.switch)
          .font(.subheadline)
        Spacer()
        Picker("Section", selection: $sectionFilter) {
          ForEach(sectionOptions, id: \.key) { opt in
            Text(opt.label).tag(opt.key)
          }
        }
        .pickerStyle(.menu)
      }
    }
  }

  // MARK: - Tile grid

  private var tilesGrid: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(filteredRows) { row in
        TileView(
          row: row,
          points: pointsByID[row.id] ?? [],
          predictorColor: theme.color(for: row.predictorSection)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedRowID = row.id }
      }
    }
  }

  // MARK: - Filtering

  private var filteredRows: [CorrelationRow] {
    rows.filter { row in
      if trustedOnly && row.tier != "trusted" { return false }
      if sectionFilter != "all"
        && row.predictorSection != sectionFilter
        && row.targetSection != sectionFilter { return false }
      return true
    }
  }

  // MARK: - Loading

  private func recompute() async {
    loading = true
    defer { loading = false }
    let ouraNights = (try? await client.ouraHistory(days: 30)) ?? []
    let features = CorrelationEngine.buildFeatures(
      context: modelContext,
      ouraNights: ouraNights,
      days: 30
    )
    coveredDays = features.count
    let result = CorrelationEngine.run(features: features)
    rows = result.rows
    pointsByID = result.pointsByID
    loadError = rows.isEmpty && features.isEmpty
      ? "No logged data found in the last 30 days. Once you log some training, sleep, or nutrition entries, pairs will appear here."
      : nil
  }
}

// MARK: - Tile

private struct TileView: View {
  let row: CorrelationRow
  let points: [CorrelationPairPoint]
  let predictorColor: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Circle()
          .fill(predictorColor)
          .frame(width: 6, height: 6)
        Text(row.predictor)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer()
        Badge(r: row.r, tier: row.tier, absR: row.absR)
      }
      HStack(spacing: 4) {
        Image(systemName: "arrow.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(row.target)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer()
      }
      miniChart
        .frame(height: 88)
      HStack {
        Text("lag \(row.lag)d")
        Spacer()
        Text("n=\(row.n)")
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Theme.cardSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private var miniChart: some View {
    if points.isEmpty {
      Text("no data")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let ys = points.map(\.y)
      Chart {
        ForEach(points, id: \.date) { pt in
          PointMark(
            x: .value("x", pt.x),
            y: .value("y", pt.y)
          )
          .foregroundStyle(predictorColor.opacity(0.65))
          .symbolSize(28)
        }
        ForEach(tertiles(for: points), id: \.x) { b in
          PointMark(
            x: .value("bx", b.x),
            y: .value("by", b.y)
          )
          .foregroundStyle(predictorColor)
          .symbolSize(70)
          .symbol(.diamond)
        }
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartYScale(domain: autoYDomain(target: row.target, values: ys))
    }
  }

  private func autoYDomain(target: String, values: [Double]) -> ClosedRange<Double> {
    let lower = target.lowercased()
    if lower.contains("score") || lower.contains("readiness") { return 50...100 }
    if lower.contains("bristol") { return 1...7 }
    guard let lo = values.min(), let hi = values.max() else { return 0...1 }
    if lo == hi { return (lo - 1)...(hi + 1) }
    let pad = (hi - lo) * 0.1
    return (lo - pad)...(hi + pad)
  }

  private func tertiles(for points: [CorrelationPairPoint]) -> [(x: Double, y: Double)] {
    guard points.count >= 6 else { return [] }
    let sorted = points.sorted { $0.x < $1.x }
    let n = sorted.count
    let cut1 = n / 3
    let cut2 = (2 * n) / 3
    let buckets: [[CorrelationPairPoint]] = [
      Array(sorted[0..<cut1]),
      Array(sorted[cut1..<cut2]),
      Array(sorted[cut2..<n]),
    ]
    return buckets.compactMap { b -> (Double, Double)? in
      guard !b.isEmpty else { return nil }
      let mx = b.reduce(0.0) { $0 + $1.x } / Double(b.count)
      let my = b.reduce(0.0) { $0 + $1.y } / Double(b.count)
      return (mx, my)
    }
  }
}

// MARK: - Badge

private struct Badge: View {
  let r: Double
  let tier: String
  let absR: Double

  var body: some View {
    let positive = r >= 0
    let color: Color = {
      if absR < 0.2 { return .gray }
      if tier != "trusted" { return .yellow }
      return positive ? .green : .red
    }()
    let sign = r >= 0 ? "+" : ""
    return Text("r=\(sign)\(r, specifier: "%.2f")")
      .font(.caption2.monospacedDigit().weight(.semibold))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.18), in: Capsule())
      .foregroundStyle(color)
  }
}

// MARK: - Detail sheet (tap to expand a tile)

private struct DetailScatterSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SectionTheme.self) private var theme
  let row: CorrelationRow
  let points: [CorrelationPairPoint]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Badge(r: row.r, tier: row.tier, absR: row.absR)
            Text("lag \(row.lag)d · n=\(row.n) · \(strengthLabel(row.r))")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
          }
          if points.isEmpty {
            Text("No overlapping points")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            Chart {
              ForEach(points, id: \.date) { pt in
                PointMark(
                  x: .value(row.predictor, pt.x),
                  y: .value(row.target, pt.y)
                )
                .foregroundStyle(theme.color(for: row.predictorSection).opacity(0.7))
                .symbolSize(70)
              }
            }
            .frame(height: 320)
          }
          Text("x: \(row.predictor)\(row.predictorUnit.isEmpty ? "" : " (\(row.predictorUnit))")")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("y: \(row.target)\(row.targetUnit.isEmpty ? "" : " (\(row.targetUnit))")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
      }
      .navigationTitle("\(row.predictor) → \(row.target)")
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

  private func strengthLabel(_ r: Double) -> String {
    let a = abs(r)
    let kind = r >= 0 ? "positive" : "negative"
    if a >= 0.5  { return "strong \(kind)" }
    if a >= CorrelationEngine.strongR { return "moderate \(kind)" }
    if a >= 0.2  { return "weak \(kind)" }
    return "noise"
  }
}
