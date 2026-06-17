import Foundation
import Observation
import Security

// Readwise layer — direct, read-only client for the Readwise export API.
// Pulls the user's highlights and mirrors them into `QuoteStore` (origin
// "readwise") so they can feed the optional daily-message dashboard footer.
//
// Per-device by construction: each install authenticates with its own access
// token (Keychain, never synced, never sent to any Septena server). The
// imported QuoteEntity rows DO sync via CloudKit like all other data, so a
// second device shows the same lines even before its own token is entered —
// and re-syncing there is idempotent (deterministic `readwise:<id>` ids).
//
// Readwise uses a simple `Authorization: Token <key>` header — no OAuth.
//   • GET /api/v2/auth/    → 204 when the token is valid (cheap validation).
//   • GET /api/v2/export/  → books with nested highlights, cursor-paginated.

@MainActor
@Observable
public final class ReadwiseProvider {
  public static let shared = ReadwiseProvider()

  /// Mirror of the Keychain-stored token. Settings reads / writes via
  /// `setToken` / `clearToken`; everything else inspects `hasToken`.
  public private(set) var token: String?

  public var hasToken: Bool { token?.isEmpty == false }

  /// Live UI state for the Settings connect row.
  public private(set) var isSyncing = false
  /// Highlights present after the last successful sync (for "N highlights").
  public private(set) var lastSyncCount: Int?
  public private(set) var lastSyncError: String?

  /// Last successful sync instant, persisted for display across launches.
  public var lastSyncedAt: Date? {
    get { UserDefaults.standard.object(forKey: Self.lastSyncDefaultsKey) as? Date }
    set { UserDefaults.standard.set(newValue, forKey: Self.lastSyncDefaultsKey) }
  }

  private let session: URLSession
  private let keychainAccount = "septena.readwise.token"
  private static let lastSyncDefaultsKey = "septena.readwise.lastSyncedAt"

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
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
    lastSyncCount = nil
    lastSyncError = nil
    lastSyncedAt = nil
  }

  /// Validate the current token against `/auth/` (204 = good). Returns false
  /// on any non-204 / network error, never throws — Settings shows a soft
  /// "couldn't verify" rather than an alert.
  public func validateToken() async -> Bool {
    guard let token, !token.isEmpty,
          let url = URL(string: "https://readwise.io/api/v2/auth/") else { return false }
    var req = URLRequest(url: url)
    req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
    guard let (_, resp) = try? await session.data(for: req) else { return false }
    return (resp as? HTTPURLResponse)?.statusCode == 204
  }

  // MARK: Sync

  /// Pull every highlight via the export endpoint and upsert into QuoteStore.
  /// Returns the number of highlights imported. Throws on auth / decode /
  /// network failure so the caller can surface it.
  @discardableResult
  public func sync() async throws -> Int {
    guard let token, !token.isEmpty else {
      throw SeptenaError.server(401, "No Readwise token configured.")
    }
    isSyncing = true
    lastSyncError = nil
    defer { isSyncing = false }

    var imported: [ImportedQuote] = []
    var cursor: String? = nil
    repeat {
      let page = try await fetchExportPage(token: token, cursor: cursor)
      for book in page.results {
        // Prefer the author for attribution; fall back to the book title so a
        // line is never orphaned. Strip nothing — Readwise text is verbatim.
        let credit = (book.author?.isEmpty == false ? book.author : book.title) ?? ""
        for h in book.highlights {
          imported.append(ImportedQuote(sourceID: String(h.id),
                                        text: h.text,
                                        attribution: credit))
        }
      }
      cursor = page.nextPageCursor
    } while cursor != nil

    QuoteStore.shared.upsertReadwise(imported)
    lastSyncCount = QuoteStore.shared.all(origin: "readwise").count
    lastSyncedAt = .now
    return imported.count
  }

  private func fetchExportPage(token: String, cursor: String?) async throws -> ExportPage {
    var components = URLComponents(string: "https://readwise.io/api/v2/export/")!
    if let cursor { components.queryItems = [URLQueryItem(name: "pageCursor", value: cursor)] }
    guard let url = components.url else { throw SeptenaError.invalidURL }
    var req = URLRequest(url: url)
    req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code >= 400 {
      let message = String(data: data, encoding: .utf8) ?? ""
      lastSyncError = message
      throw SeptenaError.server(code, message)
    }
    do {
      return try JSONDecoder().decode(ExportPage.self, from: data)
    } catch {
      lastSyncError = String(describing: error)
      throw SeptenaError.decoding(String(describing: error))
    }
  }

  // MARK: Decoding

  private struct ExportPage: Decodable {
    let nextPageCursor: String?
    let results: [Book]

    enum CodingKeys: String, CodingKey {
      case nextPageCursor, results
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      results = try c.decode([Book].self, forKey: .results)
      // Readwise returns the cursor as a number (page index), but has been
      // seen as a string too — accept either and normalize to String, which
      // is what the `pageCursor` query param wants. Absent/null ⇒ last page.
      if let n = try? c.decodeIfPresent(Int.self, forKey: .nextPageCursor) {
        nextPageCursor = String(n)
      } else {
        nextPageCursor = try c.decodeIfPresent(String.self, forKey: .nextPageCursor)
      }
    }

    struct Book: Decodable {
      let title: String?
      let author: String?
      let highlights: [Highlight]
    }
    struct Highlight: Decodable {
      let id: Int
      let text: String
    }
  }

  // MARK: Keychain (same pattern as OuraProvider / GitHubProvider)

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
