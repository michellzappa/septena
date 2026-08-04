import Foundation

// Connection health — shared "is this integration actually working?" state.
//
// "Has a credential" is NOT "working". A token that expired, was revoked, or
// lost a scope still sits in the Keychain, so a credential-only status reads
// "Connected" in green while every fetch 401s — and because each surface
// paints from `ResponseCache` first, the section keeps showing frozen data
// with no hint that it stopped updating.
//
// So a provider records every fetch outcome here, persisted so the answer
// survives a cold launch, and the status surfaces read *this* rather than
// "do we hold a token". One type instead of a copy per provider: the display
// vocabulary and the staleness threshold have to agree across Settings rows
// and detail panes, and two copies drift.

/// Settings-facing summary of an integration's connection — one source of
/// truth for the Integrations overview row and the provider's detail pane so
/// they can never disagree.
public enum ConnectionDisplayState: Equatable, Sendable {
  case disconnected
  case connected
  case stale
  case needsAttention

  public var label: String {
    switch self {
    case .disconnected:   return "Connect"
    case .connected:      return "Connected"
    case .stale:          return "Not syncing"
    case .needsAttention: return "Needs attention"
    }
  }

  /// Drives the green/secondary tint — only a fresh, successful fetch earns
  /// the reassuring color.
  public var isHealthy: Bool { self == .connected }
}

/// Per-provider fetch outcome, persisted in `UserDefaults` under
/// `septena.<namespace>.lastFetchAt` / `septena.<namespace>.lastError`.
///
/// Held as a stored property on the provider (`private var health =
/// ConnectionHealth(namespace: "github")`), which is what makes `@Observable`
/// pick up the mutations: `recordSuccess()` / `recordFailure(_:)` write
/// through the property, so the forwarding accessors on the provider
/// invalidate the views reading them.
public struct ConnectionHealth: Sendable {
  /// A successful fetch older than this means the section is painting
  /// history, not today: the dashboard refetches on every launch, so a gap
  /// past a couple of days is a stall, not a quiet week.
  public static let defaultStaleAfter: TimeInterval = 48 * 3600

  /// Longest error text kept. Provider error bodies (GitHub's GraphQL
  /// especially) run long; the head is where "Bad credentials" / the missing
  /// scope actually appears.
  private static let maxErrorLength = 300

  private let lastFetchKey: String
  private let lastErrorKey: String
  private let staleAfter: TimeInterval

  /// When the last fetch succeeded. `nil` = never (on this device).
  public private(set) var lastFetchAt: Date?
  /// Why the last fetch failed, or `nil` if it succeeded. Shown verbatim in
  /// Settings — the provider's own error text is the diagnostic.
  public private(set) var lastError: String?

  /// Reads whatever a previous launch persisted, so the status is honest
  /// before the first fetch of this session lands.
  public init(namespace: String, staleAfter: TimeInterval = ConnectionHealth.defaultStaleAfter) {
    self.lastFetchKey = "septena.\(namespace).lastFetchAt"
    self.lastErrorKey = "septena.\(namespace).lastError"
    self.staleAfter = staleAfter
    let stamp = UserDefaults.standard.double(forKey: lastFetchKey)
    self.lastFetchAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    self.lastError = UserDefaults.standard.string(forKey: lastErrorKey)
  }

  public mutating func recordSuccess(at date: Date = Date()) {
    lastFetchAt = date
    lastError = nil
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastFetchKey)
    UserDefaults.standard.removeObject(forKey: lastErrorKey)
  }

  public mutating func recordFailure(_ error: Error) {
    recordFailure(message: error.localizedDescription)
  }

  public mutating func recordFailure(message: String) {
    let trimmed = String(message.prefix(Self.maxErrorLength))
    lastError = trimmed
    UserDefaults.standard.set(trimmed, forKey: lastErrorKey)
  }

  /// Clean slate. Called when credentials change or are removed — the old
  /// token's 401 must not keep the row red until the next fetch lands.
  public mutating func reset() {
    lastFetchAt = nil
    lastError = nil
    UserDefaults.standard.removeObject(forKey: lastFetchKey)
    UserDefaults.standard.removeObject(forKey: lastErrorKey)
  }

  /// `hasCredentials` is the provider's own notion of "configured" (a token,
  /// an OAuth pair, a grant) — without it there is nothing to be stale about.
  public func displayState(hasCredentials: Bool) -> ConnectionDisplayState {
    guard hasCredentials else { return .disconnected }
    if lastError != nil { return .needsAttention }
    guard let last = lastFetchAt else { return .stale }
    return Date().timeIntervalSince(last) > staleAfter ? .stale : .connected
  }
}
