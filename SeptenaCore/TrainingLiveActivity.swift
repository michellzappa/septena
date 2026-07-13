#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

struct TrainingActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var doneCount: Int
    var totalCount: Int
    var nextExercise: String?
    var cardioMinutes: Int
    /// Total lifted volume already converted into `liftedUnit` for display —
    /// the widget extension can't read the app's unit preference, so the app
    /// resolves it when building the state. Stored data stays kg.
    var lifted: Int
    var liftedUnit: String
  }

  var sessionID: String
  var sessionType: String
  var sessionLabel: String
  var startedAt: Date
  /// SF Symbol for the session's category (`SessionKind.icon`), resolved
  /// at start so the widget shows the same session glyph as the in-app
  /// tab-bar accessory without needing the routine catalog in-process.
  var sessionIcon: String
  /// Authored Training section accent carried into the extension, which
  /// cannot read the app's `SectionTheme` directly. Optional so an activity
  /// restored across an app update still renders with the default accent.
  var accentToken: String?
}
#endif
