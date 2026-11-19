import Foundation
import SwiftData

// MARK: - Shared id helpers
//
// ⚠️  IDENTIFIER MODEL — applies to ALL label-style entities project-wide.
//     Read [IDENTIFIERS.md](docs/IDENTIFIERS.md) before adding a new entity type.
//     Do not invent a per-type id scheme.
//
//   • `id`   — frozen at creation, base32 shortid. Internal stable key,
//              CKRecord.recordName, FK target. Invisible to users.
//   • `title`— freely editable display string. The only user-facing name.

/// Generate opaque, immutable identifiers for new records. base32-style
/// alphabet (no `0/o/1/l/i` — characters that are easy to misread in
/// logs or hand-copy). 4 chars = 32^4 ≈ 1M combos — comfortable for the
/// dozens-of-records-per-type scale we're at. Collision handling lives
/// at the call site (try-once-then-retry).
enum IDShortcode {
  /// 32-character alphabet without ambiguous glyphs.
  static let alphabet: [Character] =
    Array("abcdefghjkmnpqrstuvwxyz23456789")

  /// 4-char shortid for label-style entities (areas, projects, and
  /// eventually chores/habits/sections etc).
  static func generate(length: Int = 4) -> String {
    String((0..<length).map { _ in alphabet.randomElement()! })
  }
}

// AreasBackend — the mutation seam for areas. Views call `AreasMutator`
// without caring how the write reaches the CloudKit mirror.

@MainActor
protocol AreasBackend: AnyObject {
  func create(title: String, context: String?) async throws -> Area
  func rename(id: String, to title: String) async throws
  func setContext(id: String, context: String?) async throws
  func setEmoji(id: String, emoji: String?) async throws
  func setAttachment(id: String, attachment: AreaAttachment?) async throws
  func delete(id: String) async throws
  /// Renumber areas to match `orderedIDs` (synced sidebar order). See
  /// `docs/DRAG_AND_DROP.md` §5 gap #2.
  func reorder(orderedIDs: [String]) async throws
}

// MARK: - Facade

@MainActor
@Observable
final class AreasMutator: AreasBackend {
  private let context: ModelContext
  private var ckBackend: CloudKitAreasBackend?
  /// Set once at startup so `delete` can detach the area's tasks and projects
  /// through their own write boundaries. Weak: neither points back here.
  weak var taskMutator: TaskMutator?
  weak var projectsMutator: ProjectsMutator?

  init(context: ModelContext) {
    self.context = context
  }

  func bind(ckEngine: CKEngine) {
    self.ckBackend = CloudKitAreasBackend(engine: ckEngine, context: context)
  }

  private func requireBackend() throws -> CloudKitAreasBackend {
    guard let ck = ckBackend else {
      throw NSError(
        domain: "AreasMutator", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "AreasMutator used before CloudKit bind()"]
      )
    }
    return ck
  }

  func create(title: String, context ctx: String? = nil) async throws -> Area {
    try await requireBackend().create(title: title, context: ctx)
  }
  func rename(id: String, to title: String) async throws {
    try await requireBackend().rename(id: id, to: title)
  }
  func setContext(id: String, context ctx: String?) async throws {
    try await requireBackend().setContext(id: id, context: ctx)
  }
  func setEmoji(id: String, emoji: String?) async throws {
    try await requireBackend().setEmoji(id: id, emoji: emoji)
  }
  func setAttachment(id: String, attachment: AreaAttachment?) async throws {
    try await requireBackend().setAttachment(id: id, attachment: attachment)
  }
  /// Delete an area. Its projects and tasks are DETACHED first (area → nil),
  /// never deleted: the confirm dialog promises that, and a dangling area id
  /// hid the tasks from every list. Open loose tasks then land in the Inbox,
  /// tasks in a project stay with the project.
  func delete(id: String) async throws {
    let backend = try requireBackend()
    DeletedAreaLedger.record(id)
    await detachReferences(toArea: id)
    try await backend.delete(id: id)
  }
  func reorder(orderedIDs: [String]) async throws {
    try await requireBackend().reorder(orderedIDs: orderedIDs)
  }

  /// Clear the area link on every project and task that points at `areaID`,
  /// through the projects / task mutators (local write + CloudKit push + the
  /// usual notifications). Soft-deleted tasks are included, so a restore
  /// from Recently Deleted cannot bring back a dangling id.
  func detachReferences(toArea areaID: String) async {
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.area == areaID }
    ))) ?? []
    for project in projects.map(\.id) {
      try? await projectsMutator?.setArea(id: project, area: nil)
    }
    let tasks = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.area == areaID }
    ))) ?? []
    for task in tasks.map(\.id) {
      taskMutator?.moveToArea(id: task, area: nil)
    }
    if !projects.isEmpty || !tasks.isEmpty {
      SeptenaLog.info("[CK] area \(areaID) detached \(projects.count) project(s), \(tasks.count) task(s)")
    }
  }

  /// Repair for an area deleted on ANOTHER device (or by the MCP gateway):
  /// the CloudKit apply removes the area row but leaves the tasks and
  /// projects that point at it. Detach those for every area id the ledger
  /// knows was deleted. Only ledger ids, never "any unknown id": an area that
  /// is merely not fetched yet must not lose its tasks. Skips an id whose
  /// area exists again (forensic re-create). Idempotent; cheap when clean.
  func repairDeletedAreaReferences() async {
    for areaID in DeletedAreaLedger.ids() {
      let exists = ((try? context.fetchCount(FetchDescriptor<AreaEntity>(
        predicate: #Predicate { $0.id == areaID }
      ))) ?? 0) > 0
      guard !exists else { continue }
      await detachReferences(toArea: areaID)
    }
  }

  /// Forensic — create a record with a specific id.
  @discardableResult
  func createWithExplicitID(id: String, title: String, context ctx: String? = nil) async throws -> Area {
    try await requireBackend().createWithExplicitID(id: id, title: title, context: ctx)
  }
}

// MARK: - CloudKit impl

@MainActor
final class CloudKitAreasBackend: AreasBackend {
  private let engine: CKEngine
  private let context: ModelContext

  init(engine: CKEngine, context: ModelContext) {
    self.engine = engine
    self.context = context
  }

  private func fetch(id: String) -> AreaEntity? {
    let descriptor = FetchDescriptor<AreaEntity>(
      predicate: #Predicate { $0.id == id }
    )
    return try? context.fetch(descriptor).first
  }

  /// Generate a fresh opaque `id` for a new area. Try once; on the
  /// (statistically improbable) double collision, fall to 6 chars. Past
  /// that, panic to a UUID prefix — the panic branch never fires in
  /// practice at this scale.
  private func uniqueShortcode() -> String {
    let first = IDShortcode.generate(length: 4)
    if fetch(id: first) == nil { return first }
    let second = IDShortcode.generate(length: 6)
    if fetch(id: second) == nil { return second }
    return String(UUID().uuidString.prefix(8)).lowercased()
  }

  private func commitAndPush(_ entity: AreaEntity, op: String, deletion: Bool = false) {
    let id = entity.id
    let title = entity.title
    // A rolled-back save means the change no longer exists locally, so it
    // must not be pushed to CloudKit as if it did. Same rule as
    // `CloudKitTasksBackend.commitAndPush`.
    guard StoreHealth.save(context, op: "area.\(op)") else {
      SeptenaLog.error("[CK] area \(op) id=\(id) NOT pushed — local save failed and rolled back")
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
      return
    }
    if deletion {
      engine.noteAreaDeletion(id: id)
      SeptenaLog.info("[CK] area \(op) id=\(id) title=\"\(title)\" → engine.noteAreaDeletion")
    } else {
      engine.noteAreaChange(id: id)
      SeptenaLog.info("[CK] area \(op) id=\(id) title=\"\(title)\" → engine.noteAreaChange")
    }
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }

  func create(title: String, context ctx: String?) async throws -> Area {
    let newId = uniqueShortcode()
    let entity = AreaEntity(id: newId, title: title, context: ctx)
    context.insert(entity)
    commitAndPush(entity, op: "create")
    return Area(entity)
  }

  /// Forensic create: caller supplies the entity id (becomes CKRecord
  /// recordName `area:<id>`). Used to rebuild a missing record so that
  /// existing dangling task/project references (which match on entity id)
  /// resolve. Skips uniqueShortcode because the caller is asserting a
  /// specific identity.
  @discardableResult
  func createWithExplicitID(id: String, title: String, context ctx: String? = nil) async throws -> Area {
    if let existing = fetch(id: id) {
      return Area(existing)
    }
    let entity = AreaEntity(id: id, title: title, context: ctx)
    context.insert(entity)
    commitAndPush(entity, op: "create(explicit-id)")
    return Area(entity)
  }

  func rename(id: String, to title: String) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.title = title
    commitAndPush(entity, op: "rename")
  }

  func setContext(id: String, context ctx: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.context = (ctx?.isEmpty == true) ? nil : ctx
    commitAndPush(entity, op: "setContext")
  }

  func setEmoji(id: String, emoji: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.emoji = (emoji?.isEmpty == true) ? nil : emoji
    commitAndPush(entity, op: "setEmoji")
  }

  func setAttachment(id: String, attachment: AreaAttachment?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.attachmentJSON = attachment?.normalized?.encodedString()
    commitAndPush(entity, op: "setAttachment")
  }

  func delete(id: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let staged = entity
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }

  /// Renumber areas to `orderedIDs` (positions 1…N) and sync. The set is tiny,
  /// so we rewrite the whole order on each reorder rather than midpoint-insert;
  /// only rows whose position actually changed are pushed, with a single save +
  /// one structure-changed post for the batch. See `docs/DRAG_AND_DROP.md` §5.
  func reorder(orderedIDs: [String]) async throws {
    var changed: [String] = []
    for (index, id) in orderedIDs.enumerated() {
      guard let entity = fetch(id: id) else { continue }
      let newPos = index + 1
      if entity.position != newPos { entity.position = newPos; changed.append(id) }
    }
    guard !changed.isEmpty else { return }
    guard StoreHealth.save(context, op: "area.reorder") else { return }
    for id in changed { engine.noteAreaChange(id: id) }
    SeptenaLog.info("[CK] area reorder → \(changed.count) repositioned")
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }
}

// MARK: - Deleted-area ledger

/// Area ids this device knows were deleted — locally, or by a CloudKit
/// deletion applied from another device. `AreasMutator.repairDeletedAreaReferences`
/// detaches tasks and projects that still point at one of these. A plain
/// device-local list in `UserDefaults`; capped so it cannot grow without end.
/// Thread-safe (`UserDefaults` is), so the CloudKit apply path can record ids
/// off the main actor.
enum DeletedAreaLedger {
  private static let key = "septena.deletedAreaIDs"
  private static let cap = 200

  static func record(_ id: String) {
    var list = ids()
    guard !list.contains(id) else { return }
    list.append(id)
    if list.count > cap { list.removeFirst(list.count - cap) }
    UserDefaults.standard.set(list, forKey: key)
  }

  static func ids() -> [String] {
    UserDefaults.standard.stringArray(forKey: key) ?? []
  }
}
