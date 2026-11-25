#if os(iOS)
import ActivityKit
import Foundation

/// Floats the Do when the user leaves the app (docs/DO_SPEC.md §4.2): a Live
/// Activity, on the device that shows the Do screen. It is local. An end on
/// another device clears it when this app next runs (push is #519).
@MainActor
enum DoActivity {
  /// The Do that already has its activity. A user who swipes it away does not
  /// get it back for the same Do.
  private static let shownKey = "septena.do.activitySession"

  static func update(for doing: DoState?) {
    let all = Activity<DoActivityAttributes>.activities
    for activity in all where activity.attributes.sessionID != doing?.sessionID {
      let id = activity.id
      Task { await end(id) }
    }
    let defaults = UserDefaults.standard
    guard let doing else {
      defaults.removeObject(forKey: shownKey)
      return
    }
    let content = ActivityContent(state: DoActivityAttributes.ContentState(title: doing.title),
                                  staleDate: doing.staleAt)
    if let shown = all.first(where: { $0.attributes.sessionID == doing.sessionID }) {
      guard shown.content.state != content.state || shown.content.staleDate != content.staleDate else { return }
      let id = shown.id
      Task { await set(id, content) }
      return
    }
    guard defaults.string(forKey: shownKey) != doing.sessionID,
          ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let attributes = DoActivityAttributes(sessionID: doing.sessionID, startedAt: doing.startedAt,
                                          symbol: RegistryIcons.sfSymbol(for: "action.do"))
    do {
      _ = try Activity.request(attributes: attributes, content: content)
      defaults.set(doing.sessionID, forKey: shownKey)
    } catch {
      // Not in the foreground, or too many activities: the next refresh tries again.
      SeptenaLog.info("[Do] no activity: \(error.localizedDescription)")
    }
  }

  nonisolated private static func end(_ id: String) async {
    for activity in Activity<DoActivityAttributes>.activities where activity.id == id {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }

  nonisolated private static func set(_ id: String,
                                      _ content: ActivityContent<DoActivityAttributes.ContentState>) async {
    for activity in Activity<DoActivityAttributes>.activities where activity.id == id {
      await activity.update(content)
    }
  }
}
#endif
