import Foundation
import Security
import SwiftData
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// Withings layer — direct iOS client for the Withings Public Health
// Data API plus local CloudKit-mirrored persistence. Replaces the
// FastAPI `/api/health/withings` proxy.
//
// Withings forces full OAuth2 authorization-code flow (no PAT, no
// PKCE), so the connect step opens an ASWebAuthenticationSession
// against account.withings.com, exchanges the returned code for an
// access+refresh pair, and stores both in Keychain. Refresh tokens
// rotate on every use — `WithingsProvider.refreshTokens` always
// overwrites the stored refresh token with whatever the server hands
// back, since the previous one is now invalid.
//
// Per-device by construction (tokens are not iCloud-Keychain-sync'd).
// Per-user data still ends up everywhere via CloudKit: connect on one
// device, fetched weigh-ins flow through WithingsStore → CKEngine →
// every other device the user is signed in on.
//
// Three pieces in this file:
//   • WithingsRowEntity — SwiftData @Model, one row per date.
//   • WithingsStore     — upsert + read, fans out to CloudKit.
//   • WithingsProvider  — OAuth + paginated measure/getmeas fetch +
//                         token rotation + Settings UI driver.
//
// CloudKit schema enum and the CloudKitSystemFieldsBacked
// extension live in Persistence.swift alongside Oura's.

// MARK: - Entity

@Model
final class WithingsRowEntity {
  /// "yyyy-MM-dd" — one row per day. Same shape as OuraNightEntity.
  @Attribute(.unique) var id: String

  var weightKg: Double?
  var fatPct: Double?
  var fatMassKg: Double?
  var fatFreeMassKg: Double?
  var muscleMassKg: Double?
  var hydrationKg: Double?
  var boneMassKg: Double?

  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       weightKg: Double? = nil,
       fatPct: Double? = nil,
       fatMassKg: Double? = nil,
       fatFreeMassKg: Double? = nil,
       muscleMassKg: Double? = nil,
       hydrationKg: Double? = nil,
       boneMassKg: Double? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.weightKg = weightKg
    self.fatPct = fatPct
    self.fatMassKg = fatMassKg
    self.fatFreeMassKg = fatFreeMassKg
    self.muscleMassKg = muscleMassKg
    self.hydrationKg = hydrationKg
    self.boneMassKg = boneMassKg
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }

  /// Apply `row`'s values; returns true iff any field actually changed. See
  /// `OuraNightEntity.update(from:)` — guarding each assignment turns a
  /// re-fetch of unchanged body history into a genuine no-op instead of a
  /// per-row write + CloudKit push + WAL growth on every dashboard refresh.
  @discardableResult
  func update(from row: WithingsRow) -> Bool {
    var changed = false
    func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<WithingsRowEntity, T>, _ value: T) {
      if self[keyPath: keyPath] != value {
        self[keyPath: keyPath] = value
        changed = true
      }
    }
    set(\.weightKg, row.weightKg)
    set(\.fatPct, row.fatPct)
    set(\.fatMassKg, row.fatMassKg)
    set(\.fatFreeMassKg, row.fatFreeMassKg)
    set(\.muscleMassKg, row.muscleMassKg)
    set(\.hydrationKg, row.hydrationKg)
    set(\.boneMassKg, row.boneMassKg)
    if changed { updatedAt = .now }
    return changed
  }

  func toRow() -> WithingsRow {
    var r = WithingsRow(date: id)
    r.weightKg = weightKg
    r.fatPct = fatPct
    r.fatMassKg = fatMassKg
    r.fatFreeMassKg = fatFreeMassKg
    r.muscleMassKg = muscleMassKg
    r.hydrationKg = hydrationKg
    r.boneMassKg = boneMassKg
    return r
  }
}

// MARK: - Store

@MainActor
@Observable
final class WithingsStore {
  static let shared = WithingsStore()

  private var context: ModelContext { LocalStore.shared.container.mainContext }
  private var ckEngine: CKEngine?

  private init() {}

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  /// Upsert a batch of rows. Skips dateless / fully-nil rows so the
  /// store doesn't fill up with empty placeholders.
  func upsert(_ rows: [WithingsRow]) {
    guard !rows.isEmpty else { return }
    var touched: [String] = []
    for row in rows where row.hasAnyData {
      let id = row.date
      let descriptor = FetchDescriptor<WithingsRowEntity>(
        predicate: #Predicate { $0.id == id }
      )
      if let entity = try? context.fetch(descriptor).first {
        if entity.update(from: row) { touched.append(id) }
      } else {
        let entity = WithingsRowEntity(id: id)
        entity.update(from: row)
        context.insert(entity)
        touched.append(id)
      }
    }
    // Unchanged re-fetch ⇒ no save, no CloudKit fan-out, no UI refresh, and
    // no body-goal re-evaluation (the trailing average can't have moved).
    guard !touched.isEmpty else { return }
    do { try context.save() }
    catch { SeptenaLog.error("WithingsStore: save failed", error) }
    for id in touched {
      ckEngine?.noteWithingsRowChange(id: id)
    }
    NotificationCenter.default.post(name: .septenaWithingsChanged, object: nil)
    // Body-metric goal rungs ride the ingest: a sync that moves the trailing
    // average past a rung queues the celebration for the next foreground
    // moment (Withings lands in the background — nobody is watching).
    SeptenaServices.shared.milestoneMutator.evaluateBodyGoals(
      now: .now, today: SeptenaDate.today)
  }

  /// N most recent days, newest-first (matches the FastAPI envelope).
  func history(days: Int, now: Date = Date()) -> [WithingsRow] {
    let cal = Calendar(identifier: .gregorian)
    guard let earliest = cal.date(byAdding: .day, value: -(days - 1), to: now)
    else { return [] }
    let earliestStr = Self.dateFormatter.string(from: earliest)
    let rows = (try? context.fetch(FetchDescriptor<WithingsRowEntity>(
      predicate: #Predicate { $0.id >= earliestStr },
      sortBy: [SortDescriptor(\.id, order: .reverse)]
    ))) ?? []
    return rows.map { $0.toRow() }
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

private extension WithingsRow {
  var hasAnyData: Bool {
    weightKg != nil || fatPct != nil || fatMassKg != nil ||
    fatFreeMassKg != nil || muscleMassKg != nil ||
    hydrationKg != nil || boneMassKg != nil
  }
}

// MARK: - Notification

extension Notification.Name {
  /// Posted after WithingsStore upserts a batch or after a CloudKit
  /// apply touches a WithingsRow record.
  static let septenaWithingsChanged = Notification.Name("septena.withings.changed")
}

// MARK: - OAuth credentials

/// App-level OAuth credentials registered at developer.withings.com.
/// Withings dev-app OAuth credentials.
///
/// Injected at build time from `Config/Secrets.xcconfig` (gitignored) via the
/// `WithingsClientID` / `WithingsClientSecret` Info.plist keys wired up in
/// `project.yml` — see `Config/Secrets.example.xcconfig` for the template.
/// The values are kept out of source control but are still embedded in the
/// shipped binary's Info.plist, which is acceptable for an OAuth "public
/// client" (a distributed app cannot hold a true secret). A clone without a
/// `Secrets.xcconfig` resolves both to empty strings, so `isConfigured` is
/// false and Withings degrades to "not configured" instead of failing the build.
enum WithingsAppCredentials {
  /// Withings dev-app `client_id`.
  static let clientID: String = infoString("WithingsClientID")
  /// Withings dev-app `client_secret`.
  static let clientSecret: String = infoString("WithingsClientSecret")
  /// Must match the redirect URI registered in the Withings dev app.
  /// The `septena` scheme is declared in Septena/Info.plist so the OS
  /// can route it back if anything ever opens the URL externally;
  /// ASWebAuthenticationSession itself intercepts the callback either
  /// way as long as `callbackURLScheme` matches.
  static let redirectURI: String = "septena://withings/callback"
  /// Scope string Withings expects on the authorize URL.
  static let scope: String = "user.metrics"

  static var isConfigured: Bool {
    !clientID.isEmpty && !clientSecret.isEmpty
  }

  /// Reads a string from the app bundle's Info.plist, returning "" when the
  /// key is absent or its `$(…)` build-setting substitution resolved to empty.
  private static func infoString(_ key: String) -> String {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
  }
}

// MARK: - Provider

@MainActor
@Observable
final class WithingsProvider {
  static let shared = WithingsProvider()

  /// Mirror of the Keychain-stored tokens. Updated whenever
  /// `connect`, `refreshTokens`, or `disconnect` change them.
  private(set) var hasTokens: Bool = false

  // MARK: Connection health
  //
  // See `ConnectionHealth` — "tokens sit in the Keychain" is not "Withings is
  // syncing". Withings is the most exposed of the three: the refresh token
  // rotates on every use, so one interrupted refresh can leave a pair that
  // will never work again, and the weigh-ins on screen come from the
  // CloudKit-mirrored store rather than the network — the chart simply stops
  // advancing, which is indistinguishable from not stepping on the scale.
  // Every fetch records its outcome here and the status surfaces read
  // `connectionDisplayState` instead of `hasTokens`.

  private var health = ConnectionHealth(namespace: "withings")

  /// When the last network fetch succeeded. `nil` = never (on this device).
  var lastFetchAt: Date? { health.lastFetchAt }
  /// Why the last network fetch failed, or `nil` if it succeeded.
  var lastError: String? { health.lastError }
  /// Settings-facing summary — one source of truth for the Integrations row
  /// and the Withings detail pane so they can never disagree.
  var connectionDisplayState: ConnectionDisplayState {
    health.displayState(hasCredentials: hasTokens)
  }

  private let session: URLSession
  private let accessAccount  = "septena.withings.access"
  private let refreshAccount = "septena.withings.refresh"
  private let expiresAccount = "septena.withings.expiresAt"

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
    self.hasTokens = Self.loadString(account: accessAccount) != nil
  }

  var isConfigured: Bool { WithingsAppCredentials.isConfigured }

  // MARK: Connect / disconnect

  /// Run the OAuth dance: open ASWebAuthenticationSession, exchange
  /// the returned code for tokens, persist them. Throws if the user
  /// cancels, if the app credentials aren't configured, or if either
  /// network step fails.
  func connect() async throws {
    guard isConfigured else { throw WithingsError.notConfigured }
    let state = UUID().uuidString
    var auth = URLComponents(string: "https://account.withings.com/oauth2_user/authorize2")!
    auth.queryItems = [
      .init(name: "response_type", value: "code"),
      .init(name: "client_id",     value: WithingsAppCredentials.clientID),
      .init(name: "state",         value: state),
      .init(name: "scope",         value: WithingsAppCredentials.scope),
      .init(name: "redirect_uri",  value: WithingsAppCredentials.redirectURI),
    ]
    guard let authURL = auth.url else { throw SeptenaError.invalidURL }

    let callbackURL = try await runAuthSession(authURL: authURL)
    let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    guard comps?.queryItems?.first(where: { $0.name == "state" })?.value == state else {
      throw WithingsError.stateMismatch
    }
    guard let code = comps?.queryItems?.first(where: { $0.name == "code" })?.value,
          !code.isEmpty else {
      throw WithingsError.missingCode
    }

    try await exchangeCode(code)
    // Fresh authorization deserves a clean slate — the previous connection's
    // rejection must not keep the row red until the next fetch lands.
    health.reset()
  }

  /// Wipe tokens. Doesn't revoke server-side — Withings's revoke
  /// endpoint requires a signed request and the next refresh attempt
  /// will fail cleanly anyway.
  func disconnect() {
    Self.deleteItem(account: accessAccount)
    Self.deleteItem(account: refreshAccount)
    Self.deleteItem(account: expiresAccount)
    hasTokens = false
    health.reset()
  }

  // MARK: Fetch

  /// N days of Withings weigh-ins, newest-first. Hits
  /// `wbsapi.withings.net/v2/measure?action=getmeas`, paginates via
  /// `body.more` + `offset`, collapses every measure group into one
  /// row per date, upserts via WithingsStore (which fans out to
  /// CloudKit), returns the merged window.
  ///
  /// When no tokens are set, returns whatever's in the local store —
  /// CloudKit-mirrored history still shows on a fresh device before
  /// the user re-connects.
  ///
  /// Success and failure are both recorded on the provider, so a caller that
  /// swallows the error with `try?` (the dashboard does, deliberately) still
  /// leaves the status surfaces able to say the section stopped updating and
  /// why.
  func fetchHistory(days: Int) async throws -> [WithingsRow] {
    // No credential, so nothing to be healthy or unhealthy about — the
    // display state already reads `.disconnected`, and recording anything
    // here would just overwrite the last real verdict.
    guard hasTokens else { return WithingsStore.shared.history(days: days) }
    do {
      let rows = try await performFetch(days: days)
      health.recordSuccess()
      return rows
    } catch {
      // A refresh that Withings rejected has already called `disconnect()`
      // deep inside this fetch, which resets health — so record *after*, or
      // the reason the user has to reconnect is wiped before they see it.
      health.recordFailure(error)
      throw error
    }
  }

  private func performFetch(days: Int) async throws -> [WithingsRow] {
    let cal = Calendar(identifier: .gregorian)
    let today = Date()
    let start = cal.date(byAdding: .day, value: -days, to: today) ?? today
    let startTs = Int(start.timeIntervalSince1970)
    let endTs   = Int(today.timeIntervalSince1970)

    let groups = try await fetchAllMeasureGroups(startTs: startTs, endTs: endTs)
    let rows = Self.collapseByDate(groups)
    WithingsStore.shared.upsert(rows)
    return WithingsStore.shared.history(days: days)
  }

  // MARK: - OAuth helpers

  /// Wraps ASWebAuthenticationSession into an async/await call. On
  /// macOS we still use ASWebAuthenticationSession (it's available);
  /// the presentation context returns the key window for either
  /// platform.
  private func runAuthSession(authURL: URL) async throws -> URL {
    #if canImport(AuthenticationServices)
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
      let session = ASWebAuthenticationSession(
        url: authURL,
        callbackURLScheme: "septena"
      ) { callback, error in
        if let error {
          cont.resume(throwing: error)
        } else if let callback {
          cont.resume(returning: callback)
        } else {
          cont.resume(throwing: WithingsError.cancelled)
        }
      }
      session.presentationContextProvider = AuthPresentationAnchor.shared
      session.prefersEphemeralWebBrowserSession = false
      if !session.start() {
        cont.resume(throwing: WithingsError.cancelled)
      }
    }
    #else
    throw WithingsError.notConfigured
    #endif
  }

  private func exchangeCode(_ code: String) async throws {
    let body: [String: String] = [
      "action":        "requesttoken",
      "grant_type":    "authorization_code",
      "client_id":     WithingsAppCredentials.clientID,
      "client_secret": WithingsAppCredentials.clientSecret,
      "code":          code,
      "redirect_uri":  WithingsAppCredentials.redirectURI,
    ]
    try await postToken(body: body)
  }

  /// Force a token refresh. Persists the new refresh_token returned
  /// in the response — Withings rotates it on every call and the
  /// previous one is invalidated as soon as this returns.
  func refreshTokens() async throws {
    guard let refresh = Self.loadString(account: refreshAccount) else {
      throw WithingsError.noRefreshToken
    }
    let body: [String: String] = [
      "action":        "requesttoken",
      "grant_type":    "refresh_token",
      "client_id":     WithingsAppCredentials.clientID,
      "client_secret": WithingsAppCredentials.clientSecret,
      "refresh_token": refresh,
    ]
    do {
      try await postToken(body: body)
    } catch WithingsError.apiStatus(let status, let msg) {
      // Withings returned a definitive "this refresh token is dead"
      // verdict (rotated, revoked, expired). Clear local tokens so the
      // Settings status flips to "Not connected" and the user sees the
      // Connect button instead of a stuck-green chip.
      SeptenaLog.error("Withings refresh rejected (status=\(status)): \(msg) — clearing tokens", nil)
      disconnect()
      throw WithingsError.refreshRejected(status, msg)
    }
  }

  private func postToken(body: [String: String]) async throws {
    let url = URL(string: "https://wbsapi.withings.net/v2/oauth2")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
      .map { "\($0.key)=\(percentEncode($0.value))" }
      .joined(separator: "&")
      .data(using: .utf8)

    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
    let envelope: TokenEnvelope
    do {
      envelope = try JSONDecoder().decode(TokenEnvelope.self, from: data)
    } catch {
      // Surface the raw body so the user can paste it back if Withings
      // ever returns an unexpected shape — this is the kind of thing
      // that breaks silently otherwise.
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      SeptenaLog.error("Withings token decode failed; body=\(raw)", error)
      throw WithingsError.malformedTokenResponse
    }
    if envelope.status != 0 {
      throw WithingsError.apiStatus(envelope.status, envelope.error ?? "unknown")
    }
    guard let body = envelope.body,
          let access = body.accessToken,
          let refresh = body.refreshToken,
          let expiresIn = body.expiresIn else {
      throw WithingsError.malformedTokenResponse
    }
    Self.storeString(access,  account: accessAccount)
    Self.storeString(refresh, account: refreshAccount)
    let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
    Self.storeString(String(Int(expiresAt.timeIntervalSince1970)), account: expiresAccount)
    hasTokens = true
  }

  // MARK: - Measure

  /// Paginated full-history pull for one timestamp window. Sends an
  /// initial GET, then keeps reissuing with `offset=…` until the
  /// server stops setting `more=1`. Caps at 50 pages as a safety
  /// stop — Withings returns ~200 groups per page, so this covers
  /// roughly ten thousand weigh-ins.
  private func fetchAllMeasureGroups(startTs: Int, endTs: Int) async throws -> [MeasureGroup] {
    var aggregated: [MeasureGroup] = []
    var offset: Int? = nil
    for _ in 0..<50 {
      let page = try await fetchMeasurePage(startTs: startTs, endTs: endTs, offset: offset)
      aggregated.append(contentsOf: page.body?.measuregrps ?? [])
      if let body = page.body, body.more == 1, let next = body.offset {
        offset = next
      } else {
        return aggregated
      }
    }
    return aggregated
  }

  /// Single GET against /v2/measure. On `status: 401` we refresh once
  /// and retry; on any other status we surface the error. HTTP-level
  /// failures (very rare — Withings almost always returns HTTP 200)
  /// are surfaced as SeptenaError.server.
  private func fetchMeasurePage(startTs: Int,
                                endTs: Int,
                                offset: Int?,
                                retriedAfterRefresh: Bool = false) async throws -> MeasureEnvelope {
    guard let access = Self.loadString(account: accessAccount) else {
      throw WithingsError.noAccessToken
    }
    var comps = URLComponents(string: "https://wbsapi.withings.net/v2/measure")!
    var items: [URLQueryItem] = [
      .init(name: "action",    value: "getmeas"),
      .init(name: "meastypes", value: "1,5,6,8,76,77,88"),
      .init(name: "category",  value: "1"),
      .init(name: "startdate", value: String(startTs)),
      .init(name: "enddate",   value: String(endTs)),
    ]
    if let offset { items.append(.init(name: "offset", value: String(offset))) }
    comps.queryItems = items
    guard let url = comps.url else { throw SeptenaError.invalidURL }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await session.data(for: req)
    let httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if httpCode >= 400 {
      throw SeptenaError.server(httpCode, String(data: data, encoding: .utf8) ?? "")
    }
    let env: MeasureEnvelope
    do {
      env = try JSONDecoder().decode(MeasureEnvelope.self, from: data)
    } catch {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      SeptenaLog.error("Withings measure decode failed; body=\(raw)", error)
      throw error
    }
    if env.status == 0 { return env }
    // 401 / 100 / 102 / 200 ≈ "token expired or invalid" depending on
    // version. The cheapest disambiguator is "try refresh once."
    if !retriedAfterRefresh, env.status == 401 || env.status == 100 || env.status == 102 || env.status == 200 {
      try await refreshTokens()
      return try await fetchMeasurePage(startTs: startTs, endTs: endTs,
                                        offset: offset, retriedAfterRefresh: true)
    }
    throw WithingsError.apiStatus(env.status, env.error ?? "unknown")
  }

  /// Collapse Withings measure groups into one WithingsRow per date.
  /// Within a day, later weigh-ins win (the API returns groups in
  /// reverse chronological order — Withings's choice — so we walk
  /// forward and keep overwriting, leaving the latest of the day).
  private static func collapseByDate(_ groups: [MeasureGroup]) -> [WithingsRow] {
    let cal = Calendar.current
    let fmt: DateFormatter = {
      let f = DateFormatter()
      f.calendar = Calendar(identifier: .gregorian)
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = .current
      f.dateFormat = "yyyy-MM-dd"
      return f
    }()
    // Process oldest → newest so the newest weigh-in of a day wins.
    let sorted = groups.sorted { $0.date < $1.date }
    var byDate: [String: WithingsRow] = [:]
    for g in sorted {
      let date = Date(timeIntervalSince1970: TimeInterval(g.date))
      let day = fmt.string(from: cal.startOfDay(for: date))
      var row = byDate[day] ?? WithingsRow(date: day)
      for m in g.measures {
        let v = Double(m.value) * pow(10.0, Double(m.unit))
        switch m.type {
        case 1:  row.weightKg      = v
        case 5:  row.fatFreeMassKg = v
        case 6:  row.fatPct        = v
        case 8:  row.fatMassKg     = v
        case 76: row.muscleMassKg  = v
        case 77: row.hydrationKg   = v
        case 88: row.boneMassKg    = v
        default: break
        }
      }
      byDate[day] = row
    }
    return Array(byDate.values)
  }

  // MARK: - Decoding

  private struct TokenEnvelope: Decodable {
    let status: Int
    let body: TokenBody?
    let error: String?
  }
  private struct TokenBody: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
      case accessToken  = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn    = "expires_in"
    }
    // Withings includes `userid`, `scope`, `token_type`, `csrf_token`
    // in the body. We don't need them and skipping them lets the
    // decoder ignore type mismatches in fields we never read (notably
    // `userid`, which is documented as String in some responses and
    // Int in others). Decodable ignores unknown keys by default, so
    // just leaving them out of CodingKeys is enough.
  }

  private struct MeasureEnvelope: Decodable {
    let status: Int
    let body: MeasureBody?
    let error: String?
  }
  private struct MeasureBody: Decodable {
    let updatetime: Int?
    let measuregrps: [MeasureGroup]?
    let more: Int?
    let offset: Int?
  }
  private struct MeasureGroup: Decodable {
    let grpid: Int64
    let date: Int           // Unix timestamp (seconds)
    let measures: [Measure]
    enum CodingKeys: String, CodingKey {
      case grpid, date, measures
    }
  }
  private struct Measure: Decodable {
    let value: Int64
    let type: Int
    let unit: Int           // value = `value * 10^unit`
  }

  // MARK: - Helpers

  private func percentEncode(_ s: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=?")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }

  // MARK: - Keychain

  private static func storeString(_ value: String, account: String) {
    let data = Data(value.utf8)
    let base: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = base
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  private static func loadString(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
      kSecReturnData as String:  true,
      kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteItem(account: String) {
    let q: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(q as CFDictionary)
  }
}

// MARK: - Errors

enum WithingsError: LocalizedError {
  case notConfigured
  case cancelled
  case stateMismatch
  case missingCode
  case malformedTokenResponse
  case noAccessToken
  case noRefreshToken
  case apiStatus(Int, String)
  case refreshRejected(Int, String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Withings app credentials are not configured. Add your client_id and client_secret to Config/Secrets.xcconfig (copy it from Config/Secrets.example.xcconfig), then rebuild."
    case .cancelled: return "Sign-in was cancelled."
    case .stateMismatch: return "OAuth state mismatch — possible CSRF, aborting."
    case .missingCode: return "Withings did not return an authorization code."
    case .malformedTokenResponse: return "Withings token response was missing required fields."
    case .noAccessToken: return "No Withings access token; reconnect in Settings."
    case .noRefreshToken: return "No Withings refresh token; reconnect in Settings."
    case .apiStatus(let s, let msg): return "Withings API status \(s): \(msg)"
    case .refreshRejected(let s, let msg):
      return "Withings rejected the refresh token (status \(s): \(msg)). Please reconnect in Settings."
    }
  }
}

// MARK: - ASWebAuthenticationSession presentation context

#if canImport(AuthenticationServices)
@MainActor
private final class AuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = AuthPresentationAnchor()

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if canImport(UIKit)
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let window = scenes
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
      ?? scenes.flatMap(\.windows).first
      ?? UIWindow()
    return window
    #elseif canImport(AppKit)
    return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
  }
}
#endif
