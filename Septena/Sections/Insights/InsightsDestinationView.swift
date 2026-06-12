import SwiftUI
import SwiftData
import Charts

// Correlation tile + drill-in detail sheet used by the
// `.correlations` homepage layout mode. Was previously the
// standalone `InsightsDestinationView` page; that surface has been
// folded into the homepage. File kept under its original name for
// pbxproj stability.

// MARK: - Tile

struct TileView: View {
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
        Text(CorrelationEngine.relationshipSentence(pair))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack {
          Text("lag \(pair.lag)d · n=\(pair.n)")
          Spacer()
          Text("q=\(pair.qValue.decimalString(3))")
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
}

// MARK: - Mini chart with bucket line

struct MiniChart: View {
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

struct TierBadge: View {
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

struct DetailSheet: View {
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
          explainer
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
        Text("\(CorrelationEngine.strengthLabel(pair.r)) · lag \(pair.lag)d · n=\(pair.n) · q=\(pair.qValue.decimalString(3))")
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
      VStack(alignment: .leading, spacing: 4) {
        Text(CorrelationEngine.effectSentence(pair))
          .font(.subheadline.weight(.medium))
        Text(CorrelationEngine.relationshipSentence(pair))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
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
    VStack(alignment: .leading, spacing: 8) {
      Text("Evidence")
        .font(.caption.weight(.medium))
      VStack(alignment: .leading, spacing: 5) {
        ForEach(CorrelationEngine.evidenceLines(pair), id: \.self) { line in
          HStack(alignment: .top, spacing: 6) {
            Circle()
              .fill(evidenceColor(for: line))
              .frame(width: 5, height: 5)
              .padding(.top, 5)
            Text(line)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Divider()
      Text("r = \(CorrelationEngine.formatR(pair.r))  ·  p = \(pair.p.decimalString(3))  ·  q = \(pair.qValue.decimalString(3))  ·  permutations = \(CorrelationEngine.permutations)")
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

  private var explainer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("How to read this")
        .font(.caption.weight(.medium))
      ForEach(CorrelationEngine.methodDefinitions(), id: \.term) { item in
        VStack(alignment: .leading, spacing: 1) {
          Text(item.term)
            .font(.caption.monospacedDigit().weight(.semibold))
          Text(item.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func evidenceColor(for line: String) -> Color {
    if line.hasPrefix("Tier: trusted") { return .green }
    if line.hasPrefix("Caution") || line.contains("do not move cleanly") { return .orange }
    return .secondary
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
    abs(d) >= 100 ? d.decimalString(0) : d.decimalString(2)
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
