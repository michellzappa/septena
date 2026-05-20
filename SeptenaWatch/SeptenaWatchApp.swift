import SwiftUI

@main
struct SeptenaWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate

  var body: some Scene {
    WindowGroup {
      NextWatchView()
    }
  }
}
