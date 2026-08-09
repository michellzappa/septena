import Foundation
import SwiftUI

// Anonymous aggregate app telemetry via Septena's Cloudflare Worker.
//
// Payload: event name, low-cardinality screen name, app version, build,
// platform, the chosen privacy level, and an app-local install id. The Worker
// stores only an HMAC of the install id, which lets Septena count opt-outs
// without linking analytics to logged content or community profile identity.
//
// Disabled in DEBUG so dev builds never hit production telemetry. What is sent
// is gated by a graded privacy *level* (`septena.privacy.telemetryLevel`, synced
// across the user's devices via `AppSettings.telemetryLevel`), not a single
// on/off switch — see `TelemetryLevel`. Level changes are still sent as
// operational privacy state (even when the new level is `.none`) so opt-out
// counts remain knowable — but that one `.none` ping is anonymized: no install
// id, version, or build rides along, only the event and the chosen level.
//
// The human-readable "What is sent" list in Settings ▸ Privacy is rendered
// straight from `dataCatalog` below, and every transmitted event is recorded to
// an on-device `SentRecord` log the same pane can show — so the screen can never
// claim something the code doesn't actually do.

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
        return "No usage data leaves your device. Septena learns nothing about how you use the app."
      case .minimal:
        return "Only that the app launched, its version, and an anonymous install ID — so Septena knows the app is healthy and which versions are in use. No screens, no sections."
      case .balanced:
        return "Adds which sections you enable and open, so Septena improves the areas people actually use. Never which individual screens you visit. Recommended."
      case .full:
        return "Adds the individual screens you open, for the most detailed picture of what to improve. Still no logged data, identity, or IP."
      }
    }
  }

  /// One human-readable description of a thing analytics can send, paired with
  /// the lowest level at which it starts being sent. Single source of truth for
  /// the "What is sent" list in Settings ▸ Privacy — the UI renders straight from
  /// this, so the screen can't drift from the code. Keep in lockstep with the
  /// `Category` gates and the `send` payload below: every field that leaves the
  /// device must have a row here.
  public struct DataItem: Identifiable, Hashable, Sendable {
    public let text: String
    public let from: TelemetryLevel
    public var id: String { text }

    /// Whether this item is actually sent at the given level.
    public func isSent(at level: TelemetryLevel) -> Bool { level.rank >= from.rank }
  }

  public static let dataCatalog: [DataItem] = [
    .init(text: "Changes to this privacy level", from: .none),
    .init(text: "That the app launched", from: .minimal),
    .init(text: "App version, build, and platform (iOS or macOS)", from: .minimal),
    .init(text: "An anonymous app-install hash, used only for aggregate counts", from: .minimal),
    .init(text: "Which sections are enabled, opened, and turned on or off", from: .balanced),
    .init(text: "Which screens you open (e.g. \"Nutrition\", \"Sleep\")", from: .full),
  ]

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

  /// What a given event category needs at minimum to be sent.
  private enum Category {
    case appHealth   // app_open — needs `.minimal`
    case sectionUsage // section_* — needs `.balanced`
    case screenViews  // screen_view — needs `.full`

    var minimumLevel: TelemetryLevel {
      switch self {
      case .appHealth:    return .minimal
      case .sectionUsage: return .balanced
      case .screenViews:  return .full
      }
    }
  }

  /// Synced privacy level key. Mirrored device-locally from
  /// `AppSettings.telemetryLevel` (see `SettingsStore.reconcileTelemetryLevel`)
  /// so this actor can read it synchronously from `UserDefaults`.
  public static let levelKey = "septena.privacy.telemetryLevel"

  /// Legacy pre-levels on/off key. Still read by `currentLevel()` so an existing
  /// user's explicit choice is honored once, then superseded by `levelKey`.
  public static let consentKey = "septena.privacy.shareUsageData"

  private static let installIDKey = "septena.telemetry.installID"
  private static let pendingLevelKey = "septena.telemetry.pendingLevel"
  private static let sectionInventoryDateKey = "septena.telemetry.sectionInventoryDate"
  private static let appOpenSentKey = "septena.telemetry.appOpenSent"
  private static let recentLogKey = "septena.telemetry.recentLog"

  /// Minimum spacing between `app_open` events per install. `trackAppOpen` fires
  /// on every foreground; across several devices that is enough traffic to burn
  /// the Worker's daily KV write budget (each telemetry POST is rate-limited with
  /// KV writes). One `app_open` per hour per install is plenty for app-health.
  private static let appOpenInterval: TimeInterval = 3600

  private let session: URLSession
  private var lastSent: [String: Date] = [:]
  private let debounce: TimeInterval = 0.5

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.waitsForConnectivity = true
    cfg.timeoutIntervalForRequest = 15
    cfg.timeoutIntervalForResource = 60
    cfg.httpMaximumConnectionsPerHost = 2
    cfg.networkServiceType = .background
    self.session = URLSession(configuration: cfg)
  }

  public func trackAppOpen() async {
    await flushPendingLevel()
    guard Self.allows(.appHealth) else { return }

    // Throttle to at most one per hour per install. The in-memory `lastSent`
    // map is useless here (it resets on the cold launch that triggers the
    // foreground), so persist the timestamp in UserDefaults.
    let defaults = UserDefaults.standard
    let now = Date()
    let last = defaults.object(forKey: Self.appOpenSentKey) as? Date
    if let last, now.timeIntervalSince(last) < Self.appOpenInterval { return }

    if await send(event: .appOpen, screen: nil, section: nil, enabled: nil, sections: nil, level: Self.currentLevel()) {
      defaults.set(now, forKey: Self.appOpenSentKey)
    }
  }

  public func track(screen: String) async {
    await flushPendingLevel()
    guard Self.allows(.screenViews) else { return }

    let now = Date()
    let key = "screen:\(screen)"
    if let last = lastSent[key], now.timeIntervalSince(last) < debounce { return }
    lastSent[key] = now

    _ = await send(event: .screenView, screen: screen, section: nil, enabled: nil, sections: nil, level: Self.currentLevel())
  }

  public func trackSectionInventory(_ sections: [SectionConfig]) async {
    await flushPendingLevel()
    guard Self.allows(.sectionUsage) else { return }

    let today = String(Self.nowISODate.prefix(10))
    let defaults = UserDefaults.standard
    if defaults.string(forKey: Self.sectionInventoryDateKey) == today { return }

    let states = sections
      .map { SectionTelemetryState(section: $0.key, enabled: $0.isEnabled) }
      .sorted { $0.section < $1.section }
    guard !states.isEmpty else { return }

    if await send(event: .sectionInventory, screen: nil, section: nil, enabled: nil, sections: states, level: Self.currentLevel()) {
      defaults.set(today, forKey: Self.sectionInventoryDateKey)
    }
  }

  public func recordSectionEnabled(section: String, enabled: Bool) async {
    await flushPendingLevel()
    guard Self.allows(.sectionUsage) else { return }
    _ = await send(event: .sectionEnabledChanged,
                   screen: nil,
                   section: section,
                   enabled: enabled,
                   sections: nil,
                   level: Self.currentLevel())
  }

  public func recordSectionUsed(section: String) async {
    await flushPendingLevel()
    guard Self.allows(.sectionUsage) else { return }

    // Aggregate usage only needs coarse resolution — throttle repeated opens of
    // the same section within a session so drawer re-opens don't each cost a
    // telemetry POST (and its Worker-side KV writes).
    let now = Date()
    let key = "section-used:\(section)"
    if let last = lastSent[key], now.timeIntervalSince(last) < Self.appOpenInterval { return }
    lastSent[key] = now

    _ = await send(event: .sectionUsed,
                   screen: nil,
                   section: section,
                   enabled: nil,
                   sections: nil,
                   level: Self.currentLevel())
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

  /// Whether the current level permits sending the given event category.
  private static func allows(_ category: Category) -> Bool {
    currentLevel().rank >= category.minimumLevel.rank
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
    if await send(event: .levelChanged, screen: nil, section: nil, enabled: nil, sections: nil, level: level) {
      defaults.removeObject(forKey: Self.pendingLevelKey)
    }
    #endif
  }

  private func send(event: TelemetryEvent,
                    screen: String?,
                    section: String?,
                    enabled: Bool?,
                    sections: [SectionTelemetryState]?,
                    level: TelemetryLevel) async -> Bool {
    #if DEBUG
    return false
    #else
    // The opt-out ping (turning the level to `.none`) is anonymized: it carries
    // only the event and the new level, never the install id, version, or build.
    // That keeps aggregate opt-out counts knowable without a final identifying
    // ping, and makes the Privacy pane's "nothing but the level change" claim
    // literally true.
    let anonymous = (event == .levelChanged && level == .none)
    let payload = TelemetryPayload(
      installId: anonymous ? nil : Self.installID,
      event: event.rawValue,
      screen: screen,
      section: section,
      enabled: enabled,
      sections: sections,
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
                           event: event.label,
                           detail: screen ?? section ?? sections.map { "\($0.count) sections" },
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

  private static var nowISODate: String {
    ISO8601DateFormatter().string(from: Date())
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

  private enum TelemetryEvent: String {
    case appOpen = "app_open"
    case screenView = "screen_view"
    // Kept on the wire as "analytics_consent_changed" so the Worker's existing
    // event taxonomy doesn't change; the payload's `level` now carries the
    // chosen graded level rather than a bare on/off.
    case levelChanged = "analytics_consent_changed"
    case sectionInventory = "section_inventory"
    case sectionEnabledChanged = "section_enabled_changed"
    case sectionUsed = "section_used"

    /// Human-readable label for the on-device sent-log.
    var label: String {
      switch self {
      case .appOpen:              return "App launched"
      case .screenView:           return "Screen viewed"
      case .levelChanged:         return "Privacy level changed"
      case .sectionInventory:     return "Section list"
      case .sectionEnabledChanged: return "Section turned on/off"
      case .sectionUsed:          return "Section opened"
      }
    }
  }

  private struct SectionTelemetryState: Encodable {
    let section: String
    let enabled: Bool
  }

  private struct TelemetryPayload: Encodable {
    // Optional so the anonymized `.none` opt-out ping can omit identifying
    // fields entirely (synthesized Encodable drops nil keys from the JSON).
    let installId: String?
    let event: String
    let screen: String?
    let section: String?
    let enabled: Bool?
    let sections: [SectionTelemetryState]?
    let analyticsEnabled: Bool
    let level: String
    let version: String?
    let build: String?
    let platform: String?
  }
}

// MARK: - SwiftUI

public extension View {
  /// Reports a screen view when the view first appears with the given name,
  /// and again only if the name changes.
  func trackScreen(_ name: String) -> some View {
    task(id: name) { await TelemetryClient.shared.track(screen: name) }
  }

  /// Reports a section drawer open as aggregate section usage.
  func trackSectionUsage(_ section: String) -> some View {
    task(id: "section:\(section)") { await TelemetryClient.shared.recordSectionUsed(section: section) }
  }
}
