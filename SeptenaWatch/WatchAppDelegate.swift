import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refreshTask as WKApplicationRefreshBackgroundTask:
        Task {
          await WatchConnectivity.shared.fetchInBackground()
          scheduleNextRefresh()
          refreshTask.setTaskCompletedWithSnapshot(false)
        }
      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }
}

func scheduleNextRefresh() {
  WKApplication.shared().scheduleBackgroundRefresh(
    withPreferredDate: Date().addingTimeInterval(15 * 60),
    userInfo: nil
  ) { _ in }
}
