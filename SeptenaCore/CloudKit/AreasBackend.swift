import Foundation
import SwiftData

// MARK: - Shared id + slug helpers
//
// ⚠️  IDENTIFIER MODEL — applies to ALL label-style entities project-wide.
//     Read [IDENTIFIERS.md](IDENTIFIERS.md) before adding a new entity type
//     (chore, habit, section, etc) to CK or to the MCP surface. Do not
//     invent a per-type id scheme.
//
//   • `id`   — frozen at creation, base32 shortid. Internal stable key,
//              CKRecord.recordName, FK target.
//   • `slug` — derived from title, auto-updates on rename, deduped.
//              Natural-name lookup for MCP / UI / deeplinks.
//   • `title`— freely editable display string.
//
// `IDShortcode` and `IDSlug` below are the shared primitives — reuse them
// from any new backend; do not duplicate.

/// Generate URL-safe slugs from human titles. The slug field on each
/// label-style entity is recomputed via this on every rename; collisions
/// resolve to `home-2`, `home-3`, … via dedup at the backend layer.
enum IDSlug {
  static func from(_ name: String) -> String {
    let s = name.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    // Empty input (purely-non-alphanumeric title) falls back to a
    // timestamp-based hint so two empty-name records don't collide.
    return s.isEmpty ? "item-\(Int(Date().timeIntervalSince1970))" : s
  }
}

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

// AreasBackend — the mutation seam for areas across FastAPI ⇄ CloudKit.
// Same pattern as `TasksBackend`: a thin protocol with a CK impl that
// works against `CKEngine`, and a `TaskMutator`-style facade
// (`AreasMutator`) that views call without worrying about which backend
// is current.
//
// On the FastAPI side, areas live as a single replaced-wholesale array
// (`PUT /api/tasks/areas`). To make per-row semantics work uniformly, the
// FastAPI impl reads the current list, applies the mutation, and writes
// the whole list back. Phase 6 deletes this layer — CK becomes the only
// backend and the bulk-replace dance disappears.

@MainActor
protocol AreasBackend: AnyObject {
  func create(title: String, context: String?) async throws -> Area
  func rename(id: String, to title: String) async throws
  func setContext(id: String, context: String?) async throws
  func delete(id: String) async throws
}

// MARK: - Facade

@MainActor
@Observable
final class AreasMutator: AreasBackend {
  private let client: SeptenaClient
  private let context: ModelContext
  private var ckBackend: CloudKitAreasBackend?
  @ObservationIgnored private let fastBackend: FastAPIAreasBackend

  init(client: SeptenaClient, context: ModelContext) {
    self.client = client
    self.context = context
    self.fastBackend = FastAPIAreasBackend(client: client)
  }

  func bind(ckEngine: CKEngine) {
    self.ckBackend = CloudKitAreasBackend(engine: ckEngine, context: context)
  }

  private var current: AreasBackend {
    if TasksBackendDefaults.current == .cloudKit, let ck = ckBackend {
      return ck
    }
    return fastBackend
  }

  func create(title: String, context ctx: String? = nil) async throws -> Area {
    try await current.create(title: title, context: ctx)
  }
  func rename(id: String, to title: String) async throws {
    try await current.rename(id: id, to: title)
  }
  func setContext(id: String, context ctx: String?) async throws {
    try await current.setContext(id: id, context: ctx)
  }
  func delete(id: String) async throws {
    try await current.delete(id: id)
  }
}

// MARK: - FastAPI impl

@MainActor
private final class FastAPIAreasBackend: AreasBackend {
  private let client: SeptenaClient
  init(client: SeptenaClient) { self.client = client }

  func create(title: String, context ctx: String?) async throws -> Area {
    let current = try await client.areas()
    // Dedup against the server's existing list so two "Home" entries
    // don't collide. Same slug pattern as the CloudKit backend.
    let base = IDSlug.from(title)
    var id = base
    if current.contains(where: { $0.id == id }) {
      var i = 2
      while current.contains(where: { $0.id == "\(base)-\(i)" }) { i += 1 }
      id = "\(base)-\(i)"
    }
    let next = current + [Area(id: id, title: title, context: ctx)]
    let updated = try await client.replaceAreas(next)
    return updated.first(where: { $0.id == id })
      ?? Area(id: id, title: title, context: ctx)
  }

  func rename(id: String, to title: String) async throws {
    var current = try await client.areas()
    guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
    current[idx].title = title
    _ = try await client.replaceAreas(current)
  }

  func setContext(id: String, context ctx: String?) async throws {
    var current = try await client.areas()
    guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
    current[idx].context = ctx
    _ = try await client.replaceAreas(current)
  }

  func delete(id: String) async throws {
    let current = try await client.areas()
    let next = current.filter { $0.id != id }
    _ = try await client.replaceAreas(next)
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

  /// Dedup a candidate slug against every other live area (excluding the
  /// caller's own id, so renaming to the same title doesn't add a `-2`).
  /// Returns the base slug if free, else `base-2`, `base-3`, …
  private func uniqueSlug(for name: String, excluding ownId: String?) -> String {
    let base = IDSlug.from(name)
    let descriptor = FetchDescriptor<AreaEntity>()
    let all = (try? context.fetch(descriptor)) ?? []
    let taken = Set(all.compactMap { $0.id == ownId ? nil : $0.slug })
    if !taken.contains(base) { return base }
    var i = 2
    while taken.contains("\(base)-\(i)") { i += 1 }
    return "\(base)-\(i)"
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
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }

  func create(title: String, context ctx: String?) async throws -> Area {
    let newId = uniqueShortcode()
    let newSlug = uniqueSlug(for: title, excluding: nil)
    let entity = AreaEntity(id: newId, title: title, context: ctx,
                            slug: newSlug)
    context.insert(entity)
    commitAndPush(entity, op: "create slug=\(newSlug)")
    return Area(entity)
  }

  func rename(id: String, to title: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let oldSlug = entity.slug ?? entity.id
    let newSlug = uniqueSlug(for: title, excluding: id)
    entity.title = title
    if newSlug != oldSlug {
      // Capture the old slug so a recently-renamed area still resolves
      // by its previous name for ~3 renames worth of grace. FIFO, cap 3.
      var history = [oldSlug] + entity.previousSlugs.filter { $0 != oldSlug }
      if history.count > 3 { history = Array(history.prefix(3)) }
      entity.previousSlugs = history
      entity.slug = newSlug
    }
    commitAndPush(entity, op: "rename slug=\(newSlug)")
  }

  func setContext(id: String, context ctx: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.context = (ctx?.isEmpty == true) ? nil : ctx
    commitAndPush(entity, op: "setContext")
  }

  func delete(id: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let staged = entity
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }
}
