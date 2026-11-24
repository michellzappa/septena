import Foundation

// The one seam between the app and the core's reference functions
// (docs/TASK_REFERENCES_SPEC.md §3, ADR 0031). The key grammar and the row id
// live in the shared core and are never written again here.
//
// The functions ship in core-v0.5.0, which is not pinned yet. Until then
// `isAvailable` is false, nothing in the app can add a reference, and pulled
// references sync, export and undo as usual. After the pin, this file is the
// only one to change:
//
//   isAvailable   true
//   parse         try? SeptenaSharedCore.parseRef(input: input)
//   mintID        SeptenaSharedCore.taskRefId(taskId: taskID, key: key,
//                                             deletedCount: UInt32(clamping: deletedCount))

enum TaskRefCore {
  /// The core's `ParsedRef`.
  struct Parsed: Hashable, Sendable {
    /// `<kind>:<id>` in normal form.
    let key: String
    let kind: String
    let id: String
    /// The id before normalisation.
    let rawId: String
    /// The web address of the item, when the input was one.
    let url: String?
  }

  static var isAvailable: Bool { false }

  /// A key, a web URL or a `message://` link. Nil when it is none of them.
  static func parse(_ input: String) -> Parsed? { nil }

  /// The row id. `deletedCount` is the number of deleted rows with the same
  /// task and key.
  static func mintID(taskID: String, key: String, deletedCount: Int) -> String? { nil }
}

/// What "Add Reference" did.
enum TaskRefAddResult: Equatable {
  case added(TaskRef)
  /// The task has this key already.
  case existing(TaskRef)
  /// The text is not a key, a web URL or a `message://` link.
  case invalid
  /// The task has `maxRefsPerTask` references.
  case limitReached
  /// This build has no core that reads a key.
  case unavailable
  /// The task is gone or deleted, or the save rolled back.
  case failed
}

extension TaskRefSnapshot {
  /// The JSON text the store keeps and the backend counts: no escaped slashes,
  /// as `JSON.stringify` writes it.
  static func json<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// The snapshot as stored. Over the cap, the title and the subtitle are
  /// shortened first (§4.1), then the fields that the key can stand in for go.
  /// Nil when nothing is left to store.
  func storedJSON() -> String? {
    var snapshot = self
    if let url = snapshot.url, !Self.isWebAddress(url) { snapshot.url = nil }
    while let text = Self.json(snapshot), text.utf8.count > RegistryEntityLimits.refSnapshotMax {
      let title = snapshot.title ?? "", subtitle = snapshot.subtitle ?? ""
      if title.count > 8 || subtitle.count > 8 {
        if title.utf8.count >= subtitle.utf8.count {
          snapshot.title = Self.shortened(title)
        } else {
          snapshot.subtitle = Self.shortened(subtitle)
        }
      } else if snapshot.url != nil {
        snapshot.url = nil
      } else if snapshot.rawId != nil {
        snapshot.rawId = nil
      } else {
        return nil
      }
    }
    return snapshot == TaskRefSnapshot() ? nil : Self.json(snapshot)
  }

  private static func shortened(_ text: String) -> String {
    text.prefix(max(0, text.count * 3 / 4 - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The backend's rule for `url`: `http` or `https`, no white space.
  private static func isWebAddress(_ text: String) -> Bool {
    let lower = text.lowercased()
    return ["https://", "http://"].contains { lower.hasPrefix($0) && lower.count > $0.count }
      && !text.contains(where: \.isWhitespace)
  }
}
