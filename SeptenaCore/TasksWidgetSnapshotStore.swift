import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// Shared snapshot & pending-completion persistence between the host app
// (Septask / SeptaskMac) and its WidgetKit extensions (docs/TASK_WIDGETS_SPEC.md).
//
// Uses `SeptenaAppGroup.defaults` (`group.com.septena.cloud` on iOS;
// `com.septena.shared` on macOS, avoiding the unsandboxed macOS App Data TCC
// prompt documented in `SeptenaAppGroup.swift`). Compiles into both the app
// targets and the lightweight widget extensions with zero SwiftData deps.

public enum TasksWidgetSnapshotStore {
  private static let snapshotKey = "septena.widget.tasksSnapshot.v1"
  private static let pendingCompletionsKey = "septena.widget.pendingCompletions.v1"

  private static var defaults: UserDefaults { SeptenaAppGroup.defaults }

  private static var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }

  private static var decoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }

  public static func load() -> TasksWidgetSnapshot? {
    guard let data = defaults.data(forKey: snapshotKey),
          let snapshot = try? decoder.decode(TasksWidgetSnapshot.self, from: data),
          snapshot.version == TasksWidgetSnapshot.currentVersion else {
      return nil
    }
    return snapshot
  }

  public static func save(_ snapshot: TasksWidgetSnapshot, reloadTimelines: Bool = true) {
    guard let data = try? encoder.encode(snapshot) else { return }
    // An unchanged snapshot needs no write and no timeline reload; WidgetKit
    // budgets reloads.
    guard defaults.data(forKey: snapshotKey) != data else { return }
    defaults.set(data, forKey: snapshotKey)
    if reloadTimelines {
      reloadWidgetTimelines()
    }
  }

  public static func invalidate() {
    defaults.removeObject(forKey: snapshotKey)
    defaults.removeObject(forKey: pendingCompletionsKey)
    reloadWidgetTimelines()
  }

  /// Called by `CompleteTaskWidgetIntent` when running inside the lightweight
  /// widget extension process: removes the task from the cached snapshot so the
  /// widget updates in-place immediately, queues the ID for the host app to
  /// commit via `TaskMutator`, and posts a Darwin notification so a running
  /// host app picks it up right away.
  public static func markCompletedOptimistically(taskID: String) {
    var pending = defaults.stringArray(forKey: pendingCompletionsKey) ?? []
    if !pending.contains(taskID) {
      pending.append(taskID)
      defaults.set(pending, forKey: pendingCompletionsKey)
    }
    if let current = load() {
      save(current.removingTask(id: taskID), reloadTimelines: true)
    } else {
      reloadWidgetTimelines()
    }
    postPendingCompletionDarwinNotification()
  }

  /// Atomically reads and clears queued widget completions for the host app to
  /// commit through `TaskMutator`.
  public static func takePendingCompletions() -> [String] {
    let ids = defaults.stringArray(forKey: pendingCompletionsKey) ?? []
    guard !ids.isEmpty else { return [] }
    defaults.removeObject(forKey: pendingCompletionsKey)
    return ids
  }

  public static func reloadWidgetTimelines() {
    #if canImport(WidgetKit)
    WidgetCenter.shared.reloadTimelines(ofKind: TasksWidgetKind.tasks)
    #endif
  }

  private static func postPendingCompletionDarwinNotification() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(TasksWidgetKind.pendingCompletionDarwinNotification as CFString)
    CFNotificationCenterPostNotification(center, name, nil, nil, true)
  }
}
