import SwiftUI
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

/// Launch wiring and background refresh: the Today list and the
/// complications stay current while the app is closed.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  func applicationDidFinishLaunching() {
    MainActor.assumeIsolated {
      WatchPhoneLink.shared.start()
    }
    Self.scheduleRefresh()
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
