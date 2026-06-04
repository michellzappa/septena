import XCTest

/// Drives the demo-seeded app through the key screens and saves each as a
/// screenshot attachment. Run with:
///
///   xcodebuild test -scheme Septena \
///     -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
///     -resultBundlePath /tmp/septena.xcresult \
///     -only-testing:SeptenaUITests/ScreenshotTests
///
/// Then extract the PNGs:
///   xcrun xcresulttool export attachments --path /tmp/septena.xcresult --output-path <dir>
///
/// The app launches with `-SeptenaSeed demo`, so it runs against an in-memory
/// store seeded with curated data, fully offline (no CloudKit, no real data).
final class ScreenshotTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testCaptureMarketingScreens() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-SeptenaSeed", "demo"]

    // Auto-dismiss any system permission dialog (Calendar / Health / etc.) that
    // might appear at launch, so it never lands in a screenshot.
    addUIInterruptionMonitor(withDescription: "system-dialog") { alert in
      for label in ["Allow", "Allow While Using App", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
        let button = alert.buttons[label]
        if button.exists { button.tap(); return true }
      }
      return false
    }

    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

    // Nudge the UI once so the interruption monitor fires on any pending alert,
    // then return to the top of the dashboard.
    app.swipeUp()
    app.swipeDown()

    capture(app, "01-Week")
    app.swipeUp()
    capture(app, "02-Week-scrolled")
    app.swipeUp()
    capture(app, "03-Week-correlations")

    tapTab(app, "Next")
    capture(app, "04-Next")
    tapTab(app, "Tasks")
    capture(app, "05-Tasks")
    tapTab(app, "Goals")
    capture(app, "06-Goals")
  }

  // MARK: - helpers

  @MainActor private func tapTab(_ app: XCUIApplication, _ name: String) {
    let tab = app.tabBars.buttons[name]
    if tab.waitForExistence(timeout: 8) {
      tab.tap()
    } else {
      // Fallback: some tab styles expose buttons outside a tabBar container.
      let alt = app.buttons[name]
      if alt.waitForExistence(timeout: 4) { alt.tap() }
    }
  }

  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    // Let content settle before grabbing the frame.
    _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
