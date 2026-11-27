import Foundation

/// Waiting on a person (docs/REVIEW_SPEC.md §6, ADR 0053). The rules every
/// shell reads: when a task waits, how the row says so, and what Waiting On…
/// writes. The task's When date is the day to chase; there is no other field.
enum TaskWaiting {
  /// The longest name `waitingOn` holds (`registry/entities.json`).
  static let maxNameLength = 80

  /// True when `waitingOn` names someone.
  static func isWaiting(_ waitingOn: String?) -> Bool {
    !(waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  /// The name as stored: trimmed, at most `maxNameLength` UTF-16 units (the
  /// backend counts as JavaScript does), nil when empty (an empty name clears
  /// the wait).
  static func normalizedName(_ raw: String?) -> String? {
    guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else { return nil }
    while name.utf16.count > maxNameLength { name.removeLast() }
    return name
  }

  /// Whole days from `since` to `today` (both `YYYY-MM-DD`), never negative.
  static func days(since: String?, today: String) -> Int? {
    guard let start = SeptenaDate.startOfDay(for: since ?? ""),
          let end = SeptenaDate.startOfDay(for: today) else { return nil }
    let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    return max(0, days)
  }

  /// "Waiting on Anna · 5 days", or "Waiting on Anna" on the first day and
  /// when the start day is unknown (as on Android and web). nil when the task
  /// does not wait.
  static func label(on waitingOn: String?, since: String?, today: String) -> String? {
    guard let name = normalizedName(waitingOn) else { return nil }
    let head = RegistryWaiting.label(name: name)
    guard let days = days(since: since, today: today), days > 0 else { return head }
    return [head, RegistryPrompts.waitingDaysPhrase(count: days)].joined(separator: " · ")
  }

  /// The check-back day Waiting On… offers for a new wait.
  static func defaultCheckBack(today: String) -> Date? {
    SeptenaDate.parse(SeptenaDate.offsetDays(RegistryWaiting.defaultCheckBackDays, from: today))
  }
}

extension ReviewGroup {
  /// The Review list's rows by group, each group in its order. Waiting holds
  /// the oldest wait first (docs/REVIEW_SPEC.md §6); the other groups keep
  /// the list's order. Both shells read it.
  static func grouped(_ tasks: [SeptenaTask]) -> [ReviewGroup: [SeptenaTask]] {
    var byGroup: [ReviewGroup: [SeptenaTask]] = [:]
    for task in tasks {
      guard let group = task.reviewGroup else { continue }
      byGroup[group, default: []].append(task)
    }
    if let waiting = byGroup[.waiting] {
      byGroup[.waiting] = waiting.enumerated().sorted { a, b in
        // A wait with no start day sorts last; ties keep the list's order.
        let da = a.element.waitingSince ?? "9999-12-31"
        let db = b.element.waitingSince ?? "9999-12-31"
        return da == db ? a.offset < b.offset : da < db
      }.map(\.element)
    }
    return byGroup
  }
}
