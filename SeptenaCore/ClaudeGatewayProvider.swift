import AuthenticationServices
import Foundation
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - ClaudeGatewayProvider
//
// Keeps the Septena MCP gateway (mcp.septena.app) supplied with a live
// CloudKit Web Services token so Claude can read/write the user's data
// without the user re-authorizing on claude.ai every ~8 hours.
//
// Why a web sign-in and not a native mint: Apple issues no server-side
// refresh for ckWebAuthTokens, and the only *native* minting API
// (CKFetchWebAuthTokenOperation) returns a PUBLIC-database-only token —
// verified empirically: it gets ACCESS_DENIED on the private DB. The sole
// way to obtain a PRIVATE-scoped token is the idmsa web sign-in flow. So
// this app drives that flow itself via ASWebAuthenticationSession, captures
// the ckWebAuthToken from the gateway's HTTPS callback, and pushes it to
// the gateway. The gateway stores only this rotating credential — never
// user data — and serves it to the bound claude.ai bearer.
//
// The HTTPS callback (/auth/apple/callback) is captured in-app via
// ASWebAuthenticationSession's `.https` callback, which requires the app
// to claim mcp.septena.app through the Associated Domains `webcredentials`
// service (see Septena.entitlements + the gateway's AASA file).
//
// Refresh is foreground-only (ASWebAuthenticationSession needs UI). With a
// live Apple session it's quick; the system may still show a brief sheet.
@MainActor
@Observable
public final class ClaudeGatewayProvider {
  public static let shared = ClaudeGatewayProvider()

  private let logger = Logger(subsystem: "com.septena.cloud", category: "ClaudeGateway")

  // MARK: Configuration

  /// Gateway base + the host/path of the OAuth callback the API token
  /// redirects to after sign-in (must match the gateway's API token config).
  private static let gatewayBaseURL = "https://mcp.septena.app"
  private static let callbackHost = "mcp.septena.app"
  private static let callbackPath = "/auth/apple/callback"

  /// CloudKit Web Services API token. MUST match the gateway's
  /// `CK_API_TOKEN` secret — a ckWebAuthToken is scoped to the API token
  /// it was minted with — and that token's sign-in callback URL must be
  /// `https://mcp.septena.app/auth/apple/callback`.
  private static let webServicesAPIToken = "REDACTED-CLOUDKIT-API-TOKEN"

  /// CloudKit environment for the Web Services REST path. Must match the
  /// gateway's CK_ENVIRONMENT. NOTE: a TestFlight/App Store build talks to
  /// the *production* CloudKit environment — flip this (and the gateway)
  /// to "production" when shipping.
  private static let ckEnvironment = "development"

  /// Re-mint if the last successful push is older than this. Set close to
  /// the ~8h token lifetime so the (foreground, possibly-visible) sign-in
  /// sheet appears at most about once per token, not on every app open.
  private static let refreshInterval: TimeInterval = 7 * 60 * 60

  // MARK: Persisted state

  private static let enabledKey = "septena.claudeGateway.enabled"
  private static let lastRefreshKey = "septena.claudeGateway.lastRefreshAt"

  /// User has connected Claude. When false we never mint or push.
  public var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
  }

  // MARK: Observable status (for Settings UI)

  public private(set) var lastRefreshAt: Date?
  public private(set) var lastError: String?
  public private(set) var isRefreshing = false

  private let session: URLSession
  // Retained for the duration of a sign-in (ASWebAuthenticationSession and
  // its context provider must outlive the call).
  private var authSession: ASWebAuthenticationSession?
  private var anchorProvider: AuthAnchorProvider?

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

  /// Mint a fresh token and push it, unless we pushed recently. Safe to
  /// call on every foreground; skips when the last push is still inside
  /// token lifetime. `force` bypasses the interval (user tapped Connect).
  public func refreshIfNeeded(force: Bool = false) async {
    guard isEnabled else { return }
    if !force, let last = lastRefreshAt, Date().timeIntervalSince(last) < Self.refreshInterval {
      return
    }
    await refreshNow()
  }

  /// Mint a token and push it now. Updates observable status either way.
  public func refreshNow() async {
    guard isEnabled else { return }
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let token = try await mintWebAuthToken()
      try await push(ckWebAuthToken: token)
      lastError = nil
      lastRefreshAt = Date()
      UserDefaults.standard.set(lastRefreshAt!.timeIntervalSince1970, forKey: Self.lastRefreshKey)
      logger.info("Claude gateway token refreshed")
    } catch {
      lastError = error.localizedDescription
      logger.error("Claude gateway refresh failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Turn the integration on and immediately seed a token (user-initiated,
  /// so the sign-in sheet is expected here).
  public func connect() async {
    isEnabled = true
    await refreshNow()
  }

  /// Turn the integration off. Gateway tokens age out on its idle-cleanup
  /// cron; we simply stop refreshing.
  public func disconnect() {
    isEnabled = false
    lastError = nil
  }

  // MARK: Internals

  /// Drive the idmsa web sign-in and return a PRIVATE-scoped ckWebAuthToken.
  private func mintWebAuthToken() async throws -> String {
    let signInURL = try await fetchSignInRedirectURL()
    let callbackURL = try await runWebAuth(startURL: signInURL)
    guard
      let token = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "ckWebAuthToken" })?.value,
      !token.isEmpty
    else {
      throw GatewayError.server(0, "callback missing ckWebAuthToken")
    }
    return token
  }

  /// Ask CloudKit (unauthenticated) for the Apple sign-in URL. The token's
  /// configured callback brings us back to mcp.septena.app/auth/apple/callback.
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

  /// Present the sign-in and capture the HTTPS callback URL.
  private func runWebAuth(startURL: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
      let provider = AuthAnchorProvider()
      let webAuth = ASWebAuthenticationSession(
        url: startURL,
        callback: .https(host: Self.callbackHost, path: Self.callbackPath)
      ) { [weak self] callbackURL, error in
        self?.authSession = nil
        self?.anchorProvider = nil
        if let callbackURL {
          cont.resume(returning: callbackURL)
        } else {
          cont.resume(throwing: error ?? GatewayError.server(0, "sign-in cancelled"))
        }
      }
      webAuth.presentationContextProvider = provider
      // Reuse the system Apple session so renewals are quieter.
      webAuth.prefersEphemeralWebBrowserSession = false
      self.anchorProvider = provider
      self.authSession = webAuth
      // start() returns false when it can't present (e.g. the Associated
      // Domains capability isn't active, or no window). Surface that instead
      // of hanging the continuation forever.
      if !webAuth.start() {
        self.authSession = nil
        self.anchorProvider = nil
        cont.resume(throwing: GatewayError.server(
          0,
          "couldn’t start sign-in — check the Associated Domains capability is enabled for com.septena.cloud and the AASA is reachable"
        ))
      }
    }
  }

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

// Supplies the window ASWebAuthenticationSession presents over.
private final class AuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    return windows.first { $0.isKeyWindow }
      ?? scenes.first { $0.activationState == .foregroundActive }?.windows.first
      ?? windows.first
      ?? ASPresentationAnchor()
    #elseif os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
  }
}
