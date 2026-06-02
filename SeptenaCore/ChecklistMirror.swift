import Foundation
import SwiftData

@MainActor
enum ChecklistMirror {
  private static let fallbackHabitBuckets = ["morning", "afternoon", "evening"]

  static func loadHabitsDay(context: ModelContext, date: String) -> HabitsDayResponse? {
    let defs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.title, comparator: .localizedStandard)]
    ))) ?? []
    guard !defs.isEmpty else { return nil }

    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.date == date }
    ))) ?? []
    let stateByID = Dictionary(uniqueKeysWithValues: states.map { ($0.habitID, $0) })

    let orderedBuckets = defs.reduce(into: [String]()) { out, item in
      if !out.contains(item.bucket) { out.append(item.bucket) }
    }
    let buckets = orderedBuckets.isEmpty ? fallbackHabitBuckets : orderedBuckets

    var grouped: [String: [[String: Any]]] = [:]
    var doneCount = 0
    for def in defs {
      let state = stateByID[def.id]
      let done = state?.done ?? false
      let skipped = state?.skipped ?? false
      if done { doneCount += 1 }
      grouped[def.bucket, default: []].append([
        "id": def.id,
        "name": def.title,
        "emoji": def.emoji as Any,
        "bucket": def.bucket,
        "done": done,
        "skipped": skipped,
        "note": state?.note as Any,
        "time": state?.time as Any,
      ])
    }

    return decode(HabitsDayResponse.self, from: [
      "date": date,
      "buckets": buckets,
      "grouped": grouped,
      "done_count": doneCount,
      "total": defs.count,
      "percent": defs.isEmpty ? 0 : Int(round((Double(doneCount) * 100) / Double(defs.count))),
    ])
  }

  static func replaceHabitsDay(_ response: HabitsDayResponse, context: ModelContext) {
    let defs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? []
    let defsByID = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.date == response.date }
    ))) ?? []
    let statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.habitID, $0) })

    var incomingIDs = Set<String>()
    var sortIndex = 0
    for bucket in response.buckets {
      for item in response.grouped[bucket] ?? [] {
        incomingIDs.insert(item.id)
        let def = defsByID[item.id] ?? HabitDefinitionEntity(id: item.id, title: item.name,
                                                             emoji: item.emoji, bucket: item.bucket)
        def.title = item.name
        def.emoji = item.emoji
        def.bucket = item.bucket
        def.sortIndex = sortIndex
        def.updatedAt = .now
        if def.modelContext == nil { context.insert(def) }
        sortIndex += 1

        if item.done || item.skipped || item.note != nil || item.time != nil {
          let state = statesByID[item.id] ?? HabitDayStateEntity(
            id: "habit:\(response.date):\(item.id)",
            date: response.date,
            habitID: item.id,
            done: item.done,
            skipped: item.skipped
          )
          state.done = item.done
          state.skipped = item.skipped
          state.note = item.note
          state.time = item.time
          state.updatedAt = .now
          if state.modelContext == nil { context.insert(state) }
        } else if let state = statesByID[item.id] {
          context.delete(state)
        }
      }
    }

    for def in defs where !incomingIDs.contains(def.id) {
      let habitID = def.id
      let staleStates = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
        predicate: #Predicate { $0.habitID == habitID }
      ))) ?? []
      for state in staleStates { context.delete(state) }
      context.delete(def)
    }

    try? context.save()
  }

  static func replaceAllHabitsHistory(_ response: HabitsRangeResponse, context: ModelContext) {
    let existingDefs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? []
    let existingDefsByID = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.id, $0) })
    let existingStates = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>())) ?? []
    let existingStatesByID = Dictionary(uniqueKeysWithValues: existingStates.map { ($0.id, $0) })

    var seenDefinitionIDs = Set<String>()
    var seenStateIDs = Set<String>()
    var sortIndexByID: [String: Int] = [:]
    var nextSortIndex = 0

    for day in response.days {
      for bucket in day.buckets {
        for item in day.grouped[bucket] ?? [] {
          seenDefinitionIDs.insert(item.id)
          if sortIndexByID[item.id] == nil {
            sortIndexByID[item.id] = nextSortIndex
            nextSortIndex += 1
          }
          let def = existingDefsByID[item.id] ?? HabitDefinitionEntity(id: item.id,
                                                                       title: item.name,
                                                                       emoji: item.emoji,
                                                                       bucket: item.bucket)
          def.title = item.name
          def.emoji = item.emoji
          def.bucket = item.bucket
          def.sortIndex = sortIndexByID[item.id] ?? 0
          def.updatedAt = .now
          if def.modelContext == nil { context.insert(def) }

          let stateID = "habit:\(day.date):\(item.id)"
          if item.done || item.skipped || item.note != nil || item.time != nil {
            seenStateIDs.insert(stateID)
            let state = existingStatesByID[stateID] ?? HabitDayStateEntity(
              id: stateID,
              date: day.date,
              habitID: item.id,
              done: item.done,
              skipped: item.skipped
            )
            state.done = item.done
            state.skipped = item.skipped
            state.note = item.note
            state.time = item.time
            state.updatedAt = .now
            if state.modelContext == nil { context.insert(state) }
          }
        }
      }
    }

    for state in existingStates where !seenStateIDs.contains(state.id) {
      context.delete(state)
    }
    for def in existingDefs where !seenDefinitionIDs.contains(def.id) {
      context.delete(def)
    }
    try? context.save()
  }

  /// Local history aggregation for the Habits dashboard tile + destination view.
  /// Mirrors the shape of `/api/habits/history?days=N`. Total is the current
  /// definition count (we don't track per-day membership history, since the
  /// dashboard only cares about the success-rate trend, not headcount drift).
  static func loadHabitsHistory(context: ModelContext, days: Int) -> HabitHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return HabitHistoryResponse(daily: [], total: 0)
    }
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(startDate) ?? today

    let total = (try? context.fetchCount(FetchDescriptor<HabitDefinitionEntity>())) ?? 0
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today && $0.done == true }
    ))) ?? []
    let doneByDate = Dictionary(grouping: states, by: \.date).mapValues(\.count)

    var daily: [HabitHistoryPoint] = []
    var grandTotal = 0
    for offset in (0..<days).reversed() {
      guard let date = calendar.date(byAdding: .day, value: -offset, to: todayDate),
            let dateStr = SeptenaDate.format(date) else { continue }
      let done = doneByDate[dateStr] ?? 0
      let percent = total > 0 ? Int(round(Double(done) * 100 / Double(total))) : 0
      daily.append(HabitHistoryPoint(date: dateStr, done: done, total: total, percent: percent))
      grandTotal += done
    }
    return HabitHistoryResponse(daily: daily, total: grandTotal)
  }

  /// Consecutive-day completion streak for a single habit, counting back
  /// from `todayISO`. Returns 0 if the habit isn't marked done on `todayISO`.
  /// Pure read — no writes, no side effects.
  static func habitStreak(context: ModelContext, habitId: String, asOf todayISO: String) -> Int {
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.habitID == habitId && $0.done == true }
    ))) ?? []
    let doneDates = Set(states.map(\.date))

    var streak = 0
    var cursor = todayISO
    while doneDates.contains(cursor) {
      streak += 1
      guard let base = SeptenaDate.parse(cursor),
            let prev = Calendar.current.date(byAdding: .day, value: -1, to: base),
            let prevStr = SeptenaDate.format(prev) else { break }
      cursor = prevStr
    }
    return streak
  }

  static func loadSupplementsHistory(context: ModelContext, days: Int) -> SupplementHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return SupplementHistoryResponse(daily: [], total: 0)
    }
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(startDate) ?? today

    let total = (try? context.fetchCount(FetchDescriptor<SupplementDefinitionEntity>())) ?? 0
    let states = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today && $0.done == true }
    ))) ?? []
    let doneByDate = Dictionary(grouping: states, by: \.date).mapValues(\.count)

    var daily: [SupplementHistoryPoint] = []
    var grandTotal = 0
    for offset in (0..<days).reversed() {
      guard let date = calendar.date(byAdding: .day, value: -offset, to: todayDate),
            let dateStr = SeptenaDate.format(date) else { continue }
      let done = doneByDate[dateStr] ?? 0
      let percent = total > 0 ? Int(round(Double(done) * 100 / Double(total))) : 0
      daily.append(SupplementHistoryPoint(date: dateStr, done: done, total: total, percent: percent))
      grandTotal += done
    }
    return SupplementHistoryResponse(daily: daily, total: grandTotal)
  }

  static func loadChoresHistory(context: ModelContext, days: Int) -> ChoreHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return ChoreHistoryResponse(daily: [], total: 0)
    }
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(startDate) ?? today

    let total = (try? context.fetchCount(FetchDescriptor<ChoreDefinitionEntity>())) ?? 0
    let completeAction = "complete"
    let events = (try? context.fetch(FetchDescriptor<ChoreEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today && $0.action == completeAction }
    ))) ?? []
    let completedByDate = Dictionary(grouping: events, by: \.date).mapValues(\.count)

    var daily: [ChoreHistoryPoint] = []
    var grandTotal = 0
    for offset in (0..<days).reversed() {
      guard let date = calendar.date(byAdding: .day, value: -offset, to: todayDate),
            let dateStr = SeptenaDate.format(date) else { continue }
      let completed = completedByDate[dateStr] ?? 0
      daily.append(ChoreHistoryPoint(date: dateStr, completed: completed, total: total))
      grandTotal += completed
    }
    return ChoreHistoryResponse(daily: daily, total: grandTotal)
  }

  static func loadSupplementsDay(context: ModelContext, date: String) -> SupplementsDayResponse? {
    let defs = (try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.title, comparator: .localizedStandard)]
    ))) ?? []
    guard !defs.isEmpty else { return nil }

    let states = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.date == date }
    ))) ?? []
    let stateByID = Dictionary(uniqueKeysWithValues: states.map { ($0.supplementID, $0) })

    let items: [[String: Any]] = defs.map { def in
      let state = stateByID[def.id]
      return [
        "id": def.id,
        "name": def.title,
        "emoji": def.emoji as Any,
        "done": state?.done ?? false,
        "note": state?.note as Any,
        "time": state?.time as Any,
      ]
    }

    return decode(SupplementsDayResponse.self, from: [
      "date": date,
      "items": items,
      "done_count": items.filter { ($0["done"] as? Bool) == true }.count,
      "total": items.count,
      "percent": items.isEmpty ? 0 : Int(round((Double(items.filter { ($0["done"] as? Bool) == true }.count) * 100) / Double(items.count))),
    ])
  }

  static func replaceSupplementsDay(_ response: SupplementsDayResponse, context: ModelContext) {
    let defs = (try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
    let defsByID = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
    let states = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.date == response.date }
    ))) ?? []
    let statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.supplementID, $0) })

    let incomingIDs = Set(response.items.map(\.id))
    for (index, item) in response.items.enumerated() {
      let def = defsByID[item.id] ?? SupplementDefinitionEntity(id: item.id, title: item.name, emoji: item.emoji)
      def.title = item.name
      def.emoji = item.emoji
      def.sortIndex = index
      def.updatedAt = .now
      if def.modelContext == nil { context.insert(def) }

      if item.done || item.note != nil || item.time != nil {
        let state = statesByID[item.id] ?? SupplementDayStateEntity(
          id: "supplement:\(response.date):\(item.id)",
          date: response.date,
          supplementID: item.id,
          done: item.done
        )
        state.done = item.done
        state.note = item.note
        state.time = item.time
        state.updatedAt = .now
        if state.modelContext == nil { context.insert(state) }
      } else if let state = statesByID[item.id] {
        context.delete(state)
      }
    }

    for def in defs where !incomingIDs.contains(def.id) {
      let supplementID = def.id
      let staleStates = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
        predicate: #Predicate { $0.supplementID == supplementID }
      ))) ?? []
      for state in staleStates { context.delete(state) }
      context.delete(def)
    }

    try? context.save()
  }

  static func replaceAllSupplementsHistory(_ response: SupplementsRangeResponse, context: ModelContext) {
    let existingDefs = (try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
    let existingDefsByID = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.id, $0) })
    let existingStates = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>())) ?? []
    let existingStatesByID = Dictionary(uniqueKeysWithValues: existingStates.map { ($0.id, $0) })

    var seenDefinitionIDs = Set<String>()
    var seenStateIDs = Set<String>()
    var sortIndexByID: [String: Int] = [:]
    var nextSortIndex = 0

    for day in response.days {
      for item in day.items {
        seenDefinitionIDs.insert(item.id)
        if sortIndexByID[item.id] == nil {
          sortIndexByID[item.id] = nextSortIndex
          nextSortIndex += 1
        }
        let def = existingDefsByID[item.id] ?? SupplementDefinitionEntity(id: item.id,
                                                                           title: item.name,
                                                                           emoji: item.emoji)
        def.title = item.name
        def.emoji = item.emoji
        def.sortIndex = sortIndexByID[item.id] ?? 0
        def.updatedAt = .now
        if def.modelContext == nil { context.insert(def) }

        let stateID = "supplement:\(day.date):\(item.id)"
        if item.done || item.note != nil || item.time != nil {
          seenStateIDs.insert(stateID)
          let state = existingStatesByID[stateID] ?? SupplementDayStateEntity(
            id: stateID,
            date: day.date,
            supplementID: item.id,
            done: item.done
          )
          state.done = item.done
          state.note = item.note
          state.time = item.time
          state.updatedAt = .now
          if state.modelContext == nil { context.insert(state) }
        }
      }
    }

    for state in existingStates where !seenStateIDs.contains(state.id) {
      context.delete(state)
    }
    for def in existingDefs where !seenDefinitionIDs.contains(def.id) {
      context.delete(def)
    }
    try? context.save()
  }

  static func loadChores(context: ModelContext) -> [ChoreItem] {
    let canonicalDefs = (try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.title, comparator: .localizedStandard)]
    ))) ?? []
    if !canonicalDefs.isEmpty {
      let events = (try? context.fetch(FetchDescriptor<ChoreEventEntity>(
        sortBy: [SortDescriptor(\.sortKey)]
      ))) ?? []
      let eventsByChore = Dictionary(grouping: events, by: \.choreID)
      return canonicalDefs.map { choreItem($0, events: eventsByChore[$0.id] ?? []) }
    }
    let rows = (try? context.fetch(FetchDescriptor<ChoreSnapshotEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.title, comparator: .localizedStandard)]
    ))) ?? []
    return rows.compactMap(choreItem)
  }

  static func replaceChores(_ chores: [ChoreItem], context: ModelContext) {
    let existing = (try? context.fetch(FetchDescriptor<ChoreSnapshotEntity>())) ?? []
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    let incomingIDs = Set(chores.map(\.id))

    for (index, chore) in chores.enumerated() {
      let row = existingByID[chore.id] ?? ChoreSnapshotEntity(id: chore.id, title: chore.name)
      row.title = chore.name
      row.emoji = chore.emoji
      row.dueDate = chore.dueDate
      row.lastCompleted = chore.lastCompleted
      row.lastCompletedTime = chore.lastCompletedTime
      row.daysOverdue = chore.daysOverdue
      row.cadenceDays = chore.cadenceDays
      row.sortIndex = index
      row.updatedAt = .now
      if row.modelContext == nil { context.insert(row) }
    }

    for row in existing where !incomingIDs.contains(row.id) {
      context.delete(row)
    }
    try? context.save()
  }

  static func replaceAllChoresExport(_ response: ChoresExportResponse, context: ModelContext) {
    let existingDefs = (try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>())) ?? []
    let existingDefsByID = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.id, $0) })
    let existingEvents = (try? context.fetch(FetchDescriptor<ChoreEventEntity>())) ?? []
    let existingEventsByID = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.id, $0) })

    let seenDefinitionIDs = Set(response.definitions.map(\.id))
    let seenEventIDs = Set(response.events.map(\.recordID))

    for (index, def) in response.definitions.enumerated() {
      let row = existingDefsByID[def.id] ?? ChoreDefinitionEntity(id: def.id,
                                                                  title: def.name,
                                                                  emoji: def.emoji,
                                                                  cadenceDays: def.cadenceDays)
      row.title = def.name
      row.emoji = def.emoji
      row.cadenceDays = def.cadenceDays
      row.sortIndex = index
      row.updatedAt = .now
      if row.modelContext == nil { context.insert(row) }
    }

    for event in response.events {
      let row = existingEventsByID[event.recordID] ?? ChoreEventEntity(id: event.recordID,
                                                                       choreID: event.choreID,
                                                                       action: event.action,
                                                                       date: event.date,
                                                                       sortKey: "\(event.date)::\(event.recordID)")
      row.choreID = event.choreID
      row.action = event.action
      row.date = event.date
      row.newDueDate = event.newDueDate
      row.reason = event.reason
      row.note = event.note
      row.time = event.time
      row.sortKey = "\(event.date)::\(event.recordID)"
      row.updatedAt = .now
      if row.modelContext == nil { context.insert(row) }
    }

    for row in existingEvents where !seenEventIDs.contains(row.id) {
      context.delete(row)
    }
    for row in existingDefs where !seenDefinitionIDs.contains(row.id) {
      context.delete(row)
    }
    try? context.save()
  }

  private static func choreItem(_ row: ChoreSnapshotEntity) -> ChoreItem? {
    decode(ChoreItem.self, from: [
      "id": row.id,
      "name": row.title,
      "emoji": row.emoji as Any,
      "due_date": row.dueDate as Any,
      "last_completed": row.lastCompleted as Any,
      "last_completed_time": row.lastCompletedTime as Any,
      "days_overdue": row.daysOverdue,
      "cadence_days": row.cadenceDays as Any,
    ])
  }

  private static func choreItem(_ def: ChoreDefinitionEntity, events: [ChoreEventEntity]) -> ChoreItem {
    let today = SeptenaDate.today
    var dueDate = today
    var lastCompleted: String?
    var lastCompletedTime: String?

    for event in events.sorted(by: { $0.sortKey < $1.sortKey }) {
      switch event.action {
      case "complete":
        lastCompleted = event.date
        lastCompletedTime = event.time
        if let next = shift(date: event.date, byDays: def.cadenceDays) {
          dueDate = next
        }
      case "defer":
        if let newDue = event.newDueDate {
          dueDate = newDue
        }
      default:
        continue
      }
    }

    let overdue = daysBetween(start: dueDate, end: today)
    return decode(ChoreItem.self, from: [
      "id": def.id,
      "name": def.title,
      "emoji": def.emoji as Any,
      "due_date": dueDate,
      "last_completed": lastCompleted as Any,
      "last_completed_time": lastCompletedTime as Any,
      "days_overdue": overdue,
      "cadence_days": def.cadenceDays,
    ]) ?? ChoreItem(fromFallbackID: def.id, name: def.title, emoji: def.emoji,
                    dueDate: dueDate, lastCompleted: lastCompleted,
                    lastCompletedTime: lastCompletedTime, daysOverdue: overdue,
                    cadenceDays: def.cadenceDays)
  }

  private static func shift(date: String, byDays: Int) -> String? {
    guard let base = SeptenaDate.parse(date) else { return nil }
    return Calendar.current.date(byAdding: .day, value: byDays, to: base).flatMap(SeptenaDate.format)
  }

  private static func daysBetween(start: String, end: String) -> Int {
    guard let startDate = SeptenaDate.parse(start),
          let endDate = SeptenaDate.parse(end) else { return 0 }
    return Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
  }

  private static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) -> T? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object.compactMapValues { $0 }) else {
      return nil
    }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  // MARK: - Gut (CloudKit-backed)

  /// Seed SwiftData with every gut entry from FastAPI export. Upserts by
  /// id; deletes any local rows the server doesn't know about. Called
  /// once during bootstrap; from then on writes go through GutMutator.
  static func replaceAllGutEntries(_ response: GutExportResponse, context: ModelContext) {
    let existing = (try? context.fetch(FetchDescriptor<GutEventEntity>())) ?? []
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var seen = Set<String>()
    for entry in response.entries {
      seen.insert(entry.id)
      let entity = existingByID[entry.id] ?? GutEventEntity(id: entry.id,
                                                            date: entry.date,
                                                            time: entry.time,
                                                            bristol: entry.bristol)
      entity.date = entry.date
      entity.time = entry.time
      entity.bristol = entry.bristol
      entity.blood = entry.blood
      entity.volume = entry.volume
      entity.discomfortLevel = entry.discomfortLevel
      entity.discomfortStart = entry.discomfortStart
      entity.discomfortEnd = entry.discomfortEnd
      entity.note = entry.note
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existing where !seen.contains(entity.id) {
      context.delete(entity)
    }
    try? context.save()
  }

  /// Build a `GutDayResponse` from local SwiftData. Mirrors the shape
  /// `client.gutDay(date:)` returned before the CK migration so callers
  /// can swap the source without touching their UI logic.
  static func loadGutDay(context: ModelContext, date: String) -> GutDayResponse {
    let entities = (try? context.fetch(FetchDescriptor<GutEventEntity>(
      predicate: #Predicate { $0.date == date },
      sortBy: [SortDescriptor(\.time)]
    ))) ?? []
    var maxBlood = 0
    var totalDiscomfortH: Double = 0
    let entries: [GutEntry] = entities.map { e in
      if e.blood > maxBlood { maxBlood = e.blood }
      let hours = discomfortHours(start: e.discomfortStart, end: e.discomfortEnd)
      if let hours { totalDiscomfortH += hours }
      return GutEntry(id: e.id,
                      date: e.date,
                      time: e.time,
                      bristol: e.bristol,
                      blood: e.blood,
                      volume: e.volume,
                      discomfortLevel: e.discomfortLevel,
                      discomfortStart: e.discomfortStart,
                      discomfortEnd: e.discomfortEnd,
                      discomfortHours: hours,
                      note: e.note)
    }
    return GutDayResponse(date: date,
                          entries: entries,
                          movementCount: entries.count,
                          maxBlood: maxBlood,
                          totalDiscomfortH: totalDiscomfortH)
  }

  /// Daily aggregated history from local SwiftData, for the heatmap.
  static func loadGutHistory(context: ModelContext, days: Int) -> GutHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return GutHistoryResponse(daily: [])
    }
    let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? context.fetch(FetchDescriptor<GutEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    let byDate = Dictionary(grouping: entities, by: \.date)
    var daily: [GutHistoryPoint] = []
    for offset in (0..<days).reversed() {
      guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate),
            let key = SeptenaDate.format(d) else { continue }
      let items = byDate[key] ?? []
      var bristolSum = 0
      var bristolN = 0
      var maxBlood = 0
      var discomfortH: Double = 0
      for e in items {
        if e.bristol > 0 {
          bristolSum += e.bristol
          bristolN += 1
        }
        if e.blood > maxBlood { maxBlood = e.blood }
        if let hours = discomfortHours(start: e.discomfortStart, end: e.discomfortEnd) {
          discomfortH += hours
        }
      }
      daily.append(GutHistoryPoint(
        date: key,
        movements: items.count,
        avgBristol: bristolN > 0 ? Double(bristolSum) / Double(bristolN) : nil,
        maxBlood: maxBlood,
        discomfortH: discomfortH
      ))
    }
    return GutHistoryResponse(daily: daily)
  }

  private static func discomfortHours(start: String?, end: String?) -> Double? {
    guard let start, let end else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var s = fmt.date(from: start)
    var e = fmt.date(from: end)
    if s == nil || e == nil {
      let alt = ISO8601DateFormatter()
      alt.formatOptions = [.withInternetDateTime]
      s = s ?? alt.date(from: start)
      e = e ?? alt.date(from: end)
    }
    guard let s, let e, e > s else { return nil }
    return (e.timeIntervalSince(s) / 3600.0 * 100).rounded() / 100
  }

  // MARK: - Caffeine (CloudKit-backed)

  static func replaceAllCaffeineExport(_ response: CaffeineExportResponse, context: ModelContext) {
    // Entries
    let existingEntries = (try? context.fetch(FetchDescriptor<CaffeineEventEntity>())) ?? []
    let entriesByID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
    var seenEntries = Set<String>()
    for row in response.entries {
      seenEntries.insert(row.id)
      let entity = entriesByID[row.id] ?? CaffeineEventEntity(id: row.id,
                                                              date: row.date,
                                                              time: row.time,
                                                              method: row.method)
      entity.date = row.date
      entity.time = row.time
      entity.method = row.method
      entity.beans = row.beans
      entity.grams = row.grams
      entity.note = row.note
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingEntries where !seenEntries.contains(entity.id) {
      context.delete(entity)
    }
    // Beans catalog
    let existingBeans = (try? context.fetch(FetchDescriptor<CaffeineBeanEntity>())) ?? []
    let beansByID = Dictionary(uniqueKeysWithValues: existingBeans.map { ($0.id, $0) })
    var seenBeans = Set<String>()
    for (idx, bean) in response.beans.enumerated() {
      seenBeans.insert(bean.id)
      let entity = beansByID[bean.id] ?? CaffeineBeanEntity(id: bean.id, name: bean.name, sortIndex: idx)
      entity.name = bean.name
      entity.sortIndex = idx
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingBeans where !seenBeans.contains(entity.id) {
      context.delete(entity)
    }
    try? context.save()
  }

  static func loadCaffeineDay(context: ModelContext, date: String) -> CaffeineDayResponse {
    let entities = (try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
      predicate: #Predicate { $0.date == date },
      sortBy: [SortDescriptor(\.time)]
    ))) ?? []
    var totalG: Double = 0
    let entries: [CaffeineEntry] = entities.map { e in
      if let g = e.grams { totalG += g }
      return CaffeineEntry(id: e.id, time: e.time, method: e.method,
                           beans: e.beans, grams: e.grams, note: e.note)
    }
    return CaffeineDayResponse(date: date,
                               entries: entries,
                               sessionCount: entries.count,
                               totalG: totalG > 0 ? totalG : nil)
  }

  static func loadCaffeineHistory(context: ModelContext, days: Int) -> CaffeineHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return CaffeineHistoryResponse(daily: [])
    }
    let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    let byDate = Dictionary(grouping: entities, by: \.date)
    var daily: [CaffeineHistoryPoint] = []
    for offset in (0..<days).reversed() {
      guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate),
            let key = SeptenaDate.format(d) else { continue }
      let items = byDate[key] ?? []
      let totalG = items.compactMap(\.grams).reduce(0, +)
      daily.append(CaffeineHistoryPoint(date: key, sessions: items.count,
                                        totalG: totalG > 0 ? totalG : nil))
    }
    return CaffeineHistoryResponse(daily: daily)
  }

  static func loadCaffeineBeans(context: ModelContext) -> [CaffeineBean] {
    let entities = (try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
    ))) ?? []
    return entities.map { CaffeineBean(id: $0.id, name: $0.name) }
  }

  // MARK: - Cannabis (CloudKit-backed)

  static func replaceAllCannabisExport(_ response: CannabisExportResponse, context: ModelContext) {
    let existingEntries = (try? context.fetch(FetchDescriptor<CannabisEventEntity>())) ?? []
    let entriesByID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })
    var seenEntries = Set<String>()
    for row in response.entries {
      seenEntries.insert(row.id)
      let entity = entriesByID[row.id] ?? CannabisEventEntity(id: row.id,
                                                              date: row.date,
                                                              time: row.time,
                                                              method: row.method)
      entity.date = row.date
      entity.time = row.time
      entity.method = row.method
      entity.strain = row.strain
      entity.hit = row.hit
      entity.grams = row.grams
      entity.effect = row.effect
      entity.note = row.note
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingEntries where !seenEntries.contains(entity.id) {
      context.delete(entity)
    }
    try? context.save()
  }

  static func loadCannabisDay(context: ModelContext, date: String) -> CannabisDayResponse {
    let entities = (try? context.fetch(FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.date == date },
      sortBy: [SortDescriptor(\.time)]
    ))) ?? []
    var totalG: Double = 0
    let entries: [CannabisEntry] = entities.map { e in
      if let g = e.grams { totalG += g }
      return CannabisEntry(id: e.id, time: e.time, method: e.method,
                           strain: e.strain, hit: e.hit, grams: e.grams,
                           note: e.note, effect: e.effect)
    }
    return CannabisDayResponse(date: date,
                               entries: entries,
                               sessionCount: entries.count,
                               totalG: totalG > 0 ? totalG : nil)
  }

  static func loadCannabisHistory(context: ModelContext, days: Int) -> CannabisHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return CannabisHistoryResponse(daily: [])
    }
    let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? context.fetch(FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    let byDate = Dictionary(grouping: entities, by: \.date)
    var daily: [CannabisHistoryPoint] = []
    for offset in (0..<days).reversed() {
      guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate),
            let key = SeptenaDate.format(d) else { continue }
      let items = byDate[key] ?? []
      let totalG = items.compactMap(\.grams).reduce(0, +)
      daily.append(CannabisHistoryPoint(date: key, sessions: items.count,
                                        totalG: totalG > 0 ? totalG : nil))
    }
    return CannabisHistoryResponse(daily: daily)
  }

  static func loadSupplementDefinitions(context: ModelContext) -> [SupplementDefinition] {
    let entities = (try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.title, comparator: .localizedStandard)]
    ))) ?? []
    return entities.map { SupplementDefinition(id: $0.id, name: $0.title, emoji: $0.emoji) }
  }

  // MARK: - Groceries (CloudKit-backed)

  /// Seed SwiftData from the FastAPI snapshot. Upserts items + categories
  /// by id and deletes anything the server doesn't know about. No history
  /// — the user explicitly said groceries is a current-state list only.
  static func replaceAllGroceries(items: [GroceryItem],
                                  categories: [GroceryCategory],
                                  context: ModelContext) {
    let existingItems = (try? context.fetch(FetchDescriptor<GroceryItemEntity>())) ?? []
    let itemsByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
    var seenItems = Set<String>()
    for (idx, item) in items.enumerated() {
      seenItems.insert(item.id)
      let entity = itemsByID[item.id] ?? GroceryItemEntity(id: item.id,
                                                           name: item.name,
                                                           category: item.category,
                                                           emoji: item.emoji)
      entity.name = item.name
      entity.category = item.category
      entity.emoji = item.emoji
      entity.low = item.low
      entity.lastBought = item.lastBought
      entity.sortIndex = idx
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingItems where !seenItems.contains(entity.id) {
      context.delete(entity)
    }

    let existingCats = (try? context.fetch(FetchDescriptor<GroceryCategoryEntity>())) ?? []
    let catsByID = Dictionary(uniqueKeysWithValues: existingCats.map { ($0.id, $0) })
    var seenCats = Set<String>()
    for (idx, cat) in categories.enumerated() {
      seenCats.insert(cat.id)
      let entity = catsByID[cat.id] ?? GroceryCategoryEntity(id: cat.id, name: cat.name, sortIndex: idx)
      entity.name = cat.name
      entity.sortIndex = idx
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingCats where !seenCats.contains(entity.id) {
      context.delete(entity)
    }
    try? context.save()
  }

  static func loadGroceryItems(context: ModelContext) -> [GroceryItem] {
    let entities = (try? context.fetch(FetchDescriptor<GroceryItemEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name, comparator: .localizedStandard)]
    ))) ?? []
    return entities.map { GroceryItem(id: $0.id, name: $0.name, category: $0.category,
                                      emoji: $0.emoji, low: $0.low, lastBought: $0.lastBought) }
  }

  static func loadGroceryCategories(context: ModelContext) -> [GroceryCategory] {
    let entities = (try? context.fetch(FetchDescriptor<GroceryCategoryEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name, comparator: .localizedStandard)]
    ))) ?? []
    return entities.map { GroceryCategory(id: $0.id, name: $0.name) }
  }

  // MARK: - Training (CloudKit-backed)

  /// Replace SwiftData with the server's full snapshot. Upsert by id, delete
  /// locals the server doesn't know about. Entries arrive without their own
  /// id (server's `file` field), so synthesize one on first import.
  static func replaceAllTrainingExport(_ response: TrainingExportResponse, context: ModelContext) {
    // Entries — server keys by `file` or composite; map to a stable short id.
    let existingEntries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    let entriesByFile: [String: ExerciseEntryEntity] = Dictionary(
      uniqueKeysWithValues: existingEntries.compactMap { entity -> (String, ExerciseEntryEntity)? in
        // Re-import key: server-side filename if present in note metadata,
        // else the composite of date+exercise+loggedAt the server returns.
        // We accept either as the "what server calls this row" key.
        let key = entity.id
        return (key, entity)
      })
    var seenIDs = Set<String>()
    for row in response.entries {
      let id = row.file.map { Self.normaliseTrainingID($0) } ?? row.id
      seenIDs.insert(id)
      let entity = entriesByFile[id] ?? ExerciseEntryEntity(
        id: id,
        date: row.date,
        time: Self.deriveTime(from: row.concludedAt),
        sessionType: row.session,
        exercise: row.exercise ?? ""
      )
      entity.date = row.date
      entity.time = Self.deriveTime(from: row.concludedAt)
      entity.sessionType = row.session
      entity.exercise = row.exercise ?? ""
      entity.weight = row.weight
      entity.sets = row.sets
      entity.reps = row.reps
      entity.difficulty = row.difficulty
      entity.durationMin = row.durationMin
      entity.distanceM = row.distanceM
      entity.level = row.level
      entity.concludedAt = row.concludedAt
      entity.loggedAt = row.loggedAt
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingEntries where !seenIDs.contains(entity.id) {
      context.delete(entity)
    }

    // Session types
    let existingTypes = (try? context.fetch(FetchDescriptor<SessionTypeEntity>())) ?? []
    let typesByID = Dictionary(uniqueKeysWithValues: existingTypes.map { ($0.id, $0) })
    var seenTypes = Set<String>()
    for (idx, st) in response.sessionTypes.enumerated() {
      seenTypes.insert(st.id)
      let entity = typesByID[st.id] ?? SessionTypeEntity(id: st.id,
                                                         label: st.label,
                                                         emoji: st.emoji,
                                                         exercises: st.exercises,
                                                         sortIndex: idx,
                                                         kindRaw: st.kind.rawValue)
      entity.label = st.label
      entity.emoji = st.emoji
      entity.exercises = st.exercises
      entity.sortIndex = idx
      // Mirror the kind from the seed config so an upstream-defined
      // routine carries its category into the local mirror. Existing
      // entities keep their stored kind if the incoming config falls
      // back to the seed default (i.e. nothing user-meaningful to write).
      entity.kindRaw = st.kind.rawValue
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingTypes where !seenTypes.contains(entity.id) {
      context.delete(entity)
    }

    // Exercise definitions
    let existingDefs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    let defsByID = Dictionary(uniqueKeysWithValues: existingDefs.map { ($0.id, $0) })
    var seenDefs = Set<String>()
    for (idx, def) in response.exercises.enumerated() {
      seenDefs.insert(def.id)
      let entity = defsByID[def.id] ?? ExerciseDefinitionEntity(id: def.id,
                                                                name: def.name,
                                                                type: def.type,
                                                                subgroup: def.subgroup,
                                                                aliases: def.aliases ?? [],
                                                                sortIndex: idx)
      entity.name = def.name
      entity.type = def.type
      entity.subgroup = def.subgroup
      entity.aliases = def.aliases ?? []
      entity.sortIndex = idx
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for entity in existingDefs where !seenDefs.contains(entity.id) {
      context.delete(entity)
    }

    try? context.save()
  }

  /// Server's `file` field (`2026-05-23--chest-press--01.json`) is fine as
  /// a stable key — but we want short CK record names. Hash it down to 12
  /// chars deterministically so the same row imports to the same id.
  private static func normaliseTrainingID(_ raw: String) -> String {
    let trimmed = raw.replacingOccurrences(of: ".json", with: "")
    let hash = trimmed.unicodeScalars.reduce(UInt64(5381)) { acc, c in
      acc &* 33 &+ UInt64(c.value)
    }
    return String(hash, radix: 36).prefix(12).description
  }

  /// Pull "HH:MM" off the server's "YYYY-MM-DDTHH:MM:SS" concludedAt stamp.
  private static func deriveTime(from concludedAt: String?) -> String {
    guard let s = concludedAt else { return "" }
    let parts = s.split(separator: "T")
    guard parts.count == 2 else { return "" }
    let hm = parts[1].split(separator: ":")
    guard hm.count >= 2 else { return "" }
    return "\(hm[0]):\(hm[1])"
  }

  // MARK: Training readers

  static func loadTrainingEntries(context: ModelContext, since: String? = nil) -> [ExerciseEntry] {
    var descriptor = FetchDescriptor<ExerciseEntryEntity>(
      sortBy: [SortDescriptor(\.date, order: .reverse),
               SortDescriptor(\.loggedAt, order: .reverse)]
    )
    if let since {
      descriptor.predicate = #Predicate { $0.date >= since }
    }
    let entities = (try? context.fetch(descriptor)) ?? []
    return entities.map(Self.makeExerciseEntry)
  }

  static func loadTrainingProgression(context: ModelContext, exercise: String) -> [ProgressionPoint] {
    let entities = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.exercise == exercise },
      sortBy: [SortDescriptor(\.date), SortDescriptor(\.loggedAt)]
    ))) ?? []
    return entities.map { e in
      ProgressionPoint(date: e.date,
                       weight: e.weight,
                       sets: e.sets,
                       reps: e.reps,
                       difficulty: e.difficulty,
                       durationMin: e.durationMin,
                       distanceM: e.distanceM,
                       level: e.level)
    }
  }

  static func loadTrainingCardioHistory(context: ModelContext, days: Int) -> CardioHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return CardioHistoryResponse(daily: [], targetWeeklyMin: 150)
    }
    // Pull a window with 6 extra days so the rolling-7d at the left edge has
    // full lookback. Cardio entries are those whose exercise is in a cardio
    // definition OR have durationMin/distanceM set.
    let lookbackStart = Calendar.current.date(byAdding: .day, value: -(days + 6 - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(lookbackStart) ?? today
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    // Lowercased on both sides — entry.exercise stores the name the user
    // logged, which may have different casing than the def's catalog name
    // (especially for stubs created by RoutineSlugRepair which humanizes).
    let cardioExercises = Set(defs
      .filter { $0.type == "cardio" || $0.type == "mobility" }
      .map { $0.name.lowercased() })
    let cardioByDate: [String: Int] = entries.reduce(into: [:]) { acc, e in
      let isCardio = cardioExercises.contains(e.exercise.lowercased()) ||
                     e.durationMin != nil || e.distanceM != nil
      guard isCardio else { return }
      let mins = Int(e.durationMin?.rounded() ?? 0)
      if mins > 0 { acc[e.date, default: 0] += mins }
    }
    var window: [CardioDay] = []
    for offset in (0..<(days + 6)).reversed() {
      guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate),
            let key = SeptenaDate.format(d) else { continue }
      window.append(CardioDay(date: key, minutes: cardioByDate[key] ?? 0, rolling7d: nil))
    }
    // Rolling 7-day average, fill only the last `days` entries.
    var daily: [CardioDay] = []
    for i in 0..<window.count {
      let day = window[i]
      let from = max(0, i - 6)
      let slice = window[from...i]
      // 7-day rolling SUM — the Z2 chart stacks this on top of the day's
      // bar so the column visualizes week-to-date progress against the
      // weekly target. (Server-side `/api/training/cardio-history` named
      // this `rolling_7d`; webapp shipped the same shape.)
      let sum = slice.map { $0.minutes }.reduce(0, +)
      if i >= window.count - days {
        daily.append(CardioDay(date: day.date, minutes: day.minutes, rolling7d: Double(sum)))
      }
    }
    return CardioHistoryResponse(daily: daily, targetWeeklyMin: 150)
  }

  static func loadTrainingSummary(context: ModelContext, since: String? = nil) -> [ExerciseSummary] {
    var descriptor = FetchDescriptor<ExerciseEntryEntity>(
      sortBy: [SortDescriptor(\.date)]
    )
    if let since {
      descriptor.predicate = #Predicate { $0.date >= since }
    }
    let entities = (try? context.fetch(descriptor)) ?? []
    let byExercise = Dictionary(grouping: entities, by: \.exercise)
    return byExercise.map { (name, rows) -> ExerciseSummary in
      let sorted = rows.sorted {
        ($0.date, $0.loggedAt ?? "") < ($1.date, $1.loggedAt ?? "")
      }
      let last = sorted.last
      let prev = sorted.dropLast().last
      let weightLast = last?.weight
      let weightPrev = prev?.weight
      let trend: String?
      switch (weightLast, weightPrev) {
      case let (a?, b?) where a > b: trend = "up"
      case let (a?, b?) where a < b: trend = "down"
      case (_?, _?): trend = "flat"
      default: trend = nil
      }
      return ExerciseSummary(name: name,
                             count: rows.count,
                             latestWeight: last?.weight,
                             latestDate: last?.date,
                             trend: trend)
    }.sorted { ($0.latestDate ?? "") > ($1.latestDate ?? "") }
  }

  static func loadSessionTypes(context: ModelContext) -> [SessionTypeConfig] {
    let entities = (try? context.fetch(FetchDescriptor<SessionTypeEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.label, comparator: .localizedStandard)]
    ))) ?? []
    return entities.map { e in
      // Legacy rows (pre-`kind` field) read back with kindRaw == nil
      // and get a seed default by id. New rows preserve whatever the
      // user/CloudKit wrote.
      let kind = e.kindRaw.flatMap(SessionKind.init(rawValue:))
        ?? SessionKind.defaulted(for: e.id)
      return SessionTypeConfig.make(
        id: e.id,
        label: e.label,
        emoji: e.emoji,
        exercises: e.exercises,
        archived: e.archived,
        kind: kind
      )
    }
  }

  static func loadExerciseDefinitions(context: ModelContext) -> [ExerciseDefinition] {
    let entities = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name, comparator: .localizedStandard)]
    ))) ?? []
    return entities.map { e in
      ExerciseDefinition(
        id: e.id, name: e.name, type: e.type,
        subgroup: e.subgroup, aliases: e.aliases,
        primaryMuscle: e.primaryMuscle.flatMap(Muscle.init(rawValue:)),
        secondaryMuscles: e.secondaryMuscles.compactMap(Muscle.init(rawValue:)),
        archived: e.archived
      )
    }
  }

  /// For each exercise name, walk the progression backward picking the most-
  /// recent non-null value per field. Mirrors the server's last-entries logic.
  ///
  /// Case-insensitive on the name join: routine slugs may differ in casing
  /// from how the user logged the entry (e.g. routine has "chest press",
  /// entries say "Chest Press"). A SwiftData #Predicate can't lowercase
  /// strings inline, so we fetch all entries once and bucket in Swift.
  static func loadLastEntries(context: ModelContext, exercises: [String]) -> [String: LastEntryValues] {
    let wanted = Set(exercises.map { exerciseKey($0) })
    guard !wanted.isEmpty else { return [:] }
    let all = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      sortBy: [SortDescriptor(\.date, order: .reverse),
               SortDescriptor(\.loggedAt, order: .reverse)]
    ))) ?? []
    let grouped = Dictionary(grouping: all.filter { wanted.contains(exerciseKey($0.exercise)) },
                              by: { exerciseKey($0.exercise) })

    var out: [String: LastEntryValues] = [:]
    for name in exercises {
      guard let entities = grouped[exerciseKey(name)], !entities.isEmpty else { continue }
      var values = LastEntryValues.empty
      values.date = entities.first?.date
      for e in entities {
        if values.weight == nil, let v = e.weight { values.weight = v }
        if values.sets == nil, let v = e.sets { values.sets = v }
        if values.reps == nil, let v = e.reps { values.reps = v }
        if values.difficulty == nil, let v = e.difficulty { values.difficulty = v }
        if values.durationMin == nil, let v = e.durationMin { values.durationMin = v }
        if values.distanceM == nil, let v = e.distanceM { values.distanceM = v }
        if values.level == nil, let v = e.level { values.level = v }
      }
      // Key by the input casing so callers indexing with routine slugs hit.
      out[name] = values
    }
    return out
  }

  /// Map an ExerciseEntryEntity to the wire shape views already consume.
  private static func makeExerciseEntry(_ e: ExerciseEntryEntity) -> ExerciseEntry {
    ExerciseEntry(date: e.date,
                  session: e.sessionType,
                  exercise: e.exercise,
                  weight: e.weight,
                  sets: e.sets,
                  reps: e.reps,
                  difficulty: e.difficulty,
                  durationMin: e.durationMin,
                  distanceM: e.distanceM,
                  level: e.level,
                  file: e.id,
                  concludedAt: e.concludedAt,
                  loggedAt: e.loggedAt)
  }

  // MARK: Suggested workout
  //
  // Each ExerciseEntry tags its own sessionType ("upper", "yoga", "cardio",
  // …). A day "counts as" every distinct sessionType logged on it. Track
  // days-since per type; suggest the one longest unworked, respecting a
  // 2-day rest from the most recent session.

  static func loadSuggestedWorkout(context: ModelContext) -> SuggestedWorkoutResponse {
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      sortBy: [SortDescriptor(\.date)]
    ))) ?? []
    let types = (try? context.fetch(FetchDescriptor<SessionTypeEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []

    let entriesByDate = Dictionary(grouping: entries, by: \.date)
    let sortedDates = entriesByDate.keys.sorted(by: >)   // newest first

    func classify(_ rows: [ExerciseEntryEntity]) -> Set<String> {
      Set(rows.map(\.sessionType).filter { !$0.isEmpty })
    }

    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return SuggestedWorkoutResponse.make(suggested: nil, daysAgo: [:])
    }

    var daysAgo: [String: Int] = [:]
    for typeID in types.map(\.id) where !typeID.isEmpty {
      for dateStr in sortedDates {
        guard let day = SeptenaDate.parse(dateStr) else { continue }
        let matched = classify(entriesByDate[dateStr] ?? [])
        if matched.contains(typeID) {
          let comps = Calendar.current.dateComponents([.day], from: day, to: todayDate)
          daysAgo[typeID] = comps.day ?? 0
          break
        }
      }
    }

    // Most-recent session date across any type — for the 2-day rest gate.
    var lastSession: Date? = nil
    for dateStr in sortedDates {
      if !classify(entriesByDate[dateStr] ?? []).isEmpty {
        lastSession = SeptenaDate.parse(dateStr)
        break
      }
    }
    if let last = lastSession {
      let comps = Calendar.current.dateComponents([.day], from: last, to: todayDate)
      if (comps.day ?? 99) < 2 {
        return SuggestedWorkoutResponse.make(suggested: nil, daysAgo: daysAgo)
      }
    }

    // Pick the type with the largest days-ago. Types never trained get
    // priority (treat missing as +infinity).
    let candidates = types.filter { !$0.id.isEmpty }
    let pick: SessionTypeEntity? = candidates.max { a, b in
      (daysAgo[a.id] ?? Int.max) < (daysAgo[b.id] ?? Int.max)
    }
    guard let suggestion = pick else {
      return SuggestedWorkoutResponse.make(suggested: nil, daysAgo: daysAgo)
    }
    let reason: String? = daysAgo[suggestion.id].map { "\($0) days since last \(suggestion.label)" }
    let sw = SuggestedWorkout(type: suggestion.id, reason: reason)
    return SuggestedWorkoutResponse.make(suggested: sw, daysAgo: daysAgo)
  }

  // MARK: - Nutrition (CloudKit-backed)

  /// Wipe and recompute every NutritionDailySummaryEntity from scratch.
  /// Use after bulk import; incremental writes use NutritionMutator.
  static func rebuildAllNutritionSummaries(context: ModelContext) {
    let allEntries = (try? context.fetch(FetchDescriptor<NutritionEntryEntity>())) ?? []
    let allSummaries = (try? context.fetch(FetchDescriptor<NutritionDailySummaryEntity>())) ?? []
    for s in allSummaries { context.delete(s) }

    let cal = Calendar.current
    func dayKey(_ date: Date) -> String {
      let c = cal.dateComponents([.year, .month, .day], from: date)
      return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    let grouped = Dictionary(grouping: allEntries, by: { dayKey($0.loggedAt) })
    for (day, entries) in grouped {
      let sorted = entries.sorted { $0.loggedAt < $1.loggedAt }
      let totalKcal = entries.reduce(0.0) {
        $0 + ($1.kcal ?? (4 * $1.proteinG + 9 * $1.fatG + 4 * $1.carbsG + 7 * ($1.alcoholG ?? 0)))
      }
      func sumOpt(_ kp: KeyPath<NutritionEntryEntity, Double?>) -> Double? {
        let vals = entries.compactMap { $0[keyPath: kp] }
        return vals.isEmpty ? nil : vals.reduce(0, +)
      }
      let summary = NutritionDailySummaryEntity(
        id: day, date: day, entryCount: entries.count,
        firstLoggedAt: sorted.first?.loggedAt,
        lastLoggedAt: sorted.last?.loggedAt,
        computedAt: .now,
        kcal: totalKcal > 0 ? totalKcal : nil,
        proteinG: entries.reduce(0, { $0 + $1.proteinG }),
        fatG: entries.reduce(0, { $0 + $1.fatG }),
        carbsG: entries.reduce(0, { $0 + $1.carbsG }),
        fiberG: sumOpt(\.fiberG),
        sugarG: sumOpt(\.sugarG),
        saturatedFatG: sumOpt(\.saturatedFatG),
        alcoholG: sumOpt(\.alcoholG),
        sodiumMg: sumOpt(\.sodiumMg),
        cholesterolMg: sumOpt(\.cholesterolMg),
        potassiumMg: sumOpt(\.potassiumMg),
        waterMl: sumOpt(\.waterMl),
        cloudKitSystemFields: nil
      )
      context.insert(summary)
    }
    try? context.save()
  }

  static func loadNutritionEntries(context: ModelContext, since: String? = nil) -> [NutritionEntry] {
    let today = SeptenaDate.today
    var descriptor = FetchDescriptor<NutritionEntryEntity>(
      sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
    )
    if let since {
      let sinceDate = nutritionDate(date: since, time: "00:00") ?? .distantPast
      descriptor.predicate = #Predicate { $0.loggedAt >= sinceDate }
    }
    let entities = (try? context.fetch(descriptor)) ?? []
    return entities.map { makeNutritionEntry($0) }
  }

  static func loadNutritionToday(context: ModelContext) -> [NutritionEntry] {
    loadNutritionEntries(context: context, since: SeptenaDate.today)
  }

  static func loadNutritionSummaries(context: ModelContext, days: Int) -> [NutritionDailySummaryEntity] {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else { return [] }
    let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    return (try? context.fetch(FetchDescriptor<NutritionDailySummaryEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today },
      sortBy: [SortDescriptor(\.date)]
    ))) ?? []
  }

  /// Compute a `NutritionStatsResponse` from local SwiftData entries.
  /// Computes directly off `NutritionEntryEntity` rather than the day
  /// summaries — summaries are a CK-sync cache and may be missing or stale
  /// on a freshly bootstrapped device.
  static func buildNutritionStatsResponse(context: ModelContext, days: Int = 90) -> NutritionStatsResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return NutritionStatsResponse(daily: [], fasting: nil,
                                    todayMealCount: nil, todayLatestMeal: nil)
    }
    let cal = Calendar.current
    let start = cal.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startOfStartDay = cal.startOfDay(for: start)

    let entries = (try? context.fetch(FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= startOfStartDay },
      sortBy: [SortDescriptor(\.loggedAt)]
    ))) ?? []

    func dayKey(_ date: Date) -> String {
      let c = cal.dateComponents([.year, .month, .day], from: date)
      return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    let byDay = Dictionary(grouping: entries, by: { dayKey($0.loggedAt) })

    // Daily macro totals — one point per day that has entries.
    let daily: [NutritionDailyPoint] = byDay.keys.sorted().map { day in
      let es = byDay[day] ?? []
      let kcal = es.reduce(0.0) { sum, e in
        sum + (e.kcal ?? (4 * e.proteinG + 9 * e.fatG + 4 * e.carbsG + 7 * (e.alcoholG ?? 0)))
      }
      let fiberVals = es.compactMap(\.fiberG)
      return NutritionDailyPoint(
        date: day,
        proteinG: es.reduce(0, { $0 + $1.proteinG }),
        fatG: es.reduce(0, { $0 + $1.fatG }),
        carbsG: es.reduce(0, { $0 + $1.carbsG }),
        fiberG: fiberVals.isEmpty ? nil : fiberVals.reduce(0, +),
        kcal: kcal
      )
    }

    // Today stats
    let todayEntries = byDay[today] ?? []
    let todayMealCount = todayEntries.isEmpty ? nil : todayEntries.count
    let todayLatestMeal: String? = todayEntries.map(\.loggedAt).max().map { nutritionTimeStr($0) }

    // Fasting windows: last meal of day N-1 → first meal of day N
    var fasting: [FastingWindow] = []
    var yesterdayLastMeal: String?
    let firstOfDay: [String: Date] = byDay.compactMapValues { $0.map(\.loggedAt).min() }
    let lastOfDay:  [String: Date] = byDay.compactMapValues { $0.map(\.loggedAt).max() }
    for offset in 0..<days {
      guard let dayDate = cal.date(byAdding: .day, value: -offset, to: todayDate) else { continue }
      let dayStr = dayKey(dayDate)
      guard let prevDate = cal.date(byAdding: .day, value: -1, to: dayDate) else { continue }
      let prevStr = dayKey(prevDate)
      guard let firstMealDate = firstOfDay[dayStr],
            let lastMealDate  = lastOfDay[prevStr] else { continue }
      let hours = firstMealDate.timeIntervalSince(lastMealDate) / 3600
      fasting.append(FastingWindow(
        date: dayStr,
        hours: hours > 0 ? hours : nil,
        lastMeal: nutritionTimeStr(lastMealDate),
        firstMeal: nutritionTimeStr(firstMealDate)
      ))
      if dayStr == today {
        yesterdayLastMeal = nutritionTimeStr(lastMealDate)
      }
    }

    // Fallback: if today had no meals yet, the loop above skipped today's
    // window entirely. Pull yesterday's last meal directly so the live
    // fasting tile can still anchor.
    if yesterdayLastMeal == nil,
       let yDate = cal.date(byAdding: .day, value: -1, to: todayDate),
       let yLast = lastOfDay[dayKey(yDate)] {
      yesterdayLastMeal = nutritionTimeStr(yLast)
    }

    let validFastHours = fasting.compactMap(\.hours).filter { $0 >= 6 && $0 <= 24 }
    let avgFastH: Double? = validFastHours.isEmpty ? nil
      : validFastHours.reduce(0, +) / Double(validFastHours.count)

    return NutritionStatsResponse(
      daily: daily,
      fasting: fasting.isEmpty ? nil : fasting,
      todayMealCount: todayMealCount,
      todayLatestMeal: todayLatestMeal,
      yesterdayLastMeal: yesterdayLastMeal,
      avgFastH: avgFastH
    )
  }

  // MARK: Nutrition helpers

  private static func makeNutritionEntry(_ e: NutritionEntryEntity) -> NutritionEntry {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: e.loggedAt)
    let dateStr = String(format: "%04d-%02d-%02d",
                         comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    let timeStr = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    let computedKcal = 4 * e.proteinG + 9 * e.fatG + 4 * e.carbsG + 7 * (e.alcoholG ?? 0)
    return NutritionEntry(
      date: dateStr,
      time: timeStr,
      emoji: e.emoji,
      proteinG: e.proteinG,
      fatG: e.fatG,
      saturatedFatG: e.saturatedFatG,
      carbsG: e.carbsG,
      sugarG: e.sugarG,
      fiberG: e.fiberG,
      alcoholG: e.alcoholG,
      kcal: e.kcal ?? computedKcal,
      sodiumMg: e.sodiumMg,
      cholesterolMg: e.cholesterolMg,
      potassiumMg: e.potassiumMg,
      waterMl: e.waterMl,
      foods: e.foods.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
      photoAssetID: e.photoAssetID,
      file: e.id
    )
  }

  private static func nutritionDate(date: String, time: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: "\(date) \(time)")
  }

  private static func nutritionTimeStr(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
  }

  // MARK: - Today aggregator (replaces /api/next/items)

  /// Local equivalent of the FastAPI `/api/next/items` endpoint. Merges
  /// today's open habits, supplements, and due-or-overdue chores from the
  /// CloudKit-mirrored SwiftData store into a single ranked list. Same
  /// `NextItemsResponse` shape the Watch and Sidebar already consume.
  ///
  /// Ordering: overdue chores first (most overdue at top), then due-today
  /// chores, then habits by bucket, then supplements. `sortKey` increases
  /// monotonically so callers can stable-sort if they re-merge.
  static func loadNextItems(context: ModelContext,
                            date: String,
                            bucket: String? = nil,
                            limit: Int? = nil) -> NextItemsResponse {
    var items: [NextItem] = []
    var sortKey = 0

    // Chores: due today (daysOverdue >= 0) and not yet completed. Sort
    // most-overdue first so the dashboard's "you're behind" signal stays
    // visible at the top.
    let chores = loadChores(context: context)
      .filter { $0.daysOverdue >= 0 }
      .filter { c in
        // Hide chores already checked off today.
        c.lastCompleted != date
      }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
    for chore in chores {
      let trailing: String?
      if chore.daysOverdue == 0 {
        trailing = "today"
      } else if chore.daysOverdue == 1 {
        trailing = "1 day late"
      } else {
        trailing = "\(chore.daysOverdue) days late"
      }
      items.append(NextItem(
        id: chore.id,
        kind: "chore",
        title: chore.emoji.map { "\($0) \(chore.name)" } ?? chore.name,
        subtitle: nil,
        trailing: trailing,
        overdue: chore.daysOverdue > 0,
        sortKey: sortKey
      ))
      sortKey += 1
    }

    // Habits: open (not done, not skipped). Group by bucket in the
    // canonical morning → afternoon → evening order the user defined.
    if let habits = loadHabitsDay(context: context, date: date) {
      for b in habits.buckets {
        if let filter = bucket, b != filter { continue }
        let grouped = habits.grouped[b] ?? []
        for h in grouped where !h.done && !h.skipped {
          items.append(NextItem(
            id: h.id,
            kind: "habit",
            title: h.emoji.map { "\($0) \(h.name)" } ?? h.name,
            subtitle: b,
            trailing: nil,
            overdue: false,
            sortKey: sortKey
          ))
          sortKey += 1
        }
      }
    }

    // Supplements: open (not done). Server returns a flat list — keep
    // declaration order.
    if let supps = loadSupplementsDay(context: context, date: date) {
      for s in supps.items where !s.done {
        items.append(NextItem(
          id: s.id,
          kind: "supplement",
          title: s.emoji.map { "\($0) \(s.name)" } ?? s.name,
          subtitle: nil,
          trailing: nil,
          overdue: false,
          sortKey: sortKey
        ))
        sortKey += 1
      }
    }

    if let limit, items.count > limit {
      items = Array(items.prefix(limit))
    }
    return NextItemsResponse(date: date, bucket: bucket ?? "", items: items)
  }

  // MARK: - Mood

  static func loadMoodDay(context: ModelContext, date: String) -> MoodDayResponse {
    let entities = (try? context.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.date == date },
      sortBy: [SortDescriptor(\.time)]
    ))) ?? []
    let entries: [MoodEntry] = entities.map { e in
      MoodEntry(id: e.id, time: e.time, bucket: e.bucket,
                quadrant: e.quadrant, arousal: e.arousal, valence: e.valence,
                emotion: e.emotion, note: e.note)
    }
    var byBucket: [String: MoodEntry] = [:]
    // Most-recent-wins per bucket — entries are sorted ascending by time,
    // so overwriting in order leaves the latest in place.
    for entry in entries { byBucket[entry.bucket] = entry }
    return MoodDayResponse(date: date, entries: entries,
                           logCount: entries.count, byBucket: byBucket)
  }

  static func loadMoodHistory(context: ModelContext, days: Int) -> MoodHistoryResponse {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else {
      return MoodHistoryResponse(daily: [])
    }
    let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? context.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    let byDate = Dictionary(grouping: entities, by: \.date)
    // Stable tie-breaker: hap → lap → lan → han. Brighter quadrants win
    // ties so an even day reads as "mostly fine" rather than darkening.
    let tieOrder = ["hap": 0, "lap": 1, "lan": 2, "han": 3]
    func dominantQuadrant(in items: [MoodEventEntity]) -> String? {
      let counts = Dictionary(items.map { ($0.quadrant, 1) }, uniquingKeysWith: +)
      return counts.max(by: { a, b in
        if a.value != b.value { return a.value < b.value }
        return (tieOrder[a.key] ?? 99) > (tieOrder[b.key] ?? 99)
      })?.key
    }
    var daily: [MoodHistoryPoint] = []
    for offset in (0..<days).reversed() {
      guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate),
            let key = SeptenaDate.format(d) else { continue }
      let items = byDate[key] ?? []
      // Per-bucket dominant quadrant — populated only for buckets the
      // user actually logged on this day, so the heatmap can leave
      // empty cells empty instead of inferring a color.
      var bucketQuadrants: [String: String] = [:]
      for (bucket, bucketItems) in Dictionary(grouping: items, by: \.bucket) {
        if let q = dominantQuadrant(in: bucketItems) {
          bucketQuadrants[bucket] = q
        }
      }
      daily.append(MoodHistoryPoint(date: key,
                                    logs: items.count,
                                    dominantQuadrant: dominantQuadrant(in: items),
                                    bucketQuadrants: bucketQuadrants))
    }
    return MoodHistoryResponse(daily: daily)
  }
}
