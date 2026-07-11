import XCTest

/// Navigation contract for the focused app: a task result must land on the
/// exact row, not merely open a long project/list and leave the person hunting.
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
    result.click()

    let target = app.descendants(matching: .any)["septena.task.row.demo-keyboard-task-35"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertTrue(target.isHittable)
  }
}
