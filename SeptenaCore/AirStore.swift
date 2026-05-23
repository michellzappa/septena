import Foundation
import SwiftData

// AirStore — local persistence + client-side aggregation for Aranet
// readings captured by AranetBridge.
//
// SwiftData is the only authoritative store today. CloudKit sync for
// AirReading is intentionally deferred: wiring a new record type into
// CKEngine + SeptenaServices' record dispatcher is a non-trivial pass
// that's better done alongside the rest of the air-data backend
// (history archive, multi-device merge). For now the Mac Mini + REST
// path goes away, and air data lives where the readings were captured.
// When CK is added, the persisted `cloudKitSystemFields` slot on the
// entity is the hook — same pattern as CaffeineEventEntity et al.

// MARK: - Entity

@Model
final class AirReadingEntity {
  /// Stable identifier — UUID-prefix, opaque. Not a CloudKit recordName
  /// today; will become one when the CK pass lands (see file header).
  @Attribute(.unique) var id: String
  /// ISO date "yyyy-MM-dd" so day-aggregations can group by string
  /// without re-parsing capturedAt every time, matching the rest of the
  /// app's date model (TaskEntity.scheduled, CaffeineEventEntity.date, …).
  var date: String
  /// "HH:mm:ss" wall-clock of capture. Same rationale as `date`.
  var time: String
  var capturedAt: Date

  var co2Ppm: Int?
  var tempC: Double?
  var humidityPct: Int?
  var pressureHPa: Double?
  var batteryPct: Int?

  var updatedAt: Date
  /// Reserved for CKSyncEngine's per-record system fields blob. Nil
  /// until the CK pass lands; keeping the slot here means we can add
  /// CK sync without a schema migration.
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       time: String,
       capturedAt: Date,
       co2Ppm: Int? = nil,
       tempC: Double? = nil,
       humidityPct: Int? = nil,
       pressureHPa: Double? = nil,
       batteryPct: Int? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.time = time
    self.capturedAt = capturedAt
    self.co2Ppm = co2Ppm
    self.tempC = tempC
    self.humidityPct = humidityPct
    self.pressureHPa = pressureHPa
    self.batteryPct = batteryPct
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

// MARK: - Store

/// Persists Aranet snapshots and computes the summary/history shapes the
/// AirDestinationView already consumes (AirSummary, AirHistoryResponse).
/// Stateless on its own — holds a ModelContext reference and is safe to
/// instantiate per-call.
@MainActor
@Observable
final class AirStore {
  private let context: ModelContext
  /// CloudKit sync engine. Nil at construction (the engine is built
  /// later in SeptenaServices.start()), bound via `bind(ckEngine:)`
  /// once the dispatcher is wired so every ingested reading also
  /// fans out to CloudKit. Same pattern as the other mutators.
  private var ckEngine: CKEngine?

  /// Aranet measures once per minute; ingesting more often than that is
  /// pointless duplicate work. We collapse identical readings inside a
  /// 50s window — slightly under the device interval so we don't
  /// accidentally drop the legit next sample if it arrives a hair early.
  private static let dedupeWindow: TimeInterval = 50

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  /// Late-binding hook called from SeptenaServices.start() once the
  /// CKEngine's record-provider / apply closures are wired up. Until
  /// this fires, ingested readings stay local-only (and will sync up
  /// later via the unrelated `cloudKitSystemFields` system-field
  /// capture path the first time they're ever updated post-bind).
  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  // MARK: Ingest

  /// Record a fresh snapshot. Coalesces duplicates by `capturedAt` so
  /// re-subscribes (e.g. after a disconnect/reconnect) don't generate
  /// extra rows for the same 60s measurement.
  func ingest(_ snap: AranetSnapshot) {
    let isoDate = Self.dateFormatter.string(from: snap.capturedAt)
    let timeStr = Self.timeFormatter.string(from: snap.capturedAt)
    let cutoff = snap.capturedAt.addingTimeInterval(-Self.dedupeWindow)
    // Cheap dedupe: was a row with the same CO2 reading just persisted?
    let recent = try? context.fetch(FetchDescriptor<AirReadingEntity>(
      predicate: #Predicate { $0.capturedAt >= cutoff }
    ))
    if let r = recent?.first, r.co2Ppm == snap.co2Ppm,
       abs(r.capturedAt.timeIntervalSince(snap.capturedAt)) < Self.dedupeWindow {
      return
    }
    let id = String(UUID().uuidString.lowercased().prefix(12))
    let entity = AirReadingEntity(
      id: id,
      date: isoDate,
      time: timeStr,
      capturedAt: snap.capturedAt,
      co2Ppm: snap.co2Ppm,
      tempC: snap.tempC,
      humidityPct: snap.humidityPct,
      pressureHPa: snap.pressureHPa,
      batteryPct: snap.batteryPct
    )
    context.insert(entity)
    do { try context.save() }
    catch { SeptenaLog.error("AirStore: save failed", error) }
    // Fan out to CloudKit. The engine batches + retries internally,
    // so this is fire-and-forget — no need to await or check.
    ckEngine?.noteAirReadingChange(id: id)
    NotificationCenter.default.post(name: .septenaAirChanged, object: nil)
  }

  // MARK: Reads / aggregation

  /// Latest reading + today/last-24h stats. Mirrors what
  /// `client.airSummary()` used to return so AirDestinationView's
  /// existing render code keeps working unchanged.
  func summary(now: Date = Date()) -> AirSummary {
    let cal = Calendar.current
    let startOfDay = cal.startOfDay(for: now)
    let last24h = now.addingTimeInterval(-24 * 3600)
    let all = (try? context.fetch(FetchDescriptor<AirReadingEntity>(
      sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
    ))) ?? []
    let latest = all.first.map(Self.toReading(_:))
    let today = all.filter { $0.capturedAt >= startOfDay }
    let day24 = all.filter { $0.capturedAt >= last24h }
    return AirSummary(
      latest: latest,
      co2Band: all.first.flatMap { Self.band(forCo2: $0.co2Ppm) },
      today: Self.stats(today),
      last24h: Self.stats(day24)
    )
  }

  /// Daily averages over the past `days` days, ordered oldest-first to
  /// match the FastAPI response shape AirDestinationView reverses.
  func history(days: Int = 7, now: Date = Date()) -> AirHistoryResponse {
    let cal = Calendar.current
    let startOfDay = cal.startOfDay(for: now)
    guard let cutoff = cal.date(byAdding: .day,
                                value: -(days - 1),
                                to: startOfDay) else {
      return AirHistoryResponse(daily: [])
    }
    let rows = (try? context.fetch(FetchDescriptor<AirReadingEntity>(
      predicate: #Predicate { $0.capturedAt >= cutoff }
    ))) ?? []
    let grouped = Dictionary(grouping: rows, by: \.date)
    let points: [AirHistoryPoint] = (0..<days).compactMap { offset in
      guard let day = cal.date(byAdding: .day, value: -offset, to: startOfDay)
      else { return nil }
      let dateStr = Self.dateFormatter.string(from: day)
      let bucket = grouped[dateStr] ?? []
      let stats = Self.stats(bucket)
      return AirHistoryPoint(date: dateStr,
                             readings: stats.readings,
                             co2Avg: stats.co2Avg,
                             co2Max: stats.co2Max,
                             minutesOver1000: stats.minutesOver1000)
    }
    return AirHistoryResponse(daily: points.reversed())
  }

  // MARK: Helpers

  private static func toReading(_ e: AirReadingEntity) -> AirReading {
    AirReading(date: e.date,
               time: e.time,
               id_: e.id,
               co2Ppm: e.co2Ppm.map(Double.init),
               tempC: e.tempC,
               humidityPct: e.humidityPct.map(Double.init))
  }

  /// Same band thresholds AranetSnapshot uses — duplicated here because
  /// we may be summarizing historical rows whose original snapshot is
  /// long gone.
  private static func band(forCo2 ppm: Int?) -> String? {
    guard let ppm else { return nil }
    switch ppm {
    case ..<700:  return "good"
    case ..<1000: return "ok"
    case ..<1400: return "poor"
    default:      return "bad"
    }
  }

  /// Aggregate one bucket of readings into the stats shape the dashboard
  /// expects. `minutesOver1000` is approximated as
  /// `readings_over_1000 * device_interval` — every reading represents
  /// 60s of measurement, so the count is the dwell time in minutes.
  private static func stats(_ rows: [AirReadingEntity]) -> AirDayStats {
    let co2 = rows.compactMap(\.co2Ppm)
    let temps = rows.compactMap(\.tempC)
    let hums = rows.compactMap(\.humidityPct).map(Double.init)
    let avg: ([Double]) -> Double? = { xs in
      xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
    return AirDayStats(
      readings: rows.count,
      co2Avg: avg(co2.map(Double.init)),
      co2Max: co2.max().map(Double.init),
      tempAvg: avg(temps),
      humidityAvg: avg(hums),
      minutesOver1000: co2.filter { $0 > 1000 }.count
    )
  }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "HH:mm:ss"
    return f
  }()
}

// MARK: - Notification

extension Notification.Name {
  /// Posted whenever AirStore ingests a fresh reading. AirDestinationView
  /// listens for this so the dashboard repaints in real time.
  static let septenaAirChanged = Notification.Name("septena.air.changed")
}
