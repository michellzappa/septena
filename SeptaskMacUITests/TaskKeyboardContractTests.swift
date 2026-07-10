import XCTest

/// Septask owns the same task surface, so it receives the same executable
/// keyboard contract as the full app. This catches target-membership drift in
/// shared task UI code.
final class TaskKeyboardContractTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testKeyboardSelectionRevealsRowsAndUsesCommandKToComplete() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-SeptenaSeed", "demo", "-SeptenaTaskContractSeed",
                           "-septena.security.appLock", "NO"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

    clickRequired(app, labels: ["Today"])
    let first = taskRow(app, id: "demo-keyboard-task-0")
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    first.click()
    for _ in 0..<35 { app.typeKey(.downArrow, modifierFlags: []) }

    let target = taskRow(app, id: "demo-keyboard-task-35")
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertEqual(target.value as? String, "selected, open")
    XCTAssertTrue(target.isHittable)

    app.typeKey(.space, modifierFlags: [])
    XCTAssertEqual(target.value as? String, "selected, open")
    app.typeKey("k", modifierFlags: .command)
    let completed = expectation(
      for: NSPredicate(format: "value == %@", "selected, completed"),
      evaluatedWith: target
    )
    wait(for: [completed], timeout: 3)
  }

  @MainActor
  private func clickRequired(_ app: XCUIApplication, labels: [String]) {
    for label in labels {
      let candidates = [app.buttons[label], app.staticTexts[label], app.cells[label]]
      for element in candidates where element.waitForExistence(timeout: 4) && element.isHittable {
        element.click()
        return
      }
    }
    XCTFail("Could not find a hittable navigation control: \(labels.joined(separator: ", "))")
  }

  private func taskRow(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any)["septena.task.row.\(id)"]
  }
}
