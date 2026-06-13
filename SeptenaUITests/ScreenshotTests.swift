import XCTest

/// Captures App Store / marketing screenshots from the demo-seeded app. Run via
/// `scripts/screenshots.sh`, or:
///   xcodebuild test -scheme Septena \
///     -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max,OS=26.0' \
///     -resultBundlePath /tmp/septena.xcresult \
///     -only-testing:SeptenaUITests/ScreenshotTests
/// Extract: xcrun xcresulttool export attachments --path /tmp/septena.xcresult --output-path <dir>
///
/// These are the raw material for the App Store viz/render pipeline in
/// `appstore/`. Each capture's name is the contract: `appstore/panels.config.mjs`
/// references shots by these exact basenames (e.g. `01-Week`, `08-Correlations`).
/// If you rename a capture here, update the matching `shot.src` there. Current
/// marketing-panel mapping (appstore/panels.config.mjs → iphone69):
///   hook         → 01-Week            (all-in-one hero)
///   week         → 06-Week-heatmap    (glanceable seven days)
///   correlations → 08-Correlations    (cross-section insight)
///   sections     → 17-Sections        (the enable/hide editor)
///   privacy/close → no shot (statement panels)
/// The remaining captures (02/03/04/05/07/09 and the section sheets 10–16) are
/// kept as a bench the viz can swap in without a re-capture.
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

    // Pass 4 — section detail sheets (dense layout so the rows are tappable).
    // These give the viz a colorful bench of section shots to swap into the
    // breadth panel. Ordered so the most marketing-friendly come first.
    app.terminate()
    launch(app, layout: "dense")
    captureSection(app, "Nutrition", "10-Nutrition")
    captureSection(app, "Training", "11-Training")
    captureSection(app, "Sleep", "12-Sleep")
    captureSection(app, "Mood", "13-Mood")
    captureSection(app, "Body", "14-Body")
    captureSection(app, "Habits", "15-Habits")
    captureSection(app, "Hydration", "16-Hydration")

    // The sections editor (Settings → Sections) — proves the "turn on only what
    // matters" panel. Best-effort navigation; skips cleanly if labels differ.
    captureSettingsSections(app, "17-Sections")
  }

  /// Open Settings → Sections, snapshot the enable/hide list, return to root.
  @MainActor private func captureSettingsSections(_ app: XCUIApplication, _ shot: String) {
    for label in ["Settings", "More", "gear"] {
      let b = app.tabBars.buttons[label].exists ? app.tabBars.buttons[label] : app.buttons[label]
      if b.waitForExistence(timeout: 3), b.isHittable { b.tap(); dwell(0.6); break }
    }
    let row = app.buttons["Sections"].exists ? app.buttons["Sections"]
            : app.staticTexts["Sections"].exists ? app.staticTexts["Sections"]
            : app.cells["Sections"]
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 6 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }
    row.tap(); dwell()
    capture(app, shot)
  }

  // MARK: - helpers

  @MainActor private func launch(_ app: XCUIApplication, layout: String) {
    app.launchArguments = ["-SeptenaSeed", "demo", "-SeptenaLayout", layout]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    app.swipeUp(); app.swipeDown()   // fire the interruption monitor; settle at top
    dwell()
  }

  /// iPhone shows a tab bar; iPad shows a NavigationSplitView sidebar. Try the
  /// tab first, then fall back to a sidebar/list item with the same label, so
  /// the one test drives both idioms.
  @MainActor private func tapTab(_ app: XCUIApplication, _ label: String) {
    let tab = app.tabBars.buttons[label]
    if tab.waitForExistence(timeout: 4), tab.isHittable { tab.tap(); dwell(); return }
    for el in [app.buttons[label], app.cells[label], app.staticTexts[label]] {
      if el.waitForExistence(timeout: 2), el.isHittable { el.tap(); dwell(); return }
    }
    dwell()
  }

  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Open a section's detail sheet from the Week list, snapshot it, dismiss.
  /// Rows carry a compound a11y label that starts with the section name.
  @MainActor private func captureSection(_ app: XCUIApplication, _ name: String, _ shot: String) {
    for _ in 0..<6 { app.swipeDown() }                 // reset to the top
    dwell(0.5)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }   // skip rather than fail
    row.tap()
    dwell()
    capture(app, shot)
    app.swipeDown(); app.swipeDown()                   // dismiss the sheet
    dwell(0.5)
  }

  /// Let async section loads (training/nutrition fetches) finish before capture.
  private func dwell(_ seconds: Double = 2.0) { Thread.sleep(forTimeInterval: seconds) }
}
