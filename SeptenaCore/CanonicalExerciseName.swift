import Foundation
import SwiftData

/// Single source of truth for turning a stored/typed exercise label into
/// the name the user *sees*. The exercise **catalog is authoritative** — a
/// logged `ExerciseEntry.exercise` string is just a reference into it, so
/// display should resolve through the catalog rather than echo whatever
/// happened to be written (which, historically, is a mixed bag of catalog
/// names like "Seated Row" and raw slugs/aliases like "rear-delt").
///
/// Two entry points, deliberately different:
///   • `display(_:catalog:)` — rich resolution for the UI. Returns the full
///     canonical name ("rear-delt" → "Rear Delt Fly").
///   • `forStorage(_:)`      — conservative, *key-preserving* cleanup for the
///     write path. Only ever returns a name whose `exerciseKey` equals the
///     input's, so normalizing on write never moves an entry to a different
///     join key — history, PR baselines and prefill all key off
///     `exerciseKey`, and silently fragmenting them on rename would be a bug.
///
/// All matching goes through `exerciseKey` (lowercase, alphanumerics only)
/// so casing and separator drift never blocks a hit.
enum CanonicalExerciseName {

  // MARK: Display (read path)

  /// Resolve `raw` to a canonical, title-cased display name.
  /// Order, first hit wins:
  ///   1. the user's own catalog (their chosen names take precedence)
  ///   2. the curated `DefaultExerciseLibrary` (id + name + aliases)
  ///   3. title-cased fallback for genuinely unknown labels
  ///
  /// `catalog` is a precomputed `exerciseKey → name` map (see `catalogMap`)
  /// so this stays cheap enough to call per row. Pass `[:]` to resolve
  /// against the library alone.
  static func display(_ raw: String, catalog: [String: String] = [:]) -> String {
    let key = exerciseKey(raw)
    guard !key.isEmpty else { return titleCased(raw) }
    if let name = catalog[key] { return name }
    if let lib = DefaultExerciseLibrary.byKey[key] { return lib.name }
    return titleCased(raw)
  }

  // MARK: Storage (write path)

  /// Conservative normalization for names about to be persisted. Returns a
  /// canonical name **only when it shares the input's `exerciseKey`** — i.e.
  /// pure case/separator cleanup, never a remap to a different exercise.
  /// Falls back to a title-cased version of the literal, which is always
  /// key-preserving by construction. This keeps freshly-logged names tidy
  /// without ever splitting an exercise's history across two keys.
  static func forStorage(_ raw: String) -> String {
    let key = exerciseKey(raw)
    guard !key.isEmpty else { return raw }
    if let lib = DefaultExerciseLibrary.byKey[key], exerciseKey(lib.name) == key {
      return lib.name
    }
    return titleCased(raw)
  }

  // MARK: Catalog map

  /// Build an `exerciseKey → display name` map from the user's catalog.
  /// Indexed by both the definition's id/slug *and* its name so a slug-form
  /// entry ("chest-press") resolves to the user's chosen name. Cache the
  /// result; don't call this per row.
  @MainActor
  static func catalogMap(context: ModelContext) -> [String: String] {
    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    var map: [String: String] = [:]
    for def in defs where !def.name.isEmpty {
      for raw in [def.id, def.name] {
        let key = exerciseKey(raw)
        if !key.isEmpty, map[key] == nil { map[key] = def.name }
      }
    }
    return map
  }

  // MARK: Title-case fallback

  /// Title-case a free-text/slug label: split on space, hyphen and
  /// underscore, upper-case the first character of each token, rejoin with
  /// spaces. "triceps-extension" → "Triceps Extension". The rest of each
  /// token is left as typed so intentional capitals (e.g. "EZ") survive.
  /// `exerciseKey` is invariant under this transform, so it is always safe
  /// to apply on the write path.
  static func titleCased(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return raw }
    let tokens = trimmed.split { $0 == " " || $0 == "-" || $0 == "_" }
    let words = tokens.map { token -> String in
      let s = String(token)
      return s.prefix(1).uppercased() + s.dropFirst()
    }
    return words.joined(separator: " ")
  }
}
