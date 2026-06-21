import Foundation
import Observation
import Security

// Readwise layer — direct, read-only client for the Readwise export API.
// Pulls the user's highlights and mirrors them into `QuoteStore` (origin
// "readwise") so they can feed the optional daily-message dashboard footer.
//
// Per-device by construction: each install authenticates with its own access
// token (Keychain, never synced, never sent to any Septena server). The
// imported QuoteEntity rows are DEVICE-LOCAL — deliberately NOT mirrored through
// CloudKit: a library can be many thousands of highlights, and pushing each as
// its own CKRecord to power a single daily-quote line flooded the sync engine
// and locked the app. Each device re-imports from its own token instead;
// re-syncing is idempotent (deterministic `readwise:<id>` ids).
//
// Readwise uses a simple `Authorization: Token <key>` header — no OAuth.
//   • GET /api/v2/auth/    → 204 when the token is valid (cheap validation).
//   • GET /api/v2/books/   → the user's sources with highlight counts (the
//     "Choose books" picker; lightweight — no highlight text downloaded).
//   • GET /api/v2/export/  → books with nested highlights, cursor-paginated;
//     `ids=<user_book_ids>` narrows it to the books the user selected.

/// One Readwise source for the "Choose books" picker. `id` is the Readwise
/// `user_book_id` — the same identifier the export endpoint filters on via `ids`
/// and the one persisted in `selectedBookIDs`.
public struct ReadwiseBook: Identifiable, Sendable, Hashable {
  public let id: Int
  public let title: String
  public let author: String
  public let category: String
  public let numHighlights: Int
}

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

  /// Which books feed the rotation. `nil` ⇒ import every book (the default, and
  /// new books you add to Readwise join automatically); a set ⇒ import only
  /// these `user_book_id`s; an empty set ⇒ import nothing. Device-local like the
  /// rest of the integration (persisted in UserDefaults, never synced). Stored
  /// (not computed over UserDefaults) so the Settings summary tracks it via
  /// @Observable. Write through `setSelectedBookIDs`.
  public private(set) var selectedBookIDs: Set<Int>?

  private let session: URLSession
  private let keychainAccount = "septena.readwise.token"
  private static let lastSyncDefaultsKey = "septena.readwise.lastSyncedAt"
  private static let selectionDefaultsKey = "septena.readwise.selectedBookIDs"

  private init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
    KeychainStore.makeSynchronizable(account: keychainAccount)  // upgrade pre-sync tokens
    self.token = Self.loadToken(account: keychainAccount)
    if let stored = UserDefaults.standard.array(forKey: Self.selectionDefaultsKey) as? [Int] {
      self.selectedBookIDs = Set(stored)
    }
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
    setSelectedBookIDs(nil)
  }

  /// Persist the book selection (see `selectedBookIDs`). `nil` clears the filter
  /// back to "all books"; a set narrows it. Caller re-syncs to apply.
  public func setSelectedBookIDs(_ ids: Set<Int>?) {
    selectedBookIDs = ids
    if let ids {
      UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.selectionDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: Self.selectionDefaultsKey)
    }
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

  /// Pull highlights via the export endpoint and reconcile them into QuoteStore.
  /// Honors `selectedBookIDs`: `nil` pulls every book, a set narrows the export
  /// to those `user_book_id`s (via the `ids` query param, so excluded books are
  /// never downloaded), and an empty set skips the network entirely. The
  /// reconcile prunes any previously-imported line whose book is no longer
  /// selected. Returns the number of highlights imported. Throws on auth /
  /// decode / network failure so the caller can surface it.
  @discardableResult
  public func sync() async throws -> Int {
    guard let token, !token.isEmpty else {
      throw SeptenaError.server(401, "No Readwise token configured.")
    }
    isSyncing = true
    lastSyncError = nil
    defer { isSyncing = false }

    let selection = selectedBookIDs
    var imported: [ImportedQuote] = []
    // An explicit empty selection means "import nothing" — skip the fetch and
    // let the reconcile below clear out whatever was imported before. A nil or
    // non-empty selection both hit the network (nil ⇒ all books).
    if selection.map({ !$0.isEmpty }) ?? true {
      let bookIDs = selection.map { Array($0).sorted() }
      var cursor: String? = nil
      repeat {
        let page = try await fetchExportPage(token: token, cursor: cursor, bookIDs: bookIDs)
        for book in page.results {
          // Author on the lead line, the book/article title beneath it (the
          // footer styles the second line). Fall back to whichever we have, and
          // skip the title when it merely repeats the author — Readwise reuses
          // the title as the author for some sources. "\n" is the lead/detail
          // separator the DailyMessage split reads. Strip nothing from the
          // highlight text — Readwise text is verbatim.
          let a = book.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let t = book.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let credit = (!a.isEmpty && !t.isEmpty && a != t) ? "\(a)\n\(t)" : (a.isEmpty ? t : a)
          for h in book.highlights {
            imported.append(ImportedQuote(sourceID: String(h.id),
                                          text: h.text,
                                          attribution: credit))
          }
        }
        cursor = page.nextPageCursor
      } while cursor != nil
    }

    QuoteStore.shared.reconcileReadwise(imported)
    lastSyncCount = QuoteStore.shared.all(origin: "readwise").count
    lastSyncedAt = .now
    return imported.count
  }

  /// List the user's Readwise sources (books, articles, …) for the picker. A
  /// light call — returns titles + highlight counts, no highlight text. Follows
  /// `next` until the library is exhausted. Throws like `sync`.
  public func fetchBooks() async throws -> [ReadwiseBook] {
    guard let token, !token.isEmpty else {
      throw SeptenaError.server(401, "No Readwise token configured.")
    }
    var out: [ReadwiseBook] = []
    var page = 1
    while true {
      var components = URLComponents(string: "https://readwise.io/api/v2/books/")!
      components.queryItems = [
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "page_size", value: "1000"),
      ]
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
      let list: BookList
      do { list = try JSONDecoder().decode(BookList.self, from: data) }
      catch {
        lastSyncError = String(describing: error)
        throw SeptenaError.decoding(String(describing: error))
      }
      out.append(contentsOf: list.results.map { $0.asBook })
      if list.next == nil { break }
      page += 1
    }
    // Most-highlighted first, then title — the order the picker wants.
    return out.sorted {
      if $0.numHighlights != $1.numHighlights { return $0.numHighlights > $1.numHighlights }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private func fetchExportPage(token: String, cursor: String?, bookIDs: [Int]?) async throws -> ExportPage {
    var components = URLComponents(string: "https://readwise.io/api/v2/export/")!
    var items: [URLQueryItem] = []
    if let cursor { items.append(URLQueryItem(name: "pageCursor", value: cursor)) }
    if let bookIDs, !bookIDs.isEmpty {
      items.append(URLQueryItem(name: "ids", value: bookIDs.map(String.init).joined(separator: ",")))
    }
    if !items.isEmpty { components.queryItems = items }
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

  /// One page of `GET /api/v2/books/` — the lightweight source listing the
  /// picker uses. `next` is a full URL (or null on the last page); we paginate
  /// by incrementing `page` so we don't have to parse it.
  private struct BookList: Decodable {
    let next: String?
    let results: [Row]

    struct Row: Decodable {
      let id: Int
      let title: String?
      let author: String?
      let category: String?
      let numHighlights: Int?

      enum CodingKeys: String, CodingKey {
        case id, title, author, category
        case numHighlights = "num_highlights"
      }

      var asBook: ReadwiseBook {
        ReadwiseBook(id: id,
                     title: (title?.isEmpty == false ? title! : "Untitled"),
                     author: author ?? "",
                     category: category ?? "",
                     numHighlights: numHighlights ?? 0)
      }
    }
  }

  // MARK: Keychain — static token, synced via iCloud Keychain (see `KeychainStore`)

  private static func storeToken(_ token: String, account: String) {
    KeychainStore.store(token, account: account, synchronizable: true)
  }

  private static func loadToken(account: String) -> String? {
    KeychainStore.load(account: account)
  }

  private static func deleteToken(account: String) {
    KeychainStore.delete(account: account)
  }
}
