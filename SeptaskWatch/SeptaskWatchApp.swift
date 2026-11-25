import SwiftUI
import UserNotifications
import WatchKit

@main
struct SeptaskWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate

  var body: some Scene {
    WindowGroup {
      TodayView()
        .tint(WatchStore.shared.accentColor)
    }
  }
}

/// Launch wiring, interactive agent-question notification category registration
/// (F1b #213), and background refresh: the Today list and the complications
/// stay current while the app is closed.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
  private static let agentQuestionCategoryID = "AGENT_QUESTION"
  private static let agentOptionActionIDs = [
    "AGENT_OPTION_0",
    "AGENT_OPTION_1",
    "AGENT_OPTION_2",
  ]

  func applicationDidFinishLaunching() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    Self.registerAgentQuestionCategory(on: center)
    MainActor.assumeIsolated {
      WatchPhoneLink.shared.start()
    }
    Self.scheduleRefresh()
  }

  private static func registerAgentQuestionCategory(on center: UNUserNotificationCenter) {
    let actions: [UNNotificationAction] = agentOptionActionIDs.enumerated().map { idx, id in
      let title = String(
        format: String(localized: "Option %lld", comment: "Watch notification option slot for agent question"),
        Int64(idx + 1)
      )
      return UNNotificationAction(identifier: id, title: title, options: [])
    }
    let category = UNNotificationCategory(
      identifier: agentQuestionCategoryID,
      actions: actions,
      intentIdentifiers: [],
      options: []
    )
    center.getNotificationCategories { existing in
      var merged = existing.filter { $0.identifier != agentQuestionCategoryID }
      merged.insert(category)
      center.setNotificationCategories(merged)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let optionIndex = Self.agentOptionActionIDs.firstIndex(of: response.actionIdentifier) else {
      return
    }
    let userInfo = response.notification.request.content.userInfo
    guard let taskID = userInfo["taskId"] as? String,
          !taskID.isEmpty,
          let options = userInfo["options"] as? [String],
          optionIndex < options.count else {
      return
    }
    let chosen = options[optionIndex]
    let turnSeq = (userInfo["turnSeq"] as? Int) ?? (userInfo["turnSeq"] as? NSNumber)?.intValue
    let step = userInfo["step"] as? String
    try? await WatchAPI.shared.answerAgentQuestion(
      taskID: taskID,
      turnSeq: turnSeq,
      step: step,
      chosen: chosen
    )
  }

  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refresh as WKApplicationRefreshBackgroundTask:
        Task { @MainActor in
          await WatchStore.shared.refreshNow(.today)
          Self.scheduleRefresh()
          refresh.setTaskCompletedWithSnapshot(false)
        }
      case let link as WKWatchConnectivityRefreshBackgroundTask:
        // The delegate receives the pending context / transfer once the
        // session is active; give it a moment, then finish.
        Task { @MainActor in
          WatchPhoneLink.shared.start()
          try? await Task.sleep(for: .seconds(3))
          link.setTaskCompletedWithSnapshot(false)
        }
      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }

  static func scheduleRefresh() {
    WKApplication.shared().scheduleBackgroundRefresh(
      withPreferredDate: Date().addingTimeInterval(30 * 60), userInfo: nil) { _ in }
  }
}
