import Foundation
import SwiftData

// "Which tasks point at this?" (docs/TASK_REFERENCES_SPEC.md §6.4). Quick Find,
// the open task's "Also in" chips and the Share extension's index read it here.
// A task points at an item when it has a reference to it, or when its title or
// notes hold a link to it: every spelling of a link gives one key.

@MainActor
enum TaskRefLookup {
  /// Another task that points at the same item.
  struct Other: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
  }

  // MARK: Quick Find

  /// The tasks that point at the link, references first. Nil when the text is
  /// not one link.
  static func taskIDs(forLink text: String, in context: ModelContext) -> [String]? {
    let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !link.contains(where: \.isWhitespace), let url = URL(string: link),
          TaskRefResolver.canOpen(url), let parsed = TaskRefCore.parse(link) else { return nil }
    let target = Target(keys: pair(parsed.key))
    let referenced = referencingTaskIDs(keys: target.keys, in: context)
    var first: [String] = [], second: [String] = []
    for task in LocalCache.liveAggregateEntities(in: context) {
      if referenced.contains(task.id) {
        first.append(task.id)
      } else if target.isMentioned(by: task) {
        second.append(task.id)
      }
    }
    return first + second
  }

  /// What a text search reads of each task's references: title, subtitle and
  /// the id part of the key ("owner/repo#7").
  static func searchTexts(in context: ModelContext) -> [String: String] {
    Dictionary(grouping: StoreHealth.fetch(context, FetchDescriptor<TaskRefEntity>()).map { TaskRef($0) },
               by: \.taskId)
      .mapValues { refs in
        refs.flatMap { [$0.snapshot.title, $0.snapshot.subtitle, $0.keyID] }
          .compactMap { $0 }.joined(separator: " ")
      }
  }

  // MARK: The open task

  /// The other open tasks that point at what this task points at, or at the
  /// task itself. A completed task is left out: each past occurrence of a
  /// repeating task has the same references.
  static func alsoIn(taskID: String, title: String, notes: String?, in context: ModelContext) -> [Other] {
    let refs = LocalCache.taskRefs(forTaskID: taskID, in: context)
    let links = TaskRefRows.offers(title: title, notes: notes, existing: [])
    let shared = Set((refs.map(\.key) + links.map(\.key)).flatMap { pair($0) })
    let target = Target(keys: shared)
    let referenced = referencingTaskIDs(keys: shared.union(["task:\(taskID)"]), in: context)
      .subtracting([taskID])
    guard !referenced.isEmpty || !target.needles.isEmpty else { return [] }
    var first: [Other] = [], second: [Other] = []
    for task in LocalCache.liveAggregateEntities(in: context)
    where task.status == .open && task.id != taskID && !task.title.isEmpty {
      if referenced.contains(task.id) {
        first.append(Other(id: task.id, title: task.title))
      } else if target.isMentioned(by: task) {
        second.append(Other(id: task.id, title: task.title))
      }
    }
    return Array((first + second).prefix(RegistryTaskReferences.maxSuggestions))
  }

  // MARK: Share extension

  /// Every link of every open task, for the Share extension.
  static func shareIndex(in context: ModelContext) -> SharedTaskLinkIndex {
    let refs = Dictionary(grouping: StoreHealth.fetch(context, FetchDescriptor<TaskRefEntity>()), by: \.taskID)
    let entries = LocalCache.liveAggregateEntities(in: context)
      .filter { $0.status == .open && !$0.title.isEmpty }
      .compactMap { task -> SharedTaskLinkIndex.Entry? in
        let links = TaskRefRows.offers(title: task.title, notes: task.notes, existing: [])
        let keys = Set((refs[task.id] ?? []).map(\.key) + links.map(\.key))
        return keys.isEmpty ? nil : .init(title: task.title, keys: keys.sorted())
      }
    return SharedTaskLinkIndex(heading: RegistryTaskReferences.alreadyTaskTitle, entries: entries)
  }

  // MARK: Parts

  private struct Target {
    let keys: Set<String>
    /// A text without one of these holds none of the keys, so most texts need
    /// no link detection.
    let needles: [String]

    init(keys: Set<String>) {
      self.keys = keys
      needles = Array(Set(keys.compactMap(TaskRefLookup.needle)))
    }

    func isMentioned(by task: TaskEntity) -> Bool {
      let texts = [task.title, task.notes ?? ""].filter { text in
        needles.contains { text.range(of: $0, options: .caseInsensitive) != nil }
      }
      return texts.contains { text in
        TaskRefRows.linkTexts(in: text).contains { link in
          TaskRefCore.parse(link).map { keys.contains($0.key) } ?? false
        }
      }
    }
  }

  /// A part of every link that gives this key.
  private nonisolated static func needle(_ key: String) -> String? {
    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "issue": return "github.com"
    case "email", "thread": return "message:"
    case "url": return URLComponents(string: parts[1])?.host
    case "door": return parts[1].split(separator: "|").first.map(String.init)
    case "task": return parts[1].contains("/") ? parts[1].split(separator: "/").first.map(String.init) : nil
    default: return nil
    }
  }

  /// A mail and the thread it starts share an id: a link to one finds both.
  private nonisolated static func pair(_ key: String) -> Set<String> {
    for (a, b) in [("email:", "thread:"), ("thread:", "email:")] where key.hasPrefix(a) {
      return [key, b + key.dropFirst(a.count)]
    }
    return [key]
  }

  private static func referencingTaskIDs(keys: Set<String>, in context: ModelContext) -> Set<String> {
    let wanted = Array(keys)
    return Set(StoreHealth.fetch(context, FetchDescriptor<TaskRefEntity>(
      predicate: #Predicate { wanted.contains($0.key) })).map(\.taskID))
  }
}
