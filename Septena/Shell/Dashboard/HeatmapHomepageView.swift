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
  @Environment(DayClock.self) private var clock
  let items: [HomepageDomainData]
  let onTap: (DomainTapAction) -> Void
  /// Long-press / right-click quickadd menu per domain — same plumbing
  /// as `DenseHomepageView`. Caller hands back `EmptyView` for domains
  /// without a menu (sleep, body, activity).
  @ViewBuilder let menuContent: (HomepageDomainData) -> MenuContent

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
          ForEach(items, id: \.id) { item in
            Button { onTap(item.tap) } label: {
              HeatmapDomainCard(data: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menuContent(item) }
          }
        }
      } else {
        VStack(spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
            Button {
              onTap(item.tap)
            } label: {
              HeatmapDomainRow(data: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menuContent(item) }

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
  @Environment(DayClock.self) private var clock
  let data: HomepageDomainData

  private let windowDays: Int = 90

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        SectionGlyph(icon: data.icon,
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
        endDate: clock.now,
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
    .tileHover(cornerRadius: 14)
  }

  private var firstDataDate: Date? {
    Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: clock.now)
  }

  private var levelByIso: [String: Int] {
    let today = SeptenaDate.parse(clock.today) ?? Date()
    return HeatmapLevels.buildLevelMap(from: data.history?.wire, windowDays: windowDays,
                                       today: today)
  }
}

private struct HeatmapDomainRow: View {
  @Environment(SectionTheme.self) private var theme
  let data: HomepageDomainData

  var body: some View {
    HeatmapTileRow(
      display: data.tileDisplay(accentHex: data.accentHex ?? theme.token(for: data.domain.rawValue)),
      useHover: true
    )
  }
}
