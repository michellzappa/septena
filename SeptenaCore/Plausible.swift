import Foundation
import SwiftUI

// Anonymous aggregate screen-view analytics via Plausible
// (https://plausible.io). Sends one HTTP POST per screen view; nothing
// else leaves the device through this path.
//
// Payload: screen name (e.g. "nutrition"), app version, build, platform.
// Never sends anything the user has logged — no foods, no intake, no
// notes — and no cross-session identifier; Plausible's daily-
// rotated visitor hash means even Plausible can't link Monday to Tuesday.
//
// Disabled in DEBUG so dev builds never hit the dashboard, and gated by
// the `septena.privacy.shareUsageData` UserDefault (default on, visible
// toggle in Settings → Privacy).
//
// Reliability: URLSession's `waitsForConnectivity` holds requests when
// offline and flushes when the network returns — no custom queue needed
// for aggregate counts. Per-screen debounce stops `.onAppear` storms on
// nav pops from double-counting.

public actor PlausibleClient {
  public static let shared = PlausibleClient()

  // Replace with the actual configured Plausible site + endpoint when
  // the dashboard is set up. Kept as constants here so there's exactly
  // one place to change and no per-call-site duplication.
  private let endpoint = URL(string: "https://plausible.io/api/event")!
  private let siteDomain = "app.septena.app"

  /// UserDefaults key for the consent toggle. Default behaviour is on
  /// (see `isEnabled`), but the user can flip this in Settings → Privacy
  /// and it takes effect on the very next event.
  public static let consentKey = "septena.privacy.shareUsageData"

  private let session: URLSession
  private var lastSent: [String: Date] = [:]
  private let debounce: TimeInterval = 0.5

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.waitsForConnectivity = true
    cfg.timeoutIntervalForRequest = 15
    cfg.timeoutIntervalForResource = 60
    cfg.httpMaximumConnectionsPerHost = 2
    // Don't let analytics requests fight foreground UI traffic.
    cfg.networkServiceType = .background
    self.session = URLSession(configuration: cfg)
  }

  /// Fire-and-forget screen view. View code should never `await` this —
  /// wrap in a detached Task or call from `.task(id:)`.
  public func track(screen: String) async {
    #if DEBUG
    return
    #else
    guard Self.isEnabled() else { return }

    let now = Date()
    if let last = lastSent[screen], now.timeIntervalSince(last) < debounce { return }
    lastSent[screen] = now

    let props: [String: String] = [
      "version":  Self.version,
      "build":    Self.build,
      "platform": Self.platform,
    ]
    let payload: [String: Any] = [
      "name":   "pageview",
      "url":    "app://septena/\(screen)",
      "domain": siteDomain,
      "props":  props,
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.httpBody = body

    _ = try? await session.data(for: req)
    #endif
  }

  // MARK: - Helpers

  /// Reads the consent toggle. Default true on first launch — the
  /// Settings UI explains what's sent and the toggle is one tap away.
  public static func isEnabled() -> Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: consentKey) == nil { return true }
    return defaults.bool(forKey: consentKey)
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
}

// MARK: - SwiftUI

public extension View {
  /// Reports a screen view to Plausible when this view first appears with
  /// the given name, and again only if the name changes. Backed by
  /// `.task(id:)` so it's cancelled on disappear and never blocks UI;
  /// pair with the per-screen debounce inside `PlausibleClient` to absorb
  /// rapid re-appearances from nav-stack pops.
  func trackScreen(_ name: String) -> some View {
    task(id: name) { await PlausibleClient.shared.track(screen: name) }
  }
}
