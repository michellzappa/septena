import SwiftData

/// Shared off-main reader for the `@MainActor`-free mirror functions
/// (`ChecklistMirror`, `SettingsMirror.loadSettings`).
///
/// Section destination views run their `reload()` reads on the view's main
/// context, which hitches the push transition while a section's day/history
/// is fetched. Routing those reads through this background `@ModelActor`
/// (its own `ModelContext`, off the UI thread) keeps the transition smooth.
///
/// Usage — pass a closure taking the actor's background context, returning a
/// Sendable value (the mirror DTOs are all value types). Bind any inputs to
/// value-type locals first so the closure never captures the view or its
/// `modelContext`:
///
///     let date = viewingDate
///     today = await MirrorReader.shared.read {
///       ChecklistMirror.loadGutDay(context: $0, date: date)
///     }
@ModelActor
actor MirrorReader {
  static let shared = MirrorReader(modelContainer: LocalStore.shared.container)

  func read<T>(_ body: @Sendable (ModelContext) -> T) -> T {
    body(modelContext)
  }
}
