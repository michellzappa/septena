import Foundation

// AreaAttachment — the one read-only "context feed" an Area or Project can
// carry. The *pointer* (this value, JSON-encoded) syncs via CloudKit on the
// Area/Project record; the fetched payload (commits, events, feed items) stays
// per-device cached, exactly like the GitHub/Oura providers. See
// [AreaRecord.swift] / [ProjectRecord.swift] for where the JSON is stored (one
// reserved string slot each) and [AreasProjectsView.swift] for the intake UI.
//
// One per entity for now. The value is deliberately small and typed — a curated
// allowlist of `Kind`s, each with a first-party renderer — not a generic embed.
public struct AreaAttachment: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case git       // ref = "owner/repo"
    case calendar  // ref = webcal:// or https ICS/iCal URL
    case feed      // ref = RSS / Atom URL
  }

  /// How a calendar attachment treats all-day events. Ignored by git/feed.
  public enum AllDayFilter: String, Codable, Sendable, CaseIterable {
    case all   // show everything (default)
    case hide  // hide all-day events
    case only  // show only all-day events

    public var label: String {
      switch self {
      case .all:  return "All"
      case .hide: return "Hide all-day"
      case .only: return "Only all-day"
      }
    }
  }

  public var kind: Kind
  /// The subscription target: "owner/repo", a calendar URL, or a feed URL.
  public var ref: String
  /// Optional user label; falls back to a derived display name when nil.
  public var title: String?
  /// Calendar-only all-day handling. nil ⇒ `.all`. Optional so existing stored
  /// JSON (which predates this field) still decodes.
  public var allDay: AllDayFilter?

  public init(kind: Kind, ref: String, title: String? = nil, allDay: AllDayFilter? = nil) {
    self.kind = kind
    self.ref = ref
    self.title = (title?.isEmpty == true) ? nil : title
    self.allDay = allDay
  }

  /// The effective all-day policy (nil coerced to `.all`).
  public var allDayFilter: AllDayFilter { allDay ?? .all }

  /// A trimmed value, or nil when `ref` is empty — the canonical "no
  /// attachment" state so callers can treat empty refs as detach.
  public var normalized: AreaAttachment? {
    let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return AreaAttachment(kind: kind, ref: trimmed, title: title, allDay: allDay)
  }

  /// Best display name: explicit title, else a kind-appropriate derivation of
  /// the ref (repo name, calendar/feed host).
  public var displayName: String {
    if let title, !title.isEmpty { return title }
    switch kind {
    case .git:
      return ref  // "owner/repo" already reads well
    case .calendar, .feed:
      if let host = URL(string: ref)?.host { return host }
      return ref
    }
  }

  // MARK: - JSON round-trip (stored as a single CloudKit string)

  public func encodedString() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func decode(_ json: String?) -> AreaAttachment? {
    guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(AreaAttachment.self, from: data)
  }
}

public extension AreaAttachment.Kind {
  /// SF Symbol name (plain string — SeptenaCore stays UI-free). Concrete
  /// domain glyphs, never `sparkles`.
  var glyph: String {
    switch self {
    case .git:      return "chevron.left.forwardslash.chevron.right"
    case .calendar: return "calendar"
    case .feed:     return "dot.radiowaves.up.forward"
    }
  }

  var label: String {
    switch self {
    case .git:      return "Repo"
    case .calendar: return "Calendar"
    case .feed:     return "Feed"
    }
  }

  var refPlaceholder: String {
    switch self {
    case .git:      return "owner/repo"
    case .calendar: return "webcal:// or ICS URL"
    case .feed:     return "RSS / Atom URL"
    }
  }
}
