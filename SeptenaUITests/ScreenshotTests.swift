import XCTest

/// Captures App Store / marketing screenshots from the demo-seeded app, in two
/// homepage layouts (Sparkline + Heatmap). Run via `scripts/screenshots.sh`, or:
///   xcodebuild test -scheme Septena \
///     -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max,OS=26.0' \
///     -resultBundlePath /tmp/septena.xcresult \
///     -only-testing:SeptenaUITests/ScreenshotTests
/// Extract: xcrun xcresulttool export attachments --path /tmp/septena.xcresult --output-path <dir>
final class ScreenshotTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testCaptureMarketingScreens() throws {
    let app = XCUIApplication()
    addUIInterruptionMonitor(withDescription: "system-dialog") { alert in
      for label in ["Allow", "Allow While Using App", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
        let b = alert.buttons[label]
        if b.exists { b.tap(); return true }
      }
      return false
    }

    // Pass 1 — Sparkline layout (the default).
    launch(app, layout: "dense")
    capture(app, "01-Week")
    app.swipeUp(); dwell(); capture(app, "02-Week-scrolled")
    app.swipeDown(); dwell()
    tapTab(app, "Next");  capture(app, "03-Next")
    tapTab(app, "Tasks"); capture(app, "04-Tasks")
    tapTab(app, "Goals"); capture(app, "05-Goals")

    // Pass 2 — Heatmap layout. Terminate + relaunch reseeds the in-memory store.
    app.terminate()
    launch(app, layout: "heatmap")
    capture(app, "06-Week-heatmap")
    app.swipeUp(); dwell(); capture(app, "07-Week-heatmap-scrolled")

    // Pass 3 — Correlations layout (caffeine→sleep should surface with 90 days).
    app.terminate()
    launch(app, layout: "correlations")
    capture(app, "08-Correlations")
    app.swipeUp(); dwell(); capture(app, "09-Correlations-scrolled")
  }

  // MARK: - helpers

  @MainActor private func launch(_ app: XCUIApplication, layout: String) {
    app.launchArguments = ["-SeptenaSeed", "demo", "-SeptenaLayout", layout]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    app.swipeUp(); app.swipeDown()   // fire the interruption monitor; settle at top
    dwell()
  }

  @MainActor private func tapTab(_ app: XCUIApplication, _ label: String) {
    let tab = app.tabBars.buttons[label]
    if tab.waitForExistence(timeout: 8) { tab.tap() }
    dwell()
  }

  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Let async section loads (training/nutrition fetches) finish before capture.
  private func dwell() { Thread.sleep(forTimeInterval: 2.0) }
}
