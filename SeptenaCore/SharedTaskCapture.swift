import Foundation
#if !SHARE_EXTENSION
import SwiftData
#endif

/// Versioned hand-off written by a Share extension and consumed by its app.
/// Attachments can later be added as stable relative references without
/// changing this text/URL capture path.
struct SharedTaskCapture: Codable, Identifiable, Sendable {
  static let currentSchemaVersion = 1
  let schemaVersion: Int
  let id: UUID
  let createdAt: Date
  var title: String
  var notes: String
  var today: Bool
  var sourceURL: URL?

  init(id: UUID = UUID(), createdAt: Date = .now, title: String,
       notes: String = "", today: Bool = false, sourceURL: URL? = nil) {
    schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.createdAt = createdAt
    self.title = title
    self.notes = notes
    self.today = today
    self.sourceURL = sourceURL
  }
}

/// The links of the open tasks, written by the app and read by the Share
/// extension, which cannot open the store (docs/TASK_REFERENCES_SPEC.md §6.4).
struct SharedTaskLinkIndex: Codable, Sendable {
  struct Entry: Codable, Sendable {
    let title: String
    let keys: [String]
  }

  /// "Already a task", in the app's language.
  let heading: String
  let entries: [Entry]
}

/// The raw value is a folder name in the app group, so it stays `septask`.
enum SharedTaskCaptureDestination: String, Sendable { case septask }

enum SharedTaskCaptureQueue {
  private static let appGroup = "group.com.septena.cloud"

  static func enqueue(_ capture: SharedTaskCapture,
                      for destination: SharedTaskCaptureDestination) throws {
    let directory = try directory(for: destination, leaf: "pending")
    let finalURL = directory.appendingPathComponent("\(capture.id.uuidString).json")
    let temporaryURL = directory.appendingPathComponent(".\(capture.id.uuidString).tmp")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(capture).write(to: temporaryURL, options: .atomic)
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
  }

  /// Moving before decoding claims the item against overlapping scene wakes.
  static func claimAll(for destination: SharedTaskCaptureDestination) -> [(URL, SharedTaskCapture)] {
    guard let pending = try? directory(for: destination, leaf: "pending"),
          let claimed = try? directory(for: destination, leaf: "claimed") else { return [] }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: pending, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return files.compactMap { source in
      guard source.pathExtension == "json" else { return nil }
      let target = claimed.appendingPathComponent(source.lastPathComponent)
      do {
        try FileManager.default.moveItem(at: source, to: target)
        let capture = try decoder.decode(SharedTaskCapture.self, from: Data(contentsOf: target))
        guard capture.schemaVersion <= SharedTaskCapture.currentSchemaVersion else { return nil }
        return (target, capture)
      } catch { return nil }
    }
  }

  // MARK: Links of the open tasks

  private static let linkIndexName = "links.json"

  static func linkIndex(for destination: SharedTaskCaptureDestination) -> SharedTaskLinkIndex? {
    guard let url = try? directory(for: destination, leaf: "index").appendingPathComponent(linkIndexName),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SharedTaskLinkIndex.self, from: data)
  }

  /// Nil removes the index.
  static func saveLinkIndex(_ index: SharedTaskLinkIndex?, for destination: SharedTaskCaptureDestination) {
    guard let url = try? directory(for: destination, leaf: "index").appendingPathComponent(linkIndexName) else { return }
    guard let index, let data = try? JSONEncoder().encode(index) else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  static func finish(_ claimedURL: URL) { try? FileManager.default.removeItem(at: claimedURL) }

  private static func directory(for destination: SharedTaskCaptureDestination,
                                leaf: String) throws -> URL {
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup) else { throw CocoaError(.fileNoSuchFile) }
    let url = root.appendingPathComponent("SharedTaskCaptures", isDirectory: true)
      .appendingPathComponent(destination.rawValue, isDirectory: true)
      .appendingPathComponent(leaf, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

#if !SHARE_EXTENSION
@MainActor
enum SharedTaskCaptureImporter {
  static func importPending(using mutator: TaskMutator) {
    // No Mac target embeds a share extension (neither SeptenaMac nor
    // SeptaskMac lists one in project.yml), so nothing on a Mac ever writes
    // this queue — and reading it costs a container access: the group
    // container is behind the App Data TCC service for a non-sandboxed app,
    // which is a "would like to access data from other apps" prompt on every
    // launch that no grant makes stick. See `SeptenaAppGroup.suiteName`.
    #if os(macOS)
    return
    #else
    let destination = SharedTaskCaptureDestination.septask
    for (claimedURL, capture) in SharedTaskCaptureQueue.claimAll(for: destination) {
      let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { SharedTaskCaptureQueue.finish(claimedURL); continue }
      let notes = capture.notes.trimmingCharacters(in: .whitespacesAndNewlines)
      let task = mutator.create(title: title, today: capture.today,
                                notes: notes.isEmpty ? nil : notes, source: "share_extension")
      if let url = capture.sourceURL {
        _ = mutator.addTaskRef(taskID: task.id, input: url.absoluteString, role: .from)
      }
      SharedTaskCaptureQueue.finish(claimedURL)
    }
    #endif
  }

  /// What the Share extension reads, written when the app leaves the
  /// foreground. Nothing while App Lock hides the tasks.
  static func publishLinkIndex(in context: ModelContext) {
    #if os(iOS)
    SharedTaskCaptureQueue.saveLinkIndex(
      TasksWidgetBuilder.isAppLockRedacted() ? nil : TaskRefLookup.shareIndex(in: context), for: .septask)
    #endif
  }

  /// Account switch, sign-out or delete: the index holds the old tasks.
  static func clearLinkIndex() {
    #if os(iOS)
    SharedTaskCaptureQueue.saveLinkIndex(nil, for: .septask)
    #endif
  }
}
#endif
