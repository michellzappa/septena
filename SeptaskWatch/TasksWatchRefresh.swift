import WatchKit

enum TasksWatchRefresh {
  static func scheduleNext() {
    WKApplication.shared().scheduleBackgroundRefresh(
      withPreferredDate: Date().addingTimeInterval(15 * 60),
      userInfo: nil
    ) { _ in }
  }
}
