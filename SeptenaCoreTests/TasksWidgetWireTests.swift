import XCTest

final class TasksWidgetWireTests: XCTestCase {
  func testSnapshotRoundTripAndOptimisticCompletion() throws {
    let snap = TasksWidgetSnapshot.sample
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(snap)
    let decoded = try decoder.decode(TasksWidgetSnapshot.self, from: data)
    XCTAssertEqual(decoded.day, snap.day)
    XCTAssertEqual(decoded.todayList.count, 4)
    XCTAssertEqual(decoded.todayList.items.count, 4)

    // Removing "sample-4" removes it from both Today and Starred and decrements counts.
    let after = decoded.removingTask(id: "sample-4")
    XCTAssertEqual(after.todayList.count, 3)
    XCTAssertEqual(after.todayList.items.map(\.id), ["sample-1", "sample-2", "sample-3"])
    XCTAssertEqual(after.list(for: TasksWidgetListSummary.starredID)?.count, 0)
    XCTAssertTrue(after.list(for: TasksWidgetListSummary.starredID)?.items.isEmpty == true)
  }

  func testDeepLinkRoundTrip() {
    let quickAdd = TasksWidgetDeepLink.quickAdd
    XCTAssertEqual(TasksWidgetDeepLink.parse(quickAdd.url), .quickAdd)

    let listLink = TasksWidgetDeepLink.list(id: "project:abc-123")
    XCTAssertEqual(TasksWidgetDeepLink.parse(listLink.url), .list(id: "project:abc-123"))

    let taskLink = TasksWidgetDeepLink.task(id: "t-42")
    XCTAssertEqual(TasksWidgetDeepLink.parse(taskLink.url), .task(id: "t-42"))

    XCTAssertNil(TasksWidgetDeepLink.parse(URL(string: "https://septena.app")!))
  }
}
