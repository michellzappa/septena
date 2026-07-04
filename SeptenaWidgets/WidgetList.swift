import SwiftUI
import WidgetKit

// MARK: - Shared list-widget design language
//
// Septena's two home-screen "list" widgets — Next and Today — both render a
// title header over up to four rows. They render through the primitives here so
// the pair reads as siblings: one surface, one type scale, one header anatomy,
// one row anatomy, one empty state. Exactly two things vary, both passed in by
// the caller: the per-widget `accent` and the row's leading glyph.
//
// Outer margins stay per-widget on purpose, NOT by oversight. Next also ships
// lock-screen accessories and must keep system content margins ENABLED, while
// the tile widgets disable them (`septenaWidgetMargins()`). Both list widgets
// still target the same content box — ~8pt horizontal, 16pt vertical — so the
// content lines up regardless of how each one reaches that inset:
//   • Next  — system margins (~16) + `widgetHorizontalBleed()` (−6)  → ~10 / 16
//   • Today — `septenaWidgetMargins()` + `widgetSurfaceInsets()`     →  10 / 16
// Both sit on `Theme.cardSurface`.

/// The single source of truth for sizes and spacing across the list widgets.
/// Two values per role: `compact` is `systemSmall`, regular is `systemMedium`.
enum WidgetListMetrics {
  // Header
  static func headerIcon(_ compact: Bool) -> CGFloat { compact ? 12 : 13 }
  static func headerText(_ compact: Bool) -> CGFloat { compact ? 13 : 14 }

  // Row
  static func glyphFrame(_ compact: Bool) -> CGFloat { compact ? 13 : 14 }
  static func rowText(_ compact: Bool) -> CGFloat { compact ? 12.5 : 13.5 }
  static let trailingText: CGFloat = 9.5
  static let overdueGlyph: CGFloat = 9.5

  // Spacing
  static func headerGap(_ compact: Bool) -> CGFloat { compact ? 6 : 8 }
  static func rowGap(_ compact: Bool) -> CGFloat { compact ? 8 : 10 }
  /// Wider gap for the `.distributed` fill (Next) so its rows breathe into the
  /// full card height instead of clumping under the header.
  static func rowGapWide(_ compact: Bool) -> CGFloat { compact ? 11 : 14 }
}

/// `[accent icon]  Title  …  trailing`. The trailing slot is a bare count
/// (monospaced, secondary) — no "left" suffix, so both widgets read identically.
struct WidgetListHeader: View {
  let icon: String
  let title: String
  let accent: Color
  var trailing: String? = nil
  let compact: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: WidgetListMetrics.headerIcon(compact), weight: .semibold))
        .foregroundStyle(accent)
      Text(title)
        .font(.system(size: WidgetListMetrics.headerText(compact), weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 0)
      if let trailing {
        Text(trailing)
          .font(.system(size: WidgetListMetrics.headerText(compact), weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// `[leading glyph]  Title  [overdue?]  …  [count?]`. The leading glyph is the
/// only content-specific piece — Next passes a per-category SF Symbol, Today a
/// stroked checkbox circle — so it's supplied by the caller and pinned to a
/// shared-width column. `trailingCount` renders only when greater than 1.
struct WidgetListRow<Leading: View>: View {
  let compact: Bool
  let title: String
  var overdue: Bool = false
  var trailingCount: Int? = nil
  @ViewBuilder var leading: Leading

  var body: some View {
    HStack(spacing: 8) {
      leading
        .frame(width: WidgetListMetrics.glyphFrame(compact))
      Text(title)
        .font(.system(size: WidgetListMetrics.rowText(compact), weight: .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      if overdue {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: WidgetListMetrics.overdueGlyph, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      if let trailingCount, trailingCount > 1 {
        Text("\(trailingCount)")
          .font(.system(size: WidgetListMetrics.trailingText, weight: .regular).monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// The "nothing left" reward state — centered in the space the rows would fill.
struct WidgetListEmptyState: View {
  let compact: Bool
  var label: String = "All done"

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      Text(label)
        .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// How the rows sit in the space below the header.
///   • `.packed`      — pinned up under the header (a trailing spacer eats the
///                       slack). Today uses this.
///   • `.distributed` — the rows block fills the remaining height and centers
///                       within it, so the margin under the header equals the
///                       margin at the bottom and the rows breathe. Next uses
///                       this (with a slightly wider row gap).
enum WidgetRowFill { case packed, distributed }

/// Header-over-rows scaffold shared by both list widgets: the header gap, the
/// rows' own gap, top-leading alignment, and the trailing spacer that pins rows
/// up when there are fewer than the family allows.
struct WidgetListLayout<Rows: View>: View {
  let compact: Bool
  let header: WidgetListHeader
  let isEmpty: Bool
  var fill: WidgetRowFill = .packed
  @ViewBuilder var rows: Rows

  private var rowSpacing: CGFloat {
    switch fill {
    case .packed:      return WidgetListMetrics.rowGap(compact)
    case .distributed: return WidgetListMetrics.rowGapWide(compact)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WidgetListMetrics.headerGap(compact)) {
      header
      if isEmpty {
        WidgetListEmptyState(compact: compact)
      } else {
        let stack = VStack(alignment: .leading, spacing: rowSpacing) { rows }
        switch fill {
        case .packed:
          stack
          Spacer(minLength: 0)
        case .distributed:
          // Fill the leftover height and center — equal margin top and bottom.
          stack.frame(maxHeight: .infinity, alignment: .center)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
