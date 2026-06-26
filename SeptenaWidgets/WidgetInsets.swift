import SwiftUI
import WidgetKit

/// Home-screen widget gutters. Horizontal is half the typical system content
/// margin (~16pt → 8pt); vertical matches the system default.
enum WidgetLayout {
  static let horizontal: CGFloat = 8
  static let vertical: CGFloat = 16
  /// Pull home-screen content outward by half the system horizontal gutter
  /// (used when system content margins stay enabled — e.g. Next + accessories).
  static let horizontalBleed: CGFloat = -8
}

struct WidgetSurfaceInsets: ViewModifier {
  var vertical: CGFloat = WidgetLayout.vertical

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, WidgetLayout.horizontal)
      .padding(.vertical, vertical)
  }
}

extension View {
  func widgetSurfaceInsets(vertical: CGFloat? = nil) -> some View {
    if let vertical {
      modifier(WidgetSurfaceInsets(vertical: vertical))
    } else {
      modifier(WidgetSurfaceInsets())
    }
  }

  /// Inner gutter matching `DomainTile` / `HeatmapTileRow` inside `widgetSurfaceInsets()`.
  func widgetTileInnerPadding() -> some View {
    padding(.horizontal, 6)
      .padding(.vertical, 12)
  }

  /// Eat half the system horizontal content margin on home-screen families.
  func widgetHorizontalBleed() -> some View {
    padding(.horizontal, WidgetLayout.horizontalBleed)
  }
}

extension WidgetConfiguration {
  /// Take over layout margins so `widgetSurfaceInsets()` is the sole gutter.
  func septenaWidgetMargins() -> some WidgetConfiguration {
    contentMarginsDisabled()
  }
}
