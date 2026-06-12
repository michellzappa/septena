import SwiftUI
import SwiftData

/// Homepage layout mode `.correlations` — embeds the trusted +
/// exploratory correlation grids inline. Supplements → Sleep table
/// and the insufficient-data fold-out render conditionally based on
/// the prefs in Settings → Customize → Correlations.
struct CorrelationsHomepageView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  @State private var result: CorrelationEngine.Result? = nil
  @State private var loading = true
  @State private var loadingStage = "Preparing insights..."
  @State private var loadError: String? = nil
  @State private var focused: CorrelationEngine.EvaluatedPair? = nil
  @State private var insufficientExpanded = false
  /// Habit + supplement signals are binary (taken/not, done/not) and
  /// generate one tile per pair across many habits — they dominate the
  /// grid visually while saying less per tile than a continuous dose-
  /// response curve. Default collapsed; the user can pop them open when
  /// they want to scan. Persisted so the choice sticks across launches.
  @AppStorage("insights.binaryExpanded") private var binaryExpanded = false

  @AppStorage(SettingsKey.correlationsWindowDays)
  private var windowDays: Int = 365
  @AppStorage(SettingsKey.correlationsSectionFilter)
  private var sectionFilter: String = "all"
  @AppStorage(SettingsKey.correlationsShowSupplements)
  private var showSupplements: Bool = true
  @AppStorage(SettingsKey.correlationsShowInsufficient)
  private var showInsufficient: Bool = false

  private var columns: [GridItem] {
    #if os(iOS)
    let count = (hSize == .regular) ? 3 : 2
    return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    #else
    return [GridItem(.adaptive(minimum: 260), spacing: 12)]
    #endif
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if loading {
        loadingStatus
      }
      if loading && result == nil {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 120)
      } else if let r = result {
        if let report = markdownReport(for: r) {
          HStack {
            Spacer()
            ShareLink(item: report, preview: SharePreview("Septena Correlations")) {
              Label("Share report", systemImage: "square.and.arrow.up")
                .font(.footnote.weight(.medium))
            }
          }
        }
        content(for: r)
      } else if let err = loadError {
        emptyState(message: err)
      } else {
        emptyState(message: "No trusted correlations yet.")
      }
    }
    .task(id: windowDays) { await recompute() }
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

  private var loadingStatus: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text("Generating insights")
          .font(.caption.weight(.medium))
        Text(loadingStage)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
    )
  }

  @ViewBuilder
  private func content(for r: CorrelationEngine.Result) -> some View {
    let filtered = filter(r.evaluated)
    // Split continuous (dose-response) from binary (taken/not, done/not)
    // predictors — binary pairs read as noise in the main grid because
    // their slope/r interpretation is qualitatively different from a
    // gradient like "+10g fiber → +X sleep score". Binary pairs go into
    // their own collapsed disclosure below the supplements→sleep table.
    let continuous = filtered.filter { !$0.binary }
    let binarySignals = filtered.filter { $0.binary }
    let trusted = continuous.filter { $0.tier == .trusted }
    let exploratory = continuous.filter { $0.tier == .exploratory }

    if trusted.isEmpty && exploratory.isEmpty && binarySignals.isEmpty
       && (r.supplementsTable.isEmpty || !showSupplements) {
      emptyState(message: "No matching correlations yet — pairs unlock at n ≥ \(CorrelationEngine.minN).")
    }

    if showSupplements && !r.supplementsTable.isEmpty
       && (sectionFilter == "all" || sectionFilter == "supplements" || sectionFilter == "sleep") {
      supplementsSection(rows: r.supplementsTable)
    }

    let reports = sectionReports(from: filtered)
    if !reports.isEmpty {
      reportsSection(reports)
    }

    if !trusted.isEmpty {
      sectionHeader("Trusted signals", subtitle: "|r| ≥ \(String(format: "%.2f", CorrelationEngine.strongR)), q < 0.05, monotonic")
      grid(trusted)
    }
    if !exploratory.isEmpty {
      sectionHeader("Exploratory", subtitle: "n ≥ \(CorrelationEngine.minN) but weak r, non-monotonic, or contradicts physiology")
      grid(exploratory)
    }
    if !binarySignals.isEmpty {
      binarySignalsSection(binarySignals)
    }
    if showInsufficient && !r.insufficient.isEmpty {
      insufficientSection(r.insufficient)
    }
  }

  // MARK: - Binary signals disclosure

  /// Collapsed-by-default group for habit + supplement (taken/not)
  /// correlations. Keeps the main grid focused on continuous gradients
  /// where the slope value is interpretable, while still giving the
  /// user a way to scan binary signals when they want to.
  private func binarySignalsSection(_ items: [CorrelationEngine.EvaluatedPair]) -> some View {
    let trustedCount = items.filter { $0.tier == .trusted }.count
    return DisclosureGroup(isExpanded: $binaryExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        let trusted = items.filter { $0.tier == .trusted }
        let exploratory = items.filter { $0.tier == .exploratory }
        if !trusted.isEmpty {
          Text("Trusted")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          grid(trusted)
        }
        if !exploratory.isEmpty {
          Text("Exploratory")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          grid(exploratory)
        }
      }
      .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Habits & supplements")
          .font(.septenaSectionTitle)
        Text("\(items.count) binary signals · \(trustedCount) trusted · tap to expand")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
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

  private func sectionHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.septenaSectionTitle)
      Text(subtitle).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.top, 4)
  }

  private func grid(_ items: [CorrelationEngine.EvaluatedPair]) -> some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(items) { e in
        TileView(pair: e, color: theme.color(for: e.spec.predictor.section))
          .contentShape(Rectangle())
          .onTapGesture { focused = e }
      }
    }
  }

  // MARK: - Generalized section reports

  private struct SectionReport: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let pairs: [CorrelationEngine.EvaluatedPair]
  }

  private func sectionReports(from rows: [CorrelationEngine.EvaluatedPair]) -> [SectionReport] {
    let actionable = rows
      .filter { $0.n >= CorrelationEngine.minN }
      .sorted { lhs, rhs in
        if lhs.tier != rhs.tier { return lhs.tier == .trusted }
        return lhs.absR > rhs.absR
      }
    guard !actionable.isEmpty else { return [] }

    let preferredTargets = ["symptoms", "medications", "sleep", "mood", "gut"]
    var reports: [SectionReport] = []
    for section in preferredTargets {
      let targetRows = actionable
        .filter { $0.spec.target.section == section }
        .prefix(3)
      guard !targetRows.isEmpty else { continue }
      reports.append(SectionReport(
        id: "target-\(section)",
        title: "\(displayName(for: section)) drivers",
        subtitle: "Top possible drivers of \(displayName(for: section).lowercased()) outcomes.",
        pairs: Array(targetRows)))
    }

    let medicationRows = actionable
      .filter { $0.spec.predictor.section == "medications" || $0.spec.target.section == "medications" }
      .prefix(3)
    if !medicationRows.isEmpty && !reports.contains(where: { $0.id == "target-medications" }) {
      reports.append(SectionReport(
        id: "medication-signals",
        title: "Medication signals",
        subtitle: "Dose, skip, and medication-day patterns worth reviewing.",
        pairs: Array(medicationRows)))
    }
    return Array(reports.prefix(5))
  }

  private func reportsSection(_ reports: [SectionReport]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Reports", subtitle: "Same engine, grouped by the outcome you care about.")
      ForEach(reports) { report in
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(report.title)
              .font(.headline)
            Text(report.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ForEach(report.pairs) { pair in
            Button {
              focused = pair
            } label: {
              HStack(alignment: .top, spacing: 8) {
                Circle()
                  .fill(theme.color(for: pair.spec.predictor.section))
                  .frame(width: 7, height: 7)
                  .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                  Text(CorrelationEngine.effectSentence(pair))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                  Text("q=\(pair.qValue.decimalString(3)) · r=\(CorrelationEngine.formatR(pair.r)) · n=\(pair.n) · lag \(pair.lag)d")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                TierBadge(pair: pair)
              }
              .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
        )
      }
    }
  }

  private func displayName(for section: String) -> String {
    SectionManifest.byKey[section]?.defaultLabel ?? section.capitalized
  }

  // MARK: - Supplements section

  private func supplementsSection(rows: [CorrelationEngine.SupplementSleepRow]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionHeader("Supplements → Sleep score", subtitle: "Δ = taken mean − off mean. Above bar: |Δ| ≥ 3 with ≥10 days in each state.")
      VStack(spacing: 0) {
        ForEach(rows) { row in
          HStack(spacing: 8) {
            Circle().fill(supplementColor(row)).frame(width: 8, height: 8)
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
    DisclosureGroup(isExpanded: $insufficientExpanded) {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(items) { i in
          HStack {
            Text(i.spec.title).font(.caption).lineLimit(1)
            Spacer()
            Text("n=\(i.n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      }
      .padding(.top, 4)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Not enough data yet (\(items.count))").font(.septenaSectionTitle)
        Text("n < \(CorrelationEngine.minN) — too noisy to plot")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private func emptyState(message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message).font(.subheadline.weight(.medium))
      Text("Keep logging — pairs need n ≥ \(CorrelationEngine.minN) overlapping days.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
    )
  }

  private func markdownReport(for r: CorrelationEngine.Result) -> String? {
    let any = !r.evaluated.isEmpty || !r.supplementsTable.isEmpty
    guard any else { return nil }
    return CorrelationEngine.markdownReport(from: r)
  }

  private func recompute() async {
    setLoadingStage("Checking cached insights...")
    log("start windowDays=\(windowDays)")
    // Same-day reopen with no data changes: serve the engine's memoized
    // result — no Oura fetch, no stats run, the drawer paints instantly.
    if let cached = CorrelationEngine.cachedResult(days: windowDays) {
      log("cache hit evaluated=\(cached.evaluated.count) insufficient=\(cached.insufficient.count)")
      apply(cached)
      loading = false
      setLoadingStage("Loaded cached insights.")
      return
    }
    loading = true
    loadError = nil
    defer { loading = false }
    setLoadingStage("Fetching sleep history...")
    let oura = await fetchOuraHistory(days: windowDays)
    log("oura fetched nights=\(oura.count)")
    setLoadingStage("Comparing local signals...")
    let r = await CorrelationEngine.runEverything(
      context: modelContext,
      ouraNights: oura,
      days: windowDays
    )
    setLoadingStage("Rendering \(r.evaluated.count) insights...")
    log("done evaluated=\(r.evaluated.count) insufficient=\(r.insufficient.count) supplements=\(r.supplementsTable.count)")
    apply(r)
  }

  private func fetchOuraHistory(days: Int) async -> [OuraNight] {
    await withTaskGroup(of: [OuraNight]?.self) { group in
      group.addTask {
        (try? await OuraProvider.shared.fetchHistory(days: days)) ?? []
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      if let rows = first { return rows }
      log("oura fetch timed out after 8s; continuing with local-only signals")
      return []
    }
  }

  private func setLoadingStage(_ stage: String) {
    loadingStage = stage
    log(stage)
  }

  private func log(_ message: String) {
    let line = "[Insights] \(message)"
    SeptenaLog.info(line)
    #if DEBUG
    print(line)
    #endif
  }

  private func apply(_ r: CorrelationEngine.Result) {
    // Sort each tier by |r| desc for at-a-glance prominence.
    result = CorrelationEngine.Result(
      evaluated: r.evaluated.sorted { $0.absR > $1.absR },
      insufficient: r.insufficient,
      supplementsTable: r.supplementsTable,
      coveredDays: r.coveredDays,
      dateRange: r.dateRange
    )
    if r.evaluated.isEmpty && r.supplementsTable.isEmpty {
      loadError = "No logged data in the last \(windowDays) days."
    } else {
      loadError = nil
    }
  }
}
