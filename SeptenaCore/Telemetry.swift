import Foundation

// Anonymous aggregate app telemetry via Septena's Cloudflare Worker.
//
// The task app sends one event: a change of the privacy level
// (`septena.privacy.telemetryLevel`, synced as `AppSettings.telemetryLevel`),
// so opt-out counts stay knowable. It carries the app version, build, platform
// and an app-local install id, of which the worker stores only an HMAC. A
// change to `.none` carries no install id, version or build. Disabled in DEBUG.

public actor TelemetryClient {
  public static let shared = TelemetryClient()

  /// Graded privacy levels, in increasing order of what leaves the device.
  /// Each step is a strict superset of the one before it, so the UI can present
  /// them as a single ladder and the gating below is a simple threshold check.
  /// Synced across devices via `AppSettings.telemetryLevel`; the raw values are
  /// the wire/storage contract, so don't rename them.
  public enum TelemetryLevel: String, CaseIterable, Sendable {
    /// Nothing leaves the device (bar the one operational level-change ping, so
    /// opt-out counts stay knowable).
    case none
    /// App launches + version/build/platform + the anonymous install hash. Lets
    /// Septena know the app is healthy and which versions are in use.
    case minimal
    /// Adds which sections you enable and use (feature-level, not screen-level),
    /// so Septena improves the areas people actually reach for. The default.
    case balanced
    /// Adds the individual screens you open, for the most detailed product view.
    case full

    /// Rank for threshold comparisons (`allows`). Higher = more is shared.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Short label for the level picker.
    public var title: String {
      switch self {
      case .none:     return "Off"
      case .minimal:  return "Minimal"
      case .balanced: return "Balanced"
      case .full:     return "Full"
      }
    }

    /// One-paragraph explanation shown under the picker.
    public var summary: String {
      switch self {
      case .none:
        return "No usage data leaves your device. \(AppDisplayName.current) learns nothing about how you use the app."
      case .minimal:
        return "Only that the app launched, its version, and an anonymous install ID, so \(AppDisplayName.current) knows the app is healthy and which versions are in use. No screens, no sections."
      case .balanced:
        return "Adds which sections you enable and open, so \(AppDisplayName.current) improves the areas people actually use. Never which individual screens you visit. Recommended."
      case .full:
        return "Adds the individual screens you open, for the most detailed picture of what to improve. Still no logged data, identity, or IP."
      }
    }
  }

  /// A record of one event actually transmitted from this device, kept on-device
  /// only (newest first, capped at `maxLogEntries`) so the Privacy pane can show
  /// the user exactly what has left their device. Holds only the event metadata
  /// that was already sent — nothing more.
  public struct SentRecord: Codable, Identifiable, Hashable, Sendable {
    public let date: Date
    public let event: String
    public let detail: String?
    public let level: String
    public var id: String { "\(date.timeIntervalSince1970)|\(event)|\(detail ?? "")" }
  }

  public static let maxLogEntries = 20

  /// Synced privacy level key. Mirrored device-locally from
  /// `AppSettings.telemetryLevel` (see `SettingsStore.reconcileTelemetryLevel`)
  /// so this actor can read it synchronously from `UserDefaults`.
  public static let levelKey = "septena.privacy.telemetryLevel"

  /// Legacy pre-levels on/off key. Still read by `currentLevel()` so an existing
  /// user's explicit choice is honored once, then superseded by `levelKey`.
  public static let consentKey = "septena.privacy.shareUsageData"

  private static let installIDKey = "septena.telemetry.installID"
  private static let pendingLevelKey = "septena.telemetry.pendingLevel"
  /// The worker's name for a level change, from before the graded levels.
  private static let levelChangedEvent = "analytics_consent_changed"
  private static let recentLogKey = "septena.telemetry.recentLog"

  private let session: URLSession

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.waitsForConnectivity = true
    cfg.timeoutIntervalForRequest = 15
    cfg.timeoutIntervalForResource = 60
    cfg.httpMaximumConnectionsPerHost = 2
    cfg.networkServiceType = .background
    self.session = URLSession(configuration: cfg)
  }

  /// Record a privacy-level change. Sent as operational state even when the new
  /// level is `.none` (one final ping), so aggregate opt-out counts stay
  /// knowable. The local mirror key is written at the edit site (SettingsStore);
  /// this just emits the change event.
  public func recordLevelChange(_ level: TelemetryLevel) async {
    #if DEBUG
    return
    #else
    UserDefaults.standard.set(level.rawValue, forKey: Self.pendingLevelKey)
    await flushPendingLevel()
    #endif
  }

  /// The device's currently-effective privacy level. Reads the synced mirror
  /// key first; falls back to honoring a pre-levels `shareUsageData` choice once
  /// (on → `.full`, off → `.none`); otherwise the `.balanced` default.
  public static func currentLevel() -> TelemetryLevel {
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: levelKey),
       let level = TelemetryLevel(rawValue: raw) {
      return level
    }
    if defaults.object(forKey: consentKey) != nil {
      return defaults.bool(forKey: consentKey) ? .full : .none
    }
    return .balanced
  }

  /// The most recent events actually transmitted from this device, newest first.
  /// On-device only; the Privacy pane shows these as ground truth for the list of
  /// what gets sent. Empty in DEBUG, since nothing is ever transmitted there.
  public func recentlySent() -> [SentRecord] { Self.loadLog() }

  private static func loadLog() -> [SentRecord] {
    guard let data = UserDefaults.standard.data(forKey: recentLogKey),
          let items = try? JSONDecoder().decode([SentRecord].self, from: data) else { return [] }
    return items
  }

  private func appendLog(_ record: SentRecord) {
    var items = Self.loadLog()
    items.insert(record, at: 0)
    if items.count > Self.maxLogEntries { items = Array(items.prefix(Self.maxLogEntries)) }
    if let data = try? JSONEncoder().encode(items) {
      UserDefaults.standard.set(data, forKey: Self.recentLogKey)
    }
  }

  private func flushPendingLevel() async {
    #if DEBUG
    return
    #else
    let defaults = UserDefaults.standard
    guard let raw = defaults.string(forKey: Self.pendingLevelKey),
          let level = TelemetryLevel(rawValue: raw) else { return }
    if await sendLevelChanged(level) {
      defaults.removeObject(forKey: Self.pendingLevelKey)
    }
    #endif
  }

  private func sendLevelChanged(_ level: TelemetryLevel) async -> Bool {
    #if DEBUG
    return false
    #else
    // The opt-out ping (turning the level to `.none`) is anonymized: it carries
    // only the event and the new level, never the install id, version, or build.
    // That keeps aggregate opt-out counts knowable without a final identifying
    // ping, and makes the Privacy pane's "nothing but the level change" claim
    // literally true.
    let anonymous = level == .none
    let payload = TelemetryPayload(
      installId: anonymous ? nil : Self.installID,
      event: Self.levelChangedEvent,
      // Back-compat: the Worker's existing `analyticsEnabled` boolean stays a
      // faithful "is any usage data flowing" flag, while `level` carries the new
      // graded detail for Workers that understand it.
      analyticsEnabled: level != .none,
      level: level.rawValue,
      version: anonymous ? nil : Self.version,
      build: anonymous ? nil : Self.build,
      platform: anonymous ? nil : Self.platform
    )
    guard let body = try? JSONEncoder().encode(payload) else { return false }

    var req = URLRequest(url: CommunityEndpoint.baseURL
      .appendingPathComponent("api")
      .appendingPathComponent("telemetry"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.httpBody = body

    do {
      let (_, response) = try await session.data(for: req)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(code) else { return false }
      appendLog(SentRecord(date: Date(),
                           event: "Privacy level changed",
                           detail: nil,
                           level: level.rawValue))
      return true
    } catch {
      return false
    }
    #endif
  }

  private static var installID: String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: installIDKey), !existing.isEmpty {
      return existing
    }
    let fresh = UUID().uuidString.lowercased()
    defaults.set(fresh, forKey: installIDKey)
    return fresh
  }

  private static var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
  }

  private static var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
  }

  private static var platform: String {
    #if os(macOS)
    return "macOS"
    #elseif os(iOS)
    #if targetEnvironment(macCatalyst)
    return "Catalyst"
    #else
    return "iOS"
    #endif
    #else
    return "Unknown"
    #endif
  }

  private static var userAgent: String {
    let os: String = {
      #if os(macOS)
      let v = ProcessInfo.processInfo.operatingSystemVersion
      return "macOS \(v.majorVersion).\(v.minorVersion)"
      #elseif os(iOS)
      let v = ProcessInfo.processInfo.operatingSystemVersion
      return "iOS \(v.majorVersion).\(v.minorVersion)"
      #else
      return "Unknown"
      #endif
    }()
    return "Septena/\(version) (\(os))"
  }

  private struct TelemetryPayload: Encodable {
    // Optional so the anonymized `.none` opt-out ping can omit identifying
    // fields entirely (synthesized Encodable drops nil keys from the JSON).
    let installId: String?
    let event: String
    let analyticsEnabled: Bool
    let level: String
    let version: String?
    let build: String?
    let platform: String?
  }
}
