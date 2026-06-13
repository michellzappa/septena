#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

struct TrainingActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var doneCount: Int
    var totalCount: Int
    var nextExercise: String?
    var cardioMinutes: Int
    var liftedKg: Int
  }

  var sessionID: String
  var sessionType: String
  var sessionLabel: String
  var startedAt: Date
  /// SF Symbol for the session's category (`SessionKind.icon`), resolved
  /// at start so the widget shows the same session glyph as the in-app
  /// tab-bar accessory without needing the routine catalog in-process.
  var sessionIcon: String
}
#endif
