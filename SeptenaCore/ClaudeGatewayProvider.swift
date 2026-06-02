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
// CloudKit Web Services token so Claude can read/write the user's data.
//
// Apple gives no server-side refresh for ckWebAuthTokens, and the native
// mint (CKFetchWebAuthTokenOperation) is PUBLIC-DB only (ACCESS_DENIED on
// private — verified). The only path to a PRIVATE-scoped token is the
// idmsa web sign-in. We drive it with ASWebAuthenticationSession, which
// runs in the Safari context — so it gets Password AutoFill and the system
// Apple session (a live session = a quick Face ID / Continue, no typing).
// We capture the ckWebAuthToken from the gateway's HTTPS callback and push
// it; the gateway stores only this rotating credential, never user data.
//
// NOTE: we tried a raw-WKWebView "silent renewal" to drop the periodic
// consent tap — it regressed the UX (no autofill, no shared Apple session,
// unreliable offscreen execution) and was reverted. See LEARNINGS.md in
// the gateway repo. Refresh is foreground-only; the ~8h token means an
// Apple prompt at most ~once per token when you open the app.
//
// The HTTPS callback (.https) requires Associated Domains `webcredentials`
// for mcp.septena.app (Septena.entitlements + the gateway's AASA file).
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
  /// whose sign-in callback URL must be the one above.
  private static let webServicesAPIToken = "REDACTED-CLOUDKIT-API-TOKEN"

  /// CloudKit env for the REST path. Must match the gateway's CK_ENVIRONMENT.
  /// Flip to "production" (with the gateway) for TestFlight/App Store builds.
  private static let ckEnvironment = "development"

  /// Re-mint when the last push is older than this — comfortably under the
  /// ~8h token lifetime.
  private static let refreshInterval: TimeInterval = 7 * 60 * 60

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

  private let session: URLSession
  // Retained for the duration of a sign-in.
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

  /// Auto path (foreground), throttled. Re-mints the token if it's stale.
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

  public func connect() async {
    isEnabled = true
    await refreshNow()
  }

  public func disconnect() {
    isEnabled = false
    lastError = nil
  }

  // MARK: Internals

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

  /// Ask CloudKit (unauthenticated) for the Apple sign-in URL.
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
      // Reuse the system Apple session so a live session signs in quickly.
      webAuth.prefersEphemeralWebBrowserSession = false
      self.anchorProvider = provider
      self.authSession = webAuth
      // start() returns false when it can't present (e.g. Associated Domains
      // not active / no window). Surface that instead of hanging forever.
      if !webAuth.start() {
        self.authSession = nil
        self.anchorProvider = nil
        cont.resume(throwing: GatewayError.server(
          0,
          "couldn’t start sign-in — check Associated Domains for com.septena.cloud and that the AASA is reachable"
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
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    return window ?? ASPresentationAnchor()
    #elseif os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
  }
}
