import Foundation

// Shared diff helpers for passive CloudKit sync on live task lists — the
// arrival counterpart to ghost-check completions. Callers own @State arrays,
// `SettleStore`, and `A11yMotion`; this file only classifies diffs and merges
// settling rows back in.

enum RemoteTaskSync {
  /// IDs present in `fresh` but not `prior` — rows worth revealing with the
  /// expand beat. Empty when `animate` is false (first paint, cold assign) so
  /// lists don't cascade-fade on load.
  static func arrivingIDs(
    prior: [SeptenaTask],
    fresh: [SeptenaTask],
    excluding: Set<String> = [],
    animate: Bool
  ) -> Set<String> {
    guard animate else { return [] }
    let priorIDs = Set(prior.map(\.id))
    return Set(fresh.compactMap { task in
      priorIDs.contains(task.id) || excluding.contains(task.id) ? nil : task.id
    })
  }

  /// One-shot amber wash when a row lands on Today from another device. Silent
  /// — no haptics (same contract as ghost-check). Capped so a batch sync
  /// doesn't pulse the whole list — the first `cap` Today rows in LIST order,
  /// so the ones that flash are the ones nearest the top, not whichever ids a
  /// `Set` happened to yield first. `SeptaskKitTaskList.queueTodayArrivalFlashes`
  /// is the AppKit twin; keep the cap and the ordering rule in step.
  @MainActor
  static func flashTodayPromotes(
    ids: Set<String>,
    in tasks: [SeptenaTask],
    via store: PromoteFlashStore,
    cap: Int = 3
  ) {
    guard !ids.isEmpty else { return }
    var flashed = 0
    for task in tasks where ids.contains(task.id) && task.isOnToday {
      store.flash(task.id)
      flashed += 1
      if flashed >= cap { break }
    }
  }

  /// Reinsert mid-settle rows the fresh read dropped (done tasks vanish from
  /// Today/Inbox queries) at their prior anchor so they fade in place.
  static func preservingSettling(
    fresh: [SeptenaTask],
    prior: [SeptenaTask],
    isSettling: (String) -> Bool
  ) -> [SeptenaTask] {
    let freshIDs = Set(fresh.map(\.id))
    let lingering = prior.filter { isSettling($0.id) && !freshIDs.contains($0.id) }
    var merged = fresh
    for task in lingering {
      guard let priorIndex = prior.firstIndex(where: { $0.id == task.id }) else { continue }
      var insertAt = 0
      for i in stride(from: priorIndex - 1, through: 0, by: -1) {
        if let anchor = merged.firstIndex(where: { $0.id == prior[i].id }) {
          insertAt = anchor + 1
          break
        }
      }
      merged.insert(task, at: min(insertAt, merged.count))
    }
    return merged
  }
}
