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
}
#endif
