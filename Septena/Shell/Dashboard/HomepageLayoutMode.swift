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

  /// Compact grid of progress rings — one ring per domain, filled to
  /// today's value over its target. Optimized for "am I hitting my
  /// targets." Target-less domains fall back to a week-activity ring.
  case rings

  var id: String { rawValue }

  /// Title shown in Settings → General → Homepage layout.
  var title: String {
    switch self {
    case .tiles:   return String(localized: "Histogram", comment: "Homepage layout mode")
    case .dense:   return String(localized: "Sparkline", comment: "Homepage layout mode")
    case .heatmap: return String(localized: "Heatmap", comment: "Homepage layout mode")
    case .rings:   return String(localized: "Rings", comment: "Homepage layout mode")
    }
  }

  /// One-line description shown under the picker, explaining what
  /// each mode optimizes for.
  var summary: String {
    switch self {
    case .tiles:   return String(localized: "Card grid with 7-day histogram per tile. Quick-launch + ambient glance.", comment: "Homepage layout mode description")
    case .dense:   return String(localized: "Rows with today's value + sparkline. Maximum signal per scroll.", comment: "Homepage layout mode description")
    case .heatmap: return String(localized: "Rows with 90-day heatmap grid. Optimized for consistency.", comment: "Homepage layout mode description")
    case .rings:   return String(localized: "Grid of progress rings vs today's targets. Optimized for goals.", comment: "Homepage layout mode description")
    }
  }

  /// SF Symbol shown in the picker as a visual cue per mode.
  var icon: String {
    switch self {
    case .tiles:   return "square.grid.2x2"
    case .dense:   return "waveform.path"
    case .heatmap: return "square.grid.3x3.fill"
    case .rings:   return "circle.dashed"
    }
  }

  /// Forward-compat flag: a future mode that returns `false` re-enables the
  /// "Coming soon" placeholder + reset button in `WeekDashboardView` without
  /// further wiring. All current modes are implemented.
  var isImplemented: Bool {
    switch self {
    case .tiles, .dense, .heatmap, .rings: return true
    }
  }
}
