#if os(iOS)
import ActivityKit
import Foundation

/// The floating Do of iPhone and iPad (docs/DO_SPEC.md §4.2). Shared by the app,
/// which starts it, and the widget extension, which draws it.
struct DoActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
  }

  let sessionID: String
  let startedAt: Date
  /// The registry's Do icon. The extension does not compile the registry.
  let symbol: String
}
#endif
