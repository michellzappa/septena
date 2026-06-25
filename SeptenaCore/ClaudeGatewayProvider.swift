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

  private let logger = Log.claudeGateway

  // MARK: Configuration
  private static let gatewayBaseURL = "https://mcp.septena.app"
  private static let callbackHost = "mcp.septena.app"
  private static let callbackPath = "/auth/apple/callback"

  /// CloudKit Web Services API token — MUST match the gateway's CK_API_TOKEN,
  /// whose sign-in callback URL must be the one above. Injected at build time
  /// from `Config/Secrets.xcconfig` (gitignored) via the `CloudKitWebAPIToken`
  /// Info.plist key wired in `project.yml`; empty on a clone without secrets,
  /// which degrades the in-app reconnect to "not configured" instead of failing
  /// the build. See `Config/Secrets.example.xcconfig`.
  private static let webServicesAPIToken: String =
    (Bundle.main.object(forInfoDictionaryKey: "CloudKitWebAPIToken") as? String) ?? ""

  /// CloudKit env for the REST path. Must match the gateway's CK_ENVIRONMENT.
  /// Flip to "production" (with the gateway) for TestFlight/App Store builds.
  private static let ckEnvironment = "development"

  /// Re-mint when the last push is older than this — comfortably under the
  /// ~8h token lifetime. Still drives the proactive pre-expiry nudge
  /// (`nudgeFireDate`); the foreground `needsReauth` decision no longer relies
  /// on it as a guess — see `probeStoredToken`.
  private static let refreshInterval: TimeInterval = 7 * 60 * 60

  /// Below this age a freshly-minted token is trusted without a network probe —
  /// no point asking CloudKit about a token minted minutes ago on every
  /// foreground. Past it we close the loop and verify the real verdict.
  /// Conservatively under any observed CloudKit lifetime.
  private static let probeAfter: TimeInterval = 5 * 60 * 60

  // MARK: Persisted state
  private static let enabledKey = "septena.claudeGateway.enabled"
  private static let lastRefreshKey = "septena.claudeGateway.lastRefreshAt"
  /// Keychain account for the last token we minted+pushed, kept so we can ask
  /// CloudKit whether it's still valid (the closed-loop expiry check). A
  /// rotating, device-specific credential → device-local (not iCloud-synced),
  /// same posture as the Withings OAuth token.
  private static let tokenKeychainAccount = "septena.claudeGateway.ckToken"

  /// UserDefaults key for the "keep Claude connected" notification choice.
  /// Follows the `septena.notify.toggle.<id>` convention used by the section
  /// nudges, so it reads as one more per-nudge toggle even though Claude is
  /// an Account▸Integrations feature, not a dashboard section. Absent → on.
  public static let connectionNudgeKey = "septena.notify.toggle.claude.connection"

  /// Whether the pre-expiry reconnect nudge is enabled. Absent → on (opt-out).
  public static var connectionNudgeEnabled: Bool {
    UserDefaults.standard.object(forKey: connectionNudgeKey) as? Bool ?? true
  }

  /// The wall-clock moment the current token is presumed to go stale —
  /// `lastRefreshAt` + the ~7h refresh interval (under the ~8h CloudKit
  /// lifetime). `nil` if never authed. The scheduler arms a one-shot nudge
  /// for this instant so the user can re-mint *while Claude is still live*.
  public var nudgeFireDate: Date? {
    lastRefreshAt.map { $0.addingTimeInterval(Self.refreshInterval) }
  }

  public var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
  }

  // MARK: Observable status (for Settings UI)
  public private(set) var lastRefreshAt: Date?
  public private(set) var lastError: String?
  public private(set) var isRefreshing = false
  /// Token is (presumed) stale and needs an interactive re-mint. Set on
  /// foreground when the last refresh is older than the token lifetime —
  /// the UI surfaces a subtle "reconnect" cue rather than auto-popping the
  /// sign-in. Cleared on a successful refresh.
  public private(set) var needsReauth = false

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

  /// Auto path (foreground). NEVER presents UI — a sign-in sheet can only
  /// be shown from an explicit user action. Here we just decide whether the
  /// token is stale and set `needsReauth` so the homepage can show a subtle
  /// reconnect cue. `force` (a user action) does present and re-mint.
  public func refreshIfNeeded(force: Bool = false) async {
    guard isEnabled else { return }
    if force {
      await refreshNow()
      return
    }

    let age = lastRefreshAt.map { Date().timeIntervalSince($0) }

    // A comfortably-fresh token is trusted without a round-trip.
    if let age, age < Self.probeAfter {
      needsReauth = false
      logger.info("Claude gateway fresh on foreground (age \(Int(age), privacy: .public)s, no probe)")
      return
    }

    // Closed loop: past the floor, ask CloudKit whether the token we last
    // minted is *actually* still accepted, instead of flipping `needsReauth`
    // on a guessed interval. This kills both failure modes of the timer — a
    // false reconnect nag while the token is still live, and a dead token that
    // only surfaces when Claude fails mid-request. Never pops UI; just flags.
    switch await probeStoredToken() {
    case .some(true):
      needsReauth = false
      logger.info("Claude gateway token verified live (age \(age.map(Int.init) ?? -1, privacy: .public)s)")
      if let age { recordMeasurement(ageSec: age, valid: true) }
    case .some(false):
      needsReauth = true
      // The measured CloudKit token lifetime — the real number behind the 7h
      // guess. Persisted (below) so it survives for later calibration.
      logger.info("Claude gateway token expired after \(age.map(Int.init) ?? -1, privacy: .public)s → needsReauth")
      if let age { recordMeasurement(ageSec: age, valid: false) }
    case .none:
      // Inconclusive (offline, or no stored token from a pre-upgrade connect):
      // fall back to the original time heuristic so behaviour never regresses.
      needsReauth = (age ?? .greatestFiniteMagnitude) >= Self.refreshInterval
      logger.info("Claude gateway probe inconclusive → time heuristic, needsReauth=\(self.needsReauth, privacy: .public)")
    }
  }

  /// Closed-loop validity check: ask CloudKit (the same authority Claude's
  /// gateway depends on) whether the last token we minted + pushed is still
  /// accepted on the private DB. Returns `true` (valid), `false`
  /// (expired/rejected), or `nil` (couldn't tell — offline, or nothing stored
  /// yet). No token is ever logged.
  private func probeStoredToken() async -> Bool? {
    guard
      let token = KeychainStore.load(account: Self.tokenKeychainAccount),
      !token.isEmpty
    else { return nil }
    var comps = URLComponents(
      string: "https://api.apple-cloudkit.com/database/1/\(SeptenaCloudKit.containerIdentifier)/\(Self.ckEnvironment)/private/users/current"
    )!
    comps.queryItems = [
      URLQueryItem(name: "ckAPIToken", value: Self.webServicesAPIToken),
      URLQueryItem(name: "ckWebAuthToken", value: token),
    ]
    var req = URLRequest(url: comps.url!)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, resp) = try await session.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      // A live token resolves to a user record; an expired one gets a
      // redirectURL (Apple sign-in) or a 401 instead — same signal the gateway
      // reads server-side (CloudKitError.isAuthExpired).
      struct Resp: Decodable { let userRecordName: String?; let redirectURL: String? }
      let parsed = try? JSONDecoder().decode(Resp.self, from: data)
      if let name = parsed?.userRecordName, !name.isEmpty { return true }
      if code == 401 || parsed?.redirectURL != nil { return false }
      return nil // unexpected shape — don't guess
    } catch {
      return nil // transient/offline — let the caller fall back
    }
  }

  // MARK: Lifetime measurement (calibration)
  //
  // Each token cycle, track the largest age the probe still saw the token as
  // valid (`lastValid`) and the age at which it first saw it expired
  // (`expiredBy`). The true CloudKit lifetime lies in (lastValid, expiredBy].
  // Finalized samples are appended to `samplesKey` so they outlive the `.info`
  // logs — read them back in a few days with:
  //   defaults read com.septena.cloud.mac septena.claudeGateway.measure.samples
  // and calibrate `refreshInterval` / `probeAfter` to the observed minimum.
  private static let measureCycleKey = "septena.claudeGateway.measure.cycleRefreshAt"
  private static let measureValidKey = "septena.claudeGateway.measure.lastValidAge"
  private static let measureFinalizedKey = "septena.claudeGateway.measure.finalizedCycle"
  private static let measureSamplesKey = "septena.claudeGateway.measure.samples"

  private func recordMeasurement(ageSec: Double, valid: Bool) {
    guard let last = lastRefreshAt else { return }
    let d = UserDefaults.standard
    let cycle = last.timeIntervalSince1970
    // New token cycle → reset the running lower bound.
    if d.double(forKey: Self.measureCycleKey) != cycle {
      d.set(cycle, forKey: Self.measureCycleKey)
      d.set(0, forKey: Self.measureValidKey)
    }
    if valid {
      if ageSec > d.double(forKey: Self.measureValidKey) {
        d.set(ageSec, forKey: Self.measureValidKey)
      }
      return
    }
    // First expiry seen for this cycle → finalize one sample (dedup the
    // repeated foregrounds that keep seeing the same dead token).
    guard d.double(forKey: Self.measureFinalizedKey) != cycle else { return }
    d.set(cycle, forKey: Self.measureFinalizedKey)
    let lastValid = Int(d.double(forKey: Self.measureValidKey))
    let minted = ISO8601DateFormatter().string(from: last)
    var samples = d.stringArray(forKey: Self.measureSamplesKey) ?? []
    samples.append("minted \(minted) | lastValid \(lastValid)s | expiredBy \(Int(ageSec))s")
    d.set(Array(samples.suffix(12)), forKey: Self.measureSamplesKey)
  }

  /// Mint a token and push it now. Updates observable status either way.
  /// Returns `true` only on a successful re-mint, so callers (the homepage
  /// banner) can confirm the reconnect; a user-cancel returns `false` without
  /// recording an error.
  @discardableResult
  public func refreshNow() async -> Bool {
    guard isEnabled else { return false }
    guard !isRefreshing else { return false }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let token = try await mintWebAuthToken()
      try await push(ckWebAuthToken: token)
      // Keep the pushed token so we can later ask CloudKit whether it's still
      // valid (the closed-loop expiry check) — it's the exact credential the
      // gateway now holds, so its validity tracks Claude's connection.
      KeychainStore.store(token, account: Self.tokenKeychainAccount, synchronizable: false)
      lastError = nil
      needsReauth = false
      lastRefreshAt = Date()
      UserDefaults.standard.set(lastRefreshAt!.timeIntervalSince1970, forKey: Self.lastRefreshKey)
      // Re-arm the pre-expiry reconnect nudge off the fresh timestamp.
      NotificationCenter.default.post(name: .septenaClaudeGatewayChanged, object: nil)
      logger.info("Claude gateway token refreshed")
      return true
    } catch GatewayError.cancelled {
      // Not a failure — keep `needsReauth` so the cue stays, leave `lastError`
      // untouched so Settings doesn't show a stale "cancelled" error.
      logger.info("Claude gateway sign-in cancelled by user")
      return false
    } catch {
      lastError = error.localizedDescription
      logger.error("Claude gateway refresh failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  public func connect() async {
    isEnabled = true
    await refreshNow()
  }

  public func disconnect() {
    isEnabled = false
    lastError = nil
    needsReauth = false
    KeychainStore.delete(account: Self.tokenKeychainAccount)
    // Withdraw any pending reconnect nudge.
    NotificationCenter.default.post(name: .septenaClaudeGatewayChanged, object: nil)
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
        } else if let asError = error as? ASWebAuthenticationSessionError,
                  asError.code == .canceledLogin {
          // User tapped Cancel / swiped the sheet away — leave the reconnect
          // cue up, don't record it as an error.
          cont.resume(throwing: GatewayError.cancelled)
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
    logger.info("Claude gateway push /ingest/ck-token → HTTP \(code, privacy: .public)")
    guard (200...299).contains(code) else {
      let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
      throw GatewayError.server(code, String(detail))
    }
  }

  enum GatewayError: LocalizedError {
    case badURL
    /// The user dismissed the Apple sign-in sheet — not a failure.
    case cancelled
    case server(Int, String)
    var errorDescription: String? {
      switch self {
      case .badURL: return "Invalid gateway URL"
      case .cancelled: return "Sign-in cancelled"
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
