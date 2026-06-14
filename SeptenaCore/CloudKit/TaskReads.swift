import Foundation
import SwiftData

// TaskReads — the read side of the task data path. Synthesizes
// `TasksListResponse` / `TasksCounts` from the local SwiftData mirror
// that CKSyncEngine keeps fresh; the shape matches what the (now
// retired) FastAPI endpoints used to return so existing view code
// doesn't have to branch on backend.
//
// Mutations live in `TaskMutator`. No FastAPI seams remain in either path.

@MainActor
enum TaskReads {

  // MARK: - list

  /// CloudKit-mode return values for `client.list(...)`. View-string
  /// semantics:
  ///   "today"      — open + (today flag or scheduled≤today or due≤today)
  ///   "triage"     — unratified: agent proposals + loose captures (⊇ inbox)
  ///   "inbox"      — open, no area/project/scheduled/due/today
  ///   "upcoming"   — open, !today, scheduled>today or due>today
  ///   "unscheduled"— open, !today, no scheduled, no due
  ///                  ("anytime"/"someday" are accepted aliases)
  ///   "logbook"    — status==done
  ///   "all"        — every live task (filter out tombstones)
  ///   "next"       — alias of "today" (used by NextItemsSection)
  /// `area` / `project` scoping always wins over the view string.
  static func list(view: String = "today",
                   area: String? = nil,
                   project: String? = nil,
                   days: Int = 90,
                   context: ModelContext) async -> TasksListResponse {
    // See note on `counts(...)` — same off-main race applies. Force
    // MainActor execution so SwiftData reads never hit the cooperative
    // executor.
    return await MainActor.run {
      localList(view: view, area: area, project: project, days: days, context: context)
    }
  }

  /// Synthesize a `TasksListResponse` from SwiftData. Matches the
  /// server's shape (view, today, items, optional review/done) so
  /// callers can treat the result identically.
  static func localList(view: String,
                        area: String?,
                        project: String?,
                        days: Int,
                        context: ModelContext) -> TasksListResponse {
    let todayIso = SeptenaDate.today

    // Area/project scoping bypasses the view string — they're always
    // "give me every live task with this area/project."
    if let aid = area {
      let items = LocalCache.tasks(in: context, filter: .area(aid))
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)
    }
    if let pid = project {
      let items = LocalCache.tasks(in: context, filter: .project(pid))
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)
    }

    switch view {
    case "today":
      let items = LocalCache.tasks(in: context, filter: .today)
      // The server's "today" response also includes `review` (overdue
      // scheduled-but-not-due) and `done` (completed today). For Phase
      // 5 we leave these empty — the UI tolerates absent arrays and
      // the data is computable later if we need it.
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: [], done: [])

    case "triage":
      // Unratified layer above Today (agent proposals + loose human captures).
      // Superset of "inbox"; see `docs/TRIAGE_BAND_SPEC.md`.
      let items = LocalCache.tasks(in: context, filter: .triage)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "inbox":
      let items = LocalCache.tasks(in: context, filter: .inbox)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "upcoming":
      let items = LocalCache.tasks(in: context, filter: .upcoming)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    // "anytime" is the user-facing name; "unscheduled" is the legacy server
    // key; "someday" is the retired bucket — all resolve to the single
    // open-and-dateless pile.
    case "unscheduled", "anytime", "someday":
      let items = LocalCache.tasks(in: context, filter: .unscheduled)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "logbook":
      // Filter to last `days` based on completedAt.
      let cutoff = cutoffDate(daysAgo: days)
      let all = LocalCache.tasks(in: context, filter: .logbook)
      let items = all.filter { t in
        guard let stamp = t.completedAt else { return false }
        return stamp >= cutoff
      }
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "all", "next":
      // Live tasks regardless of status (the server's "all" returns
      // open + done + cancelled; the aggregators downstream decide).
      let items = LocalCache.allTasks(in: context)
        .filter { $0.deletedAt == nil }
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    default:
      // Unknown view — fall back to inbox so we don't blow up.
      let items = LocalCache.tasks(in: context, filter: .inbox)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)
    }
  }

  // MARK: - counts

  static func counts(context: ModelContext) async -> TasksCounts {
    // Force the SwiftData reads onto the main thread regardless of
    // caller's executor. The enum-level @MainActor annotation isn't
    // enough because ModelContext isn't Sendable — when passed across
    // an `async let` boundary, the runtime can run this body off-main,
    // which crashes SwiftData (mainContext is not thread-safe). See
    // malloc double-free repro 2026-05-21 (TaskReads.localCount path).
    return await MainActor.run { localCounts(context: context) }
  }

  static func localCounts(context: ModelContext) -> TasksCounts {
    // ONE pass over the table. This used to be five filtered
    // `LocalCache.tasks` calls plus an `allTasks` — six full-table
    // fetch+convert scans on the main thread, and it runs on every task
    // change (sidebar reload + the dashboard's Tasks tile). The bucket
    // rules mirror `LocalCache.convert`'s filter semantics — keep in sync.
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    let today = SeptenaDate.today
    var todayN = 0, inbox = 0, triage = 0, upcoming = 0, unscheduled = 0
    var allOpen = 0
    for e in rows {
      // Matches the historical openCount (an `allTasks` reduce), which
      // did not exclude pendingDeletion rows.
      if e.status == .open { allOpen += 1 }
      guard !e.pendingDeletion else { continue }
      // Today excludes the triage band — unratified rows live above Today,
      // not in it (docs/TRIAGE_BAND_SPEC.md). `triage` counts the band.
      if e.isInTriageBand { triage += 1 }
      if e.isOnToday && !e.isInTriageBand { todayN += 1 }
      switch e.status {
      case .open:
        let undated = e.scheduled == nil && e.due == nil
        if undated, e.project == nil, e.area == nil, !e.today { inbox += 1 }
        if !e.today {
          if let s = e.scheduled, s > today { upcoming += 1 }
          else if let d = e.due, d > today { upcoming += 1 }
          if undated { unscheduled += 1 }
        }
      default:
        break
      }
    }
    return TasksCounts(today: today,
                       todayCount: todayN,
                       reviewCount: 0,
                       inboxCount: inbox,
                       triageCount: triage,
                       upcomingCount: upcoming,
                       unscheduledCount: unscheduled,
                       openCount: allOpen)
  }

  // MARK: - tasksHistory

  /// Local replacement for the (removed) FastAPI `/api/tasks/history`.
  /// Counts done-today, deferred (status open with todaySetOn matching the
  /// day), and cancelled tasks per day for the last `days` days ending
  /// today. The Tasks tile histogram only consumes `daily[*].done` —
  /// `made` and `deferred` are best-effort and `cancelled` is exact.
  static func tasksHistory(days: Int = 7, context: ModelContext) -> TasksHistory {
    let todayIso = SeptenaDate.today
    let cal = Calendar.current
    let now = Date()

    // Build the day buckets in chronological order ending today.
    var dayKeys: [String] = []
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    for offset in stride(from: days - 1, through: 0, by: -1) {
      guard let d = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
      dayKeys.append(f.string(from: d))
    }

    var doneByDay: [String: Int] = [:]
    var cancelledByDay: [String: Int] = [:]
    var madeByDay: [String: Int] = [:]
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    for e in rows {
      // Bucket completions / cancellations by the date prefix of completedAt
      // ("yyyy-MM-dd" — the same shape the server stamps).
      if let stamp = e.completedAt, stamp.count >= 10 {
        let day = String(stamp.prefix(10))
        switch e.status {
        case .done: doneByDay[day, default: 0] += 1
        case .cancelled: cancelledByDay[day, default: 0] += 1
        default: break
        }
      }
      if e.createdAt != .distantPast {
        madeByDay[f.string(from: e.createdAt), default: 0] += 1
      }
    }

    let daily = dayKeys.map { day in
      TasksHistoryDay(date: day,
                      made: madeByDay[day] ?? 0,
                      done: doneByDay[day] ?? 0,
                      deferred: 0,
                      cancelled: cancelledByDay[day] ?? 0)
    }
    return TasksHistory(daily: daily, today: todayIso, windowDays: days)
  }

  // MARK: - helpers

  /// Logbook cutoff stamp at YYYY-MM-DDTHH:MM:SS — matches what the
  /// server stores in `completed_at`, so direct string compare works.
  private static func cutoffDate(daysAgo: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: d)
  }
}
