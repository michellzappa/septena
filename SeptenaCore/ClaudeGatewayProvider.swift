import Foundation
import WebKit
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - ClaudeGatewayProvider
//
// Keeps the Septena MCP gateway (mcp.septena.app) supplied with a live
// CloudKit Web Services token so Claude can read/write the user's data.
//
// Apple gives no server-side refresh for ckWebAuthTokens, and the native
// mint (CKFetchWebAuthTokenOperation) is public-DB only. The sole way to a
// PRIVATE-scoped token is the idmsa web sign-in. So we drive that sign-in
// in an app-owned WKWebView whose cookie store PERSISTS — meaning after one
// interactive sign-in, every later re-mint is SILENT (the live Apple
// session cookie auto-authenticates and idmsa redirects straight to our
// callback). We capture the ckWebAuthToken from that redirect in the
// navigation delegate — no ASWebAuthenticationSession, no Associated
// Domains / AASA needed. The user only re-authenticates when the Apple
// session cookie itself lapses (weeks), not every ~8h.
//
// Still foreground-only: a WKWebView can't run while the app is suspended.
@MainActor
@Observable
public final class ClaudeGatewayProvider {
  public static let shared = ClaudeGatewayProvider()

  private let logger = Logger(subsystem: "com.septena.cloud", category: "ClaudeGateway")

  // MARK: Configuration
  private static let gatewayBaseURL = "https://mcp.septena.app"
  private static let callbackHost = "mcp.septena.app"
  private static let callbackPath = "/auth/apple/callback"

  /// CloudKit Web Services API token — MUST match the gateway's CK_API_TOKEN,
  /// and that token's sign-in callback URL must be the one above.
  private static let webServicesAPIToken = "REDACTED-CLOUDKIT-API-TOKEN"

  /// CloudKit env for the REST path. Must match the gateway's CK_ENVIRONMENT.
  /// Flip to "production" (with the gateway) for TestFlight/App Store builds.
  private static let ckEnvironment = "development"

  /// Re-mint when the last push is older than this. Silent now, so we can
  /// keep it comfortably under the ~8h token lifetime.
  private static let refreshInterval: TimeInterval = 6 * 60 * 60

  /// How long a silent (hidden) attempt waits before declaring the session
  /// lapsed and requiring interactive sign-in.
  private static let silentTimeout: TimeInterval = 12

  // MARK: Persisted state
  private static let enabledKey = "septena.claudeGateway.enabled"
  private static let lastRefreshKey = "septena.claudeGateway.lastRefreshAt"

  public var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
  }

  // MARK: Observable status (for Settings UI)
  public private(set) var lastRefreshAt: Date?
  public private(set) var lastError: String?
  public private(set) var isRefreshing = false
  /// Silent refresh failed (session lapsed) — Settings should offer an
  /// explicit "Reauthenticate". We never pop UI from the auto path.
  public private(set) var needsReauth = false

  /// Drives the interactive sign-in sheet. The SwiftUI layer presents
  /// `interactiveWebView` while `showingInteractiveAuth` is true.
  public private(set) var showingInteractiveAuth = false
  public private(set) var interactiveWebView: WKWebView?

  private let session: URLSession
  private var authContinuation: CheckedContinuation<URL, Error>?
  private var navDelegate: WebNavDelegate?
  private var hiddenWebView: WKWebView?
  private var timeoutTask: Task<Void, Never>?

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
    self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    let stamp = UserDefaults.standard.double(forKey: Self.lastRefreshKey)
    self.lastRefreshAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
  }

  // MARK: API

  /// Auto path (foreground). Silent only — never pops UI. On a lapsed
  /// session it sets `needsReauth` and the user reauthenticates explicitly.
  public func refreshIfNeeded(force: Bool = false) async {
    guard isEnabled else { return }
    if !force, let last = lastRefreshAt, Date().timeIntervalSince(last) < Self.refreshInterval {
      return
    }
    await refresh(interactiveAllowed: false)
  }

  /// User-initiated (Reauthenticate). If we already know the session lapsed,
  /// skip the silent attempt and go straight to the sheet.
  public func refreshNow() async {
    guard isEnabled else { return }
    await refresh(interactiveAllowed: true, skipSilent: needsReauth)
  }

  /// First connect — no session cookie yet, so present the sheet directly.
  public func connect() async {
    isEnabled = true
    await refresh(interactiveAllowed: true, skipSilent: true)
  }

  public func disconnect() {
    isEnabled = false
    lastError = nil
    needsReauth = false
  }

  /// Called by the sheet if the user dismisses sign-in without finishing.
  public func cancelInteractiveAuth() {
    failAuth(AuthError.cancelled)
  }

  // MARK: Refresh

  private func refresh(interactiveAllowed: Bool, skipSilent: Bool = false) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let token = try await mintWebAuthToken(interactiveAllowed: interactiveAllowed, skipSilent: skipSilent)
      try await push(ckWebAuthToken: token)
      lastError = nil
      needsReauth = false
      lastRefreshAt = Date()
      UserDefaults.standard.set(lastRefreshAt!.timeIntervalSince1970, forKey: Self.lastRefreshKey)
      logger.info("Claude gateway token refreshed (\(interactiveAllowed ? "interactive-ok" : "silent", privacy: .public))")
    } catch AuthError.needsInteractive {
      // Silent attempt on the auto path failed: surface, don't pop UI.
      needsReauth = true
      logger.info("Claude gateway needs reauthentication")
    } catch AuthError.cancelled {
      // User dismissed the sheet — leave state as-is.
    } catch {
      lastError = error.localizedDescription
      logger.error("Claude gateway refresh failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: Token minting (silent → interactive)

  private func mintWebAuthToken(interactiveAllowed: Bool, skipSilent: Bool) async throws -> String {
    let signInURL = try await fetchSignInRedirectURL()

    let callbackURL: URL
    if skipSilent && interactiveAllowed {
      // No live session expected — present the sheet directly.
      callbackURL = try await loadForCallback(signInURL, interactive: true, timeout: 300)
    } else {
      do {
        callbackURL = try await loadForCallback(signInURL, interactive: false, timeout: Self.silentTimeout)
      } catch AuthError.needsInteractive, AuthError.timeout {
        guard interactiveAllowed else { throw AuthError.needsInteractive }
        callbackURL = try await loadForCallback(signInURL, interactive: true, timeout: 300)
      }
    }

    guard
      let token = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "ckWebAuthToken" })?.value,
      !token.isEmpty
    else {
      throw GatewayError.server(0, "callback missing ckWebAuthToken")
    }
    return token
  }

  private func fetchSignInRedirectURL() async throws -> URL {
    var comps = URLComponents(
      string: "https://api.apple-cloudkit.com/database/1/\(SeptenaCloudKit.containerIdentifier)/\(Self.ckEnvironment)/private/users/current"
    )!
    comps.queryItems = [URLQueryItem(name: "ckAPIToken", value: Self.webServicesAPIToken)]
    var req = URLRequest(url: comps.url!)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, _) = try await session.data(for: req)
    struct Resp: Decodable { let redirectURL: String? }
    guard
      let parsed = try? JSONDecoder().decode(Resp.self, from: data),
      let str = parsed.redirectURL, let url = URL(string: str)
    else {
      throw GatewayError.server(0, "no redirectURL from users/current")
    }
    return url
  }

  /// Load `startURL` in a WKWebView (shared persistent cookie store) and
  /// resolve with the callback URL once idmsa redirects to it. Silent =
  /// offscreen hidden view + short timeout→needsInteractive. Interactive =
  /// presented via the sheet so the user can sign in.
  private func loadForCallback(_ startURL: URL, interactive: Bool, timeout: TimeInterval) async throws -> URL {
    guard authContinuation == nil else { throw AuthError.alreadyRunning }

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default() // persistent — the reason this is silent
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
    let delegate = WebNavDelegate(callbackHost: Self.callbackHost, callbackPath: Self.callbackPath) { [weak self] url in
      self?.finishAuth(url)
    }
    web.navigationDelegate = delegate
    self.navDelegate = delegate

    if interactive {
      interactiveWebView = web
      showingInteractiveAuth = true   // SwiftUI presents the sheet
    } else {
      attachHidden(web)               // offscreen so it executes
      hiddenWebView = web
    }

    return try await withCheckedThrowingContinuation { cont in
      self.authContinuation = cont
      web.load(URLRequest(url: startURL))
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        await MainActor.run {
          self?.failAuth(interactive ? AuthError.timeout : AuthError.needsInteractive)
        }
      }
    }
  }

  private func finishAuth(_ url: URL) {
    guard let cont = authContinuation else { return }
    authContinuation = nil
    teardownAuth()
    cont.resume(returning: url)
  }

  private func failAuth(_ error: Error) {
    guard let cont = authContinuation else { return }
    authContinuation = nil
    teardownAuth()
    cont.resume(throwing: error)
  }

  private func teardownAuth() {
    timeoutTask?.cancel(); timeoutTask = nil
    hiddenWebView?.removeFromSuperview()
    hiddenWebView = nil
    navDelegate = nil
    interactiveWebView = nil
    showingInteractiveAuth = false
  }

  private func attachHidden(_ web: WKWebView) {
    // A WKWebView must be in a window to actually run/redirect, so attach it
    // invisibly rather than truly detached.
    #if os(iOS)
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    web.alpha = 0.01
    web.isUserInteractionEnabled = false
    window?.addSubview(web)
    window?.sendSubviewToBack(web)
    #elseif os(macOS)
    if let content = (NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first)?.contentView {
      web.alphaValue = 0.01
      content.addSubview(web)
    }
    #endif
  }

  // MARK: Push

  private func push(ckWebAuthToken: String) async throws {
    guard let url = URL(string: "\(Self.gatewayBaseURL)/ingest/ck-token") else {
      throw GatewayError.badURL
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["ckWebAuthToken": ckWebAuthToken])
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...299).contains(code) else {
      let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
      throw GatewayError.server(code, String(detail))
    }
  }

  enum AuthError: Error { case needsInteractive, timeout, cancelled, alreadyRunning }

  enum GatewayError: LocalizedError {
    case badURL
    case server(Int, String)
    var errorDescription: String? {
      switch self {
      case .badURL: return "Invalid gateway URL"
      case let .server(code, detail): return "Gateway error \(code): \(detail)"
      }
    }
  }
}

// Watches navigation for the idmsa → callback redirect and hands the URL back.
private final class WebNavDelegate: NSObject, WKNavigationDelegate {
  private let callbackHost: String
  private let callbackPath: String
  private let onCallback: (URL) -> Void

  init(callbackHost: String, callbackPath: String, onCallback: @escaping (URL) -> Void) {
    self.callbackHost = callbackHost
    self.callbackPath = callbackPath
    self.onCallback = onCallback
  }

  func webView(_ webView: WKWebView,
               decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url,
       url.host == callbackHost, url.path == callbackPath {
      decisionHandler(.cancel)
      onCallback(url)
      return
    }
    decisionHandler(.allow)
  }
}
