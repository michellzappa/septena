import SwiftUI

/// Rings homepage renderer — one progress ring per domain in a compact
/// multi-column grid. Phase 5 of the layout-modes refactor (after Tiles /
/// Sparkline / Heatmap). Optimized for "am I hitting my targets today."
///
/// Each cell is a circular progress ring filled in the section accent:
///   * Domains with an explicit daily target (`HomepageDomainData.progress`)
///     fill `current / target` and label the center with the percentage —
///     habits done, protein grams, hydration ml, steps, Z2 minutes, …
///   * Domains without a target (sleep score, GitHub commits) fall back to
///     a *week-activity* fraction — active days in the trailing 7 — drawn in
///     a lighter accent and labeled `n/7` so it never masquerades as a goal.
///
/// Unlike Heatmap / Sparkline, this mode shows a grid on *every* size class
/// (the rings are small and read fine 3-up on iPhone). Columns are adaptive:
/// ~3 on iPhone, more on iPad / Mac, no size-class branching needed.
struct RingsHomepageView<MenuContent: View>: View {
  let items: [HomepageDomainData]
  let onTap: (DomainTapAction) -> Void
  /// Long-press / right-click quickadd menu per domain — same plumbing
  /// as the other renderers. Caller hands back `EmptyView` for domains
  /// without a menu (sleep, body, activity).
  @ViewBuilder let menuContent: (HomepageDomain) -> MenuContent

  /// Adaptive: each ring cell wants ≥104pt, so a 390pt iPhone packs 3
  /// columns, portrait iPad ~6, Mac as many as fit. `spacing` matches the
  /// other grid renderers (12pt).
  private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(items, id: \.id) { item in
        Button { onTap(item.tap) } label: {
          RingDomainCell(data: item)
        }
        .buttonStyle(.plain)
        .contextMenu { menuContent(item.domain) }
      }
    }
  }
}

/// A single domain's ring cell: ring + centered label, then glyph + title,
/// then the domain's compact headline. Sized to read at iPhone 3-up width.
private struct RingDomainCell: View {
  let data: HomepageDomainData

  private let ringSize: CGFloat = 84
  private let lineWidth: CGFloat = 9

  var body: some View {
    let fill = Self.fraction(for: data)

    VStack(spacing: 8) {
      ZStack {
        Circle()
          .stroke(data.accent.opacity(0.15), lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: max(0.0001, fill.value))
          .stroke(
            // Goal-backed rings read in full accent; derived
            // week-activity rings sit back at reduced opacity so the
            // ring never implies a target the domain doesn't have.
            data.accent.opacity(fill.hasTarget ? 1 : 0.5),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
        Text(fill.centerLabel)
          .font(.subheadline.weight(.semibold).monospacedDigit())
          .foregroundStyle(.primary)
      }
      .frame(width: ringSize, height: ringSize)
      .a11yAnimation(Theme.Motion.standard, value: fill.value)

      HStack(spacing: 4) {
        SectionGlyph(icon: data.icon,
                     accent: data.accent)
        Text(data.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
      }

      Text(data.headline)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity)
    .background(Theme.cardSurface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(Rectangle())
  }

  /// The ring's fill fraction + how to label and tint it. `hasTarget`
  /// distinguishes an explicit daily goal (percentage, full accent) from a
  /// derived week-activity fallback (`n/7`, faded accent).
  private struct RingFill {
    let value: Double
    let centerLabel: String
    let hasTarget: Bool
  }

  /// Prefer the domain's explicit `progress` (today's value vs target). Fall
  /// back to "active days in the trailing 7" derived from `history` so a
  /// target-less domain (sleep, github) still shows a meaningful ring.
  private static func fraction(for data: HomepageDomainData) -> RingFill {
    if let p = data.progress, p.target > 0 {
      let frac = min(1, max(0, p.current / p.target))
      return RingFill(value: frac,
                      centerLabel: "\(Int((frac * 100).rounded()))%",
                      hasTarget: true)
    }
    let (active, span) = activeDays(in: data.history)
    let frac = span > 0 ? Double(active) / Double(span) : 0
    return RingFill(value: frac,
                    centerLabel: span > 0 ? "\(active)/\(span)" : "—",
                    hasTarget: false)
  }

  /// Count non-empty days in the trailing 7 of a `HistorySeries`. Mirrors
  /// the "was there activity" reading the heatmap uses, collapsed to a
  /// single fraction.
  private static func activeDays(in history: HistorySeries?) -> (active: Int, span: Int) {
    func tail<T>(_ values: [T]) -> [T] { Array(values.suffix(7)) }
    switch history {
    case .bars(let values):
      let last = tail(values)
      return (last.filter { $0 > 0 }.count, last.count)
    case .stackedBars(let primary, let secondary):
      let combined = zip(primary, secondary).map { $0 + $1 }
      let last = tail(combined)
      return (last.filter { $0 > 0 }.count, last.count)
    case .centered(let values, _):
      let last = tail(values)
      return (last.filter { $0 != nil }.count, last.count)
    case .none:
      return (0, 0)
    }
  }
}
