import Foundation
import Observation
import SwiftData

/// "Is the first task list frame on screen yet?" Launch work the first frame
/// does not need (services start, sync, imports, diagnostics, the Reminders
/// mirror, the calendar agenda, filing suggestions) waits on this, so nothing
/// competes with the first Today frame for the main thread
/// (docs/LAUNCH_PERF.md).
@MainActor
@Observable
final class LaunchPhase {
  static let shared = LaunchPhase()

  /// True once the first task list frame is on screen (or the wait timed out).
  private(set) var firstFrameDrawn = false
  @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Upper bound on how long deferred launch work waits for a task list.
  static let maxWait: Duration = .milliseconds(1500)

  private init() {}

  /// Idempotent. Releases every waiter.
  func markFirstFrameDrawn() {
    guard !firstFrameDrawn else { return }
    firstFrameDrawn = true
    LaunchTrace.milestone("launch.firstFrameDrawn")
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }

  /// A task list published rows: flip the phase once the run loop has had a
  /// turn to commit that frame.
  func noteRowsPublished() {
    guard !firstFrameDrawn else { return }
    Task { @MainActor in
      await Self.nextFrame()
      self.markFirstFrameDrawn()
    }
  }

  /// Returns once the first frame is drawn, or after `maxWait`.
  func waitForFirstFrame() async {
    guard !firstFrameDrawn else { return }
    let timeout = Task { @MainActor in
      try? await Task.sleep(for: Self.maxWait)
      if !Task.isCancelled { self.markFirstFrameDrawn() }
    }
    await withCheckedContinuation { waiters.append($0) }
    timeout.cancel()
  }

  /// Suspend for about one display frame.
  static func nextFrame() async {
    try? await Task.sleep(for: .milliseconds(16))
  }
}

/// Process-wide accessor for the task-mutation stack.
@MainActor
final class SeptenaServices {
  static let shared = SeptenaServices()

  let ckEngine: CKEngine
  let taskMutator: TaskMutator
  let taskAttachmentStore: TaskAttachmentStore
  let areasMutator: AreasMutator
  let projectsMutator: ProjectsMutator

  /// Cached start task. Nil until first `start()`; non-nil thereafter so
  /// repeated calls coalesce.
  private var startTask: Task<Void, Never>?
  /// Held for the process's lifetime.
  private var dayRolloverObserver: NSObjectProtocol?

  private init() {
    let context = LocalStore.shared.container.mainContext
    self.ckEngine = CKEngine()
    self.taskMutator = TaskMutator(context: context, ckEngine: nil)
    self.taskAttachmentStore = TaskAttachmentStore(context: context, engine: self.ckEngine)
    self.areasMutator = AreasMutator(context: context)
    self.projectsMutator = ProjectsMutator(context: context)
  }

  func ensureSectionEnabled(_ key: String) {
    SettingsMirror.setSectionEnabled(
      key, true,
      context: LocalStore.shared.container.mainContext,
      engine: ckEngine)
  }

  func enabledSectionKeys() -> Set<String> {
    let context = LocalStore.shared.container.mainContext
    let sections = SettingsMirror.loadSections(context: context)
    return Set(sections.filter(\.isEnabled).map(\.key))
  }

  static let alwaysAvailableSectionKeys: Set<String> = ["tasks"]

  func isSectionEnabled(_ key: String) -> Bool {
    if SectionManifest.isRetired(key) { return false }
    if SectionManifest.byKey[key]?.activation == .always { return true }
    if SeptenaServices.alwaysAvailableSectionKeys.contains(key) { return true }
    return enabledSectionKeys().contains(key)
  }

  /// True once the mutators are bound (`bindWriteBoundary`).
  private var writeBoundaryBound = false

  /// Binds the task/area/project mutators to the backend write path.
  func bindWriteBoundary() {
    guard !writeBoundaryBound else { return }
    writeBoundaryBound = true
    LaunchTrace.spanSync("start.bindMutators") {
      taskMutator.bind(ckEngine: ckEngine)
      areasMutator.bind(ckEngine: ckEngine)
      projectsMutator.bind(ckEngine: ckEngine)
      // Lets project deletion cascade-clear the link on referencing tasks.
      projectsMutator.taskMutator = taskMutator
      // Lets area deletion detach its projects and tasks (never delete them).
      areasMutator.taskMutator = taskMutator
      areasMutator.projectsMutator = projectsMutator
    }
  }

  /// Idempotent startup: binds mutators, marks backend mode, starts
  /// `TaskSyncEngine`, and installs the day-rollover observer.
  func start() async {
    if let existing = startTask {
      await existing.value
      return
    }
    let task = Task { @MainActor [self] in
      let context = LocalStore.shared.container.mainContext

      LaunchTrace.spanSync("start.backfillSectionOnboarding") {
        SettingsMirror.backfillHasOnboardedForLegacySections(context: context)
      }
      TaskStoreMode.markDeviceBackend()
      LaunchTrace.spanSync("start.seedSyncedSettings") {
        SeptaskSyncedSettings.seedIfNeeded(from: SettingsMirror.loadCloudKitSettingsRow(context: context))
      }
      bindWriteBoundary()

      // Demo-seed (screenshot) builds stay offline — never start sync.
      if !DemoSeedMode.isOn {
        LaunchTrace.spanSync("start.taskSyncStart") {
          TaskSyncEngine.shared.start()
        }
      }

      dayRolloverObserver = NotificationCenter.default.addObserver(
        forName: .NSCalendarDayChanged, object: nil, queue: .main
      ) { _ in
        Task { @MainActor in
          SeptenaServices.shared.taskMutator.catchUpFixedSchedules()
          SeptenaServices.shared.runFadePassIfDue()
          SeptenaServices.shared.purgeExpiredTasksIfDue()
        }
      }
    }
    startTask = task
    await LaunchTrace.span("launch.servicesStart") { await task.value }
  }

  /// Launch follow-up to `start()`: pull remote state from `api.septena.app`,
  /// then run post-sync graph healing, migrations, repeat catch-up, fade pass,
  /// and 30-day purge.
  @MainActor
  func absorbRemoteChanges() async {
    guard !DemoSeedMode.isOn else { return }
    let context = LocalStore.shared.container.mainContext
    await TaskSyncEngine.shared.syncNow()
    await reconcileProjectGraph(context: context)
    await areasMutator.sweepDeletedContainerOrphans()
    SomedayStatusMigrator.runIfNeeded(context: context, engine: ckEngine)
    PeekAckProposalRecovery.runIfNeeded(context: context, mutator: taskMutator)
    taskMutator.catchUpFixedSchedules()
    runFadePassIfDue()
    purgeExpiredTasksIfDue()
    SettingsMirror.publishDeviceTimezone(context: context, engine: ckEngine)
  }

  /// The app calendar day the fade pass last ran in this process.
  private var lastFadePassDay: String?

  /// Idempotent daily fade pass (`docs/TASK_FADE_SPEC.md` §4).
  @MainActor
  func runFadePassIfDue() {
    let day = DayClock.appToday
    guard lastFadePassDay != day else { return }
    lastFadePassDay = day
    taskMutator.runFadePass(now: DayClock.appNow, today: day)
  }

  /// The real calendar day the Recently Deleted purge last ran in this process.
  private var lastExpiredPurgeDay: String?

  /// Permanently remove tasks soft-deleted more than 30 days ago.
  func purgeExpiredTasksIfDue() {
    let day = SeptenaDate.format(Date()) ?? ""
    guard lastExpiredPurgeDay != day else { return }
    lastExpiredPurgeDay = day
    let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    taskMutator.purgeExpired(before: cutoff)
  }

  @MainActor
  func reconcileProjectGraph(context: ModelContext) async {
    let tasks = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    ))) ?? []
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let projectIds = Set(projects.map { $0.id })
    let referenced = Set(tasks.compactMap { $0.project })
    let deleted = Set(DeletedContainerLedger.ids(.project))
    let orphans = referenced.subtracting(projectIds).subtracting(deleted).sorted()

    for id in orphans {
      _ = try? await projectsMutator.createWithExplicitID(
        id: id, title: Self.humanizeProjectSlug(id))
    }

    let removedSeed = projectIds.contains("seed-project") && !referenced.contains("seed-project")
    if removedSeed {
      try? await projectsMutator.delete(id: "seed-project")
    }

    if !orphans.isEmpty || removedSeed {
      SeptenaLog.info(
        "[Crosswalk] reconciled project graph: stubbed \(orphans), removedSeedProject=\(removedSeed)")
    }
  }

  private static func humanizeProjectSlug(_ slug: String) -> String {
    switch slug {
    case "ios": return "iOS"
    default: return slug.prefix(1).uppercased() + slug.dropFirst()
    }
  }
}
