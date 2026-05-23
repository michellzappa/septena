import Foundation
import CoreLocation

// PollenClient — pollen data fetched directly from Open-Meteo's free
// Air Quality API and cached locally. No CloudKit, no SwiftData: the
// data is publicly available, identical for every device at the same
// location, and refreshes slowly (hourly resolution, twice-a-day
// granularity is sufficient). Syncing it through CloudKit would burn
// bytes and quota for zero benefit.
//
// Mirrors septena-app's `scripts/pollen_poller.py` and `/api/air/pollen`
// endpoint — same species set, same severity bands, same aggregation
// rules. If you change one, change the other.

// MARK: - Models

/// Snapshot of pollen readings for a single day, rolled up across the
/// hourly forecast Open-Meteo returns. `*_max` are the day's peak,
/// per-species; bare names are daily averages. Tree = max(birch,
/// alder, olive); weed = max(ragweed, mugwort).
struct PollenSummary: Codable, Hashable {
  let date: String              // "yyyy-MM-dd"
  let grass: Double?
  let grassMax: Double?
  let birch: Double?
  let birchMax: Double?
  let tree: Double?
  let treeMax: Double?
  let weed: Double?
  let weedMax: Double?
  let overallBand: String       // "low" | "medium" | "high" | "very_high" | "unknown"

  enum CodingKeys: String, CodingKey {
    case date
    case grass, birch, tree, weed
    case grassMax = "grass_max"
    case birchMax = "birch_max"
    case treeMax  = "tree_max"
    case weedMax  = "weed_max"
    case overallBand = "overall_band"
  }
}

/// Severity bucket for a single pollen species value. Thresholds
/// match `POLLEN_THRESHOLDS` in septena-app/api/routers/air.py.
enum PollenBand: String {
  case unknown, low, medium, high, veryHigh = "very_high"

  /// Color helper for UI — kept here so SwiftUI views don't need to
  /// import a separate palette module.
  var swatchHex: String {
    switch self {
    case .unknown:  return "#9ca3af" // neutral gray
    case .low:      return "#22c55e"
    case .medium:   return "#eab308"
    case .high:     return "#f97316"
    case .veryHigh: return "#ef4444"
    }
  }
}

// MARK: - Thresholds (single source of truth, matches air.py)

private let pollenThresholds: [String: (low: Double, medium: Double, high: Double)] = [
  "grass":   (5,  20, 50),
  "birch":   (10, 50, 200),
  "alder":   (10, 50, 200),
  "olive":   (10, 50, 200),
  "ragweed": (5,  11, 25),
  "mugwort": (5,  11, 25),
]

private func pollenBand(species: String, value: Double?) -> PollenBand {
  guard let value else { return .unknown }
  // Tree / weed roll-ups share the worse single-species thresholds.
  let key: String = {
    switch species {
    case "tree": return "birch"
    case "weed": return "ragweed"
    default: return species
    }
  }()
  guard let t = pollenThresholds[key] else { return .unknown }
  if value <= t.low    { return .low }
  if value <= t.medium { return .medium }
  if value <= t.high   { return .high }
  return .veryHigh
}

/// Daily roll-up over a historical window. The bar chart on the Air
/// dashboard maps one of these per day. Mirrors webapp's
/// `AirPollenDayPoint` shape.
struct PollenDayPoint: Codable, Hashable, Identifiable {
  let date: String              // "yyyy-MM-dd"
  let grass: Double?
  let grassMax: Double?
  let birch: Double?
  let birchMax: Double?
  let tree: Double?
  let treeMax: Double?
  let weed: Double?
  let weedMax: Double?

  var id: String { date }
}

// MARK: - Client

/// Fetches + caches pollen for the user's current location. Permission
/// flow follows the standard "ask once on demand" pattern: first call
/// to `refresh()` prompts for "When In Use" location; subsequent calls
/// short-circuit on the cached value until it expires.
///
/// Cache TTL is 6 hours. Open-Meteo's pollen forecast is published on
/// a slow cadence and the data doesn't move minute-to-minute; hammering
/// the API more often than this would just burn battery on radio time
/// without producing different numbers.
@MainActor
@Observable
final class PollenClient: NSObject {
  /// Most recent successful fetch. Nil before first load.
  var today: PollenSummary? = nil
  /// 7-day rolling history (today + 6 past). Populated by
  /// `refreshHistory()` on the same Open-Meteo call shape. Empty
  /// until that runs. Cached in UserDefaults separately from
  /// `today` so each can refresh on its own cadence.
  var history: [PollenDayPoint] = []
  var lastError: String? = nil
  /// Coarse status for view-side gating.
  var state: State = .idle

  enum State: Equatable {
    case idle
    case locating
    case fetching
    case ready
    case denied            // user denied location
    case failed(String)    // network / parse failure
  }

  private let locationManager: CLLocationManager
  private var pendingLocationContinuation: CheckedContinuation<CLLocation, Error>?

  // MARK: - Settings-facing accessors
  //
  // Thin read-only surface for the Settings → Integrations → Pollen
  // detail pane so it doesn't have to reach into UserDefaults or
  // CoreLocation internals.

  /// Wall-clock of the most recent successful Open-Meteo fetch. Nil
  /// until the first ever success. Read fresh from UserDefaults on
  /// each access so the Settings pane reflects refreshes that happen
  /// while it's not on screen.
  var lastFetchedAt: Date? {
    let savedAt = UserDefaults.standard.double(forKey: Self.cacheKey + ".savedAt")
    guard savedAt > 0 else { return nil }
    return Date(timeIntervalSince1970: savedAt)
  }

  /// Current Core Location auth state. Distinguishes "never asked"
  /// (where we should show a Grant button) from "denied" (where the
  /// user has to go into iOS Settings to fix it).
  var locationAuthorization: CLAuthorizationStatus {
    locationManager.authorizationStatus
  }

  /// Trigger the iOS permission prompt from a UI action. No-op once
  /// authorized; system silently ignores after denial. Pair with
  /// `refresh()` in the caller so the fetch fires once permission
  /// is granted (the auth-change callback also auto-fires refresh
  /// when state was `.locating`, but explicit-from-Settings has no
  /// such priming flag).
  func requestLocationPermission() {
    locationManager.requestWhenInUseAuthorization()
  }
  /// Backing storage for the disk-cached payload. Keyed by date so we
  /// don't accidentally show yesterday's reading as today's. Cleared
  /// whenever a fresh fetch overwrites it.
  private static let cacheKey = "septena.pollen.today.v1"
  private static let historyCacheKey = "septena.pollen.history.v1"
  private static let cacheTTL: TimeInterval = 6 * 3600

  override init() {
    self.locationManager = CLLocationManager()
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyKilometer  // pollen is per-city; precision is wasted battery
    paintFromCache()
  }

  /// Fetch the past 7 days (today + 6 past) and update `history`.
  /// Runs piggyback on whatever lat/lon `refresh()` already resolved
  /// — re-uses the auth gate. Cached for 6h in UserDefaults; the
  /// view's `.onAppear` calls this on every visit but the disk-cache
  /// short-circuit makes it free after the first fetch in the window.
  func refreshHistory(force: Bool = false) async {
    if !force, !history.isEmpty, isHistoryFresh() {
      return
    }
    let auth = locationManager.authorizationStatus
    // CLAuthorizationStatus.authorizedWhenInUse is iOS-only; macOS uses
    // .authorizedAlways as its sole "granted" value.
    #if os(macOS)
    guard auth == .authorizedAlways else {
      return
    }
    #else
    guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
      // Don't double-prompt — `refresh()` handles the permission UX,
      // history fetch silently waits its turn.
      return
    }
    #endif
    do {
      let location = try await requestCurrentLocation()
      let points = try await fetchOpenMeteoHistory(lat: location.coordinate.latitude,
                                                   lon: location.coordinate.longitude)
      history = points
      writeHistoryCache(points)
    } catch {
      // Surface only through the existing lastError pipe — history
      // failure doesn't override the headline-summary state.
      lastError = error.localizedDescription
    }
  }

  /// Pull pollen for the user's current location. No-op (returns the
  /// cached value) if the last successful fetch is fresher than the
  /// TTL. First call prompts for location permission; subsequent
  /// calls reuse it.
  func refresh(force: Bool = false) async {
    if !force, let cached = today, isCacheFresh() {
      state = .ready
      return
    }
    // Permission gate. If denied, we surface the state and bail —
    // the view can present a "Grant location" CTA.
    let auth = locationManager.authorizationStatus
    if auth == .denied || auth == .restricted {
      state = .denied
      return
    }
    if auth == .notDetermined {
      state = .locating
      locationManager.requestWhenInUseAuthorization()
      // The delegate will fire didChangeAuthorization next; the view
      // should re-call refresh() once state flips off .locating.
      return
    }

    state = .locating
    do {
      let location = try await requestCurrentLocation()
      state = .fetching
      let summary = try await fetchOpenMeteo(lat: location.coordinate.latitude,
                                             lon: location.coordinate.longitude)
      today = summary
      lastError = nil
      state = .ready
      writeCache(summary)
    } catch {
      lastError = error.localizedDescription
      state = .failed(error.localizedDescription)
    }
  }

  // MARK: - Location handshake

  /// Resolves to a one-shot location. Bridges CLLocationManager's
  /// callback-based API to async/await via a held continuation —
  /// only one pending request at a time, which is fine because the
  /// public surface (`refresh()`) is itself serialized on @MainActor.
  private func requestCurrentLocation() async throws -> CLLocation {
    try await withCheckedThrowingContinuation { continuation in
      pendingLocationContinuation = continuation
      locationManager.requestLocation()
    }
  }

  // MARK: - HTTP

  /// Single GET to Open-Meteo with all pollen species and today's
  /// forecast window. Aggregates the hourly arrays to per-species
  /// avg + max, computes the tree/weed roll-ups, derives the overall
  /// band, returns a `PollenSummary`.
  private func fetchOpenMeteo(lat: Double, lon: Double) async throws -> PollenSummary {
    let species = ["grass_pollen", "birch_pollen", "ragweed_pollen",
                   "olive_pollen", "mugwort_pollen", "alder_pollen"]
    var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
    components.queryItems = [
      URLQueryItem(name: "latitude",  value: String(lat)),
      URLQueryItem(name: "longitude", value: String(lon)),
      URLQueryItem(name: "hourly",    value: species.joined(separator: ",")),
      URLQueryItem(name: "timezone",  value: "auto"),
      URLQueryItem(name: "forecast_days", value: "1"),
    ]
    let url = components.url!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw NSError(domain: "PollenClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Open-Meteo returned a non-200 response"])
    }
    let payload = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    return rollUp(payload, species: species)
  }

  /// Same endpoint as `fetchOpenMeteo`, but with `past_days=6` so the
  /// response covers today + the previous 6 days in a single GET.
  /// We group by date prefix and aggregate per day, returning oldest
  /// first so the bar chart x-axis reads left → right naturally.
  private func fetchOpenMeteoHistory(lat: Double, lon: Double) async throws -> [PollenDayPoint] {
    let species = ["grass_pollen", "birch_pollen", "ragweed_pollen",
                   "olive_pollen", "mugwort_pollen", "alder_pollen"]
    var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
    components.queryItems = [
      URLQueryItem(name: "latitude",  value: String(lat)),
      URLQueryItem(name: "longitude", value: String(lon)),
      URLQueryItem(name: "hourly",    value: species.joined(separator: ",")),
      URLQueryItem(name: "timezone",  value: "auto"),
      URLQueryItem(name: "past_days", value: "6"),
      URLQueryItem(name: "forecast_days", value: "1"),
    ]
    let url = components.url!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw NSError(domain: "PollenClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Open-Meteo returned a non-200 response"])
    }
    let payload = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    return rollUpByDay(payload, species: species)
  }

  /// Group hourly samples by their date prefix and aggregate per day.
  /// Returns 7 points (today + 6 past), oldest first. Days with no
  /// samples are dropped rather than rendered as gaps.
  private func rollUpByDay(_ payload: OpenMeteoResponse, species: [String]) -> [PollenDayPoint] {
    // Group hourly indices by date prefix.
    var indicesByDate: [String: [Int]] = [:]
    for (idx, t) in payload.hourly.time.enumerated() {
      let date = String(t.prefix(10))
      indicesByDate[date, default: []].append(idx)
    }
    let sortedDates = indicesByDate.keys.sorted()

    func vals(_ key: String, indices: [Int]) -> [Double] {
      let arr = payload.hourly.values[key] ?? []
      return indices.compactMap { idx in idx < arr.count ? arr[idx] : nil }
    }
    func avg(_ key: String, indices: [Int]) -> Double? {
      let xs = vals(key, indices: indices); guard !xs.isEmpty else { return nil }
      return (xs.reduce(0, +) / Double(xs.count)).rounded(toPlaces: 1)
    }
    func mx(_ keys: [String], indices: [Int]) -> Double? {
      let xs = keys.flatMap { vals($0, indices: indices) }
      return xs.max()?.rounded(toPlaces: 1)
    }

    return sortedDates.map { date in
      let idxs = indicesByDate[date] ?? []
      let grass    = avg("grass_pollen",  indices: idxs)
      let grassMax = mx(["grass_pollen"], indices: idxs)
      let birch    = avg("birch_pollen",  indices: idxs)
      let birchMax = mx(["birch_pollen"], indices: idxs)
      let tree     = mx(["birch_pollen", "alder_pollen", "olive_pollen"], indices: idxs)
      let weed     = mx(["ragweed_pollen", "mugwort_pollen"], indices: idxs)
      return PollenDayPoint(date: date,
                            grass: grass, grassMax: grassMax,
                            birch: birch, birchMax: birchMax,
                            tree: tree,   treeMax: tree,
                            weed: weed,   weedMax: weed)
    }
  }

  /// Open-Meteo's `hourly.*` arrays are parallel — every species
  /// array has one entry per hour in `hourly.time`. For "today" we
  /// keep entries whose time prefix matches today's ISO date, then
  /// compute avg + max. Mirrors `_pollen_from_readings` in air.py.
  private func rollUp(_ payload: OpenMeteoResponse, species: [String]) -> PollenSummary {
    let today = ISO8601DateFormatter.yyyyMMdd.string(from: Date())
    let indices = payload.hourly.time.indices.filter {
      payload.hourly.time[$0].hasPrefix(today)
    }
    func vals(_ key: String) -> [Double] {
      let arr = payload.hourly.values[key] ?? []
      return indices.compactMap { idx in idx < arr.count ? arr[idx] : nil }
    }
    func avg(_ key: String) -> Double? {
      let xs = vals(key); guard !xs.isEmpty else { return nil }
      return (xs.reduce(0, +) / Double(xs.count)).rounded(toPlaces: 1)
    }
    func mx(_ keys: String...) -> Double? {
      let xs = keys.flatMap(vals); return xs.max()?.rounded(toPlaces: 1)
    }
    let grass    = avg("grass_pollen")
    let grassMax = mx("grass_pollen")
    let birch    = avg("birch_pollen")
    let birchMax = mx("birch_pollen")
    let tree     = mx("birch_pollen", "alder_pollen", "olive_pollen")
    let weed     = mx("ragweed_pollen", "mugwort_pollen")

    // Overall band = worst of grass / tree / weed. Matches air.py.
    let bands: [PollenBand] = [
      pollenBand(species: "grass", value: grassMax),
      pollenBand(species: "tree",  value: tree),
      pollenBand(species: "weed",  value: weed),
    ]
    let order: [PollenBand] = [.unknown, .low, .medium, .high, .veryHigh]
    let worst = bands.max { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } ?? .unknown

    return PollenSummary(
      date: today,
      grass: grass, grassMax: grassMax,
      birch: birch, birchMax: birchMax,
      tree: tree,   treeMax: tree,
      weed: weed,   weedMax: weed,
      overallBand: worst.rawValue
    )
  }

  // MARK: - Cache

  private func paintFromCache() {
    if let v = readCache() {
      today = v
      state = isCacheFresh() ? .ready : .idle
    }
    if let v = readHistoryCache() {
      history = v
    }
  }

  private func isCacheFresh() -> Bool {
    let savedAt = UserDefaults.standard.double(forKey: Self.cacheKey + ".savedAt")
    guard savedAt > 0 else { return false }
    return Date().timeIntervalSince1970 - savedAt < Self.cacheTTL
  }

  private func isHistoryFresh() -> Bool {
    let savedAt = UserDefaults.standard.double(forKey: Self.historyCacheKey + ".savedAt")
    guard savedAt > 0 else { return false }
    return Date().timeIntervalSince1970 - savedAt < Self.cacheTTL
  }

  private func writeCache(_ summary: PollenSummary) {
    guard let data = try? JSONEncoder().encode(summary) else { return }
    UserDefaults.standard.set(data, forKey: Self.cacheKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheKey + ".savedAt")
  }

  private func writeHistoryCache(_ points: [PollenDayPoint]) {
    guard let data = try? JSONEncoder().encode(points) else { return }
    UserDefaults.standard.set(data, forKey: Self.historyCacheKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.historyCacheKey + ".savedAt")
  }

  private func readCache() -> PollenSummary? {
    guard let data = UserDefaults.standard.data(forKey: Self.cacheKey) else { return nil }
    return try? JSONDecoder().decode(PollenSummary.self, from: data)
  }

  private func readHistoryCache() -> [PollenDayPoint]? {
    guard let data = UserDefaults.standard.data(forKey: Self.historyCacheKey) else { return nil }
    return try? JSONDecoder().decode([PollenDayPoint].self, from: data)
  }
}

// MARK: - CLLocationManagerDelegate

extension PollenClient: CLLocationManagerDelegate {
  nonisolated func locationManager(_ manager: CLLocationManager,
                                   didUpdateLocations locations: [CLLocation]) {
    Task { @MainActor in
      guard let loc = locations.last else { return }
      pendingLocationContinuation?.resume(returning: loc)
      pendingLocationContinuation = nil
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager,
                                   didFailWithError error: Error) {
    Task { @MainActor in
      pendingLocationContinuation?.resume(throwing: error)
      pendingLocationContinuation = nil
    }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Permission changes happen async after `requestWhenInUseAuthorization`.
    // Bounce back to MainActor to flip our published state and let the
    // view re-trigger refresh().
    Task { @MainActor in
      switch manager.authorizationStatus {
      case .denied, .restricted: state = .denied
      #if os(macOS)
      case .authorizedAlways:
        if state == .locating { await refresh() }
      #else
      case .authorizedWhenInUse, .authorizedAlways:
        if state == .locating { await refresh() }
      #endif
      default: break
      }
    }
  }
}

// MARK: - Open-Meteo wire format

private struct OpenMeteoResponse: Decodable {
  let hourly: Hourly

  struct Hourly: Decodable {
    let time: [String]
    let values: [String: [Double?]]

    private struct Key: CodingKey {
      var stringValue: String
      var intValue: Int? = nil
      init?(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      // "time" is the timestamp array; every other key is a pollen species.
      self.time = try c.decode([String].self, forKey: Key(stringValue: "time")!)
      var vals: [String: [Double?]] = [:]
      for key in c.allKeys where key.stringValue != "time" {
        // Open-Meteo encodes missing samples as nulls — decode as [Double?].
        vals[key.stringValue] = (try? c.decode([Double?].self, forKey: key)) ?? []
      }
      self.values = vals
    }
  }
}

// MARK: - Helpers

private extension Double {
  func rounded(toPlaces places: Int) -> Double {
    let m = pow(10.0, Double(places))
    return (self * m).rounded() / m
  }
}

private extension ISO8601DateFormatter {
  static let yyyyMMdd: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
}
