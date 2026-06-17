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
/// `appstore/`, and the SAME names the marketing site uses (docs/MESSAGING.md
/// §4) so one capture serves both. Each name is the contract:
/// `appstore/panels.config.mjs` references shots by these exact basenames.
/// Current marketing-panel mapping (→ iphone69):
///   hook         → overview      (all-in-one hero)
///   week         → week-heatmap  (glanceable seven days)
///   correlations → insights      (cross-section insight)
///   sections     → sections      (the enable/hide editor)
///   ai           → ai            (bring your own AI)
///   privacy/close → no shot (statement panels)
/// The rest (overview-scrolled, next, tasks, goals, …-scrolled, and the section
/// sheets) are a bench the viz can swap in without a re-capture.
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

    // Semantic capture names (shared with ../septena-site, per docs/MESSAGING.md
    // §4) — one capture serves both the site and the App Store render.

    // Pass 1 — Sparkline layout (the default).
    launch(app, layout: "dense")
    capture(app, "overview")
    app.swipeUp(); dwell(); capture(app, "overview-scrolled")
    app.swipeDown(); dwell()
    tapTab(app, "Next");  capture(app, "next")
    // Tasks — two shots:
    //  • "tasks": the sidebar home (smart-list grid + the seeded Areas /
    //    Projects sections below it).
    //  • "tasks-today": the Today view, which renders the Inbox / triage band
    //    of loose captures above today's ratified list.
    tapTab(app, "Tasks"); dwell(); capture(app, "tasks")
    tapFirst(app, ["Today"]); dwell(); capture(app, "tasks-today")
    // "Goals" is not a tab — goals live in the Coach tab. Capture the coaches
    // landing as "coach", then scroll to the Goals band for "goals".
    // Coach landing → coaches band ("coach"), the reflective Exercises band
    // mid-scroll ("coach-exercises"), then the Goals band at the bottom ("goals").
    tapTab(app, "Coach"); capture(app, "coach")
    app.swipeUp(); dwell(0.4); capture(app, "coach-exercises")
    app.swipeUp(); dwell(); capture(app, "goals")

    // Pass 2 — Heatmap layout. Terminate + relaunch reseeds the in-memory store.
    app.terminate()
    launch(app, layout: "heatmap")
    capture(app, "week-heatmap")
    app.swipeUp(); dwell(); capture(app, "week-heatmap-scrolled")

    // Pass 3 — Correlations: the homepage in correlations layout, then the REAL
    // Insights explorer (correlation cards) opened via the "More" (⋯) menu.
    // Demo data surfaces caffeine→sleep at 90 days.
    app.terminate()
    launch(app, layout: "correlations")
    capture(app, "insights")
    app.swipeUp(); dwell(); capture(app, "insights-scrolled")
    app.swipeDown(); dwell()
    captureInsights(app)

    // Pass 3b — the other two Week presentations, so the site can show all four
    // layouts. `rings` = progress-ring grid; `histogram` aliases to `tiles`.
    app.terminate()
    launch(app, layout: "rings")
    capture(app, "week-rings")
    app.terminate()
    launch(app, layout: "histogram")
    capture(app, "week-histogram")

    // Pass 4 — section detail sheets (dense layout so the rows are tappable).
    // A colorful bench the viz can swap into the breadth panel. Names match the
    // site's section vocabulary (Training → "exercise").
    app.terminate()
    launch(app, layout: "dense")
    // Full per-section coverage — every section the demo enables, so the site
    // (one shot per app area, docs/MESSAGING.md §4) and the App Store both draw
    // from one capture set. Names match the site's vocabulary.
    captureSection(app, "Nutrition", "nutrition", short: true)
    captureSection(app, "Training", "training")
    captureSection(app, "Sleep", "sleep")
    captureSection(app, "Mood", "mood", short: true)
    captureSection(app, "Body", "body")
    captureSection(app, "Habits", "habits", short: true)
    captureSection(app, "Hydration", "hydration")
    captureSection(app, "Intake", "intake", short: true)
    captureSection(app, "Chores", "chores")
    captureSection(app, "Supplements", "supplements", short: true)
    captureSection(app, "Groceries", "groceries")
    captureSection(app, "Gut", "gut", short: true)
    captureSection(app, "Activity", "activity")
    captureSection(app, "Symptoms", "symptoms", short: true)
    captureSection(app, "Medications", "medications", short: true)

    // Settings editors — best-effort navigation; skip cleanly if labels differ.
    captureSettingsSections(app, "sections")   // proves "turn on only what matters"
    captureSettingsRow(app, ["AI", "Intelligence", "MCP"], "ai")  // proves "bring your own AI"

    // Pass 5 — cornerstone deep screens. The marketing site wants 3–4 shots for
    // each of the three cornerstone sections (Tasks, Training, Nutrition), so
    // these go past the single section-detail capture into the views that show
    // the section's depth: a project board, a task composer, the Patterns charts
    // (progression / strength / macros), and a meal editor. All best-effort —
    // every navigation guards on existence/hittability and RETURNS silently on a
    // miss, so a relabelled control degrades to a skipped shot, never a failed run.
    // (Demo-seeded labels: project "Q3 launch" + task "Draft the Q3 plan" from
    // DemoSeed.swift; the Log⇄Patterns toggle is a single button whose a11y label
    // is "Show patterns" while in Log mode — see SectionDrawer.DrawerModeToggle.)
    // Relaunch first: Pass 4 ends inside Settings, whose modal can cover the tab
    // bar and make every tab-based navigation below silently miss. A fresh launch
    // returns us to the dashboard/tabs.
    app.terminate()
    launch(app, layout: "dense")
    captureTasksProject(app)   // "tasks-project"
    // captureTasksEditor skipped: opening the composer hangs the app's main
    // thread (~30s) under UI test, which fails the whole run. The project board
    // + Today view already cover Tasks; revisit if the composer hang is fixed.
    captureTrainingPatterns(app)   // "training-progression" + "training-strength"
    captureNutritionPatterns(app)  // "nutrition-macros"
    captureNutritionMeal(app)      // "nutrition-meal"
  }

  /// Tasks cornerstone, shot 1: a project board. From the Tasks-tab sidebar,
  /// open the seeded "Q3 launch" project (DemoSeed `proj-q3`) and snapshot it,
  /// then return to the tab root. Best-effort: returns silently if the row or
  /// project view can't be reached.
  @MainActor private func captureTasksProject(_ app: XCUIApplication) {
    tapTab(app, "Tasks"); dwell(0.6)
    // Specific-type query (like captureSection) — never descendants(.any), which
    // walks the whole tree and times out.
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Q3 launch")).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 6 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }
    row.tap(); dwell()
    capture(app, "tasks-project")
    // Back out: a Back button on compact (push) or just re-select the tab.
    let back = app.navigationBars.buttons.element(boundBy: 0)
    if back.exists, back.isHittable { back.tap() } else { tapTab(app, "Tasks") }
    dwell(0.5)
  }

  /// Tasks cornerstone, shot 2: the task composer. From the Tasks Today view,
  /// tap the seeded "Draft the Q3 plan" row to open the editor sheet, snapshot
  /// it, then dismiss. Best-effort throughout.
  @MainActor private func captureTasksEditor(_ app: XCUIApplication) {
    tapTab(app, "Tasks"); dwell(0.5)
    tapFirst(app, ["Today"]); dwell(0.6)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Draft the Q3 plan")).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 6 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }
    row.tap(); dwell()
    capture(app, "tasks-editor")
    // Dismiss the composer sheet: an explicit Cancel/Done if present, else swipe down.
    for label in ["Cancel", "Done"] {
      let b = app.buttons[label]
      if b.exists, b.isHittable { b.tap(); dwell(0.5); return }
    }
    app.swipeDown(); dwell(0.5)
  }

  /// Flip a Log/Patterns drawer into Patterns. The toggle is a single button
  /// (SectionDrawer.DrawerModeToggle) whose a11y label reads "Show patterns"
  /// while the drawer is in Log mode and "Show log" once in Patterns — so we tap
  /// "Show patterns" only. Best-effort: returns silently if absent (single-mode
  /// drawers have no toggle, or it's already in Patterns).
  @MainActor private func togglePatterns(_ app: XCUIApplication) {
    let toggle = app.buttons["Show patterns"]
    if toggle.waitForExistence(timeout: 3), toggle.isHittable { toggle.tap(); dwell() }
  }

  /// Training cornerstone, shots 2+3: the Patterns charts. Open the Training
  /// drawer from the Week dashboard, flip to Patterns, snapshot the per-exercise
  /// progression chart ("training-progression"), swipe up once to the strength-
  /// volume / hard-sets chart ("training-strength"), then dismiss. Best-effort.
  @MainActor private func captureTrainingPatterns(_ app: XCUIApplication) {
    tapTab(app, "Week"); dwell(0.6)                    // drawers open from the Week dashboard
    for _ in 0..<6 { app.swipeDown() }                 // reset to the top
    dwell(0.5)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Training")).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }
    row.tap(); dwell()
    togglePatterns(app)
    capture(app, "training-progression")
    app.swipeUp(); dwell()
    capture(app, "training-strength")
    dismissDrawer(app, short: false)
  }

  /// Nutrition cornerstone, shot 2: the macro tiles. Open the Nutrition drawer,
  /// flip to Patterns, snapshot the macro tiles ("nutrition-macros"), dismiss.
  /// Best-effort.
  @MainActor private func captureNutritionPatterns(_ app: XCUIApplication) {
    tapTab(app, "Week"); dwell(0.6)
    for _ in 0..<6 { app.swipeDown() }
    dwell(0.5)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Nutrition")).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }
    row.tap(); dwell()
    togglePatterns(app)
    capture(app, "nutrition-macros")
    dismissDrawer(app, short: true)
  }

  /// Nutrition cornerstone, shot 3: a meal editor. Open the Nutrition drawer in
  /// its default Log mode and tap a seeded meal row to open the edit sheet. The
  /// demo seeds three meals/day with RANDOMIZED food strings (DemoSeed
  /// `seedNutrition`), so we target the fixed candidate strings first, then fall
  /// back to the meal emoji, then the first cell — whichever lands. Snapshot
  /// ("nutrition-meal"), dismiss. Best-effort.
  @MainActor private func captureNutritionMeal(_ app: XCUIApplication) {
    tapTab(app, "Week"); dwell(0.6)
    for _ in 0..<6 { app.swipeDown() }
    dwell(0.5)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Nutrition")).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }
    row.tap(); dwell()                                 // Nutrition opens in Log mode
    // The seeded meal food strings are randomized, so target the meal rows by
    // position (cells) rather than a slow whole-tree label query. Tap the first
    // hittable cell that opens an edit sheet.
    var opened = false
    for i in 0..<5 {
      let cell = app.cells.element(boundBy: i)
      if cell.exists, cell.isHittable { cell.tap(); opened = true; break }
    }
    guard opened else { dismissDrawer(app, short: true); return }
    dwell()
    capture(app, "nutrition-meal")
    // Dismiss the edit sheet, then the drawer.
    for label in ["Cancel", "Done"] {
      let b = app.buttons[label]
      if b.exists, b.isHittable { b.tap(); dwell(0.5); break }
    }
    app.swipeDown(); dwell(0.4)
    dismissDrawer(app, short: true)
  }

  @MainActor private func captureSettingsSections(_ app: XCUIApplication, _ shot: String) {
    captureSettingsRow(app, ["Sections"], shot)
  }

  /// Open Settings, tap the first matching row label, snapshot it. Best-effort:
  /// returns silently if Settings or the row can't be reached.
  @MainActor private func captureSettingsRow(_ app: XCUIApplication, _ labels: [String], _ shot: String) {
    for label in ["Settings", "More", "gear"] {
      let b = app.tabBars.buttons[label].exists ? app.tabBars.buttons[label] : app.buttons[label]
      if b.waitForExistence(timeout: 3), b.isHittable { b.tap(); dwell(0.6); break }
    }
    for name in labels {
      let row = app.buttons[name].exists ? app.buttons[name]
              : app.staticTexts[name].exists ? app.staticTexts[name]
              : app.cells[name]
      var tries = 0
      while !(row.exists && row.isHittable) && tries < 4 { app.swipeUp(); dwell(0.4); tries += 1 }
      if row.exists, row.isHittable { row.tap(); dwell(); capture(app, shot); return }
    }
  }

  /// Open the Insights explorer (the real correlation cards) from the Week
  /// dashboard's "More" (⋯) menu → Insights, snapshot it as "correlations",
  /// then dismiss. Best-effort: returns silently if the menu can't be reached.
  @MainActor private func captureInsights(_ app: XCUIApplication) {
    for _ in 0..<6 { app.swipeDown() }           // reset to the top of the dashboard
    dwell(0.4)
    let more = app.buttons["More"]
    guard more.waitForExistence(timeout: 4), more.isHittable else { return }
    more.tap(); dwell(0.6)
    let insights = app.buttons["Insights"]
    guard insights.waitForExistence(timeout: 3), insights.isHittable else { return }
    insights.tap(); dwell()                      // the explorer opens (sheet / push)
    capture(app, "correlations")
    dismissDrawer(app, short: false)
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

  /// Tap the first hittable element matching any of `labels` (button, cell, or
  /// static text). Best-effort: returns silently if none is reachable, so a
  /// renamed control degrades to capturing wherever we are rather than failing.
  @MainActor private func tapFirst(_ app: XCUIApplication, _ labels: [String]) {
    for label in labels {
      for el in [app.buttons[label], app.cells[label], app.staticTexts[label]] {
        if el.waitForExistence(timeout: 2), el.isHittable { el.tap(); return }
      }
    }
  }

  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Open a section's detail sheet from the Week list, snapshot it, dismiss.
  /// Rows carry a compound a11y label that starts with the section name. Pass
  /// `short: true` for content-light sections (gut, caffeine, nutrition) that
  /// the app keeps at the medium detent in demo builds — the dismissal differs.
  @MainActor private func captureSection(_ app: XCUIApplication, _ name: String, _ shot: String,
                                         short: Bool = false) {
    for _ in 0..<6 { app.swipeDown() }                 // reset to the top
    dwell(0.5)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    var tries = 0
    while !(row.exists && row.isHittable) && tries < 8 { app.swipeUp(); dwell(0.4); tries += 1 }
    guard row.exists, row.isHittable else { return }   // skip rather than fail
    row.tap()
    dwell()
    capture(app, shot)
    dismissDrawer(app, short: short)
  }

  /// Dismiss the section drawer. The two demo detents need different gestures:
  /// a full-height `.large` drawer's grabber sits at the top of the screen, so
  /// drag it straight down (the canonical dismissal). A `.medium` drawer covers
  /// only the bottom half, so its top is mid-screen and a top-edge drag would
  /// miss — tap the dashboard backdrop above it instead, which fires the
  /// drawer's tap-away dismissal. Getting this wrong leaves the sheet open over
  /// the next section's row and cascades into skipped captures.
  @MainActor private func dismissDrawer(_ app: XCUIApplication, short: Bool) {
    if short {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)).tap()
    } else {
      let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07))
      let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
      grabber.press(forDuration: 0.1, thenDragTo: bottom)
    }
    dwell(0.8)
  }

  /// Let async section loads (training/nutrition fetches) finish before capture.
  private func dwell(_ seconds: Double = 2.0) { Thread.sleep(forTimeInterval: seconds) }
}
