import XCTest

/// Captures App Store / marketing screenshots for **Septask** (the focused tasks
/// app) from the demo-seeded build. Run via `SEPTENA_APP=septask
/// appstore/capture.sh iphone69` (in septena/studio), or:
///   xcodebuild test -scheme Septask \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.0' \
///     -only-testing:SeptaskUITests
///
/// On compact iPhone there is no tab bar (ADR 0024): the list is the root of
/// one navigation stack and the app opens on Today. Navigation goes Back to
/// the list and taps a row. Only the task screens are shot. Basenames are the contract with septena/studio appstore/panels.septask.mjs:
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
    // The app opens here.
    capture(app, "tasks-today")

    // Anytime — the populated no-date list (the demo seeds several here; the
    // Upcoming list is empty in the demo, so Anytime is the stronger shot).
    openList(app, "Anytime"); dwell(); capture(app, "tasks-anytime")

    // A project board — the seeded "Q3 launch" project (DemoSeed `proj-q3`) is
    // reachable as a section header on the Today view.
    openList(app, "Today"); dwell()
    tapRow(app, "Q3 launch"); dwell()
    capture(app, "tasks-project")
  }

  // MARK: - navigation

  /// Open a list from the list root (compact iPhone): go Back until a row
  /// whose label begins with `name` is on screen, then tap it. A relabel
  /// degrades to a skip, never a failure.
  @MainActor private func openList(_ app: XCUIApplication, _ name: String) {
    let pred = NSPredicate(format: "label BEGINSWITH %@", name)
    for _ in 0..<3 {
      let row = app.buttons.matching(pred).firstMatch
      if row.waitForExistence(timeout: 2), row.isHittable { row.tap(); return }
      let back = app.navigationBars.buttons.element(boundBy: 0)
      guard back.exists, back.isHittable else { return }
      back.tap(); dwell(0.6)
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
    // The interruption monitor (EventKit permission dialogs) fires on the
    // first interaction, the first openList tap. Not a swipe: a top-of-list
    // swipe can trigger search.
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
