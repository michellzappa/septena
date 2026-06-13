import XCTest

/// Captures App Store marketing screenshots for the **Mac** app from the
/// demo-seeded build. Run via `appstore/capture.sh mac`, or:
///   xcodebuild test -scheme SeptenaMac -destination 'platform=macOS' \
///     -only-testing:SeptenaMacUITests
///
/// Captures the app window (not the whole screen) so the raw image is just the
/// UI; the App Store render pipeline (appstore/) drops it into a Mac window
/// frame and outputs the exact 2880×1800 ASC panel. Basenames match the `mac`
/// list in appstore/panels.config.mjs (01-Week, 06-Week-heatmap, …).
final class MacScreenshotTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testCaptureMacScreens() throws {
    // The dashboard honors -SeptenaLayout (shared with iOS), so we can reach
    // the Week / heatmap / correlations variants without sidebar navigation.
    capture(layout: "dense",        named: "01-Week")
    capture(layout: "heatmap",      named: "06-Week-heatmap")
    capture(layout: "correlations", named: "08-Correlations")

    // Goals needs the sidebar; best-effort, skip if the item isn't found.
    let app = launch(layout: "dense")
    for label in ["Coach", "Goals"] {
      let item = app.buttons[label].exists ? app.buttons[label] : app.staticTexts[label]
      if item.waitForExistence(timeout: 4), item.isHittable { item.click(); break }
    }
    dwell()
    snap(app, "05-Goals")
    app.terminate()
  }

  // MARK: - helpers

  @MainActor private func launch(layout: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-SeptenaSeed", "demo", "-SeptenaLayout", layout]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    dwell()
    return app
  }

  @MainActor private func capture(layout: String, named: String) {
    let app = launch(layout: layout)
    snap(app, named)
    app.terminate()
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
