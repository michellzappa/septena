import Foundation

// AttachmentFeed — the per-device fetch/cache layer behind an `AreaAttachment`.
// The pointer syncs via CloudKit (see [AreaAttachment.swift]); the payload
// fetched here NEVER does — it's cached in `ResponseCache` (UserDefaults blob)
// exactly like GitHubProvider/Oura. UI-free (SeptenaCore); the render lives in
// `AttachmentZone` (AreasProjectsView.swift).
//
// Three loaders share one small render model:
//   • git      → GitHub REST recent commits for owner/repo
//   • calendar → a subscribed ICS/webcal URL, parsed for upcoming VEVENTs
//   • feed     → an RSS or Atom URL, parsed for the latest entries

// MARK: - Render model

public struct AttachmentFeedItem: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var title: String
  /// Secondary line: a relative date, event time, or commit author.
  public var detail: String?
  /// Sort key when present. Not shown directly.
  public var date: Date?
  /// Calendar events only — drives the per-attachment all-day filter. Always
  /// false for git/feed.
  public var isAllDay: Bool

  public init(id: String, title: String, detail: String? = nil, date: Date? = nil, isAllDay: Bool = false) {
    self.id = id
    self.title = title
    self.detail = detail
    self.date = date
    self.isAllDay = isAllDay
  }
}

/// Result of a fetch: the snapshot (nil on failure) plus a short reason when
/// it failed, for a self-explaining error line.
public struct AttachmentFetchOutcome: Sendable {
  public let snapshot: AttachmentSnapshot?
  public let failureReason: String?
  public init(snapshot: AttachmentSnapshot?, failureReason: String?) {
    self.snapshot = snapshot
    self.failureReason = failureReason
  }
}

public struct AttachmentSnapshot: Codable, Hashable, Sendable {
  /// One-line roll-up shown next to the attachment chip ("3 upcoming").
  public var subtitle: String?
  public var items: [AttachmentFeedItem]
  public var fetchedAt: Date

  public init(subtitle: String?, items: [AttachmentFeedItem], fetchedAt: Date) {
    self.subtitle = subtitle
    self.items = items
    self.fetchedAt = fetchedAt
  }
}

// MARK: - Loader

public final class AttachmentFeedLoader {
  public static let shared = AttachmentFeedLoader()

  private let session: URLSession

  init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 15
    cfg.waitsForConnectivity = false
    self.session = URLSession(configuration: cfg)
  }

  /// Last cached snapshot for this attachment, if any — paint it immediately
  /// on appear before the network refresh resolves.
  public func cached(for attachment: AreaAttachment) -> AttachmentSnapshot? {
    guard let normalized = attachment.normalized else { return nil }
    return ResponseCache.load(AttachmentSnapshot.self, forKey: Self.cacheKey(normalized))
  }

  /// Fetch a fresh snapshot and cache it. Returns nil on failure (callers keep
  /// whatever `cached(for:)` gave them).
  @discardableResult
  public func load(_ attachment: AreaAttachment, maxItems: Int = 3) async -> AttachmentSnapshot? {
    await fetch(attachment, maxItems: maxItems).snapshot
  }

  /// Like `load`, but also returns a short human failure reason (e.g.
  /// "HTTP 410") so the UI can show *why* nothing rendered instead of a bare
  /// "couldn't load". `failureReason` is nil on success — even when the feed
  /// simply has no items.
  public func fetch(_ attachment: AreaAttachment, maxItems: Int = 3) async -> AttachmentFetchOutcome {
    guard let normalized = attachment.normalized else {
      return AttachmentFetchOutcome(snapshot: nil, failureReason: "empty URL")
    }
    SeptenaLog.info("[attachment] load kind=\(normalized.kind.rawValue) ref=\(Self.redact(normalized.ref))")
    do {
      let snapshot: AttachmentSnapshot?
      switch normalized.kind {
      case .git:      snapshot = try await loadGit(normalized.ref, maxItems: maxItems)
      case .calendar: snapshot = try await loadCalendar(normalized.ref, maxItems: maxItems)
      case .feed:     snapshot = try await loadFeed(normalized.ref, maxItems: maxItems)
      }
      if let snapshot {
        SeptenaLog.info("[attachment] load \(normalized.kind.rawValue) ok items=\(snapshot.items.count) subtitle=\(snapshot.subtitle ?? "-")")
        ResponseCache.save(snapshot, forKey: Self.cacheKey(normalized))
        return AttachmentFetchOutcome(snapshot: snapshot, failureReason: nil)
      }
      SeptenaLog.error("[attachment] load \(normalized.kind.rawValue) returned nil — unparseable ref / bad URL")
      return AttachmentFetchOutcome(snapshot: nil, failureReason: "invalid URL")
    } catch {
      SeptenaLog.error("[attachment] load \(normalized.kind.rawValue) FAILED", error)
      return AttachmentFetchOutcome(snapshot: nil, failureReason: Self.describe(error))
    }
  }

  /// A short, user-facing reason — HTTP status when we have one, else the
  /// system error text (offline, DNS, TLS).
  private static func describe(_ error: Error) -> String {
    if let e = error as? SeptenaError, case let .server(code, _) = e {
      return code > 0 ? "HTTP \(code)" : "no response"
    }
    return (error as NSError).localizedDescription
  }

  /// Host + path length only — never the private token in a TripIt/Google feed.
  private static func redact(_ ref: String) -> String {
    var raw = ref
    if raw.hasPrefix("webcal://") { raw = "https://" + raw.dropFirst("webcal://".count) }
    guard let url = URL(string: raw) else { return "<unparseable len=\(ref.count)>" }
    return "\(url.scheme ?? "?")://\(url.host ?? "?") path[\(url.path.count) chars]"
  }

  private static func cacheKey(_ attachment: AreaAttachment) -> String {
    "attachment.\(attachment.kind.rawValue).\(StableHash.hex(attachment.ref))"
  }

  // MARK: Git — recent commits

  private func loadGit(_ ref: String, maxItems: Int) async throws -> AttachmentSnapshot? {
    guard let repo = Self.normalizedRepo(ref),
          let url = URL(string: "https://api.github.com/repos/\(repo)/commits?per_page=\(max(1, maxItems))")
    else { return nil }

    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Septena", forHTTPHeaderField: "User-Agent")  // GitHub rejects UA-less calls
    // Reuse the section's PAT when present so private repos + higher rate
    // limits work; public repos still resolve unauthenticated.
    if let token = await GitHubProvider.shared.token, !token.isEmpty {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code < 400 else {
      throw SeptenaError.server(code, String(data: data, encoding: .utf8) ?? "")
    }
    let commits = try JSONDecoder().decode([GitHubCommitDTO].self, from: data)
    let items: [AttachmentFeedItem] = commits.prefix(maxItems).map { c in
      let date = c.commit.author?.date.flatMap { Self.iso8601.date(from: $0) }
      let author = c.commit.author?.name
      let when = date.map { Self.relative(from: $0) }
      let detail = [when, author].compactMap { $0 }.joined(separator: " · ")
      return AttachmentFeedItem(id: c.sha,
                                title: Self.firstLine(c.commit.message),
                                detail: detail.isEmpty ? nil : detail,
                                date: date)
    }
    let subtitle = items.isEmpty ? nil : "\(repo)"
    return AttachmentSnapshot(subtitle: subtitle, items: items, fetchedAt: Date())
  }

  static func normalizedRepo(_ ref: String) -> String? {
    var s = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://github.com/", "http://github.com/", "git@github.com:"] {
      if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
    }
    if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let parts = s.split(separator: "/")
    guard parts.count >= 2 else { return nil }
    return "\(parts[0])/\(parts[1])"
  }

  private struct GitHubCommitDTO: Decodable {
    let sha: String
    let commit: Commit
    struct Commit: Decodable {
      let message: String
      let author: Author?
      struct Author: Decodable { let name: String?; let date: String? }
    }
  }

  // MARK: Calendar — upcoming events from an ICS/webcal URL

  private func loadCalendar(_ ref: String, maxItems: Int) async throws -> AttachmentSnapshot? {
    // webcal:// is just https:// for fetching.
    var raw = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("webcal://") { raw = "https://" + raw.dropFirst("webcal://".count) }
    guard let url = URL(string: raw) else {
      SeptenaLog.error("[attachment] calendar URL(string:) failed — scheme/encoding (len=\(raw.count))")
      return nil
    }

    let (data, resp) = try await session.data(for: Self.request(url, accept: "text/calendar"))
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    SeptenaLog.info("[attachment] calendar GET host=\(url.host ?? "-") → HTTP \(code) bytes=\(data.count)")
    guard code < 400 else {
      throw SeptenaError.server(code, "Calendar fetch failed")
    }
    // Most feeds are UTF-8; a few legacy ones are Latin-1.
    guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
      throw SeptenaError.decoding("Calendar body not decodable")
    }

    let events = ICSParser.parse(text)
    let startOfToday = Calendar(identifier: .gregorian).startOfDay(for: Date())
    let upcoming = events
      .filter { ($0.end ?? $0.start) >= startOfToday }
      .sorted { $0.start < $1.start }
    SeptenaLog.info("[attachment] calendar parsed=\(events.count) upcoming=\(upcoming.count) (VEVENT blocks with a parseable DTSTART)")

    let items: [AttachmentFeedItem] = upcoming.prefix(maxItems).enumerated().map { idx, ev in
      AttachmentFeedItem(id: "\(idx)-\(ev.start.timeIntervalSince1970)",
                         title: ev.summary,
                         detail: Self.eventDetail(ev),
                         date: ev.start,
                         isAllDay: ev.isAllDay)
    }
    let subtitle = upcoming.isEmpty ? "No upcoming events" : "\(upcoming.count) upcoming"
    return AttachmentSnapshot(subtitle: subtitle, items: items, fetchedAt: Date())
  }

  private static func eventDetail(_ event: ICSEvent) -> String {
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .gregorian)
    if event.isAllDay {
      df.setLocalizedDateFormatFromTemplate("EEEMMMd")
      return df.string(from: event.start)
    }
    df.setLocalizedDateFormatFromTemplate("EEEMMMdjm")
    return df.string(from: event.start)
  }

  // MARK: Feed — latest entries from an RSS/Atom URL

  private func loadFeed(_ ref: String, maxItems: Int) async throws -> AttachmentSnapshot? {
    guard let url = URL(string: ref.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    let (data, resp) = try await session.data(for: Self.request(url, accept: "application/rss+xml, application/atom+xml, application/xml, text/xml"))
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code < 400 else { throw SeptenaError.server(code, "Feed fetch failed") }

    let entries = FeedParser.parse(data)
    let items: [AttachmentFeedItem] = entries.prefix(maxItems).enumerated().map { idx, e in
      AttachmentFeedItem(id: "\(idx)-\(e.title.hashValue)",
                         title: e.title,
                         detail: e.date.map { Self.relative(from: $0) },
                         date: e.date)
    }
    let subtitle = entries.isEmpty ? nil : (entries.first?.channelTitle ?? url.host)
    return AttachmentSnapshot(subtitle: subtitle, items: items, fetchedAt: Date())
  }

  // MARK: Shared helpers

  /// A GET with a real `User-Agent` + `Accept`. Many ICS/RSS hosts (TripIt,
  /// Google, iCloud published calendars) reject UA-less requests with 403/406,
  /// so this header is load-bearing, not cosmetic.
  private static func request(_ url: URL, accept: String) -> URLRequest {
    var req = URLRequest(url: url)
    req.setValue("Septena", forHTTPHeaderField: "User-Agent")
    req.setValue(accept, forHTTPHeaderField: "Accept")
    return req
  }

  private static func firstLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
  }

  static let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  static func relative(from date: Date) -> String {
    relativeFormatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Stable cache-key hash
//
// Swift's String.hashValue is per-process randomized, so it can't key a
// persistent cache. FNV-1a is deterministic across launches.
enum StableHash {
  static func hex(_ s: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100000001b3
    }
    return String(hash, radix: 16)
  }
}

// MARK: - ICS parsing (the common VEVENT subset)

struct ICSEvent {
  var summary: String
  var start: Date
  var end: Date?
  var isAllDay: Bool
}

enum ICSParser {
  static func parse(_ text: String) -> [ICSEvent] {
    // RFC5545 line folding: a CRLF followed by a space or tab continues the
    // previous line. Unfold before splitting.
    let unfolded = text
      .replacingOccurrences(of: "\r\n ", with: "")
      .replacingOccurrences(of: "\r\n\t", with: "")
      .replacingOccurrences(of: "\n ", with: "")
      .replacingOccurrences(of: "\n\t", with: "")

    var events: [ICSEvent] = []
    var inEvent = false
    var summary: String?
    var start: (date: Date, allDay: Bool)?
    var end: Date?

    for rawLine in unfolded.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      if line.hasPrefix("BEGIN:VEVENT") {
        inEvent = true; summary = nil; start = nil; end = nil
      } else if line.hasPrefix("END:VEVENT") {
        if let s = start {
          events.append(ICSEvent(summary: summary ?? "(untitled)",
                                 start: s.date, end: end, isAllDay: s.allDay))
        }
        inEvent = false
      } else if inEvent {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[line.startIndex..<colon])   // may carry ;params
        let value = String(line[line.index(after: colon)...])
        let name = key.split(separator: ";").first.map(String.init) ?? key
        switch name {
        case "SUMMARY": summary = unescape(value)
        case "DTSTART": start = parseDate(value, params: key)
        case "DTEND":   end = parseDate(value, params: key)?.date
        default: break
        }
      }
    }
    return events
  }

  /// Handles `20260115` (all-day), `20260115T090000Z` (UTC), and
  /// `;TZID=…:20260115T090000` (treated as UTC — approximate but fine for a
  /// glanceable "next up" list).
  private static func parseDate(_ value: String, params: String) -> (date: Date, allDay: Bool)? {
    let v = value.trimmingCharacters(in: .whitespaces)
    if params.uppercased().contains("VALUE=DATE") || (v.count == 8 && !v.contains("T")) {
      return dateOnly.date(from: v).map { ($0, true) }
    }
    if v.hasSuffix("Z") {
      return dateTimeUTC.date(from: String(v.dropLast())).map { ($0, false) }
    }
    return dateTimeUTC.date(from: v).map { ($0, false) }
  }

  private static func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\,", with: ",")
     .replacingOccurrences(of: "\\;", with: ";")
     .replacingOccurrences(of: "\\n", with: " ")
     .replacingOccurrences(of: "\\N", with: " ")
  }

  private static let dateOnly: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd"
    return f
  }()

  private static let dateTimeUTC: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss"
    return f
  }()
}

// MARK: - RSS / Atom parsing

struct FeedEntry {
  var title: String
  var date: Date?
  var channelTitle: String?
}

enum FeedParser {
  static func parse(_ data: Data) -> [FeedEntry] {
    let delegate = FeedXMLDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.entries
  }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
  var entries: [FeedEntry] = []

  private var text = ""
  private var inItem = false
  private var channelTitle: String?
  private var curTitle: String?
  private var curDate: Date?
  private var curLinkIsSelf = true

  func parser(_ parser: XMLParser, didStartElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?,
              attributes: [String: String] = [:]) {
    text = ""
    let name = elementName.lowercased()
    if name == "item" || name == "entry" {
      inItem = true; curTitle = nil; curDate = nil
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?) {
    let name = elementName.lowercased()
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "title":
      if inItem { if curTitle == nil { curTitle = value } }
      else if channelTitle == nil { channelTitle = value }
    case "pubdate", "published", "updated", "dc:date":
      if inItem, curDate == nil { curDate = Self.parseDate(value) }
    case "item", "entry":
      entries.append(FeedEntry(title: curTitle ?? "(untitled)",
                               date: curDate,
                               channelTitle: channelTitle))
      inItem = false
    default:
      break
    }
    text = ""
  }

  /// RSS uses RFC822 pubDates; Atom uses RFC3339. Try both.
  private static func parseDate(_ s: String) -> Date? {
    if let d = rfc822.date(from: s) { return d }
    return AttachmentFeedLoader.iso8601.date(from: s)
  }

  private static let rfc822: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return f
  }()
}
