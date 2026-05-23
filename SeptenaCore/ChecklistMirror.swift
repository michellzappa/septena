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
}
