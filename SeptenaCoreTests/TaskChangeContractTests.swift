import Foundation
import Testing

@Suite struct TaskChangeContractTests {
  @Test func localTaskMutationCarriesDistinctChangedIDs() {
    var received: Notification?
    let center = NotificationCenter.default
    let token = center.addObserver(forName: .septenaTasksChanged, object: nil, queue: nil) {
      received = $0
    }
    defer { center.removeObserver(token) }

    TaskChange.post("task-a", "task-b", "task-a")

    #expect(received?.changedTaskIDs == Set(["task-a", "task-b"]))
  }

  @Test func unscopedTaskBatchRemainsConservative() {
    let batch = Notification(name: .septenaTasksChanged)
    #expect(batch.changedTaskIDs == nil)
  }
}
