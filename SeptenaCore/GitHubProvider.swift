import Foundation
import Observation
import Security

// GitHub layer — direct, read-only client for the GitHub GraphQL API.
// Mirrors the authenticated user's contribution calendar (the green
// "commit heatmap") into a lightweight Codable model the section caches
// via ResponseCache.
//
// Per-device by construction: each install authenticates with its own
// Personal Access Token (Keychain). Unlike Oura / Withings, NOTHING is
// mirrored to CloudKit — GitHub is itself the source of truth, and the
// contribution calendar is one cheap query to refetch, so there's no
// schema to deploy and no per-record sync. The token never leaves the
// device and is never sent to any Septena server.
//
// Two pieces in this file:
//   • GitHubDay / GitHubContributions — Codable value types (also the
//     ResponseCache payload and the shape the destination view consumes).
//   • GitHubProvider — Keychain-backed token + a single GraphQL fetch of
//     the contribution calendar.

// MARK: - Models

public struct GitHubDay: Codable, Hashable, Identifiable, Sendable {
  /// "yyyy-MM-dd" — also the identity, one entry per calendar day.
  public let date: String
  /// Raw contribution count GitHub reports for the day.
  public let count: Int
  /// 0…4 intensity, mapped from GitHub's `contributionLevel` enum so it
  /// drops straight into `ConsistencyHeatmap`'s `HeatmapDay.level`.
  public let level: Int

  public var id: String { date }

  public init(date: String, count: Int, level: Int) {
    self.date = date
    self.count = count
    self.level = level
  }
}

public struct GitHubContributions: Codable, Hashable, Sendable {
  /// The authenticated login the calendar belongs to (for display).
  public let login: String
  /// Total contributions across the fetched window.
  public let total: Int
  /// Daily series, oldest → newest.
  public let days: [GitHubDay]

  public init(login: String, total: Int, days: [GitHubDay]) {
    self.login = login
    self.total = total
    self.days = days
  }

  public static let empty = GitHubContributions(login: "", total: 0, days: [])
}

// MARK: - Provider

@MainActor
@Observable
public final class GitHubProvider {
  public static let shared = GitHubProvider()

  /// Mirror of the Keychain-stored token. Settings reads / writes via
  /// `setToken` / `clearToken`; everything else inspects `hasToken`.
  public private(set) var token: String?

  public var hasToken: Bool { token?.isEmpty == false }

  private let session: URLSession
  private let keychainAccount = "septena.github.pat"

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
    self.token = Self.loadToken(account: keychainAccount)
  }

  // MARK: Token

  public func setToken(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { clearToken(); return }
    Self.storeToken(trimmed, account: keychainAccount)
    token = trimmed
  }

  public func clearToken() {
    Self.deleteToken(account: keychainAccount)
    token = nil
  }

  // MARK: Fetch

  /// The authenticated user's contribution calendar for the trailing
  /// `days` window. GitHub caps a single `contributionsCollection` at one
  /// year, so `days` is clamped to 365. Hits api.github.com/graphql with
  /// the Keychain token and returns the merged daily series, oldest-first.
  ///
  /// Throws `SeptenaError.server`/`.decoding` on failure — including a
  /// `.server(401, …)` when no token is set, so callers that want a soft
  /// empty state should guard on `hasToken` first.
  public func fetchContributions(days: Int = 365) async throws -> GitHubContributions {
    guard let token = token, !token.isEmpty else {
      throw SeptenaError.server(401, "No GitHub token configured.")
    }
    let span = max(1, min(days, 365))
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let from = cal.date(byAdding: .day, value: -(span - 1), to: now) ?? now

    let query = """
    query($from: DateTime!, $to: DateTime!) {
      viewer {
        login
        contributionsCollection(from: $from, to: $to) {
          contributionCalendar {
            totalContributions
            weeks {
              contributionDays { date contributionCount contributionLevel }
            }
          }
        }
      }
    }
    """
    let variables: [String: String] = [
      "from": Self.iso8601.string(from: cal.startOfDay(for: from)),
      "to":   Self.iso8601.string(from: now),
    ]
    let body: [String: Any] = ["query": query, "variables": variables]

    guard let url = URL(string: "https://api.github.com/graphql") else {
      throw SeptenaError.invalidURL
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // GitHub rejects API requests that omit a User-Agent.
    req.setValue("Septena", forHTTPHeaderField: "User-Agent")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
    let decoded: GraphQLResponse
    do {
      decoded = try JSONDecoder().decode(GraphQLResponse.self, from: data)
    } catch {
      throw SeptenaError.decoding(String(describing: error))
    }
    // GraphQL returns HTTP 200 with an `errors` array on auth / scope
    // problems, so a clean status code isn't enough on its own.
    if let message = decoded.errors?.first?.message {
      throw SeptenaError.server(200, message)
    }
    guard let viewer = decoded.data?.viewer else {
      throw SeptenaError.decoding("Missing viewer in GitHub response.")
    }
    let calendar = viewer.contributionsCollection.contributionCalendar
    let series = calendar.weeks
      .flatMap { $0.contributionDays }
      .map { GitHubDay(date: $0.date,
                       count: $0.contributionCount,
                       level: Self.level(from: $0.contributionLevel)) }
      .sorted { $0.date < $1.date }
    return GitHubContributions(login: viewer.login,
                               total: calendar.totalContributions,
                               days: series)
  }

  /// Map GitHub's five-stop `ContributionLevel` enum onto the 0…4 ramp
  /// `ConsistencyHeatmap` expects.
  private static func level(from raw: String) -> Int {
    switch raw {
    case "FIRST_QUARTILE":  return 1
    case "SECOND_QUARTILE": return 2
    case "THIRD_QUARTILE":  return 3
    case "FOURTH_QUARTILE": return 4
    default:                return 0   // NONE / unknown
    }
  }

  // MARK: Decoding

  private struct GraphQLResponse: Decodable {
    let data: DataField?
    let errors: [GraphQLError]?

    struct GraphQLError: Decodable { let message: String }
    struct DataField: Decodable { let viewer: Viewer }
    struct Viewer: Decodable {
      let login: String
      let contributionsCollection: ContributionsCollection
    }
    struct ContributionsCollection: Decodable {
      let contributionCalendar: ContributionCalendar
    }
    struct ContributionCalendar: Decodable {
      let totalContributions: Int
      let weeks: [Week]
    }
    struct Week: Decodable { let contributionDays: [Day] }
    struct Day: Decodable {
      let date: String
      let contributionCount: Int
      let contributionLevel: String
    }
  }

  // MARK: Helpers

  private static let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  // MARK: Keychain (same pattern as OuraProvider)

  private static func storeToken(_ token: String, account: String) {
    let data = Data(token.utf8)
    let baseQuery: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = baseQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(addQuery as CFDictionary, nil)
    }
  }

  private static func loadToken(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
      kSecReturnData as String:  true,
      kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteToken(account: String) {
    let query: [String: Any] = [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
