import SwiftUI

/// Heatmap homepage renderer — one row per domain, each row's right
/// half is a full `ConsistencyHeatmap` grid (7 rows tall, Mon→Sun,
/// columns are weeks). Phase 4 of the layout-modes refactor.
///
/// Layout per row, left-to-right:
///   * Identity column (≈140pt wide): icon + title + compact headline
///   * `ConsistencyHeatmap` filling the remaining width (≈102pt tall
///     for the standard 12pt cell + 3pt gap × 7-row stack)
///
/// On wide iPad (> 900pt): 4-column card grid.
/// On portrait iPad (550–900pt): 3-column card grid.
/// On iPhone / compact: original full-width list.
///
/// Window: 90 days back from today → ~13 week columns at full iPhone
/// width. Loaders in `WeekDashboardView.loadAll()` fetch 90 days so
/// all this data is available without extra round-trips.
///
/// Reuses `ConsistencyHeatmap` (the same component the destination
/// views use for per-section consistency cards) so the homepage strip
/// and the deep-dive grid feel like one component family — same 0…4
/// color ramp, same Differentiate-Without-Color overlay.
struct HeatmapHomepageView<MenuContent: View>: View {
  let items: [HomepageDomainData]
  let onTap: (DomainTapAction) -> Void
  /// Long-press / right-click quickadd menu per domain — same plumbing
  /// as `DenseHomepageView`. Caller hands back `EmptyView` for domains
  /// without a menu (sleep, body, activity).
  @ViewBuilder let menuContent: (HomepageDomain) -> MenuContent

  /// Measured at render time via a 0-height probe in the VStack below.
  /// Starts at 0; `hSize` guards against showing grid on first render on iPhone.
  @State private var containerWidth: CGFloat = 0
  @Environment(\.horizontalSizeClass) private var hSize

  private var gridColumnCount: Int {
    // On compact (iPhone), always use the list layout regardless of width.
    guard hSize == .regular else { return 1 }
    // Default to 3 on first render (containerWidth == 0) so iPad shows a
    // grid immediately; refines to 4 once the width probe fires for landscape.
    if containerWidth > 900 { return 4 }
    return 3
  }

  private var gridColumns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 12), count: gridColumnCount)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Zero-height width probe: Color.clear fills proposed width but has no
      // height, giving the background GeometryReader a concrete frame to
      // measure. A Group has no frame so this probe must be a real view.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: 0)
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: HeatmapContainerWidthKey.self, value: geo.size.width)
          }
        )
        .onPreferenceChange(HeatmapContainerWidthKey.self) { containerWidth = $0 }

      if gridColumnCount > 1 {
        LazyVGrid(columns: gridColumns, spacing: 12) {
          ForEach(items, id: \.domain) { item in
            Button { onTap(item.tap) } label: {
              HeatmapDomainCard(data: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menuContent(item.domain) }
          }
        }
      } else {
        VStack(spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.domain) { idx, item in
            Button {
              onTap(item.tap)
            } label: {
              HeatmapDomainRow(data: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menuContent(item.domain) }

            if idx < items.count - 1 {
              Divider().padding(.leading, 14)
            }
          }
        }
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }
}

private struct HeatmapContainerWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Card variant used in the multi-column iPad grid. Icon + title + headline
/// stack above the heatmap so the grid cells stay square-ish and readable.
private struct HeatmapDomainCard: View {
  let data: HomepageDomainData

  private let windowDays: Int = 90

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        SectionGlyph(icon: SectionManifest.byKey[data.domain.rawValue]?.iconSymbol ?? "circle.fill",
                     accent: data.accent)
        Text(data.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      Text(data.headline)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      ConsistencyHeatmap(
        endDate: Date(),
        firstDataDate: firstDataDate,
        accent: data.accent,
        getDay: { iso in
          HeatmapDay(
            level: levelByIso[iso] ?? 0,
            label: "\(iso) · \(data.title)"
          )
        }
      )
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.cardSurface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(Rectangle())
  }

  private var firstDataDate: Date? {
    Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: Date())
  }

  private var levelByIso: [String: Int] { HeatmapDomainRow.buildLevelMap(from: data.history, windowDays: windowDays) }
}

private struct HeatmapDomainRow: View {
  let data: HomepageDomainData

  /// Days back from today the grid covers. 90 ≈ 13 week columns —
  /// dense enough to read consistency patterns, narrow enough to fit
  /// on an iPhone with the identity column.
  private let windowDays: Int = 90

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      identityColumn

      // No `Spacer` here — `ConsistencyHeatmap` uses a
      // `GeometryReader` internally, which is already greedy. A
      // `Spacer` between them creates a flex-vs-flex contention that
      // SwiftUI sometimes resolves with a transient negative width
      // for the heatmap, triggering CoreGraphics "Invalid frame
      // dimension" log spam. Let the heatmap take all remaining
      // HStack width — its own `.frame(maxWidth: .infinity,
      // alignment: .trailing)` already right-aligns the cells within
      // that space, so the visual outcome is identical.
      ConsistencyHeatmap(
        endDate: Date(),
        firstDataDate: firstDataDate,
        accent: data.accent,
        getDay: { iso in
          HeatmapDay(
            level: levelByIso[iso] ?? 0,
            label: "\(iso) · \(data.title)"
          )
        }
      )
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }

  private var identityColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        SectionGlyph(icon: SectionManifest.byKey[data.domain.rawValue]?.iconSymbol ?? "circle.fill",
                     accent: data.accent)
        Text(data.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
      }
      Text(data.headline)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 140, alignment: .leading)
  }

  private var firstDataDate: Date? {
    Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: Date())
  }

  private var levelByIso: [String: Int] { Self.buildLevelMap(from: data.history, windowDays: windowDays) }

  /// Pre-computed ISO-date → 0…4 level map for the grid's `getDay`
  /// closure. Shared by both `HeatmapDomainRow` and `HeatmapDomainCard`.
  static func buildLevelMap(from history: HistorySeries?, windowDays: Int) -> [String: Int] {
    var levels = Self.levels(for: history)
    guard !levels.isEmpty else { return [:] }
    // Pad with leading zeros if shorter than window so every date in the
    // viewport has an entry. Do NOT truncate when longer — sources like
    // Oura append a trailing 0 for today (sleep not yet recorded) to shift
    // the anchor back by one day so the week-rounded first column is covered.
    if levels.count < windowDays {
      levels = Array(repeating: 0, count: windowDays - levels.count) + levels
    }
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    let today = cal.startOfDay(for: Date())
    var map: [String: Int] = [:]
    for (i, level) in levels.enumerated() {
      // levels is oldest-first; last element maps to today.
      let daysBack = levels.count - 1 - i
      if let d = cal.date(byAdding: .day, value: -daysBack, to: today) {
        map[fmt.string(from: d)] = level
      }
    }
    return map
  }

  /// Map a `HistorySeries` to per-day 0…4 levels. Each domain
  /// self-normalizes to its own series max so a quiet week still
  /// shows relative variation rather than collapsing to all-0.
  static func levels(for history: HistorySeries?) -> [Int] {
    switch history {
    case .bars(let values):
      return normalizedLevels(values.map(Double.init))

    case .stackedBars(let primary, let secondary):
      // Combine the two series per day before normalizing — heatmap
      // mode is about "was there activity," so total effort is the
      // right signal even though the two series mean different things.
      let combined = zip(primary, secondary).map { $0 + $1 }
      return normalizedLevels(combined)

    case .centered(let values, _):
      // Absolute deviation: a big swing up *or* down counts as
      // "activity." `nil` days (no measurement) collapse to level 0.
      let abs = values.map { $0.map(Swift.abs) ?? 0 }
      let missing = values.map { $0 == nil }
      return normalizedLevels(abs, isMissing: missing)

    case .none:
      return []
    }
  }

  /// Normalize a series to its own max:
  ///   * `0` stays at level 0 (empty).
  ///   * `value / max` is bucketed into 1…4.
  ///   * If `max == 0`, every day is level 0.
  ///
  /// `isMissing[i] == true` forces that day to level 0 even when the
  /// raw value is non-zero, so e.g. body-weight days without a
  /// measurement render as empty rather than as level cells.
  static func normalizedLevels(
    _ values: [Double],
    isMissing: [Bool] = []
  ) -> [Int] {
    guard let maxV = values.max(), maxV > 0 else {
      return Array(repeating: 0, count: values.count)
    }
    return values.enumerated().map { idx, v in
      if idx < isMissing.count, isMissing[idx] { return 0 }
      guard v > 0 else { return 0 }
      let ratio = v / maxV
      if ratio >= 0.75 { return 4 }
      if ratio >= 0.5 { return 3 }
      if ratio >= 0.25 { return 2 }
      return 1
    }
  }
}
