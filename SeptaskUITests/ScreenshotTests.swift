import XCTest

/// Captures App Store / marketing screenshots for **Septask** (the focused tasks
/// app) from the demo-seeded build. Run via `SEPTENA_APP=septask
/// appstore/capture.sh iphone69`, or:
///   xcodebuild test -scheme Septask \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.0' \
///     -only-testing:SeptaskUITests
///
/// On compact iPhone Septask presents a system TabView (Tasks · Today ·
/// Upcoming · New To-Do — see SeptaskRootView.systemTabView), NOT a sidebar, so
/// navigation is tab-bar driven like Septena's ScreenshotTests. Only the task
/// screens are shot. Basenames are the contract with appstore/panels.septask.mjs:
/// tasks-today · tasks-upcoming · tasks-project. Every navigation is best-effort.
final class ScreenshotTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testCaptureTaskScreens() throws {
    let app = XCUIApplication()
    addUIInterruptionMonitor(withDescription: "system-dialog") { alert in
      for label in ["Allow", "Allow While Using App", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
        let b = alert.buttons[label]
        if b.exists { b.tap(); return true }
      }
      return false
    }

    launch(app)

    // Today — the day's list (seeded inbox tasks + project sections below).
    tapTab(app, "Today"); dwell(); capture(app, "tasks-today")

    // Anytime — the populated no-date list (the demo seeds several here; the
    // Upcoming list is empty in the demo, so Anytime is the stronger shot). The
    // Tasks tab shows the smart-list grid; the Anytime tile opens the list.
    tapTab(app, "Tasks"); dwell()
    tapRow(app, "Anytime"); dwell(); capture(app, "tasks-anytime")

    // A project board — the seeded "Q3 launch" project (DemoSeed `proj-q3`) is
    // reachable as a section header on the Today view.
    tapTab(app, "Today"); dwell()
    tapRow(app, "Q3 launch"); dwell()
    capture(app, "tasks-project")
  }

  // MARK: - navigation

  /// Tap a tab-bar item by label (compact iPhone). Falls back to a same-named
  /// button/cell so a relabel degrades to a skip, never a failure.
  @MainActor private func tapTab(_ app: XCUIApplication, _ label: String) {
    let tab = app.tabBars.buttons[label]
    if tab.waitForExistence(timeout: 4), tab.isHittable { tab.tap(); return }
    for el in [app.buttons[label], app.cells[label]] {
      if el.waitForExistence(timeout: 2), el.isHittable { el.tap(); return }
    }
  }

  /// Tap a button/cell whose label begins with `name` (a smart-list tile or a
  /// project section header), scrolling if needed. Best-effort.
  @MainActor private func tapRow(_ app: XCUIApplication, _ name: String) {
    let pred = NSPredicate(format: "label BEGINSWITH %@", name)
    let row = app.buttons.matching(pred).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 6 { app.swipeUp(); dwell(0.4); tries += 1 }
    if row.exists, row.isHittable { row.tap() }
  }

  // MARK: - helpers

  @MainActor private func launch(_ app: XCUIApplication) {
    app.launchArguments = ["-SeptenaSeed", "demo"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    // Fire the interruption monitor (EventKit permission dialogs) with a neutral
    // tab tap, not a swipe — a top-of-list swipe can trigger search.
    tapTab(app, "Tasks")
    dwell()
  }

  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func dwell(_ seconds: Double = 2.0) { Thread.sleep(forTimeInterval: seconds) }
}
