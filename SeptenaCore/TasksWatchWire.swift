import Foundation

// The Apple Watch wire (docs/WATCH.md). Compiled into the iOS app (`Septask` target) and
// SeptaskWatch. Foundation only: the watch compiles no task model.
//
// Two channels carry it:
// - The backend: `GET /v1/tasks?view=` answers a `WatchTaskList` (the server
//   computes the view with the same rules as the MCP tools and the phone).
// - WatchConnectivity: the phone hands the watch its own backend session
//   (`WatchLink.Kind.session`) and pushes the current Today list as
//   application context, so the wrist draws real rows before any network.

/// One row as the watch draws it. Booleans arrive as `true` or absent.
struct WatchTask: Codable, Identifiable, Equatable, Hashable, Sendable {
  let id: String
  var title: String
  var notes: String?
  var scheduled: String?
  var deadline: String?
  var startTime: String?
  /// Display names, not ids.
  var area: String?
  var project: String?
  var inbox: Bool?
  var repeats: Bool?
  var starred: Bool?
  var daysOnToday: Int?
  var checklistCount: Int?
  var checklistDoneCount: Int?

  var isInbox: Bool { inbox == true }
  var isRepeating: Bool { repeats == true }
  /// Where the row lives, for the meta line: project beats area.
  var container: String? { project ?? area }

  /// `docs/TASK_DATES_SPEC.md` R3: the same split as
  /// `SeptenaTask.deadlineState`. Both states render red (R4, decision Q4).
  enum DueState: Equatable { case none, dueToday, overdue }
  func due(today: String) -> DueState {
    guard let deadline else { return .none }
    if deadline < today { return .overdue }
    if deadline == today { return .dueToday }
    return .none
  }
}

/// A view's rows. Same shape from the server and from the phone's snapshot.
struct WatchTaskList: Codable, Equatable, Sendable {
  enum View: String, Codable, Sendable { case today, inbox, upcoming, repeating, anytime, completed, starred, review }

  var view: View
  /// The day the list was computed for (YYYY-MM-DD, the user's zone).
  var today: String
  var total: Int
  var truncated: Bool?
  var tasks: [WatchTask]
  /// Not sent by the server; stamped by whoever stored the list.
  var fetchedAt: Date?

  static let rowCap = 150
  static let notesPrefix = 280

  static var sample: WatchTaskList {
    WatchTaskList(
      view: .today, today: "2026-11-22", total: 6, truncated: nil,
      tasks: [
        WatchTask(id: "s1", title: "Call the bank about the card", inbox: true),
        WatchTask(id: "s2", title: "Pay PT €250", deadline: "2026-11-20", area: "Home", daysOnToday: 3),
        WatchTask(id: "s3", title: "Envisioning profile photo", scheduled: "2026-11-22", area: "Envisioning"),
        WatchTask(id: "s4", title: "Water the plants", area: "Home", repeats: true),
        WatchTask(id: "s5", title: "Review the Septena watch build on device, end to end, before Monday",
                  notes: "Today, Upcoming, capture by voice, complications.",
                  deadline: "2026-11-22", project: "Septena", checklistCount: 4, checklistDoneCount: 1),
        WatchTask(id: "s6", title: "Return AirTags", startTime: "17:30", area: "Home"),
      ],
      fetchedAt: .now)
  }
}

/// One Area or Project row for the Watch's Lists screen (`GET /v1/tasks/lists`).
struct WatchArea: Codable, Identifiable, Equatable, Hashable, Sendable {
  let id: String
  var title: String
  var emoji: String?
  var count: Int
}

struct WatchProject: Codable, Identifiable, Equatable, Hashable, Sendable {
  let id: String
  var title: String
  var area: String?
  var count: Int
}

struct WatchListCounts: Codable, Equatable, Sendable {
  var today: Int
  var review: Int
  var upcoming: Int
  var repeating: Int
  var anytime: Int
  var starred: Int
}

struct WatchStructure: Codable, Equatable, Sendable {
  var counts: WatchListCounts?
  var areas: [WatchArea]
  var projects: [WatchProject]
}

/// The backend session the phone mints for its watch
/// (`POST /v1/auth/device`). Only the refresh token matters on the wrist: the
/// watch refreshes it at once and owns the rotation from then on.
struct WatchSessionHandoff: Codable, Equatable, Sendable {
  var refreshToken: String
  var userId: String
}

/// WatchConnectivity message keys, shared so the two ends can't drift.
enum WatchLink {
  static let kindKey = "septena.kind"
  static let payloadKey = "septena.payload"

  enum Kind: String {
    /// watch → phone: "I have no session, please mint one".
    case requestSession
    /// phone → watch: a `WatchSessionHandoff` in `payloadKey`.
    case session
    /// phone → watch: the phone signed out or switched accounts.
    case signedOut
    /// watch → phone: something changed on the wrist; refresh the snapshot.
    case changed
  }

  /// Application-context keys (phone → watch, latest wins).
  static let contextTodayKey = "septena.today"      // WatchTaskList JSON
  static let contextUserKey = "septena.userId"      // String, "" when signed out
  static let contextAccentHexKey = "septena.accentHex"       // "#RRGGBB" dark-mode accent
  static let contextAccentInkHexKey = "septena.accentInkHex" // "#RRGGBB" contrasting ink on accent
  /// The newest `WatchSessionHandoff` JSON. Application context is the one
  /// channel that is always delivered on activation, so the handoff rides it
  /// too (a queued `transferUserInfo` can take minutes). The watch adopts a
  /// given token once (`WatchLink.fingerprint`); after it rotates, the stale
  /// copy in the context is ignored.
  static let contextSessionKey = "septena.session"

  /// A short, non-secret id for a handoff, so the watch remembers which
  /// tokens it already adopted without storing them.
  static func fingerprint(_ handoff: WatchSessionHandoff) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in handoff.refreshToken.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return String(hash, radix: 36)
  }

  static func message(_ kind: Kind, payload: Data? = nil) -> [String: Any] {
    var m: [String: Any] = [kindKey: kind.rawValue]
    if let payload { m[payloadKey] = payload }
    return m
  }

  static func kind(of message: [String: Any]) -> Kind? {
    (message[kindKey] as? String).flatMap(Kind.init(rawValue:))
  }
}

extension JSONEncoder {
  static let watchWire: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }()
}

extension JSONDecoder {
  static let watchWire: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
