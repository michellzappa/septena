import Foundation
import EventKit

// Bridge to Apple Reminders. Lets the user nominate one Reminders list as
// Septena's "inbox source"; pending reminders from that list surface in the
// Septena Inbox as task-style rows and can be imported with one tap. Import
// always deletes the original reminder so dedupe is implicit.

@MainActor
@Observable
final class RemindersBridge {
  static let shared = RemindersBridge()

  let store = EKEventStore()

  private init() {}

  // MARK: - Auth

  enum Access {
    case granted        // .fullAccess (or legacy .authorized)
    case writeOnly      // can write but not read — useless for import
    case denied
    case notDetermined
  }

  var access: Access {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if #available(iOS 17.0, macOS 14.0, *) {
      switch status {
      case .fullAccess: return .granted
      case .writeOnly:  return .writeOnly
      case .denied, .restricted: return .denied
      case .notDetermined: return .notDetermined
      @unknown default: return .denied
      }
    } else {
      switch status {
      case .authorized: return .granted
      case .denied, .restricted: return .denied
      case .notDetermined: return .notDetermined
      // .fullAccess / .writeOnly exist on the enum but only get returned on
      // iOS 17+ / macOS 14+. Handle them so the switch is exhaustive on older
      // SDKs too.
      default: return .denied
      }
    }
  }

  func requestAccess() async -> Bool {
    do {
      if #available(iOS 17.0, macOS 14.0, *) {
        return try await store.requestFullAccessToReminders()
      } else {
        return try await store.requestAccess(to: .reminder)
      }
    } catch {
      return false
    }
  }

  // MARK: - Source list (which Reminders list mirrors into the Inbox)

  private static let sourceKey = "septena.reminders.sourceListID"

  /// Mirrors UserDefaults so @Observable can track changes. Initialized once
  /// on construction; the setter persists.
  var sourceListID: String? = UserDefaults.standard.string(forKey: sourceKey) {
    didSet {
      if let v = sourceListID { UserDefaults.standard.set(v, forKey: Self.sourceKey) }
      else                    { UserDefaults.standard.removeObject(forKey: Self.sourceKey) }
    }
  }

  func sourceList() -> EKCalendar? {
    guard let id = sourceListID else { return nil }
    return store.calendar(withIdentifier: id)
  }

  // MARK: - Auto-import

  private static let autoImportKey = "septena.reminders.autoImport"
  private static let logKey        = "septena.reminders.autoImportLog"
  private static let logCap        = 20

  /// When true, any pending reminder in the source list is imported as a
  /// Septena task and removed from Reminders, without user action. Triggered
  /// on app launch and whenever the EventKit store changes.
  var autoImport: Bool = UserDefaults.standard.bool(forKey: autoImportKey) {
    didSet { UserDefaults.standard.set(autoImport, forKey: Self.autoImportKey) }
  }

  /// Most recent auto-imports, newest first, capped at `logCap`. Surfaced in
  /// Settings so the user can confirm what got pulled in (and removed from
  /// Reminders) without diving into Console logs.
  var recentImports: [AutoImportLogEntry] = {
    guard let data = UserDefaults.standard.data(forKey: logKey),
          let decoded = try? JSONDecoder().decode([AutoImportLogEntry].self, from: data)
    else { return [] }
    return decoded
  }() {
    didSet {
      if let data = try? JSONEncoder().encode(recentImports) {
        UserDefaults.standard.set(data, forKey: Self.logKey)
      }
    }
  }

  /// Reentrancy guard — EventKit can fire change notifications mid-import.
  @ObservationIgnored private var autoImporting = false

  /// One pass: fetch pending from the source list, create a Septena task per
  /// item, delete the original on success, append to the log. No-op unless
  /// the toggle is on, access is granted, and a source list is nominated.
  func runAutoImport(using create: (String, Date?, String?) async throws -> Void) async {
    guard autoImport, access == .granted, let cal = sourceList(), !autoImporting else { return }
    autoImporting = true
    defer { autoImporting = false }

    let pending = await pendingReminders(in: cal)
    guard !pending.isEmpty else { return }

    var imported: [EKReminder] = []
    var entries: [AutoImportLogEntry] = []
    for r in pending {
      let title = r.title ?? "Untitled"
      do {
        try await create(title, r.dueDateComponents?.date, r.notes)
        imported.append(r)
        entries.append(AutoImportLogEntry(title: title, importedAt: Date(), succeeded: true))
      } catch {
        entries.append(AutoImportLogEntry(title: title, importedAt: Date(),
                                          succeeded: false,
                                          error: error.localizedDescription))
      }
    }
    // Removing the originals is what makes dedupe work — a reminder that
    // imports but isn't deleted will re-import on the next pass. So a delete
    // failure is surfaced in the log, never swallowed.
    if !imported.isEmpty {
      do {
        try delete(imported)
      } catch {
        SeptenaLog.error("Reminders auto-import delete", error)
        let n = imported.count
        entries.append(AutoImportLogEntry(
          title: "Couldn’t remove \(n) imported reminder\(n == 1 ? "" : "s") from Reminders",
          importedAt: Date(),
          succeeded: false,
          error: error.localizedDescription))
      }
    }
    if !entries.isEmpty {
      // Newest first; trim to cap.
      recentImports = Array((entries.reversed() + recentImports).prefix(Self.logCap))
    }
  }

  // MARK: - Read

  func reminderLists() -> [EKCalendar] {
    store.calendars(for: .reminder)
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  /// Hard ceiling on a single `fetchReminders` call. EventKit's completion
  /// handler is not contractually guaranteed to fire, so we bound the wait and
  /// cancel the request rather than leak a suspended task forever.
  private static let fetchTimeout: Duration = .seconds(10)

  /// Incomplete reminders from `calendar`, in the order Reminders returns them.
  /// Uses `predicateForReminders(in:)` and filters in-process — the
  /// `predicateForIncompleteReminders(withDueDateStarting:ending:…)` variant
  /// inconsistently drops items without a due date across OS versions.
  ///
  /// `fetchReminders` is an old-style callback API with no error channel and no
  /// guaranteed completion. We resume exactly once — whichever fires first, the
  /// EventKit callback or a timeout that cancels the in-flight request — so a
  /// store that never calls back can't strand this continuation.
  func pendingReminders(in calendar: EKCalendar) async -> [EKReminder] {
    let predicate = store.predicateForReminders(in: [calendar])
    return await withCheckedContinuation { cont in
      let resume = ResumeOnce()
      let request = store.fetchReminders(matching: predicate) { results in
        guard resume.claim() else { return }
        cont.resume(returning: (results ?? []).filter { !$0.isCompleted })
      }
      Task { [store, request] in
        try? await Task.sleep(for: Self.fetchTimeout)
        guard resume.claim() else { return }
        store.cancelFetchRequest(request)
        SeptenaLog.error("Reminders fetch timed out",
                         RemindersError.fetchTimedOut)
        cont.resume(returning: [])
      }
    }
  }

  // MARK: - Delete

  /// Batch-remove the given reminders and commit once.
  func delete(_ reminders: [EKReminder]) throws {
    for r in reminders {
      try store.remove(r, commit: false)
    }
    try store.commit()
  }
}

// MARK: - Single-resume latch

/// Thread-safe one-shot guard. `claim()` returns true to exactly one caller;
/// every later caller gets false. Used to race a callback against a timeout
/// without ever resuming a continuation twice. The callback and the timeout
/// task run on different executors, so the latch must be lock-backed.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false
  func claim() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}

enum RemindersError: Error {
  case fetchTimedOut
}

// MARK: - View-model snapshot

struct ImportedReminder: Identifiable, Hashable {
  let id: String              // EKReminder.calendarItemIdentifier
  let title: String
  let notes: String?
  let dueDate: Date?

  static func == (lhs: ImportedReminder, rhs: ImportedReminder) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }

  init(_ r: EKReminder) {
    self.id = r.calendarItemIdentifier
    self.title = r.title ?? "Untitled"
    self.notes = r.notes
    self.dueDate = r.dueDateComponents?.date
  }
}

// MARK: - Auto-import log

struct AutoImportLogEntry: Codable, Identifiable, Hashable {
  let id: UUID
  let title: String
  let importedAt: Date
  let succeeded: Bool
  let error: String?

  init(id: UUID = UUID(), title: String, importedAt: Date,
       succeeded: Bool, error: String? = nil) {
    self.id = id
    self.title = title
    self.importedAt = importedAt
    self.succeeded = succeeded
    self.error = error
  }
}
