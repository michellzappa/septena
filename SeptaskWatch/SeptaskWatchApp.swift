import SwiftUI

@main
struct SeptaskWatchApp: App {
  @WKApplicationDelegateAdaptor(TasksWatchAppDelegate.self) var delegate

  var body: some Scene {
    WindowGroup {
      TasksWatchView()
    }
  }
}
