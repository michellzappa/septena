import Foundation
import SwiftData

// Resolver — turn a natural-name reference ("obsidian", "Septena Marketing",
// or even just "obs") into the canonical entity id.
//
// ⚠️  When adding a new entity type, follow the checklist in
//     [IDENTIFIERS.md](IDENTIFIERS.md). Copy `resolveAreaId(_:in:)`
//     verbatim, swap the entity type + the "area" string, done. The
//     four-step resolution rule must stay uniform so MCP behaviour is
//     predictable across types.
//
// Used by:
//   • UI fuzzy lookups (later)
//   • MCP tool layer (incoming "create_task(area: 'obsidian')")
//   • Deeplink handlers
//
// Resolution rule (see IDENTIFIERS.md):
//   1. Exact `id` match
//   2. Exact `slug` match on a live record
//   3. Exact `previousSlugs` match on a live record
//   4. Case-insensitive `title` substring — error if multiple hit
//
// Right now: areas, projects. Later: chores, habits, sections, supplements.

@MainActor
enum EntityResolver {

  // MARK: - Errors

  enum ResolveError: LocalizedError {
    case notFound(query: String, type: String)
    case ambiguous(query: String, type: String, candidates: [String])

    var errorDescription: String? {
      switch self {
      case .notFound(let q, let t):
        return "No \(t) matches “\(q)”."
      case .ambiguous(let q, let t, let candidates):
        return "“\(q)” matches multiple \(t)s: \(candidates.joined(separator: ", ")). Be more specific."
      }
    }
  }

  // MARK: - Areas

  static func resolveAreaId(_ query: String,
                            in context: ModelContext) throws -> String {
    let q = query.trimmingCharacters(in: .whitespaces)
    let descriptor = FetchDescriptor<AreaEntity>()
    let all = (try? context.fetch(descriptor)) ?? []

    // 1. Exact id.
    if let hit = all.first(where: { $0.id == q }) { return hit.id }
    // 2. Exact current slug.
    if let hit = all.first(where: { $0.slug == q }) { return hit.id }
    // 3. Exact previousSlug.
    if let hit = all.first(where: { $0.previousSlugs.contains(q) }) {
      return hit.id
    }
    // 4. Case-insensitive title substring — only succeeds on a single hit.
    let needle = q.lowercased()
    let fuzz = all.filter { $0.title.lowercased().contains(needle) }
    switch fuzz.count {
    case 0: throw ResolveError.notFound(query: q, type: "area")
    case 1: return fuzz[0].id
    default:
      throw ResolveError.ambiguous(query: q, type: "area",
                                   candidates: fuzz.map(\.title))
    }
  }

  // MARK: - Projects

  static func resolveProjectId(_ query: String,
                               in context: ModelContext) throws -> String {
    let q = query.trimmingCharacters(in: .whitespaces)
    let descriptor = FetchDescriptor<ProjectEntity>()
    let all = (try? context.fetch(descriptor)) ?? []

    if let hit = all.first(where: { $0.id == q }) { return hit.id }
    if let hit = all.first(where: { $0.slug == q }) { return hit.id }
    if let hit = all.first(where: { $0.previousSlugs.contains(q) }) {
      return hit.id
    }
    let needle = q.lowercased()
    let fuzz = all.filter { $0.title.lowercased().contains(needle) }
    switch fuzz.count {
    case 0: throw ResolveError.notFound(query: q, type: "project")
    case 1: return fuzz[0].id
    default:
      throw ResolveError.ambiguous(query: q, type: "project",
                                   candidates: fuzz.map(\.title))
    }
  }
}
