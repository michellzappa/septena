import XCTest

/// Captures App Store marketing screenshots for the **Septask Mac** app from the
/// demo-seeded build. Run via `SEPTENA_APP=septask appstore/capture.sh mac`, or:
///   xcodebuild test -scheme SeptaskMac -destination 'platform=macOS' \
///     -only-testing:SeptaskMacUITests
///
/// Like the iOS Septask capture, this is a small cousin of Septena's Mac test:
/// same demo seed, same window-capture mechanism, but sidebar-only task
/// navigation. Snapshots the app window (not the whole screen) so the render
/// pipeline (appstore/) drops it into a Mac window frame at 2880×1800. Basenames
/// match panels.septask.mjs (mac): tasks-today · tasks-project · tasks-upcoming.
final class MacScreenshotTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testCaptureMacTaskScreens() throws {
    let app = launch()

    // Today — the landing task list.
    click(app, ["Today"]); dwell()
    snap(app, "tasks-today")

    // Upcoming — the scheduled-ahead list.
    click(app, ["Upcoming"]); dwell()
    snap(app, "tasks-upcoming")

    // A project board — seeded "Q3 launch" (DemoSeed `proj-q3`).
    clickPrefix(app, "Q3 launch"); dwell()
    snap(app, "tasks-project")

    app.terminate()
  }

  // MARK: - navigation

  @MainActor private func click(_ app: XCUIApplication, _ labels: [String]) {
    for label in labels {
      let el = app.buttons[label].exists ? app.buttons[label]
             : app.staticTexts[label].exists ? app.staticTexts[label]
             : app.cells[label]
      if el.waitForExistence(timeout: 4), el.isHittable { el.click(); return }
    }
  }

  @MainActor private func clickPrefix(_ app: XCUIApplication, _ name: String) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    if row.waitForExistence(timeout: 4), row.isHittable { row.click() }
  }

  // MARK: - helpers

  @MainActor private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-SeptenaSeed", "demo"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    dwell()
    return app
  }

  /// Snapshot the frontmost window if present, else the whole screen.
  @MainActor private func snap(_ app: XCUIApplication, _ name: String) {
    let window = app.windows.firstMatch
    let shot = window.exists ? window.screenshot() : XCUIScreen.main.screenshot()
    let a = XCTAttachment(screenshot: shot)
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }

  private func dwell(_ s: Double = 2.0) { Thread.sleep(forTimeInterval: s) }
}
