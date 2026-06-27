import Foundation
import os

// App-wide logger + a couple of shared error / notification types that
// the rest of the codebase relies on. These used to live in
// `SeptenaClient.swift` alongside the FastAPI proxy; that file has
// been removed now that every backend interaction is either direct
// (OuraProvider / WithingsProvider) or CloudKit-mirrored, so this
// file is the new home for the bits that outlived it.

// MARK: - Change notification

extension Notification.Name {
  /// Posted after task mutations and CloudKit task-sync batches complete.
  static let septenaTasksChanged = Notification.Name("septena.tasksChanged")
  /// Posted after area / project structure changes and CloudKit batches
  /// that update those records. Lets task-centric views avoid reloading
  /// when only navigation structure changed.
  static let septenaStructureChanged = Notification.Name("septena.structureChanged")
  /// Generic mutation broadcast — fires after any non-task mutation (habits,
  /// supplements, chores, gut, nutrition, intake, groceries).
  /// Destinations that show those sections subscribe to refresh themselves
  /// without each call site wiring its own reload.
  ///
  /// Posts come in two shapes (see `DataChange`):
  ///   • scoped — userInfo carries the section keys that actually changed,
  ///     so listeners showing unrelated sections skip their reload;
  ///   • unscoped — no userInfo; "anything may have changed". Reserved for
  ///     CloudKit batch arrival, section seeding, and settings-level changes.
  static let septenaDataChanged = Notification.Name("septena.dataChanged")
  /// Posted by the macOS menu bar's "New To-Do" item. ContentView
  /// listens and starts an inline draft on Inbox — same flow as ⌘N.
  static let septenaOpenQuickAdd = Notification.Name("septena.openQuickAdd")
  /// Posted whenever the Claude gateway's token state changes (refreshed,
  /// connected, disconnected). The notification scheduler re-arms the
  /// pre-expiry reconnect nudge off the new `lastRefreshAt`.
  static let septenaClaudeGatewayChanged = Notification.Name("septena.claudeGatewayChanged")
}

// MARK: - Scoped data changes

/// Section scoping for `.septenaDataChanged`. A mutator posts with the
/// `SectionManifest` key(s) of the data it touched ("caffeine", "nutrition",
/// …; plus the non-section scopes "coach" and "milestones"), and listeners
/// that only show one section check `affectsSection` before reloading. This
/// is what keeps a single logged supplement from refetching every dashboard
/// tile, destination view, and open sheet in the app.
///
/// Unscoped posts (plain `NotificationCenter.post`, no userInfo) still mean
/// "anything may have changed" and pass every listener's filter — CloudKit
/// batch arrival and settings-level changes stay on that path.
enum DataChange {
  static let sectionsKey = "septena.changedSections"

  /// Post `.septenaDataChanged` scoped to the given section keys.
  static func post(_ sections: String...) {
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil,
                                    userInfo: [sectionsKey: Set(sections)])
  }
}

extension Notification {
  /// Section keys this `.septenaDataChanged` touched; nil for an unscoped
  /// post (treat as "everything changed").
  var changedSections: Set<String>? {
    userInfo?[DataChange.sectionsKey] as? Set<String>
  }

  /// True when the post came from an inbound CloudKit batch (`applyDidFinishBatch`
  /// posts unscoped). Scoped local mutator writes carry `changedSections`; only
  /// remote arrivals are unscoped. Listeners that keep session-local UI state
  /// (settle beats, acted-row sets) should do a full mirror reload on this path
  /// only — not on scoped local posts.
  var isCloudKitBatch: Bool { changedSections == nil }

  /// Whether a listener showing `sections` should react. True when either
  /// side is unscoped (nil) or the two sets intersect.
  func affectsAnySection(of sections: Set<String>?) -> Bool {
    guard let changed = changedSections, let sections else { return true }
    return !changed.isDisjoint(with: sections)
  }

  func affectsSection(_ key: String) -> Bool { affectsAnySection(of: [key]) }
}

// MARK: - Logger

/// Single source of truth for unified logging. Everything in the app logs
/// under the one `subsystem` so the console can be filtered to just Septena
/// (Xcode console filter / Console.app: filter `subsystem` == this string),
/// cutting through Apple's framework noise (`nw_path_necp_*`, CoreData, etc.).
///
/// Use a pre-defined category logger (`Log.cloudKit.error(…)`) or vend an
/// ad-hoc one with `Log.category("Foo")`. `os.Logger` is essentially free at
/// call sites — `.debug`/`.info` aren't persisted in Release, `.error`/`.fault`
/// survive to device logs — so no manual DEBUG gating is needed.
enum Log {
  /// The one subsystem string. Matches the app's primary bundle id so it reads
  /// naturally in Console.app's subsystem column.
  static let subsystem = "com.septena.cloud"

  static let app            = Logger(subsystem: subsystem, category: "App")
  static let persistence    = Logger(subsystem: subsystem, category: "Persistence")
  static let cloudKit       = Logger(subsystem: subsystem, category: "CKEngine")
  static let schemaSeed     = Logger(subsystem: subsystem, category: "SchemaSeed")
  static let migration      = Logger(subsystem: subsystem, category: "TasksMigrator")
  static let notifications  = Logger(subsystem: subsystem, category: "Notifications")
  static let claudeGateway  = Logger(subsystem: subsystem, category: "ClaudeGateway")
  static let liveActivity   = Logger(subsystem: subsystem, category: "LiveActivity")
  static let welcome        = Logger(subsystem: subsystem, category: "Welcome")

  /// Ad-hoc logger when none of the pre-defined categories fit.
  static func category(_ name: String) -> Logger {
    Logger(subsystem: subsystem, category: name)
  }
}

/// Back-compat general-purpose facade. Pre-dates `Log`; kept so existing
/// `SeptenaLog.info/error` call sites keep working, now routed through the
/// unified `os.Logger` (category "General") instead of bare `print()`.
enum SeptenaLog {
  private static let logger = Logger(subsystem: Log.subsystem, category: "General")

  static func info(_ msg: @autoclosure () -> String) {
    let text = msg()
    logger.info("\(text, privacy: .public)")
  }

  static func error(_ msg: @autoclosure () -> String, _ error: Error? = nil) {
    let text = msg()
    if let error {
      logger.error("\(text, privacy: .public) → \(error.localizedDescription, privacy: .public)")
    } else {
      logger.error("\(text, privacy: .public)")
    }
  }
}

// MARK: - Performance tracing

/// Lightweight timing for chasing main-thread stalls. Every span emits an
/// `os_signpost` interval (visible on the Instruments timeline, and via the
/// "Septena ▸ Perf" track) AND logs its elapsed milliseconds when they cross
/// `warnMs` — so a Console filter on category "Perf" surfaces *only* the slow
/// spans, and the count detail tells you how much work each one did.
///
/// `os.Logger`/`OSSignposter` are near-free at call sites, so these can stay
/// wrapped around hot paths. Tighten/remove once a stall is localized.
enum PerfTrace {
  static let signposter = OSSignposter(subsystem: Log.subsystem, category: "Perf")
  private static let logger = Logger(subsystem: Log.subsystem, category: "Perf")

  /// Spans faster than this don't log (the signpost still fires for Instruments).
  static let warnMs = 150

  private static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  private static func emit(_ name: StaticString, _ startNanos: UInt64, _ detail: String) {
    let ms = Int((nowNanos() &- startNanos) / 1_000_000)
    guard ms >= warnMs else { return }
    if detail.isEmpty {
      logger.info("\(name, privacy: .public) \(ms, privacy: .public)ms")
    } else {
      logger.info("\(name, privacy: .public) \(ms, privacy: .public)ms — \(detail, privacy: .public)")
    }
  }

  /// Time an async span. Logs `name <ms>ms — <detail>` when slow.
  @discardableResult
  static func span<T>(_ name: StaticString,
                      _ detail: @autoclosure () -> String = "",
                      _ body: () async throws -> T) async rethrows -> T {
    let state = signposter.beginInterval(name)
    let start = nowNanos()
    defer {
      signposter.endInterval(name, state)
      emit(name, start, detail())
    }
    return try await body()
  }

  /// Time a synchronous span.
  @discardableResult
  static func spanSync<T>(_ name: StaticString,
                          _ detail: @autoclosure () -> String = "",
                          _ body: () throws -> T) rethrows -> T {
    let state = signposter.beginInterval(name)
    let start = nowNanos()
    defer {
      signposter.endInterval(name, state)
      emit(name, start, detail())
    }
    return try body()
  }
}

// MARK: - Errors

/// Shared error type used by OuraProvider / WithingsProvider for HTTP
/// + decoding failures. Pre-dates those providers; lived in
/// SeptenaClient.swift originally.
enum SeptenaError: LocalizedError {
  case server(Int, String)
  case decoding(String)
  case invalidURL

  var errorDescription: String? {
    switch self {
    case .server(let code, let body): return "Server \(code): \(body)"
    case .decoding(let s): return "Decode failed: \(s)"
    case .invalidURL: return "Invalid URL"
    }
  }
}
