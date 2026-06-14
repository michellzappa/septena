import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

// Spotlight "readability" surface (docs/SPOTLIGHT_READABILITY_PLAN.md): donate
// the user's data into the on-device Spotlight index so it's discoverable in
// system search and — per Apple — by Apple Intelligence / personal-context
// Siri. Phase 0 shipped tasks; Phase 1 adds the seven catalog entities and
// honors the section gate (a disabled section's items are purged).
//
// Observer-driven, not call-site-driven. Task writes post `.septenaTasksChanged`;
// every other section's writes — and section enable/disable — post
// `.septenaDataChanged`. We reconcile off those two signals instead of threading
// CoreSpotlight calls through every mutator. Donation uses the App Intents path
// (`indexAppEntities` over the same `IndexedEntity` types the intents already
// resolve), so each Spotlight hit maps back to its entity.
//
// Reconcile = "index everything currently present, prune the diff against the
// last-indexed id set." Because each catalog builder returns an EMPTY list when
// its section is disabled, the prune step IS the section purge — there's no
// separate delete path. Snapshots persist (UserDefaults) so a change made while
// the app was closed is still reconciled on the next launch.

@MainActor
final class SpotlightIndexer {
  static let shared = SpotlightIndexer()

  /// Sections that currently contribute entities to the index. Drives which
  /// Settings pages show the "Show in Spotlight & Siri" opt-out (a read-only
  /// section has nothing to gate). Keep in step with the builders below; grows
  /// as later phases index more (e.g. nutrition / mood logs).
  static let indexableSectionKeys: Set<String> = [
    "tasks", "habits", "supplements", "chores", "training", "groceries",
    "nutrition", "mood",
  ]

  private enum Scope { case tasks, catalogs }

  /// Last-indexed id set per snapshot key, persisted so a delete made while the
  /// app was closed is still pruned next launch (the change notifications carry
  /// no payload, so we diff to know what to remove).
  private var snapshots: [String: Set<String>] = [:]
  private var observing = false
  private var pending: Set<Scope> = []
  private var flushScheduled = false

  private init() {}

  // MARK: Lifecycle

  /// Begin reacting to data changes. Idempotent — safe to call from the scene
  /// launch and again from a Siri-triggered cold launch.
  func start() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in self?.schedule(.tasks) }
    }
    NotificationCenter.default.addObserver(
      forName: .septenaDataChanged, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in self?.schedule(.catalogs) }
    }
  }

  /// One-shot backfill, called after the launch CloudKit pull so we index the
  /// synced mirror rather than a pre-sync (possibly empty) one.
  func backfill() async {
    await reconcileTasks()
    await reconcileCatalogs()
  }

  // MARK: Debounce

  /// Coalesce bursts (a multi-row edit, a sync absorbing many changes, a
  /// section toggle) into one reconcile a beat later.
  private func schedule(_ scope: Scope) {
    pending.insert(scope)
    guard !flushScheduled else { return }
    flushScheduled = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      flushScheduled = false
      let scopes = pending
      pending = []
      if scopes.contains(.tasks) { await reconcileTasks() }
      if scopes.contains(.catalogs) { await reconcileCatalogs() }
    }
  }

  // MARK: Reconcile

  private func reconcileTasks() async {
    let context = LocalStore.shared.container.mainContext
    // Tasks is a core, always-on section, but still honors the Spotlight
    // opt-out. Opted out → empty list → reconcile prunes whatever was indexed.
    let entities: [TaskChoice]
    if SettingsMirror.showInSpotlight("tasks", context: context) {
      let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
      entities = rows.map { TaskChoice(id: $0.id, title: $0.title, notes: $0.notes) }
    } else {
      entities = []
    }
    await reconcile(entities, type: TaskChoice.self,
                    snapshotKey: "spotlight.snapshot.tasks")
  }

  private func reconcileCatalogs() async {
    let ctx = LocalStore.shared.container.mainContext
    await reconcile(habits(ctx),       type: HabitEntity.self,
                    snapshotKey: "spotlight.snapshot.habits")
    await reconcile(supplements(ctx),  type: SupplementEntity.self,
                    snapshotKey: "spotlight.snapshot.supplements")
    await reconcile(chores(ctx),       type: ChoreEntity.self,
                    snapshotKey: "spotlight.snapshot.chores")
    await reconcile(exercises(ctx),    type: ExerciseChoice.self,
                    snapshotKey: "spotlight.snapshot.exercises")
    await reconcile(sessionTypes(ctx), type: TrainingSessionTypeChoice.self,
                    snapshotKey: "spotlight.snapshot.sessionTypes")
    await reconcile(groceryItems(ctx), type: GroceryItemChoice.self,
                    snapshotKey: "spotlight.snapshot.groceryItems")
    await reconcile(groceryCats(ctx),  type: GroceryCategoryChoice.self,
                    snapshotKey: "spotlight.snapshot.groceryCategories")
    // Phase 2 — historical log events (full history; CoreSpotlight handles
    // large indexes). A trailing-window cap can be added if device backfill
    // proves slow. See docs/SPOTLIGHT_READABILITY_PLAN.md.
    await reconcile(meals(ctx),        type: MealLogEntity.self,
                    snapshotKey: "spotlight.snapshot.meals")
    await reconcile(moods(ctx),        type: MoodLogEntity.self,
                    snapshotKey: "spotlight.snapshot.moods")
    await reconcile(workouts(ctx),     type: WorkoutLogEntity.self,
                    snapshotKey: "spotlight.snapshot.workouts")
  }

  /// Index everything present, prune the diff against the last-indexed set. An
  /// empty `entities` (its section disabled) prunes all of that type — the
  /// section purge falls out for free.
  private func reconcile<E: IndexedEntity>(
    _ entities: [E], type: E.Type, snapshotKey: String
  ) async where E.ID == String {
    let currentIDs = Set(entities.map(\.id))
    let removed = loadSnapshot(snapshotKey).subtracting(currentIDs)
    guard !entities.isEmpty || !removed.isEmpty else { return }

    let index = CSSearchableIndex.default()
    do {
      if !entities.isEmpty { try await index.indexAppEntities(entities) }
      if !removed.isEmpty {
        try await index.deleteAppEntities(identifiedBy: Array(removed), ofType: type)
      }
      snapshots[snapshotKey] = currentIDs
      UserDefaults.standard.set(Array(currentIDs), forKey: snapshotKey)
      SeptenaLog.info("[Spotlight] \(snapshotKey): indexed \(entities.count), pruned \(removed.count)")
    } catch {
      SeptenaLog.error("[Spotlight] reconcile \(snapshotKey) failed", error)
    }
  }

  private func loadSnapshot(_ key: String) -> Set<String> {
    if let cached = snapshots[key] { return cached }
    let stored = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    snapshots[key] = stored
    return stored
  }

  /// A section is indexed only when it's enabled AND the user hasn't opted it
  /// out of Spotlight / Siri. Either being false makes the builder return [],
  /// so reconcile prunes the section's entries.
  private func indexable(_ key: String, _ ctx: ModelContext) -> Bool {
    SeptenaServices.shared.isSectionEnabled(key)
      && SettingsMirror.showInSpotlight(key, context: ctx)
  }

  // MARK: Catalog builders
  //
  // Each mirrors its section's `EntityQuery` catalog and returns [] when the
  // section is disabled or opted out, so reconcile prunes it. (Replicated
  // rather than shared because the queries' catalog helpers are private; the
  // shapes are trivial.)

  private func habits(_ ctx: ModelContext) -> [HabitEntity] {
    guard indexable("habits", ctx) else { return [] }
    let defs = (try? ctx.fetch(FetchDescriptor<HabitDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return defs.map { HabitEntity(id: $0.id, title: $0.title, emoji: $0.emoji) }
  }

  private func supplements(_ ctx: ModelContext) -> [SupplementEntity] {
    guard indexable("supplements", ctx) else { return [] }
    let defs = (try? ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return defs.map { SupplementEntity(id: $0.id, title: $0.title, emoji: $0.emoji) }
  }

  private func chores(_ ctx: ModelContext) -> [ChoreEntity] {
    guard indexable("chores", ctx) else { return [] }
    let defs = (try? ctx.fetch(FetchDescriptor<ChoreDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return defs.map { ChoreEntity(id: $0.id, title: $0.title, emoji: $0.emoji) }
  }

  private func exercises(_ ctx: ModelContext) -> [ExerciseChoice] {
    guard indexable("training", ctx) else { return [] }
    let defs = (try? ctx.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return defs.filter { !$0.archived }.map { ExerciseChoice(id: $0.name) }
  }

  private func sessionTypes(_ ctx: ModelContext) -> [TrainingSessionTypeChoice] {
    guard indexable("training", ctx) else { return [] }
    return ChecklistMirror.loadSessionTypes(context: ctx)
      .filter { !$0.archived }
      .map { TrainingSessionTypeChoice(id: $0.id, title: $0.label) }
  }

  private func groceryItems(_ ctx: ModelContext) -> [GroceryItemChoice] {
    guard indexable("groceries", ctx) else { return [] }
    let items = (try? ctx.fetch(FetchDescriptor<GroceryItemEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return items.map {
      GroceryItemChoice(id: $0.id, title: $0.name,
                        emoji: $0.emoji.isEmpty ? nil : $0.emoji)
    }
  }

  private func groceryCats(_ ctx: ModelContext) -> [GroceryCategoryChoice] {
    guard indexable("groceries", ctx) else { return [] }
    let cats = (try? ctx.fetch(FetchDescriptor<GroceryCategoryEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return cats.map { GroceryCategoryChoice(id: $0.id, title: $0.name) }
  }

  // MARK: Historical log builders (Phase 2)

  private func meals(_ ctx: ModelContext) -> [MealLogEntity] {
    guard indexable("nutrition", ctx) else { return [] }
    let rows = (try? ctx.fetch(FetchDescriptor<NutritionEntryEntity>())) ?? []
    return rows.map { MealLogEntity.from($0) }
  }

  private func moods(_ ctx: ModelContext) -> [MoodLogEntity] {
    guard indexable("mood", ctx) else { return [] }
    let rows = (try? ctx.fetch(FetchDescriptor<MoodEventEntity>())) ?? []
    return rows.map { MoodLogEntity.from($0) }
  }

  private func workouts(_ ctx: ModelContext) -> [WorkoutLogEntity] {
    guard indexable("training", ctx) else { return [] }
    let rows = (try? ctx.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    return rows.map { WorkoutLogEntity.from($0) }
  }
}
