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
// for mcp.septena.app (both app targets' entitlements + the gateway's AASA
// file).
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

  /// Conservative starting guess — used until `measure.samples` has enough
  /// data to calibrate. Re-mint when the last push is older than this. Still
  /// drives the proactive pre-expiry nudge (`nudgeFireDate`); the foreground
  /// `needsReauth` decision no longer relies on it as a guess — see
  /// `probeStoredToken`.
  private static let refreshIntervalFloor: TimeInterval = 7 * 60 * 60

  /// Conservative starting guess for the no-probe trust window — see
  /// `probeAfter` below for the calibrated value actually used.
  private static let probeAfterFloor: TimeInterval = 5 * 60 * 60

  /// Stay this far under the smallest confirmed-still-valid age we've ever
  /// measured, so one slow sample or a bit of clock skew never flips a token
  /// that's actually still live.
  private static let calibrationSafetyMargin: TimeInterval = 30 * 60

  /// Don't trust calibration off a single lucky sample.
  private static let calibrationMinSamples = 3

  /// How many of the most recent samples feed the floor. A rolling window
  /// (not all-time min) so growth keeps climbing as recent evidence
  /// accumulates instead of being permanently capped by one old, possibly
  /// anomalous early sample — while a genuinely tighter recent expiry still
  /// pulls the floor back down immediately.
  private static let calibrationWindow = 5

  /// Below this age a freshly-minted token is trusted without a network probe —
  /// no point asking CloudKit about a token minted minutes ago on every
  /// foreground. Past it we close the loop and verify the real verdict.
  /// Self-tunes upward from `probeAfterFloor` once `measure.samples` has
  /// enough data — see `calibratedValidFloor`.
  private static var probeAfter: TimeInterval {
    guard let floor = calibratedValidFloor() else { return probeAfterFloor }
    return max(probeAfterFloor, floor - calibrationSafetyMargin)
  }

  // MARK: Persisted state
  //
  // Septena and Septask are separate processes and bundle identifiers, but
  // they are equal peers for the hosted Claude connection. Keep the *account
  // state* in their shared App Group so opening either app can see that Claude
  // is connected and can re-mint the gateway token. The token itself remains
  // in each app's private Keychain: it is device-local and a force refresh in
  // either app simply replaces the gateway's current short-lived token.
  public static let connectionAppGroup = "group.com.septena.cloud"
  private static let connectionDefaults =
    UserDefaults(suiteName: connectionAppGroup) ?? .standard
  private static let enabledKey = "septena.claudeGateway.enabled"
  private static let lastRefreshKey = "septena.claudeGateway.lastRefreshAt"
  private static let nudgeOwnerKey = "septena.claudeGateway.nudgeOwner"
  private static let stateChangedDarwinName = "com.septena.claudeGateway.changed"
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
    didSet { Self.connectionDefaults.set(isEnabled, forKey: Self.enabledKey) }
  }

  // MARK: Observable status (for Settings UI)
  public private(set) var lastRefreshAt: Date?
  public private(set) var lastError: String?
  public private(set) var isRefreshing = false
  /// True only while `ASWebAuthenticationSession` is on-screen. AppLock
  /// reads this so the sheet's `.inactive` transition isn't mistaken for a
  /// real background (which would cover/re-lock mid-auth and can leave the
  /// session hung with `isRefreshing` stuck until a process restart).
  public private(set) var isPresentingWebAuth = false
  /// Token is (presumed) stale and needs an interactive re-mint. Set on
  /// foreground when the last refresh is older than the token lifetime —
  /// the UI surfaces a subtle "reconnect" cue rather than auto-popping the
  /// sign-in. Cleared on a successful refresh.
  public private(set) var needsReauth = false

  /// Settings-facing connection summary — one source of truth for the overview
  /// row and the gateway detail pane so they never disagree.
  public enum ConnectionDisplayState: Equatable {
    case disconnected
    case connected
    case reconnectNeeded
    case needsAttention

    public var label: String {
      switch self {
      case .disconnected: return "Connect"
      case .connected: return "Connected"
      case .reconnectNeeded: return "Reconnect needed"
      case .needsAttention: return "Needs attention"
      }
    }
  }

  public var connectionDisplayState: ConnectionDisplayState {
    guard isEnabled else { return .disconnected }
    if needsReauth { return .reconnectNeeded }
    if lastError != nil { return .needsAttention }
    return .connected
  }

  /// Cap on how long we wait for the Apple sign-in sheet to complete. The
  /// old WKWebView path had an explicit timeout; ASWebAuthenticationSession
  /// does not — if its completion never fires (bad anchor, AASA glitch,
  /// interrupted presentation), `isRefreshing` would stick true and every
  /// later tap would no-op until the process restarts.
  private static let webAuthTimeout: TimeInterval = 90

  private let session: URLSession
  // Retained for the duration of a sign-in.
  private var authSession: ASWebAuthenticationSession?
  private var anchorProvider: AuthAnchorProvider?
  private var webAuthTimeoutTask: Task<Void, Never>?

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)

    // One-release migration from Septena's bundle-local defaults. Do not seed
    // an absent value as `false`: if Septask launches first, that would mask a
    // real existing Septena connection before Septena gets to migrate it.
    if Self.connectionDefaults.object(forKey: Self.enabledKey) == nil,
       let legacyEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool {
      Self.connectionDefaults.set(legacyEnabled, forKey: Self.enabledKey)
      let legacyStamp = UserDefaults.standard.double(forKey: Self.lastRefreshKey)
      if legacyStamp > 0 {
        Self.connectionDefaults.set(legacyStamp, forKey: Self.lastRefreshKey)
      }
    }
    self.isEnabled = Self.connectionDefaults.bool(forKey: Self.enabledKey)
    let stamp = Self.connectionDefaults.double(forKey: Self.lastRefreshKey)
    self.lastRefreshAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
  }

  // MARK: API

  /// Adopt the shared connection state written by Septena or Septask. Callers
  /// do this on foreground before deciding whether the current app should
  /// surface or schedule a reconnect.
  public func reloadSharedState() {
    let sharedEnabled = Self.connectionDefaults.bool(forKey: Self.enabledKey)
    let stamp = Self.connectionDefaults.double(forKey: Self.lastRefreshKey)
    let sharedRefresh = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    if isEnabled != sharedEnabled { isEnabled = sharedEnabled }
    if lastRefreshAt != sharedRefresh { lastRefreshAt = sharedRefresh }
    if !sharedEnabled {
      needsReauth = false
      lastError = nil
    }
  }

  /// Make this foreground app responsible for the one pending reconnect
  /// reminder. The other app observes the Darwin notification and withdraws
  /// its duplicate while it is running.
  public static func claimReconnectNudge() {
    guard let bundleID = Bundle.main.bundleIdentifier,
          connectionDefaults.string(forKey: nudgeOwnerKey) != bundleID
    else { return }
    connectionDefaults.set(bundleID, forKey: nudgeOwnerKey)
    postStateChanged()
  }

  public static var currentAppOwnsReconnectNudge: Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return true }
    return connectionDefaults.string(forKey: nudgeOwnerKey) == bundleID
  }

  /// Auto path (foreground). NEVER presents UI — a sign-in sheet can only
  /// be shown from an explicit user action. Here we just decide whether the
  /// token is stale and set `needsReauth` so the homepage can show a subtle
  /// reconnect cue. `force` (a user action) does present and re-mint.
  public func refreshIfNeeded(force: Bool = false) async {
    reloadSharedState()
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

  public enum ConnectionTestResult { case valid, expired, inconclusive }

  /// On-demand version of the closed-loop check `refreshIfNeeded` runs on
  /// foreground — but always probes CloudKit regardless of `probeAfter`, so
  /// Settings can offer a "Test Connection" button that answers right now
  /// instead of waiting on the natural foreground cadence. Also feeds
  /// calibration exactly like the automatic path, so manual tests are a way
  /// to manufacture `measure.samples` on demand rather than waiting hours
  /// between organic ones.
  @discardableResult
  public func testConnection() async -> ConnectionTestResult {
    reloadSharedState()
    guard isEnabled, let age = lastRefreshAt.map({ Date().timeIntervalSince($0) }) else {
      return .inconclusive
    }
    switch await probeStoredToken() {
    case .some(true):
      needsReauth = false
      recordMeasurement(ageSec: age, valid: true)
      return .valid
    case .some(false):
      needsReauth = true
      recordMeasurement(ageSec: age, valid: false)
      return .expired
    case .none:
      return .inconclusive
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
  // valid (`lastValid`). A cycle finalizes into one `measure.samples` line
  // either when the probe catches a real expiry (also records `expiredBy`,
  // the tighter bound) OR — far more common in practice — when the NEXT
  // reconnect rolls the cycle over, so an ordinary "I tapped reconnect" still
  // teaches calibration `lastValid` for whatever age the old token was last
  // confirmed good at. Waiting only for observed expiry starves calibration:
  // most tokens get replaced by a manual reconnect long before the probe ever
  // catches them dead. Samples feed `calibratedValidFloor()` below so
  // `refreshInterval` / `probeAfter` self-tune upward as real data
  // accumulates — no hand-editing needed. To eyeball the raw samples:
  //   defaults read com.septena.cloud.mac septena.claudeGateway.measure.samples
  private static let measureCycleKey = "septena.claudeGateway.measure.cycleRefreshAt"
  private static let measureValidKey = "septena.claudeGateway.measure.lastValidAge"
  private static let measureFinalizedKey = "septena.claudeGateway.measure.finalizedCycle"
  private static let measureSamplesKey = "septena.claudeGateway.measure.samples"

  /// Re-mint when the last push is older than this. Self-tunes upward from
  /// `refreshIntervalFloor` once `measure.samples` has enough data.
  private static var refreshInterval: TimeInterval {
    guard let floor = calibratedValidFloor() else { return refreshIntervalFloor }
    return max(refreshIntervalFloor, floor - calibrationSafetyMargin)
  }

  /// The smallest "still valid" age confirmed by the closed-loop probe across
  /// the last `calibrationWindow` samples, parsed back out of the finalized
  /// `measure.samples` lines (each looks like "minted … | lastValid 27000s"
  /// or "… | lastValid 27000s | expiredBy 28800s"). This is a safe lower
  /// bound on the real CloudKit token lifetime — every sample is a case
  /// where the token was independently verified still accepted at that age.
  /// `nil` until `calibrationMinSamples` samples have accumulated, so a
  /// device fresh off the default keeps the conservative floor.
  private static func calibratedValidFloor() -> TimeInterval? {
    let samples = UserDefaults.standard.stringArray(forKey: measureSamplesKey) ?? []
    guard samples.count >= calibrationMinSamples else { return nil }
    let lastValids: [Double] = samples.suffix(calibrationWindow).compactMap { line in
      for part in line.split(separator: "|") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("lastValid "), trimmed.hasSuffix("s") {
          return Double(trimmed.dropFirst("lastValid ".count).dropLast())
        }
      }
      return nil
    }
    return lastValids.min()
  }

  private func recordMeasurement(ageSec: Double, valid: Bool) {
    guard let last = lastRefreshAt else { return }
    let d = UserDefaults.standard
    let cycle = last.timeIntervalSince1970
    let priorCycle = d.double(forKey: Self.measureCycleKey)
    // New token cycle (a reconnect just happened) → finalize whatever the
    // PREVIOUS cycle proved before resetting the running lower bound. This is
    // what lets the window grow from ordinary use, not just from watching a
    // token actually die: most reconnects happen because the user tapped
    // "reconnect" or reopened the app, never because the probe caught a real
    // expiry, so waiting only for `valid == false` starves calibration.
    if priorCycle != cycle {
      finalizeIfNeeded(cycle: priorCycle, d: d)
      d.set(cycle, forKey: Self.measureCycleKey)
      d.set(0, forKey: Self.measureValidKey)
    }
    if valid {
      if ageSec > d.double(forKey: Self.measureValidKey) {
        d.set(ageSec, forKey: Self.measureValidKey)
      }
      return
    }
    // An observed expiry is tighter evidence than a rollover guess — finalize
    // immediately with the real expiredBy instead of waiting for the next
    // reconnect to roll the cycle over.
    finalizeIfNeeded(cycle: cycle, d: d, expiredAt: ageSec)
  }

  /// Append one calibration sample for `cycle`, if it hasn't been finalized
  /// yet and we actually learned something (a confirmed-valid age, an
  /// observed expiry, or both). No-ops for `cycle == 0` (nothing tracked yet)
  /// and de-dupes repeated foregrounds that keep seeing the same dead token.
  private func finalizeIfNeeded(cycle: Double, d: UserDefaults, expiredAt: Double? = nil) {
    guard cycle > 0, d.double(forKey: Self.measureFinalizedKey) != cycle else { return }
    let lastValid = Int(d.double(forKey: Self.measureValidKey))
    guard lastValid > 0 || expiredAt != nil else { return }
    d.set(cycle, forKey: Self.measureFinalizedKey)
    let minted = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: cycle))
    var line = "minted \(minted) | lastValid \(lastValid)s"
    if let expiredAt { line += " | expiredBy \(Int(expiredAt))s" }
    var samples = d.stringArray(forKey: Self.measureSamplesKey) ?? []
    samples.append(line)
    d.set(Array(samples.suffix(12)), forKey: Self.measureSamplesKey)
  }

  /// Mint a token and push it now. Updates observable status either way.
  /// Returns `true` only on a successful re-mint, so callers (the homepage
  /// banner) can confirm the reconnect; a user-cancel returns `false` without
  /// recording an error.
  @discardableResult
  public func refreshNow() async -> Bool {
    reloadSharedState()
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
      Self.connectionDefaults.set(lastRefreshAt!.timeIntervalSince1970, forKey: Self.lastRefreshKey)
      // Re-arm the pre-expiry reconnect nudge off the fresh timestamp.
      Self.postStateChanged()
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
    reloadSharedState()
    isEnabled = true
    // Publish immediately as well as after a successful mint: if the user
    // dismisses the sign-in sheet, the sibling still knows this account has
    // opted into Claude and can offer its own reconnect path.
    Self.postStateChanged()
    await refreshNow()
  }

  public func disconnect() {
    reloadSharedState()
    isEnabled = false
    lastError = nil
    needsReauth = false
    KeychainStore.delete(account: Self.tokenKeychainAccount)
    // Withdraw any pending reconnect nudge.
    Self.postStateChanged()
  }

  private static func postStateChanged() {
    NotificationCenter.default.post(name: .septenaClaudeGatewayChanged, object: nil)
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(stateChangedDarwinName as CFString),
      nil, nil, true)
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
    guard !Self.webServicesAPIToken.isEmpty else {
      throw GatewayError.server(
        0,
        "CloudKit Web API token not configured — add CLOUDKIT_WEB_API_TOKEN to Config/Secrets.xcconfig and rebuild"
      )
    }
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
    // One-shot resume: the session completion, start()-failure, and the
    // watchdog timeout can all race; resuming a CheckedContinuation twice
    // traps.
    final class ResumeOnce: @unchecked Sendable {
      private var done = false
      private let lock = NSLock()
      func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
      }
    }
    let once = ResumeOnce()

    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
      let finish: (Result<URL, Error>) -> Void = { [weak self] result in
        once.run {
          self?.webAuthTimeoutTask?.cancel()
          self?.webAuthTimeoutTask = nil
          self?.authSession = nil
          self?.anchorProvider = nil
          self?.isPresentingWebAuth = false
          cont.resume(with: result)
        }
      }

      let provider = AuthAnchorProvider()
      let webAuth = ASWebAuthenticationSession(
        url: startURL,
        callback: .https(host: Self.callbackHost, path: Self.callbackPath)
      ) { callbackURL, error in
        if let callbackURL {
          finish(.success(callbackURL))
        } else if let asError = error as? ASWebAuthenticationSessionError,
                  asError.code == .canceledLogin {
          // User tapped Cancel / swiped the sheet away — leave the reconnect
          // cue up, don't record it as an error. (A watchdog cancel() also
          // lands here; we resume timeout *before* calling cancel(), so the
          // once-guard drops that secondary resume.)
          finish(.failure(GatewayError.cancelled))
        } else {
          finish(.failure(error ?? GatewayError.server(0, "sign-in cancelled")))
        }
      }
      webAuth.presentationContextProvider = provider
      // Reuse the system Apple session so a live session signs in quickly.
      webAuth.prefersEphemeralWebBrowserSession = false
      self.anchorProvider = provider
      self.authSession = webAuth
      self.isPresentingWebAuth = true

      // Watchdog: if the completion never fires, cancel and surface a
      // retryable error instead of leaving isRefreshing stuck forever.
      self.webAuthTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(Self.webAuthTimeout))
        guard !Task.isCancelled else { return }
        self?.logger.error("Claude gateway sign-in timed out after \(Int(Self.webAuthTimeout), privacy: .public)s")
        // Resume with timeout *before* cancel() so cancel's canceledLogin
        // completion hits the once-guard instead of winning the race as a
        // silent user-cancel (which would hide the failure from the cue).
        finish(.failure(GatewayError.server(0, "sign-in timed out — tap to try again")))
        self?.authSession?.cancel()
      }

      // start() returns false when it can't present (e.g. Associated Domains
      // not active / no window). Surface that instead of hanging forever.
      if !webAuth.start() {
        finish(.failure(GatewayError.server(
          0,
          "couldn’t start sign-in — check this app's Associated Domains and that the AASA is reachable"
        )))
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

// Supplies the window ASWebAuthenticationSession presents over. Prefer the
// foreground-active scene's key window; fall back to any scene window. Never
// return a detached `UIWindow()` — `start()` can return true against an
// unattached anchor and then never invoke its completion (the "tap spins
// forever until restart" failure mode). Prefer an empty `ASPresentationAnchor`
// in that rare case so `start()` fails cleanly instead.
private final class AuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let preferred = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    if let window = preferred?.windows.first(where: \.isKeyWindow)
      ?? preferred?.windows.first
      ?? scenes.flatMap(\.windows).first {
      return window
    }
    return ASPresentationAnchor()
    #elseif os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
  }
}
