import Foundation

/// Which renderer the homepage uses for the resolved list of domains
/// (`WeekDashboardView.visibleDomains`, ordered by Settings). The order is
/// the same across every mode — only the presentation changes.
///
/// Three modes, all free and implemented: a card grid, dense sparkline
/// rows, and a consistency heatmap. (Cross-section *correlations* used to
/// be a fourth mode here; it graduated into its own Insights destination —
/// see `InsightsDestinationView` — because it's a derived analysis of your
/// history, not a rendering of today's sections.)
///
/// The raw value is what's persisted in `UserDefaults`, so don't rename
/// existing cases — only add new ones. A persisted value that no longer
/// maps to a case (e.g. the retired `"correlations"`) falls back to `.tiles`.
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
    case .tiles:   return "Histogram"
    case .dense:   return "Sparkline"
    case .heatmap: return "Heatmap"
    }
  }

  /// One-line description shown under the picker, explaining what
  /// each mode optimizes for.
  var summary: String {
    switch self {
    case .tiles:   return "Card grid with 7-day histogram per tile. Quick-launch + ambient glance."
    case .dense:   return "Rows with today's value + sparkline. Maximum signal per scroll."
    case .heatmap: return "Rows with 90-day heatmap grid. Optimized for consistency."
    }
  }

  /// SF Symbol shown in the picker as a visual cue per mode.
  var icon: String {
    switch self {
    case .tiles:   return "square.grid.2x2"
    case .dense:   return "waveform.path"
    case .heatmap: return "square.grid.3x3.fill"
    }
  }

  /// Forward-compat flag: a future mode that returns `false` re-enables the
  /// "Coming soon" placeholder + reset button in `WeekDashboardView` without
  /// further wiring. All current modes are implemented.
  var isImplemented: Bool {
    switch self {
    case .tiles, .dense, .heatmap: return true
    }
  }
}
