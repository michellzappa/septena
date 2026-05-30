import Foundation
import Security
import SwiftData

// Oura layer — direct iOS client for the Oura Cloud v2 API plus local
// CloudKit-mirrored persistence. Replaces the FastAPI `/api/health/oura`
// proxy.
//
// Per-user by construction: each install authenticates with its own
// Personal Access Token (Keychain), and the resulting nights land in
// that user's private CloudKit zone via CKSyncEngine — the same pipe
// every other section uses.
//
// Three pieces in this file:
//   • OuraNightEntity — SwiftData @Model, one row per date.
//   • OuraStore       — upsert + read helper, wires fan-out to CloudKit.
//   • OuraProvider    — fetches from api.ouraring.com with next_token
//                       pagination, writes via OuraStore, returns the
//                       merged [OuraNight] (same shape views consume).
//
// The CloudKit-record extension and schema enum live in Persistence.swift
// alongside the other ChecklistCloudKitBackedEntity conformances (the
// helper protocol is fileprivate there).

// MARK: - Entity

@Model
final class OuraNightEntity {
  /// Date string "yyyy-MM-dd" doubles as the unique identifier. One
  /// night per date, upserted idempotently.
  @Attribute(.unique) var id: String

  var sleepScore: Int?
  var readinessScore: Int?
  var totalH: Double?
  var deepH: Double?
  var remH: Double?
  var lightH: Double?
  var awakeH: Double?
  var efficiency: Int?
  var hrv: Int?
  var restingHr: Int?
  var bedtime: String?
  var wakeTime: String?
  var stressHighMin: Int?
  var recoveryHighMin: Int?
  var stressSummary: String?

  var updatedAt: Date
  /// CKSyncEngine per-record system fields. Same pattern as the other
  /// ChecklistCloudKitBackedEntity conformances.
  var cloudKitSystemFields: Data?

  init(id: String,
       sleepScore: Int? = nil,
       readinessScore: Int? = nil,
       totalH: Double? = nil,
       deepH: Double? = nil,
       remH: Double? = nil,
       lightH: Double? = nil,
       awakeH: Double? = nil,
       efficiency: Int? = nil,
       hrv: Int? = nil,
       restingHr: Int? = nil,
       bedtime: String? = nil,
       wakeTime: String? = nil,
       stressHighMin: Int? = nil,
       recoveryHighMin: Int? = nil,
       stressSummary: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.sleepScore = sleepScore
    self.readinessScore = readinessScore
    self.totalH = totalH
    self.deepH = deepH
    self.remH = remH
    self.lightH = lightH
    self.awakeH = awakeH
    self.efficiency = efficiency
    self.hrv = hrv
    self.restingHr = restingHr
    self.bedtime = bedtime
    self.wakeTime = wakeTime
    self.stressHighMin = stressHighMin
    self.recoveryHighMin = recoveryHighMin
    self.stressSummary = stressSummary
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }

  func update(from night: OuraNight) {
    sleepScore       = night.sleepScore
    readinessScore   = night.readinessScore
    totalH           = night.totalH
    deepH            = night.deepH
    remH             = night.remH
    lightH           = night.lightH
    awakeH           = night.awakeH
    efficiency       = night.efficiency
    hrv              = night.hrv
    restingHr        = night.restingHr
    bedtime          = night.bedtime
    wakeTime         = night.wakeTime
    stressHighMin    = night.stressHighMin
    recoveryHighMin  = night.recoveryHighMin
    stressSummary    = night.stressSummary
    updatedAt = .now
  }

  func toNight() -> OuraNight {
    var n = OuraNight(date: id)
    n.sleepScore = sleepScore
    n.readinessScore = readinessScore
    n.totalH = totalH
    n.deepH = deepH
    n.remH = remH
    n.lightH = lightH
    n.awakeH = awakeH
    n.efficiency = efficiency
    n.hrv = hrv
    n.restingHr = restingHr
    n.bedtime = bedtime
    n.wakeTime = wakeTime
    n.stressHighMin = stressHighMin
    n.recoveryHighMin = recoveryHighMin
    n.stressSummary = stressSummary
    return n
  }
}

// MARK: - Store

/// SwiftData-backed read/write surface for `OuraNightEntity`. Late-binds
/// to CKEngine in SeptenaServices.start() so every upsert fans out to CloudKit.
@MainActor
@Observable
final class OuraStore {
  static let shared = OuraStore()

  private var context: ModelContext { LocalStore.shared.container.mainContext }
  private var ckEngine: CKEngine?

  private init() {}

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  /// Upsert a batch of nights. Only nights with at least one populated
  /// field beyond `date` are persisted — Oura returns rows for missing
  /// days too, and we don't want empty placeholders polluting charts.
  func upsert(_ nights: [OuraNight]) {
    guard !nights.isEmpty else { return }
    var touched: [String] = []
    for night in nights where night.hasAnyData {
      let id = night.date
      let descriptor = FetchDescriptor<OuraNightEntity>(
        predicate: #Predicate { $0.id == id }
      )
      if let entity = try? context.fetch(descriptor).first {
        entity.update(from: night)
      } else {
        let entity = OuraNightEntity(id: id)
        entity.update(from: night)
        context.insert(entity)
      }
      touched.append(id)
    }
    do { try context.save() }
    catch { SeptenaLog.error("OuraStore: save failed", error) }
    for id in touched {
      ckEngine?.noteOuraNightChange(id: id)
    }
    NotificationCenter.default.post(name: .septenaOuraChanged, object: nil)
  }

  /// Most-recent-N-days, ordered newest-first to match the FastAPI
  /// envelope ordering callers already expect.
  func history(days: Int, now: Date = Date()) -> [OuraNight] {
    let cal = Calendar(identifier: .gregorian)
    guard let earliest = cal.date(byAdding: .day, value: -(days - 1), to: now)
    else { return [] }
    let earliestStr = Self.dateFormatter.string(from: earliest)
    let rows = (try? context.fetch(FetchDescriptor<OuraNightEntity>(
      predicate: #Predicate { $0.id >= earliestStr },
      sortBy: [SortDescriptor(\.id, order: .reverse)]
    ))) ?? []
    return rows.map { $0.toNight() }
  }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
}

private extension OuraNight {
  /// True if any field beyond `date` carries a value. Used to skip
  /// no-data placeholder rows so the store stays clean.
  var hasAnyData: Bool {
    sleepScore != nil || readinessScore != nil || totalH != nil ||
    deepH != nil || remH != nil || lightH != nil || awakeH != nil ||
    efficiency != nil || hrv != nil || restingHr != nil ||
    bedtime != nil || wakeTime != nil ||
    stressHighMin != nil || recoveryHighMin != nil || stressSummary != nil
  }
}

// MARK: - Notification

extension Notification.Name {
  /// Posted after OuraStore upserts a batch. Sleep / Insights /
  /// Week dashboard listen so freshly-pulled nights repaint without
  /// each view wiring its own refresh loop.
  static let septenaOuraChanged = Notification.Name("septena.oura.changed")
}

// MARK: - Provider

@MainActor
@Observable
final class OuraProvider {
  static let shared = OuraProvider()

  /// Mirror of the Keychain-stored PAT. Settings reads / writes via
  /// `setToken` / `clearToken`; everything else inspects `hasToken`.
  private(set) var token: String?

  var hasToken: Bool { token?.isEmpty == false }

  private let session: URLSession
  private let keychainAccount = "septena.oura.pat"

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
    self.token = Self.loadToken(account: keychainAccount)
  }

  // MARK: Token

  func setToken(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { clearToken(); return }
    Self.storeToken(trimmed, account: keychainAccount)
    token = trimmed
  }

  func clearToken() {
    Self.deleteToken(account: keychainAccount)
    token = nil
  }

  // MARK: Fetch

  /// N nights of Oura sleep, newest-first. Hits api.ouraring.com,
  /// follows `next_token` until exhausted, upserts every populated row
  /// into OuraStore (which fans out to CloudKit), and returns the
  /// merged window for the caller.
  ///
  /// When no token is set, returns whatever the local store has — the
  /// app still shows historical CloudKit-synced data on a fresh
  /// install before the user pastes their PAT.
  func fetchHistory(days: Int) async throws -> [OuraNight] {
    guard let token = token, !token.isEmpty else {
      return OuraStore.shared.history(days: days)
    }

    let cal = Calendar(identifier: .gregorian)
    let today = Date()
    let start = cal.date(byAdding: .day, value: -days, to: today) ?? today
    // Widen `sleep` start by one day — long_sleep records are keyed by
    // wake date, so a session ending on day-N starts on day-(N-1).
    let widenedStart = cal.date(byAdding: .day, value: -1, to: start) ?? start
    let endPlus = cal.date(byAdding: .day, value: 1, to: today) ?? today

    let startStr = Self.dateFormatter.string(from: start)
    let widenedStartStr = Self.dateFormatter.string(from: widenedStart)
    let endStr = Self.dateFormatter.string(from: endPlus)

    // Four endpoints in series — they share api.ouraring.com and tight
    // rate limits make parallelism risky; payload is small either way.
    let sleeps:    [SleepRow]          = try await getAll("sleep",
                                                          from: widenedStartStr, to: endStr,
                                                          token: token, as: SleepRow.self)
    let dailies:   [DailySleepRow]     = try await getAll("daily_sleep",
                                                          from: startStr, to: endStr,
                                                          token: token, as: DailySleepRow.self)
    let readies:   [DailyReadinessRow] = try await getAll("daily_readiness",
                                                          from: startStr, to: endStr,
                                                          token: token, as: DailyReadinessRow.self)
    let stresses:  [DailyStressRow]    = try await getAll("daily_stress",
                                                          from: startStr, to: endStr,
                                                          token: token, as: DailyStressRow.self)

    var sleepByDay: [String: SleepRow] = [:]
    for s in sleeps where s.type == "long_sleep" { sleepByDay[s.day] = s }
    let dailyByDay   = Dictionary(uniqueKeysWithValues: dailies.map  { ($0.day, $0) })
    let readyByDay   = Dictionary(uniqueKeysWithValues: readies.map  { ($0.day, $0) })
    let stressByDay  = Dictionary(uniqueKeysWithValues: stresses.map { ($0.day, $0) })

    var rows: [OuraNight] = []
    for offset in 0..<days {
      guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
      let day = Self.dateFormatter.string(from: d)
      var night = OuraNight(date: day)
      night.sleepScore     = dailyByDay[day]?.score
      night.readinessScore = readyByDay[day]?.score
      if let s = sleepByDay[day] {
        night.totalH    = hours(s.totalSleepDuration)
        night.deepH     = hours(s.deepSleepDuration)
        night.remH      = hours(s.remSleepDuration)
        night.lightH    = hours(s.lightSleepDuration)
        night.awakeH    = hours(s.awakeTime)
        night.efficiency = s.efficiency
        night.hrv       = s.averageHrv
        night.restingHr = s.lowestHeartRate
        night.bedtime   = hhmm(from: s.bedtimeStart)
        night.wakeTime  = hhmm(from: s.bedtimeEnd)
      }
      if let st = stressByDay[day] {
        if let v = st.stressHigh   { night.stressHighMin   = Int((Double(v) / 60).rounded()) }
        if let v = st.recoveryHigh { night.recoveryHighMin = Int((Double(v) / 60).rounded()) }
        if let v = st.daySummary   { night.stressSummary   = v }
      }
      rows.append(night)
    }

    OuraStore.shared.upsert(rows)
    return rows
  }

  // MARK: HTTP

  /// Fetches every page of an Oura v2 usercollection endpoint, following
  /// `next_token` until nil. A hard cap (50 pages = up to ~years of
  /// daily data) prevents a misbehaving server from spinning forever.
  private func getAll<Row: Decodable>(_ collection: String,
                                      from start: String,
                                      to end: String,
                                      token: String,
                                      as rowType: Row.Type) async throws -> [Row] {
    var aggregated: [Row] = []
    var nextToken: String? = nil
    for _ in 0..<50 {
      let page: PagedEnvelope<Row> = try await getPage(collection,
                                                       from: start, to: end,
                                                       nextToken: nextToken,
                                                       token: token)
      aggregated.append(contentsOf: page.data)
      guard let token = page.nextToken, !token.isEmpty else { return aggregated }
      nextToken = token
    }
    return aggregated
  }

  private func getPage<Row: Decodable>(_ collection: String,
                                       from start: String,
                                       to end: String,
                                       nextToken: String?,
                                       token: String) async throws -> PagedEnvelope<Row> {
    var comps = URLComponents(string: "https://api.ouraring.com/v2/usercollection/\(collection)")!
    var items: [URLQueryItem] = [
      URLQueryItem(name: "start_date", value: start),
      URLQueryItem(name: "end_date",   value: end),
    ]
    if let nextToken { items.append(URLQueryItem(name: "next_token", value: nextToken)) }
    comps.queryItems = items
    guard let url = comps.url else { throw SeptenaError.invalidURL }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
    do {
      return try JSONDecoder().decode(PagedEnvelope<Row>.self, from: data)
    } catch {
      throw SeptenaError.decoding(String(describing: error))
    }
  }

  // MARK: Decoding

  private struct PagedEnvelope<T: Decodable>: Decodable {
    let data: [T]
    let nextToken: String?
    enum CodingKeys: String, CodingKey { case data; case nextToken = "next_token" }
  }

  private struct SleepRow: Decodable {
    let day: String
    let type: String?
    let totalSleepDuration:  Int?
    let deepSleepDuration:   Int?
    let remSleepDuration:    Int?
    let lightSleepDuration:  Int?
    let awakeTime:           Int?
    let efficiency:          Int?
    let averageHrv:          Int?
    let lowestHeartRate:     Int?
    let bedtimeStart:        String?
    let bedtimeEnd:          String?
    enum CodingKeys: String, CodingKey {
      case day, type, efficiency
      case totalSleepDuration  = "total_sleep_duration"
      case deepSleepDuration   = "deep_sleep_duration"
      case remSleepDuration    = "rem_sleep_duration"
      case lightSleepDuration  = "light_sleep_duration"
      case awakeTime           = "awake_time"
      case averageHrv          = "average_hrv"
      case lowestHeartRate     = "lowest_heart_rate"
      case bedtimeStart        = "bedtime_start"
      case bedtimeEnd          = "bedtime_end"
    }
  }

  private struct DailySleepRow:     Decodable { let day: String; let score: Int? }
  private struct DailyReadinessRow: Decodable { let day: String; let score: Int? }
  private struct DailyStressRow: Decodable {
    let day: String
    let stressHigh:   Int?
    let recoveryHigh: Int?
    let daySummary:   String?
    enum CodingKeys: String, CodingKey {
      case day
      case stressHigh   = "stress_high"
      case recoveryHigh = "recovery_high"
      case daySummary   = "day_summary"
    }
  }

  // MARK: Helpers

  private func hours(_ seconds: Int?) -> Double? {
    guard let s = seconds else { return nil }
    return (Double(s) / 3600 * 100).rounded() / 100
  }

  private func hhmm(from iso: String?) -> String? {
    guard let iso, iso.count >= 16 else { return nil }
    let start = iso.index(iso.startIndex, offsetBy: 11)
    let end   = iso.index(iso.startIndex, offsetBy: 16)
    return String(iso[start..<end])
  }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  // MARK: Keychain

  private static func storeToken(_ token: String, account: String) {
    let data = Data(token.utf8)
    let baseQuery: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = baseQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(addQuery as CFDictionary, nil)
    }
  }

  private static func loadToken(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
      kSecReturnData as String:  true,
      kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteToken(account: String) {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
