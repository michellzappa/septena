import Foundation
import SwiftData

// What a reference shows and opens (docs/TASK_REFERENCES_SPEC.md §5, §8). Both
// shells draw these rows, so the References block, the Add Reference panel and
// the conversation's Open link cannot disagree.

// MARK: - Resolvers (§5)

/// What a tap on a reference opens.
enum TaskRefTarget: Hashable, Sendable {
  /// `http`, `https` or `message`, never another scheme.
  case url(URL)
  /// A task in this account, by id.
  case task(String)
}

enum TaskRefResolver {
  /// The only schemes a reference opens, whatever its key or snapshot says.
  private static let schemes: Set<String> = ["http", "https", "message"]

  static func canOpen(_ url: URL) -> Bool {
    url.scheme.map { schemes.contains($0.lowercased()) } ?? false
  }

  /// The item of `ref`, or its stored web address when the key alone does not
  /// give one. Nil: the row shows the snapshot and opens nothing. A Septena
  /// task resolves only while this device has it.
  static func target(for ref: TaskRef, hasTask: (String) -> Bool) -> TaskRefTarget? {
    if ref.kind == "task", !ref.keyID.contains("/") {
      if hasTask(ref.keyID) { return .task(ref.keyID) }
    } else if let url = keyURL(ref), canOpen(url) {
      return .url(url)
    }
    return ref.webURL.map(TaskRefTarget.url)
  }

  /// The address built from the key.
  private static func keyURL(_ ref: TaskRef) -> URL? {
    switch ref.kind {
    case "email", "thread":
      // Mail matches a Message-ID by its exact case, so the raw id first.
      return messageURL(id: ref.snapshot.rawId ?? ref.keyID)
    case "issue":
      let parts = ref.keyID.split(separator: "#", maxSplits: 1).map(String.init)
      let path = parts.first?.split(separator: "/").map(String.init) ?? []
      guard parts.count == 2, path.count == 2 else { return nil }
      // GitHub redirects `issues` to `pull` for a pull request.
      return webURL(host: "github.com", path: path + ["issues", parts[1]])
    case "url":
      return webURL(from: ref.keyID)
    case "task":
      guard let slash = ref.keyID.firstIndex(of: "/") else { return nil }
      return webURL(host: String(ref.keyID[..<slash]),
                    path: ["work", "task", String(ref.keyID[ref.keyID.index(after: slash)...])])
    case "door":
      guard let bar = ref.keyID.firstIndex(of: "|") else { return nil }
      return doorPath(String(ref.keyID[ref.keyID.index(after: bar)...]))
        .flatMap { webURL(host: String(ref.keyID[..<bar]), path: $0) }
    default:
      return nil
    }
  }

  private static func messageURL(id: String) -> URL? {
    encoded(id).flatMap { URL(string: "message://%3C\($0)%3E") }
  }

  /// The permalink of a Starlings record. Its doors are `<kind>:<id>`.
  private static func doorPath(_ door: String) -> [String]? {
    let parts = door.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "subject":
      let subject = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
      return subject.count == 2 ? ["work", subject[0], subject[1]] : nil
    case "contact": return ["work", "contact", parts[1]]
    case "document": return ["docs", "document", parts[1]]
    case "event": return ["calendar", "event", parts[1]]
    case "thread": return ["team", "thread", parts[1]]
    default: return nil
    }
  }

  /// `host` may carry a port. Every path segment is percent-encoded.
  private static func webURL(host: String, path: [String]) -> URL? {
    let segments = path.compactMap { $0.isEmpty ? nil : encoded($0) }
    guard segments.count == path.count,
          let base = URLComponents(string: "https://\(host)"),
          base.host?.isEmpty == false, base.user == nil, base.path.isEmpty,
          base.query == nil, base.fragment == nil else { return nil }
    return URL(string: "https://\(host)/" + segments.joined(separator: "/"))
  }

  private static func encoded(_ text: String) -> String? {
    text.addingPercentEncoding(withAllowedCharacters: unreserved)
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// A whole text that is a web address.
  static func webURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else { return nil }
    return url
  }
}

// MARK: - Rows (§8)

/// One row of the References block.
struct TaskRefRow: Identifiable, Hashable, Sendable {
  /// Every reference the row stands for. More than one for a mail
  /// conversation: Remove takes them all.
  let refs: [TaskRef]
  let title: String
  let subtitle: String?
  let sfSymbol: String
  let target: TaskRefTarget?

  var id: String { refs.first?.id ?? "" }

  /// The address Copy Link copies.
  var link: URL? {
    if case .url(let url) = target { return url }
    return nil
  }

  func contains(_ ref: TaskRef) -> Bool { refs.contains { $0.id == ref.id } }
}

enum TaskRefRows {
  /// The rows of one task's references, in order. An `email` and a `thread` of
  /// one conversation make one row.
  static func rows(for refs: [TaskRef], hasTask: (String) -> Bool) -> [TaskRefRow] {
    let threads = refs.filter { $0.kind == "thread" }
    var threadOfEmail: [String: String] = [:]
    for email in refs where email.kind == "email" {
      threadOfEmail[email.id] = thread(of: email, among: threads)?.id
    }
    var rows: [TaskRefRow] = []
    var placed = Set<String>()
    for ref in refs where !placed.contains(ref.id) {
      let threadID = ref.kind == "thread" ? ref.id : threadOfEmail[ref.id]
      let group = threadID.map { id in refs.filter { $0.id == id || threadOfEmail[$0.id] == id } } ?? [ref]
      placed.formUnion(group.map(\.id))
      rows.append(row(for: group, hasTask: hasTask))
    }
    return rows
  }

  /// The conversation an email belongs to. A key names no thread, so this
  /// reads what a capture writes: the root's own id, the same subject, or one
  /// `from` pair.
  private static func thread(of email: TaskRef, among threads: [TaskRef]) -> TaskRef? {
    if let root = threads.first(where: { $0.keyID == email.keyID }) { return root }
    if let subject = subject(of: email) {
      let same = threads.filter { self.subject(of: $0) == subject }
      if same.count == 1 { return same[0] }
    }
    let from = TaskRefRole.from.rawValue
    guard threads.count == 1, email.role == from, threads[0].role == from else { return nil }
    return threads[0]
  }

  /// The subject without reply and forward marks.
  private static func subject(of ref: TaskRef) -> String? {
    guard var text = ref.snapshot.title?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
    let marks = ["re:", "fwd:", "fw:", "aw:", "wg:", "sv:", "res:", "enc:"]
    while let mark = marks.first(where: { text.hasPrefix($0) }) {
      text = String(text.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
    }
    return text.isEmpty ? nil : text
  }

  private static func row(for group: [TaskRef], hasTask: (String) -> Bool) -> TaskRefRow {
    // A conversation opens its newest email. The root of a thread is often
    // not in the local mailbox (§5).
    let opens = group.last { $0.kind == "email" } ?? group[0]
    let named = group.first { $0.kind == "thread" } ?? opens
    let kind = RegistryTaskReferences.kind(named.kind)
    let title = [named, opens].compactMap(\.title).first ?? kind.label
    let role = group.compactMap { RegistryTaskReferences.roleLabels[$0.role] }.first
    let detail = opens.snapshot.subtitle ?? named.snapshot.subtitle ?? place(of: opens, title: title)
    let subtitle = [role, detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    return TaskRefRow(refs: group, title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                      sfSymbol: kind.sfSymbol,
                      target: TaskRefResolver.target(for: opens, hasTask: hasTask))
  }

  /// Where the item lives, read from the key, when the snapshot does not say.
  private static func place(of ref: TaskRef, title: String) -> String? {
    switch ref.kind {
    case "issue": return title == ref.keyID ? nil : ref.keyID
    case "url":
      guard ref.snapshot.title?.isEmpty == false else { return nil }
      return URLComponents(string: ref.keyID)?.host
    case "door": return ref.keyID.split(separator: "|").first.map(String.init)
    case "task": return ref.keyID.contains("/") ? ref.keyID.split(separator: "/").first.map(String.init) : nil
    default: return nil
    }
  }

  // MARK: Links

  /// One link of a task's own text, offered by Add Reference.
  struct Offer: Identifiable, Hashable, Sendable {
    let key: String
    let input: String
    let title: String
    let sfSymbol: String
    var id: String { key }
  }

  /// The links in a task's title and notes that `existing` does not have yet,
  /// in order, one per key. The system finds where a link starts and ends; the
  /// core decides what it is.
  static func offers(title: String, notes: String?, existing: [TaskRef]) -> [Offer] {
    guard TaskRefCore.isAvailable else { return [] }
    var keys = Set(existing.map(\.key))
    return [title, notes ?? ""].flatMap(linkTexts).compactMap { text in
      guard let parsed = TaskRefCore.parse(text), keys.insert(parsed.key).inserted else { return nil }
      let ref = preview(parsed)
      return Offer(key: parsed.key, input: text,
                   title: ref.title ?? text,
                   sfSymbol: RegistryTaskReferences.kind(ref.kind).sfSymbol)
    }
  }

  private static func linkTexts(in text: String) -> [String] {
    guard !text.isEmpty,
          let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return [] }
    let whole = text as NSString
    return detector.matches(in: text, range: NSRange(location: 0, length: whole.length)).compactMap { match in
      let found = whole.substring(with: match.range)
      // A bare "example.com" or an address is not a link the user wrote.
      return URL(string: found).flatMap { TaskRefResolver.canOpen($0) ? found : nil }
    }
  }

  /// One string of `artifact.refs` that opens in the browser or in Mail (§7).
  /// Nil: the string is plain text.
  static func artifactLink(_ text: String) -> (title: String, sfSymbol: String, url: URL)? {
    if let parsed = TaskRefCore.parse(text) {
      let row = rows(for: [preview(parsed)], hasTask: { _ in false })[0]
      if let url = row.link {
        return (parsed.kind == "url" ? text : row.title, row.sfSymbol, url)
      }
    }
    return TaskRefResolver.webURL(from: text)
      .map { (text, RegistryIcons.sfSymbol(for: "reference.door"), $0) }
  }

  private static func preview(_ parsed: TaskRefCore.Parsed) -> TaskRef {
    let snapshot = TaskRefSnapshot(url: parsed.url, rawId: parsed.rawId)
    return TaskRef(id: parsed.key, taskId: "", key: parsed.key, kind: parsed.kind,
                   role: TaskRefRole.about.rawValue, snapshotJSON: snapshot.storedJSON())
  }
}

extension ConvoArtifact {
  /// One of the artifact's own links is this reference.
  func shows(_ row: TaskRefRow) -> Bool {
    let keys = Set(row.refs.map(\.key))
    return (refs ?? []).contains { TaskRefCore.parse($0).map { keys.contains($0.key) } ?? false }
  }
}

// MARK: - Reads

extension LocalCache {
  /// The References block of one task.
  @MainActor
  static func taskRefRows(forTaskID taskID: String, in context: ModelContext) -> [TaskRefRow] {
    TaskRefRows.rows(for: taskRefs(forTaskID: taskID, in: context)) { id in
      task(id: id, in: context).map { $0.deletedAt == nil } ?? false
    }
  }

  @MainActor
  static func hasTaskRefs(taskID: String, in context: ModelContext) -> Bool {
    var descriptor = FetchDescriptor<TaskRefEntity>(predicate: #Predicate { $0.taskID == taskID })
    descriptor.fetchLimit = 1
    return !StoreHealth.fetch(context, descriptor).isEmpty
  }

  /// The kind of every task's `from` reference, for the row icon. One read per
  /// list load, never one per row.
  @MainActor
  static func fromRefKinds(in context: ModelContext) -> [String: String] {
    let from = TaskRefRole.from.rawValue
    let rows = StoreHealth.fetch(context, FetchDescriptor<TaskRefEntity>(
      predicate: #Predicate { $0.role == from }, sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
    return Dictionary(rows.map { ($0.taskID, $0.kind) }, uniquingKeysWith: { first, _ in first })
  }

  /// The task's newest `issue` reference: the last one added (§6.6).
  @MainActor
  static func newestIssueRef(forTaskID taskID: String, in context: ModelContext) -> TaskRefRow? {
    issueRow(taskRefs(forTaskID: taskID, in: context).filter { $0.kind == "issue" })
  }

  /// The newest `issue` reference of every task that has one (Review rows).
  @MainActor
  static func newestIssueRefs(in context: ModelContext) -> [String: TaskRefRow] {
    let rows = StoreHealth.fetch(context, FetchDescriptor<TaskRefEntity>(
      predicate: #Predicate { $0.kind == "issue" })).map { TaskRef($0) }
    return Dictionary(grouping: rows, by: \.taskId).compactMapValues(issueRow)
  }

  private static func issueRow(_ issues: [TaskRef]) -> TaskRefRow? {
    issues.max {
      let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
      return a == b ? ($0.position ?? 0) < ($1.position ?? 0) : a < b
    }.flatMap { TaskRefRows.rows(for: [$0], hasTask: { _ in false }).first }
  }
}
