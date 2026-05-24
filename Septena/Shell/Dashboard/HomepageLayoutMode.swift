import Foundation

/// Which renderer the homepage uses for the canonical list of domains
/// (`HomepageDomain.defaultOrder`). The order is the same across every
/// mode — only the presentation changes.
///
/// Phase 2 of the layout-modes refactor introduces this enum + the
/// `@AppStorage` setting that selects between modes. Only `.tiles`
/// renders real content for now; the other three short-circuit to a
/// "Coming soon" placeholder that resets back to Tiles. Phases 3-5
/// land the actual renderers.
///
/// The raw value is what's persisted in `UserDefaults`, so don't rename
/// existing cases — only add new ones.
enum HomepageLayoutMode: String, CaseIterable, Identifiable, Hashable {
  /// The current card-grid layout. Each domain renders as a tile with
  /// headline stats + 7-day chart. Optimized for quick-launch + glance.
  case tiles

  /// Health-Favorites-style row per domain: icon + label + today's
  /// value + sparkline. Optimized for "what are my numbers."
  ///
  /// Case is named `.dense` historically (the enum's raw value is
  /// persisted in `UserDefaults`, renaming would orphan saved
  /// preferences). User-facing strings call this "Sparkline" — see
  /// `title` / `summary` / `icon` below.
  case dense

  /// One row per domain, full-width 30-day heatmap strip. Optimized
  /// for "am I being consistent."
  case heatmap

  var id: String { rawValue }

  /// Title shown in Settings → General → Homepage layout.
  var title: String {
    switch self {
    case .tiles:   return "Tiles"
    case .dense:   return "Sparkline"
    case .heatmap: return "Heatmap"
    }
  }

  /// One-line description shown under the picker, explaining what
  /// each mode optimizes for.
  var summary: String {
    switch self {
    case .tiles:   return "Card grid. Quick-launch + ambient glance."
    case .dense:   return "Rows with today's value + sparkline. Maximum signal per scroll."
    case .heatmap: return "Rows with 90-day heatmap grid. Optimized for consistency."
    }
  }

  /// SF Symbol shown in the picker as a visual cue per mode.
  var icon: String {
    switch self {
    case .tiles:   return "square.grid.2x2"
    case .dense:   return "chart.xyaxis.line"
    case .heatmap: return "square.grid.3x3.fill"
    }
  }

  /// All currently-implemented modes are listed; the `isImplemented`
  /// flag is kept for forward-compatibility — adding a new case that
  /// returns `false` re-enables the "Coming soon" placeholder + reset
  /// button in `WeekDashboardView` without further wiring.
  var isImplemented: Bool {
    switch self {
    case .tiles, .dense, .heatmap: return true
    }
  }
}
