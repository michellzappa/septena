import Foundation
import SwiftData

// Read side for the intake mini-app. Sendable DTOs so reads can cross the
// MirrorReader actor boundary, mirroring ChecklistMirror.loadCaffeineDay. The
// destination/page/manage views are pure functions of these. Writes go through
// IntakeMutator (the write boundary); nothing here mutates.

/// A kind plus its config and a cheap event count — everything the switcher and
/// per-kind page need without touching the @Model on the main actor.
struct IntakeKindDTO: Identifiable, Sendable, Hashable {
  let id: String
  let name: String
  let symbol: String
  let color: String
  let unit: String?
  let doseStyle: String        // "amount" | "count" | "both" | "none"
  let countNoun: String?
  let containerNoun: String?
  let containerCap: Int?
  let catalogNoun: String?
  let flourish: String
  let metricMode: String
  let objective: String        // "log" | "limit" | "reduce" | "quit"
  let methods: [IntakeMethodRow]
  let archived: Bool
  let eventCount: Int

  var showsAmount: Bool { doseStyle == "amount" || doseStyle == "both" }
  var showsCount: Bool { doseStyle == "count" || doseStyle == "both" }
  var hasCatalog: Bool { (catalogNoun?.isEmpty == false) }
}

/// One logged event in display form.
struct IntakeEntryDTO: Identifiable, Sendable, Hashable {
  let id: String
  let method: String
  let itemID: String?
  let amount: Double?
  let count: Int?
  let note: String?
  let occurredAt: Date
  var time: String { EventTimestamp.hhmm(from: occurredAt) }
}

struct IntakeItemDTO: Identifiable, Sendable, Hashable {
  let id: String
  let name: String
}

/// One homepage tile's worth of a kind — name, accent, and today's totals.
struct IntakeTileDTO: Identifiable, Sendable, Hashable {
  let id: String
  let name: String
  let symbol: String
  let color: String
  let unit: String?
  let objective: String
  let showsAmount: Bool
  let todayCount: Int
  let todayAmount: Double
  let lastEventAt: Date?
  /// Trailing-90-day daily event counts, oldest → newest (today last).
  /// Feeds the homepage sparkline/heatmap/tile history for this kind.
  let dailyCounts: [Int]
}

enum IntakeReader {
  /// Non-archived kinds in user order, each with its live event count.
  static func loadKinds(context: ModelContext) -> [IntakeKindDTO] {
    let kinds = (try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    let events = (try? context.fetch(FetchDescriptor<IntakeEventEntity>())) ?? []
    var counts: [String: Int] = [:]
    for e in events { counts[e.kindID, default: 0] += 1 }
    var seenIDs = Set<String>()
    return kinds.filter { $0.archivedAt == nil && seenIDs.insert($0.id).inserted }
      .map { dto($0, count: counts[$0.id] ?? 0) }
  }

  /// Every kind incl. archived, in user order — for the Settings tracker
  /// manager (which offers unarchive). Active list uses `loadKinds`.
  static func loadAllKinds(context: ModelContext) -> [IntakeKindDTO] {
    let kinds = (try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    let events = (try? context.fetch(FetchDescriptor<IntakeEventEntity>())) ?? []
    var counts: [String: Int] = [:]
    for e in events { counts[e.kindID, default: 0] += 1 }
    var seenIDs = Set<String>()
    return kinds.filter { seenIDs.insert($0.id).inserted }
      .map { dto($0, count: counts[$0.id] ?? 0) }
  }

  /// A single kind by id (archived included — the Manage sheet needs it).
  static func loadKind(context: ModelContext, id: String) -> IntakeKindDTO? {
    guard let k = (try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      predicate: #Predicate { $0.id == id }
    )))?.first else { return nil }
    let count = (try? context.fetchCount(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.kindID == id }
    ))) ?? 0
    return dto(k, count: count)
  }

  /// One kind's events for a given local date, oldest first.
  static func loadDay(context: ModelContext, kindID: String, date: String) -> [IntakeEntryDTO] {
    let rows = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.kindID == kindID && $0.date == date },
      sortBy: [SortDescriptor(\.occurredAt)]
    ))) ?? []
    return rows.map {
      IntakeEntryDTO(id: $0.id, method: $0.method, itemID: $0.itemID,
                     amount: $0.amount, count: $0.count, note: $0.note,
                     occurredAt: $0.occurredAt)
    }
  }

  /// A kind's catalog items in order.
  static func loadItems(context: ModelContext, kindID: String) -> [IntakeItemDTO] {
    let rows = (try? context.fetch(FetchDescriptor<IntakeItemEntity>(
      predicate: #Predicate { $0.kindID == kindID && $0.archivedAt == nil },
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return rows.map { IntakeItemDTO(id: $0.id, name: $0.name) }
  }

  /// The most recent count today for the container method — feeds
  /// ConsumableContainer's "Continue (use N)" the way CannabisCapsule reads
  /// `cannabisLastVapeHit`.
  static func lastContainerCount(context: ModelContext, kindID: String,
                                 containerToken: String, date: String) -> Int? {
    let rows = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate {
        $0.kindID == kindID && $0.date == date && $0.method == containerToken
      },
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    )))
    return rows?.first?.count
  }

  /// One tile per non-archived kind, with today's count/amount folded in —
  /// the homepage tile-per-kind source (Option C).
  static func loadTiles(context: ModelContext, date: String) -> [IntakeTileDTO] {
    var seenIDs = Set<String>()
    let kinds = ((try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []).filter { $0.archivedAt == nil && seenIDs.insert($0.id).inserted }
    guard !kinds.isEmpty else { return [] }
    // One full events scan: today's counts/sums plus the last-ever instant per
    // kind (the reduce/quit "days since last" the tile surfaces).
    let events = (try? context.fetch(FetchDescriptor<IntakeEventEntity>())) ?? []
    var counts: [String: Int] = [:]
    var sums: [String: Double] = [:]
    var lastAt: [String: Date] = [:]
    var byDay: [String: [String: Int]] = [:]   // kindID → date → count
    for e in events {
      if e.date == date {
        counts[e.kindID, default: 0] += 1
        sums[e.kindID, default: 0] += e.amount ?? 0
      }
      byDay[e.kindID, default: [:]][e.date, default: 0] += 1
      if let prev = lastAt[e.kindID] { if e.occurredAt > prev { lastAt[e.kindID] = e.occurredAt } }
      else { lastAt[e.kindID] = e.occurredAt }
    }
    let window = trailingDates(endingAt: date, days: 90)
    return kinds.map { k in
      let days = byDay[k.id] ?? [:]
      return IntakeTileDTO(id: k.id, name: k.name, symbol: k.symbol, color: k.color,
                           unit: k.unit, objective: k.objective,
                           showsAmount: k.doseStyle == "amount" || k.doseStyle == "both",
                           todayCount: counts[k.id] ?? 0,
                           todayAmount: sums[k.id] ?? 0,
                           lastEventAt: lastAt[k.id],
                           dailyCounts: window.map { days[$0] ?? 0 })
    }
  }

  /// The trailing `days` date strings ending at `end` (inclusive), oldest first.
  private static func trailingDates(endingAt end: String, days: Int) -> [String] {
    guard let endDate = SeptenaDate.parse(end) else { return [] }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    let cal = Calendar.current
    return (0..<days).reversed().compactMap { back in
      cal.date(byAdding: .day, value: -back, to: endDate).map(fmt.string(from:))
    }
  }

  /// The target of a kind's objective goal (the cap for "limit", etc.), so the
  /// Manage/wizard target field seeds from the live goal. Nil if no goal yet.
  static func objectiveGoalTarget(context: ModelContext, kindID: String) -> Double? {
    ((try? context.fetch(FetchDescriptor<GoalEntity>())) ?? [])
      .first { $0.metricKey?.hasPrefix("intake.\(kindID).") == true }?.metricTarget
  }

  /// Instant of the most recent event for a kind, for the "days since last"
  /// reduction signal. Nil if never logged.
  static func lastEventInstant(context: ModelContext, kindID: String) -> Date? {
    var desc = FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.kindID == kindID },
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    )
    desc.fetchLimit = 1
    return (try? context.fetch(desc))?.first?.occurredAt
  }

  private static func dto(_ k: IntakeKindEntity, count: Int) -> IntakeKindDTO {
    IntakeKindDTO(id: k.id, name: k.name, symbol: k.symbol, color: k.color,
                  unit: k.unit, doseStyle: k.doseStyle, countNoun: k.countNoun,
                  containerNoun: k.containerNoun, containerCap: k.containerCap,
                  catalogNoun: k.catalogNoun, flourish: k.flourish,
                  metricMode: k.metricMode, objective: k.objective,
                  methods: k.methods,
                  archived: k.archivedAt != nil, eventCount: count)
  }
}
