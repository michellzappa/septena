import XCTest

/// Behavioral guardrails for the macOS task surface. Screenshot tests protect
/// appearance; this test protects the interaction contract a screenshot cannot
/// see: keyboard traversal must reveal rows, Space must not mutate, and ⌘K is
/// the explicit completion command.
final class TaskKeyboardContractTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testKeyboardSelectionRevealsRowsAndUsesCommandKToComplete() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-SeptenaSeed", "demo", "-SeptenaTaskContractSeed",
                           "-septena.security.appLock", "NO"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

    clickRequired(app, labels: ["Tasks"])
    clickRequired(app, labels: ["Today"])

    let first = taskRow(app, id: "demo-keyboard-task-0")
    XCTAssertTrue(first.waitForExistence(timeout: 10), "The dense task-contract seed should render Today rows.")
    first.click()

    // The target begins well below the viewport. Starting from an explicit
    // click makes this independent of Inbox rows that precede the test data.
    for _ in 0..<35 { app.typeKey(.downArrow, modifierFlags: []) }

    let target = taskRow(app, id: "demo-keyboard-task-35")
    XCTAssertTrue(target.waitForExistence(timeout: 5), "Keyboard selection should materialize an off-screen row.")
    XCTAssertEqual(target.value as? String, "selected, open")
    XCTAssertTrue(target.isHittable, "The selected row must be visible, not merely realized off-screen.")

    app.typeKey(.space, modifierFlags: [])
    XCTAssertEqual(target.value as? String, "selected, open", "Space must not complete a selected task.")

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
