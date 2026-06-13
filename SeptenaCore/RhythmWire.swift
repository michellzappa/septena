import Foundation

/// Compact, `Codable` snapshot of the homepage **Wheel** — every enabled
/// section's timestamped events (and duration bands) over the trailing window,
/// reduced to `(fraction, daysAgo, colorHex)` so the widget extension can draw
/// `TimeOfDayWheel` without ever touching SwiftData.
///
/// Published alongside the "Next" payload on the same `WatchSnapshot` record
/// (default-zone field `rhythmPayload`, see `WatchSnapshotPublisher`) and read
/// back by `RhythmWidgetSnapshot`. The same single-record / O(1) read pattern
/// the watch + Next widget already use — no second record, no extra write.
///
/// The producer side (`RhythmSnapshotBuilder`) derives this from the same
/// SwiftData primitives the in-app dials use (`LoggedEvents.timed`, completed
/// tasks, intake per-kind, training sessions) — the build mirrors `RhythmData`
/// in `RhythmHomepageView.swift`; keep the two in sync.
///
/// Colors travel as authored tokens (the section / intake-kind hex), not
/// resolved `Color`s — the widget re-resolves them through `AdaptiveColor` so
/// they stay appearance-adaptive (light/dark) at render time.
public struct RhythmWire: Codable, Sendable {

  /// One plotted instant — a logged event or completed task.
  public struct Event: Codable, Sendable {
    public let id: String
    /// Time of day as 0..<1 (0 = local midnight, 0.5 = noon).
    public let fraction: Double
    /// Calendar days before the snapshot day: 0 = today (brightest).
    public let daysAgo: Int
    /// Section / intake-kind accent token (hex / `hsl(...)`). `nil` → the
    /// wheel's neutral accent.
    public let colorHex: String?

    public init(id: String, fraction: Double, daysAgo: Int, colorHex: String?) {
      self.id = id
      self.fraction = fraction
      self.daysAgo = daysAgo
      self.colorHex = colorHex
    }
  }

  /// One plotted duration — a training session (`opaque`), drawn as an arc.
  public struct Band: Codable, Sendable {
    public let id: String
    /// Start of the arc as 0..<1.
    public let start: Double
    /// End of the arc as 0..<1; may be < `start` (wraps midnight).
    public let end: Double
    public let daysAgo: Int
    public let colorHex: String?
    /// Solid + sheen (training) vs. soft wash; mirrors `TimeOfDayWheel.Band`.
    public let opaque: Bool
    /// Half-weight stroke (calendar-style thin pill).
    public let thin: Bool

    public init(id: String, start: Double, end: Double, daysAgo: Int,
                colorHex: String?, opaque: Bool = false, thin: Bool = false) {
      self.id = id
      self.start = start
      self.end = end
      self.daysAgo = daysAgo
      self.colorHex = colorHex
      self.opaque = opaque
      self.thin = thin
    }
  }

  /// A section that contributed at least one event/band this window — drives
  /// the widget's color legend (dot + name).
  public struct Legend: Codable, Sendable {
    public let key: String
    public let label: String
    public let colorHex: String

    public init(key: String, label: String, colorHex: String) {
      self.key = key
      self.label = label
      self.colorHex = colorHex
    }
  }

  /// How many trailing days the recency fade spans (today + previous N−1).
  public let windowDays: Int
  public let events: [Event]
  public let bands: [Band]
  public let legend: [Legend]

  public init(windowDays: Int, events: [Event], bands: [Band], legend: [Legend]) {
    self.windowDays = windowDays
    self.events = events
    self.bands = bands
    self.legend = legend
  }

  /// Empty snapshot — nothing timed logged in the window.
  public static let empty = RhythmWire(windowDays: 7, events: [], bands: [], legend: [])
}
