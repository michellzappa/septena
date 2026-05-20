import Foundation
import SwiftData

// TaskReads — the read-side seam for the FastAPI ⇄ CloudKit cutover.
//
// Phase 5: every place in the app that fetched task data through
// `SeptenaClient.list / .counts` for displaying lists, badge counts,
// or the dashboard now goes through here. When the backend flag is
// `.fastAPI` the call passes straight through to the network client;
// when it's `.cloudKit` we synthesize the same response shape from
// the local SwiftData mirror (which CKSyncEngine keeps fresh). View
// code doesn't have to branch — same return type, same call site.
//
// Mutations are NOT routed here — `TaskMutator` owns the write side
// and has been backend-aware since Phase 1.

@MainActor
enum TaskReads {

  // MARK: - list

  /// CloudKit-mode return values for `client.list(...)`. View-string
  /// semantics:
  ///   "today"      — open + (today flag or scheduled≤today or due≤today)
  ///   "inbox"      — open, no area/project/scheduled/due/today
  ///   "upcoming"   — open, !today, scheduled>today or due>today
  ///   "unscheduled"— open, !today, no scheduled, no due
  ///   "someday"    — status==someday
  ///   "logbook"    — status==done
  ///   "all"        — every live task (filter out tombstones)
  ///   "next"       — alias of "today" (used by NextItemsSection)
  /// `area` / `project` scoping always wins over the view string.
  static func list(view: String = "today",
                   area: String? = nil,
                   project: String? = nil,
                   days: Int = 90,
                   client: SeptenaClient,
                   context: ModelContext) async throws -> TasksListResponse {
    _ = client
    return localList(view: view, area: area, project: project, days: days, context: context)
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

    case "inbox":
      let items = LocalCache.tasks(in: context, filter: .inbox)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "upcoming":
      let items = LocalCache.tasks(in: context, filter: .upcoming)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "unscheduled":
      let items = LocalCache.tasks(in: context, filter: .unscheduled)
      return TasksListResponse(view: view, today: todayIso, items: items,
                               review: nil, done: nil)

    case "someday":
      let items = LocalCache.tasks(in: context, filter: .someday)
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

  static func counts(client: SeptenaClient,
                     context: ModelContext) async throws -> TasksCounts {
    _ = client
    return localCounts(context: context)
  }

  static func localCounts(context: ModelContext) -> TasksCounts {
    let today = LocalCache.tasks(in: context, filter: .today).count
    let inbox = LocalCache.tasks(in: context, filter: .inbox).count
    let upcoming = LocalCache.tasks(in: context, filter: .upcoming).count
    let unscheduled = LocalCache.tasks(in: context, filter: .unscheduled).count
    let someday = LocalCache.tasks(in: context, filter: .someday).count
    let allOpen = LocalCache.allTasks(in: context).reduce(into: 0) { acc, t in
      if t.status == .open { acc += 1 }
    }
    return TasksCounts(today: SeptenaDate.today,
                       todayCount: today,
                       reviewCount: 0,
                       inboxCount: inbox,
                       upcomingCount: upcoming,
                       unscheduledCount: unscheduled,
                       somedayCount: someday,
                       openCount: allOpen)
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
