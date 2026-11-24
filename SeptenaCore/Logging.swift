import Foundation
import os

// App-wide logger and the shared notification names.

// MARK: - Change notification

extension Notification.Name {
  /// Posted after task mutations and CloudKit task-sync batches complete.
  /// Local mutations carry `TaskChange.changedIDs`; inbound CloudKit batches
  /// remain unscoped because a batch can add, delete, and move many rows.
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
  /// Posted when a task *view* option flips (currently only
  /// `SettingsKey.todayGroupByList`, from the View menu / the Tasks "···"
  /// menu / Settings). SwiftUI surfaces bind the key through `@AppStorage` and
  /// repaint themselves; Septask's AppKit list reads `UserDefaults` directly
  /// and has no observation of it, so it needs this nudge to rebuild its rows.
  static let septenaTaskViewOptionsChanged = Notification.Name("septena.taskViewOptionsChanged")
}

// MARK: - Scoped task changes

/// Identity scoping for local task mutations. This is intentionally separate
/// from `DataChange`: tasks have their own high-frequency repaint path and a
/// task list needs to determine whether one changed row can enter or leave its
/// current filter. An absent payload remains the conservative "reload all"
/// signal used by CloudKit batches and migrations.
enum TaskChange {
  static let idsKey = "septena.changedTaskIDs"

  static func post(_ ids: String...) {
    NotificationCenter.default.post(
      name: .septenaTasksChanged,
      object: nil,
      userInfo: [idsKey: Set(ids)]
    )
  }
}

// MARK: - Scoped data changes

extension Notification {
  /// Changed task ids for a local optimistic mutation; nil for an unscoped
  /// batch where any task may have changed.
  var changedTaskIDs: Set<String>? {
    userInfo?[TaskChange.idsKey] as? Set<String>
  }

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

public enum Diagnostics {
  /// Resolved once — this is read on hot paths and must not re-scan
  /// `CommandLine.arguments` per call.
  public static let enabled: Bool = {
    let args = CommandLine.arguments
    if args.contains("-SeptenaQuiet") { return false }
    if args.contains("-SeptenaVerbose") { return true }
    #if DEBUG
    return true
    #else
    return false
    #endif
  }()
}

/// Back-compat general-purpose facade. Pre-dates `Log`; kept so existing
/// `SeptenaLog.info/error` call sites keep working, now routed through the
/// unified `os.Logger` (category "General") instead of bare `print()`.
enum SeptenaLog {
  private static let logger = Logger(subsystem: Log.subsystem, category: "General")

  /// Gated on `Diagnostics.enabled`. The `@autoclosure` is what makes the gate
  /// worth having: the message is never built when diagnostics are off, so an
  /// interpolated log line on a hot path costs a bool check.
  static func info(_ msg: @autoclosure () -> String) {
    guard Diagnostics.enabled else { return }
    // Bound to a local first: `logger.info`'s interpolation is itself an
    // escaping autoclosure, which a non-escaping parameter can't be fed into.
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
  ///
  /// A no-op passthrough when `Diagnostics.enabled` is false — no signpost, no
  /// clock read, no detail string. That matters precisely when it's off: these
  /// wrap the hot paths, and a speed test shouldn't be measuring the tracing.
  @discardableResult
  static func span<T>(_ name: StaticString,
                      _ detail: @autoclosure () -> String = "",
                      _ body: () async throws -> T) async rethrows -> T {
    guard Diagnostics.enabled else { return try await body() }
    let state = signposter.beginInterval(name)
    let start = nowNanos()
    defer {
      signposter.endInterval(name, state)
      emit(name, start, detail())
    }
    return try await body()
  }

  /// Time a synchronous span. No-op passthrough when diagnostics are off.
  @discardableResult
  static func spanSync<T>(_ name: StaticString,
                          _ detail: @autoclosure () -> String = "",
                          _ body: () throws -> T) rethrows -> T {
    guard Diagnostics.enabled else { return try body() }
    let state = signposter.beginInterval(name)
    let start = nowNanos()
    defer {
      signposter.endInterval(name, state)
      emit(name, start, detail())
    }
    return try body()
  }
}

// MARK: - Launch tracing

/// Cold-launch measurement (docs/LAUNCH_PERF.md). Unlike `PerfTrace`, these
/// signposts are ALWAYS on, in Release too: the number that matters is a
/// Release build on a device, and a launch emits only a handful of them, so
/// the cost is a few `os_signpost` calls per process. They land on their own
/// Instruments track: subsystem `com.septena.cloud`, category "Launch".
///
/// Two shapes:
/// - `span` / `spanSync`: an interval (LocalStore open, services start, …).
/// - `milestone`: a one-shot point event (App.init, first Today body, Today
///   rows on screen, first frame drawn). The first call per name wins, so a
///   milestone on a hot path still fires once per process.
///
/// Every span and milestone also logs one info line with its time since the
/// kernel created the process, so `log stream --predicate 'category ==
/// "Launch"'` reads a launch without Instruments.
enum LaunchTrace {
  static let signposter = OSSignposter(subsystem: Log.subsystem, category: "Launch")
  private static let logger = Logger(subsystem: Log.subsystem, category: "Launch")
  private static let fired = OSAllocatedUnfairLock(initialState: Set<String>())

  /// Wall-clock start of this process, read once from the kernel.
  private static let processStart: Date? = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
  }()

  /// Milliseconds since the kernel created this process (-1 when unknown).
  static func msSinceProcessStart() -> Int {
    guard let processStart else { return -1 }
    return Int(Date().timeIntervalSince(processStart) * 1000)
  }

  /// One-shot point event. The first call per `name` in this process wins.
  static func milestone(_ name: StaticString) {
    let key = name.description
    let isFirst = fired.withLock { $0.insert(key).inserted }
    guard isFirst else { return }
    let ms = msSinceProcessStart()
    signposter.emitEvent(name, "\(ms, privacy: .public) ms since process start")
    logger.info("\(key, privacy: .public) at \(ms, privacy: .public) ms")
  }

  /// Time an async interval.
  @discardableResult
  static func span<T>(_ name: StaticString,
                      _ body: () async throws -> T) async rethrows -> T {
    let state = signposter.beginInterval(name)
    let start = DispatchTime.now().uptimeNanoseconds
    defer {
      signposter.endInterval(name, state)
      log(name, start)
    }
    return try await body()
  }

  /// Time a synchronous interval.
  @discardableResult
  static func spanSync<T>(_ name: StaticString,
                          _ body: () throws -> T) rethrows -> T {
    let state = signposter.beginInterval(name)
    let start = DispatchTime.now().uptimeNanoseconds
    defer {
      signposter.endInterval(name, state)
      log(name, start)
    }
    return try body()
  }

  private static func log(_ name: StaticString, _ startNanos: UInt64) {
    let ms = Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
    let key = name.description
    let end = msSinceProcessStart()
    logger.info("\(key, privacy: .public) took \(ms, privacy: .public) ms, ended at \(end, privacy: .public) ms")
  }
}

// MARK: - Errors
