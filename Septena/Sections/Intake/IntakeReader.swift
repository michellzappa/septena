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
  let showsAmount: Bool
  let todayCount: Int
  let todayAmount: Double
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
    return kinds.filter { $0.archivedAt == nil }.map { dto($0, count: counts[$0.id] ?? 0) }
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
    return kinds.map { dto($0, count: counts[$0.id] ?? 0) }
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
    let kinds = (try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    )))?.filter { $0.archivedAt == nil } ?? []
    guard !kinds.isEmpty else { return [] }
    let events = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.date == date }
    ))) ?? []
    var counts: [String: Int] = [:]
    var sums: [String: Double] = [:]
    for e in events {
      counts[e.kindID, default: 0] += 1
      sums[e.kindID, default: 0] += e.amount ?? 0
    }
    return kinds.map { k in
      IntakeTileDTO(id: k.id, name: k.name, symbol: k.symbol, color: k.color,
                    unit: k.unit,
                    showsAmount: k.doseStyle == "amount" || k.doseStyle == "both",
                    todayCount: counts[k.id] ?? 0,
                    todayAmount: sums[k.id] ?? 0)
    }
  }

  private static func dto(_ k: IntakeKindEntity, count: Int) -> IntakeKindDTO {
    IntakeKindDTO(id: k.id, name: k.name, symbol: k.symbol, color: k.color,
                  unit: k.unit, doseStyle: k.doseStyle, countNoun: k.countNoun,
                  containerNoun: k.containerNoun, containerCap: k.containerCap,
                  catalogNoun: k.catalogNoun, flourish: k.flourish,
                  metricMode: k.metricMode, methods: k.methods,
                  archived: k.archivedAt != nil, eventCount: count)
  }
}
