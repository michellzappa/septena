#if !WIDGET_EXTENSION
import Foundation
import SwiftData

// Builds and publishes `TasksWidgetSnapshot` from the local SwiftData mirror
// whenever tasks, structure, settings, or the calendar day change
// (docs/TASK_WIDGETS_SPEC.md §2, #160).

@MainActor
enum TasksWidgetBuilder {
  private static let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .autoupdatingCurrent
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f
  }()

  nonisolated static func isAppLockRedacted() -> Bool {
    UserDefaults.standard.bool(forKey: SettingsKey.appLockEnabled)
      || SeptenaAppGroup.defaults.bool(forKey: SettingsKey.appLockEnabled)
  }

  static func build(
    in context: ModelContext,
    today: String = SeptenaDate.today,
    isRedacted: Bool? = nil
  ) -> TasksWidgetSnapshot {
    let redacted = isRedacted ?? isAppLockRedacted()
    let structure = StructureCache.snapshot(in: context)
    let areaByID = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0) })
    let projectByID = Dictionary(uniqueKeysWithValues: structure.projects.map { ($0.id, $0) })

    let (todayTasks, triageTasks) = LocalCache.todayAndTriage(in: context)
    let upcomingTasks = LocalCache.tasks(in: context, filter: .upcoming)
    let starredTasks = LocalCache.tasks(in: context, filter: .starred)

    // Per docs/TASK_WIDGETS_SPEC.md §7: Inbox band items sit at the top of
    // Today (matching Today badge semantics), deduplicated by id.
    var seenToday = Set<String>()
    var combinedToday: [SeptenaTask] = []
    for t in triageTasks {
      if seenToday.insert(t.id).inserted { combinedToday.append(t) }
    }
    for t in todayTasks {
      if seenToday.insert(t.id).inserted { combinedToday.append(t) }
    }

    var lists: [TasksWidgetListSummary] = [
      makeSummary(
        id: TasksWidgetListSummary.todayID,
        kind: .today,
        title: String(localized: "Today"),
        symbol: RegistryIcons.sfSymbol(for: "list.today"),
        tasks: combinedToday,
        today: today,
        isRedacted: redacted,
        subtitleFor: { task in
          containerSubtitle(for: task, areaByID: areaByID, projectByID: projectByID, fallbackInbox: true)
        }
      ),
      makeSummary(
        id: TasksWidgetListSummary.upcomingID,
        kind: .upcoming,
        title: String(localized: "Upcoming"),
        symbol: RegistryIcons.sfSymbol(for: "list.upcoming"),
        tasks: upcomingTasks,
        today: today,
        isRedacted: redacted,
        subtitleFor: { task in
          // The day the row sits under in Upcoming: the earlier of its
          // future dates (`docs/TASK_DATES_SPEC.md` R5), never a past When.
          if let day = [task.scheduled, task.deadline].compactMap({ $0 })
            .filter({ $0 > today }).min() {
            return relativeDayLabel(day, today: today)
          }
          return containerSubtitle(for: task, areaByID: areaByID, projectByID: projectByID, fallbackInbox: false)
        }
      ),
      makeSummary(
        id: TasksWidgetListSummary.inboxID,
        kind: .inbox,
        title: String(localized: "Inbox"),
        symbol: RegistryIcons.sfSymbol(for: "list.inbox"),
        tasks: triageTasks,
        today: today,
        isRedacted: redacted,
        subtitleFor: { _ in nil }
      ),
      makeSummary(
        id: TasksWidgetListSummary.starredID,
        kind: .starred,
        title: String(localized: "Starred"),
        symbol: RegistryIcons.sfSymbol(for: "list.starred"),
        tasks: starredTasks,
        today: today,
        isRedacted: redacted,
        subtitleFor: { task in
          containerSubtitle(for: task, areaByID: areaByID, projectByID: projectByID, fallbackInbox: false)
        }
      ),
    ]

    for project in structure.projects where project.status == .active {
      let projectTasks = LocalCache.tasks(in: context, filter: .project(project.id))
        .filter { $0.status == .open && !$0.isHeading && $0.fadedAt == nil }
      lists.append(makeSummary(
        id: TasksWidgetListSummary.projectID(project.id),
        kind: .project,
        title: project.title,
        symbol: RegistryIcons.sfSymbol(for: "place.project"),
        tasks: projectTasks,
        today: today,
        isRedacted: redacted,
        subtitleFor: { task in
          if let s = task.scheduled, s > today { return relativeDayLabel(s, today: today) }
          return nil
        }
      ))
    }

    for area in structure.areas {
      let areaTasks = LocalCache.tasks(in: context, filter: .area(area.id))
        .filter { $0.status == .open && !$0.isHeading && $0.fadedAt == nil }
      lists.append(makeSummary(
        id: TasksWidgetListSummary.areaID(area.id),
        kind: .area,
        title: area.title,
        symbol: RegistryIcons.sfSymbol(for: "place.area"),
        tasks: areaTasks,
        today: today,
        isRedacted: redacted,
        subtitleFor: { task in
          if let pid = task.project, let p = projectByID[pid] { return p.title }
          if let s = task.scheduled, s > today { return relativeDayLabel(s, today: today) }
          return nil
        }
      ))
    }

    let prefs = AppearancePreferences.shared
    let accentHex: String? = (prefs.accentColorID == "colorful") ? nil : prefs.currentFruit.lightHex

    return TasksWidgetSnapshot(
      day: today,
      updatedAt: Date(),
      isRedacted: redacted,
      accentHex: accentHex,
      lists: lists
    )
  }

  private static func makeSummary(
    id: String,
    kind: TasksWidgetListKind,
    title: String,
    symbol: String,
    tasks: [SeptenaTask],
    today: String,
    isRedacted: Bool,
    subtitleFor: (SeptenaTask) -> String?
  ) -> TasksWidgetListSummary {
    let items: [TasksWidgetTaskItem] = isRedacted
      ? []
      : tasks.prefix(TasksWidgetSnapshot.maxItemsPerList).map { task in
          TasksWidgetTaskItem(
            id: task.id,
            title: task.title,
            isOverdue: {
              let state = task.deadlineState(today: today)
              return state == .dueToday || state == .overdue
            }(),
            isStarred: task.starred,
            subtitle: subtitleFor(task),
            timeBadge: formatTimeBadge(startTime: task.startTime, durationMinutes: task.durationMinutes),
            deadlineBadge: formatDeadlineBadge(task.deadline, today: today)
          )
        }
    return TasksWidgetListSummary(
      id: id,
      kind: kind,
      title: title,
      symbol: symbol,
      count: tasks.count,
      items: items
    )
  }

  private static func containerSubtitle(
    for task: SeptenaTask,
    areaByID: [String: Area],
    projectByID: [String: Project],
    fallbackInbox: Bool
  ) -> String? {
    if let pid = task.project, let p = projectByID[pid] { return p.title }
    if let aid = task.area, let a = areaByID[aid] { return a.title }
    return (fallbackInbox && task.isInTriageBand) ? String(localized: "Inbox") : nil
  }

  private static func formatTimeBadge(startTime: String?, durationMinutes: Int?) -> String? {
    guard let start = startTime, !start.isEmpty else { return nil }
    guard let duration = durationMinutes, duration > 0 else { return start }
    let parts = start.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return start }
    let total = (parts[0] * 60 + parts[1] + duration) % 1440
    let end = String(format: "%02d:%02d", total / 60, total % 60)
    return "\(start)–\(end)"
  }

  private static func formatDeadlineBadge(_ deadline: String?, today: String) -> String? {
    guard let deadline, !deadline.isEmpty else { return nil }
    if deadline < today { return String(localized: "Overdue") }
    if deadline == today { return String(localized: "Today") }
    return relativeDayLabel(deadline, today: today)
  }

  private static func relativeDayLabel(_ ymd: String, today: String) -> String {
    if ymd == today { return String(localized: "Today") }
    if let tomorrow = SeptenaDate.offsetDays(1, from: today), ymd == tomorrow {
      return String(localized: "Tomorrow")
    }
    if let date = SeptenaDate.parse(ymd) {
      return shortDateFormatter.string(from: date)
    }
    return ymd
  }
}

/// Observes task/structure/sync/day-rollover changes and keeps
/// `TasksWidgetSnapshotStore` fresh for Home Screen, Lock Screen, and macOS
/// Desktop widgets.
@MainActor
final class TasksWidgetSnapshotPublisher {
  static let shared = TasksWidgetSnapshotPublisher()

  private static let debounce: Duration = .milliseconds(300)

  private var started = false
  private var pendingTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var darwinRegistered = false
  /// The only setting the snapshot reads. `UserDefaults.didChangeNotification`
  /// fires for every defaults write in the process, the snapshot's own save
  /// included, so a bare observer rebuilt the snapshot every debounce forever
  /// (a full store read on the main actor, ~3 times a second).
  private var lastAppLockRedacted = TasksWidgetBuilder.isAppLockRedacted()

  private init() {}

  func start() {
    guard !started else { return }
    started = true
    let names: [Notification.Name] = [
      .septenaTasksChanged,
      .septenaStructureChanged,
      .septaskSettingsPulled,
      .septenaAppearanceChanged,
      .NSCalendarDayChanged,
    ]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          TasksWidgetSnapshotPublisher.shared.schedulePublish()
        }
      })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        TasksWidgetSnapshotPublisher.shared.appLockSettingMayHaveChanged()
      }
    })
    registerDarwinObserver()
    publishNow()
  }

  private func appLockSettingMayHaveChanged() {
    let redacted = TasksWidgetBuilder.isAppLockRedacted()
    guard redacted != lastAppLockRedacted else { return }
    lastAppLockRedacted = redacted
    schedulePublish()
  }

  func schedulePublish() {
    pendingTask?.cancel()
    pendingTask = Task { @MainActor in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      self.publishNow()
    }
  }

  func publishNow() {
    pendingTask?.cancel()
    pendingTask = nil
    let context = LocalStore.shared.container.mainContext
    let snapshot = TasksWidgetBuilder.build(in: context)
    TasksWidgetSnapshotStore.save(snapshot, reloadTimelines: true)
  }

  /// Drains any task completions that occurred inside a widget extension while
  /// the host app was suspended or closed, routing every write through
  /// `TaskMutator` (the canonical write boundary).
  func drainPendingCompletions(using mutator: TaskMutator) {
    let pendingIDs = TasksWidgetSnapshotStore.takePendingCompletions()
    guard !pendingIDs.isEmpty else { return }
    for id in pendingIDs {
      mutator.complete(id: id)
    }
    publishNow()
  }

  private func registerDarwinObserver() {
    guard !darwinRegistered else { return }
    darwinRegistered = true
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(TasksWidgetKind.pendingCompletionDarwinNotification as CFString)
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      center,
      observer,
      { _, _, _, _, _ in
        Task { @MainActor in
          let services = SeptenaServices.shared
          services.bindWriteBoundary()
          TasksWidgetSnapshotPublisher.shared.drainPendingCompletions(using: services.taskMutator)
        }
      },
      name.rawValue,
      nil,
      .deliverImmediately
    )
  }
}
#endif
