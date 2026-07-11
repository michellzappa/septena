import XCTest

/// iPhone counterpart to the Mac search-reveal contract. The result routes out
/// of the compact tab pane into the owning task list, then scrolls to its row.
final class TaskNavigationContractTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testQuickFindRevealsTheMatchedTask() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-SeptenaSeed", "demo", "-SeptenaTaskContractSeed",
                           "-septena.security.appLock", "NO"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

    app.typeKey("f", modifierFlags: [.command, .shift])
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.typeText("Keyboard Contract 36")

    let result = app.staticTexts["Keyboard Contract 36"].firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    result.tap()

    let target = app.descendants(matching: .any)["septena.task.row.demo-keyboard-task-35"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertTrue(target.isHittable)
  }
}
