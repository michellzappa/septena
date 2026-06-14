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
  func delete(id: String) async throws
}

// MARK: - Facade

@MainActor
@Observable
final class AreasMutator: AreasBackend {
  private let context: ModelContext
  private var ckBackend: CloudKitAreasBackend?

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
  func delete(id: String) async throws {
    try await requireBackend().delete(id: id)
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
    do { try context.save() } catch {
      SeptenaLog.error("CK areas: context.save failed", error)
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

  func delete(id: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let staged = entity
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }
}
