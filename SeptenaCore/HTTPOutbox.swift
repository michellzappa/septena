import Foundation
import SwiftData

// Generic at-least-once delivery queue for non-task mutations.
//
// TaskMutator owns a typed outbox for tasks because tasks have a local
// SwiftData mirror and a fixed set of operations. Habits / supplements /
// chores / intake logs / training sessions / groceries have no local
// mirror — the existing view layer already does its own optimistic
// in-memory flip (`NextItemsModel.toggleHabit` etc.) and the only thing
// missing is reliable delivery of the server-side write.
//
// HTTPOutbox stores raw `(method, path, body)` tuples and replays them
// against SeptenaClient.executeRaw on the next foreground / network
// recovery. The view layer keeps its existing UX; this just guarantees
// the server eventually sees the mutation.
//
// Not a CloudKit stepping stone — when habits / supplements / etc.
// eventually go cloud-native, they'll get typed-mutator treatment as
// part of that migration. This is a pragmatic stopgap for reliability.

// MARK: - Entity

@Model
final class HTTPOutboxEntity {
  @Attribute(.unique) var id: String
  /// HTTP verb (POST / PUT / PATCH / DELETE).
  var method: String
  /// Request path (e.g. `/api/habits/toggle`).
  var path: String
  /// JSON-encoded request body, or empty Data for body-less requests.
  var bodyData: Data
  /// Free-form tag for the Sync pane's "Last failed mutation: …" surface.
  /// e.g. `habits.toggle`, `nutrition.add`. Not load-bearing.
  var kind: String
  var createdAt: Date
  var attempts: Int
  var nextAttemptAt: Date
  var lastError: String?

  init(id: String = UUID().uuidString,
       method: String,
       path: String,
       bodyData: Data,
       kind: String) {
    self.id = id
    self.method = method
    self.path = path
    self.bodyData = bodyData
    self.kind = kind
    self.createdAt = Date()
    self.attempts = 0
    self.nextAttemptAt = Date()
    self.lastError = nil
  }
}

// MARK: - HTTPOutbox

@MainActor
@Observable
final class HTTPOutbox {
  private let client: SeptenaClient
  private let context: ModelContext
  private var drainTask: Task<Void, Never>?

  /// Exposed for the Sync pane and offline-banner copy.
  var pendingCount: Int {
    (try? context.fetchCount(FetchDescriptor<HTTPOutboxEntity>())) ?? 0
  }

  init(client: SeptenaClient, context: ModelContext) {
    self.client = client
    self.context = context
  }

  // MARK: - Enqueue

  /// Queue a mutation for at-least-once delivery. The view layer should
  /// optimistically reflect the intended state before calling — this
  /// returns immediately and does not block on the network.
  ///
  /// Body shapes get JSON-encoded here. Pass `nil` for body-less requests
  /// (e.g. DELETE). `kind` is a free-form tag for telemetry / debugging.
  func enqueue(method: String, path: String, body: [String: Any]?, kind: String) {
    let bodyData: Data = body
      .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
      ?? Data()
    let entry = HTTPOutboxEntity(method: method, path: path,
                                 bodyData: bodyData, kind: kind)
    context.insert(entry)
    do {
      try context.save()
    } catch {
      SeptenaLog.error("HTTPOutbox.enqueue save failed", error)
    }
    kickDrain()
  }

  // MARK: - Drain

  func kickDrain() {
    if drainTask != nil { return }
    drainTask = Task { @MainActor in
      await self.drain()
      self.drainTask = nil
    }
  }

  private func drain() async {
    while true {
      guard let entry = nextReadyEntry() else { break }
      do {
        let body = entry.bodyData.isEmpty ? nil : entry.bodyData
        try await client.executeRaw(method: entry.method,
                                    path: entry.path,
                                    bodyData: body)
        context.delete(entry)
        try context.save()
      } catch {
        let isTransport = (error as? URLError) != nil
        entry.attempts += 1
        entry.lastError = error.localizedDescription
        // Same backoff curve as TaskMutator: 2^attempts seconds, capped 32.
        let delay = min(32.0, pow(2.0, Double(entry.attempts)))
        entry.nextAttemptAt = Date().addingTimeInterval(delay)
        // HTTP-error: server has rejected this 5x in a row. The mutation
        // is dead in the water (e.g. a duplicate POST that 409s every
        // time). Drop it so the queue doesn't get stuck. Transport
        // errors retry forever — user is just offline.
        if !isTransport && entry.attempts >= 5 {
          SeptenaLog.error("HTTPOutbox: dropping \(entry.kind) \(entry.path) after \(entry.attempts) attempts", error)
          context.delete(entry)
        }
        try? context.save()
        if isTransport { break }
      }
    }
  }

  private func nextReadyEntry() -> HTTPOutboxEntity? {
    let now = Date()
    let descriptor = FetchDescriptor<HTTPOutboxEntity>(
      predicate: #Predicate { $0.nextAttemptAt <= now },
      sortBy: [SortDescriptor(\.nextAttemptAt), SortDescriptor(\.createdAt)]
    )
    return try? context.fetch(descriptor).first
  }
}
