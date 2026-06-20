import Foundation
import SwiftUI

// Anonymous aggregate app telemetry via Septena's Cloudflare Worker.
//
// Payload: event name, low-cardinality screen name, app version, build,
// platform, analytics preference, and an app-local install id. The Worker
// stores only an HMAC of the install id, which lets Septena count opt-outs
// without linking analytics to logged content or community profile identity.
//
// Disabled in DEBUG so dev builds never hit production telemetry, and gated by
// `septena.privacy.shareUsageData` for usage events. Consent changes are still
// sent as operational privacy state so opt-out counts remain knowable.

public actor TelemetryClient {
  public static let shared = TelemetryClient()

  public static let consentKey = "septena.privacy.shareUsageData"

  private static let installIDKey = "septena.telemetry.installID"
  private static let pendingConsentKey = "septena.telemetry.pendingConsent"

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
    await flushPendingConsent()
    guard Self.isEnabled() else { return }
    _ = await send(event: .appOpen, screen: nil, analyticsEnabled: true)
  }

  public func track(screen: String) async {
    await flushPendingConsent()
    guard Self.isEnabled() else { return }

    let now = Date()
    let key = "screen:\(screen)"
    if let last = lastSent[key], now.timeIntervalSince(last) < debounce { return }
    lastSent[key] = now

    _ = await send(event: .screenView, screen: screen, analyticsEnabled: true)
  }

  public func recordConsent(enabled: Bool) async {
    #if DEBUG
    return
    #else
    UserDefaults.standard.set(enabled, forKey: Self.pendingConsentKey)
    await flushPendingConsent()
    #endif
  }

  public static func isEnabled() -> Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: consentKey) == nil { return true }
    return defaults.bool(forKey: consentKey)
  }

  private func flushPendingConsent() async {
    #if DEBUG
    return
    #else
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Self.pendingConsentKey) != nil else { return }
    let enabled = defaults.bool(forKey: Self.pendingConsentKey)
    if await send(event: .analyticsConsentChanged, screen: nil, analyticsEnabled: enabled) {
      defaults.removeObject(forKey: Self.pendingConsentKey)
    }
    #endif
  }

  private func send(event: TelemetryEvent, screen: String?, analyticsEnabled: Bool) async -> Bool {
    #if DEBUG
    return false
    #else
    let payload = TelemetryPayload(
      installId: Self.installID,
      event: event.rawValue,
      screen: screen,
      analyticsEnabled: analyticsEnabled,
      version: Self.version,
      build: Self.build,
      platform: Self.platform
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
      return (200..<300).contains(code)
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

  private enum TelemetryEvent: String {
    case appOpen = "app_open"
    case screenView = "screen_view"
    case analyticsConsentChanged = "analytics_consent_changed"
  }

  private struct TelemetryPayload: Encodable {
    let installId: String
    let event: String
    let screen: String?
    let analyticsEnabled: Bool
    let version: String
    let build: String
    let platform: String
  }
}

// MARK: - SwiftUI

public extension View {
  /// Reports a screen view when the view first appears with the given name,
  /// and again only if the name changes.
  func trackScreen(_ name: String) -> some View {
    task(id: name) { await TelemetryClient.shared.track(screen: name) }
  }
}
