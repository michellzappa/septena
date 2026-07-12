import WatchKit

final class TasksWatchAppDelegate: NSObject, WKApplicationDelegate {
  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refreshTask as WKApplicationRefreshBackgroundTask:
        Task {
          await TasksWatchStore.shared.fetchInBackground()
          TasksWatchRefresh.scheduleNext()
          refreshTask.setTaskCompletedWithSnapshot(false)
        }
      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }
}
