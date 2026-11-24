import Foundation
import SwiftData
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Local OS notification scheduler and action handler for timed task reminders
// (docs/TIMED_REMINDERS_SPEC.md, Phase TR1).
//
// Design invariants:
// - Never requests notification permission at launch (TR2 requests lazily on
//   the user's first saved reminder).
// - Caps pending requests at 50 soonest future reminders (headroom below iOS's
//   64-notification system limit).
// - Unacknowledged agent proposals (`source == "mcp" && acknowledgedAt == nil`)
//   NEVER arm OS alerts (ADR 0008).
// - Reconciles on launch, foreground, `.septenaTasksChanged`, and timezone /
//   significant-time changes; removes both pending AND delivered notifications
//   when a task is completed, cancelled, deleted, dismissed, or resnoozed on
//   another device.

@MainActor
final class TaskReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
  static let shared = TaskReminderScheduler()

  static let categoryID = "septena.task.reminder"
  static let requestPrefix = "septask.reminder."
  static let maxPendingRequests = 50

  enum ActionID {
    static let complete       = "septena.task.reminder.complete"
    static let snooze15m      = "septena.task.reminder.snooze15m"
    static let snooze1h       = "septena.task.reminder.snooze1h"
    static let snoozeTomorrow = "septena.task.reminder.snoozeTomorrow9"
  }

  enum UserInfoKey {
    static let taskID = "taskID"
  }

  private weak var contextRef: ModelContext?
  private var observers: [NSObjectProtocol] = []
  private var started = false
  private var reconcileTask: Task<Void, Never>?

  /// Optional delegate hook for non-reminder notifications (such as remote
  /// APNs agent question actions in `SeptaskPushNotifications`), keeping a
  /// single `UNUserNotificationCenterDelegate` owner without clobbering.
  static var externalResponseHandler: (@Sendable (UNNotificationResponse) async -> Bool)?

  /// Optional hook invoked whenever notification authorization is confirmed or
  /// newly granted, so remote APNs registration can arm automatically.
  static var onAuthorizationGranted: (@MainActor () -> Void)?

  private override init() { super.init() }

  /// Idempotent startup called from `SeptaskLaunch.run(settings:)`.
  func start(context: ModelContext) {
    contextRef = context
    guard !started else {
      scheduleReconcile()
      return
    }
    started = true

    let unCenter = UNUserNotificationCenter.current()
    unCenter.delegate = self
    registerCategory(on: unCenter)

    let nc = NotificationCenter.default
    observers.append(nc.addObserver(forName: .septenaTasksChanged, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.scheduleReconcile() }
    })
    observers.append(nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.scheduleReconcile() }
    })
    #if os(iOS)
    observers.append(nc.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.scheduleReconcile() }
    })
    #endif

    scheduleReconcile()
  }

  /// Lazily request alert + sound authorization (called by UI only when the
  /// user saves their first reminder — never at app launch).
  @discardableResult
  func requestAuthorizationIfNeeded() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional:
      Self.onAuthorizationGranted?()
      return true
    #if os(iOS)
    case .ephemeral:
      Self.onAuthorizationGranted?()
      return true
    #endif
    case .denied:
      return false
    case .notDetermined:
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      if granted {
        scheduleReconcile()
        Self.onAuthorizationGranted?()
      }
      return granted
    @unknown default:
      return false
    }
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  /// Coalesced reconcile trigger so rapid sync batches don't thrash
  /// `UNUserNotificationCenter`.
  func scheduleReconcile() {
    reconcileTask?.cancel()
    reconcileTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self else { return }
      await self.reconcile()
    }
  }

  /// Synchronizes up to `maxPendingRequests` soonest future task reminders with
  /// `UNUserNotificationCenter`, and clears stale pending/delivered banners.
  func reconcile(now: Date = Date()) async {
    guard let context = contextRef else { return }

    let tasks: [TaskEntity]
    do {
      tasks = try context.fetch(FetchDescriptor<TaskEntity>(
        predicate: #Predicate { $0.reminderAt != nil }
      ))
    } catch {
      SeptenaLog.error("[TaskReminderScheduler] fetch failed", error)
      return
    }

    struct Desired {
      let id: String
      let taskID: String
      let title: String
      let fireDate: Date
      let mode: TaskReminderMode
      let isSnoozed: Bool
    }

    var candidates: [Desired] = []
    var activeTaskIDs: Set<String> = []

    for t in tasks {
      let isUnratifiedProposal = (t.source == TaskSource.mcp && t.acknowledgedAt == nil)
      let arms = TaskReminderRules.shouldArm(
        status: t.statusRaw,
        isDeleted: t.deletedAt != nil,
        isHeading: t.isHeading,
        isUnratifiedProposal: isUnratifiedProposal,
        reminderAt: t.reminderAt,
        reminderDismissedAt: t.reminderDismissedAt
      )
      guard arms, let fireAt = t.reminderAt else { continue }
      let mode = t.reminderMode.flatMap(TaskReminderMode.init(rawValue:)) ?? .floating

      let resolved: (date: Date, isSnoozed: Bool)?
      if let snoozed = t.reminderSnoozedUntil, let snoozeDate = Self.parseISOInstant(snoozed) {
        resolved = (snoozeDate, true)
      } else if let baseDate = Self.resolveFireDate(fireAt: fireAt, mode: mode, timeZone: .current) {
        resolved = (baseDate, false)
      } else {
        resolved = nil
      }

      guard let resolved else { continue }
      activeTaskIDs.insert(t.id)
      // Do not retroactively spam missed alerts; keep only future fire dates.
      guard resolved.date > now else { continue }

      candidates.append(Desired(
        id: Self.requestID(for: t.id),
        taskID: t.id,
        title: t.title,
        fireDate: resolved.date,
        mode: mode,
        isSnoozed: resolved.isSnoozed
      ))
    }

    candidates.sort { $0.fireDate < $1.fireDate }
    let desired = Array(candidates.prefix(Self.maxPendingRequests))
    let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })

    let center = UNUserNotificationCenter.current()

    // 1. Clean up delivered notifications for tasks that are no longer active
    //    or have been snoozed into the future (cross-device sync dedup).
    let delivered = await center.deliveredNotifications()
    var removeDeliveredIDs: [String] = []
    for note in delivered {
      let rid = note.request.identifier
      guard rid.hasPrefix(Self.requestPrefix) else { continue }
      let tid = String(rid.dropFirst(Self.requestPrefix.count))
      if !activeTaskIDs.contains(tid) || desiredByID[rid]?.isSnoozed == true {
        removeDeliveredIDs.append(rid)
      }
    }
    if !removeDeliveredIDs.isEmpty {
      center.removeDeliveredNotifications(withIdentifiers: removeDeliveredIDs)
    }

    // 2. Diff pending requests: drop obsolete ones, reschedule only changed ones.
    let pending = await center.pendingNotificationRequests()
    var removePendingIDs: [String] = []
    var unchangedIDs: Set<String> = []
    for req in pending {
      let rid = req.identifier
      guard rid.hasPrefix(Self.requestPrefix) else { continue }
      guard let want = desiredByID[rid] else {
        removePendingIDs.append(rid)
        continue
      }
      if Self.requestMatches(req, desiredTitle: want.title, fireDate: want.fireDate) {
        unchangedIDs.insert(rid)
      } else {
        removePendingIDs.append(rid)
      }
    }
    if !removePendingIDs.isEmpty {
      center.removePendingNotificationRequests(withIdentifiers: removePendingIDs)
    }

    // 3. Schedule missing or updated reminders (skip if unauthorized).
    let auth = await center.notificationSettings().authorizationStatus
    #if os(iOS)
    guard auth == .authorized || auth == .provisional || auth == .ephemeral else { return }
    #else
    guard auth == .authorized || auth == .provisional else { return }
    #endif

    for item in desired where !unchangedIDs.contains(item.id) {
      let content = UNMutableNotificationContent()
      content.title = item.title.isEmpty
        ? String(localized: "Task Reminder", comment: "Fallback reminder notification title")
        : item.title
      content.sound = .default
      content.categoryIdentifier = Self.categoryID
      content.threadIdentifier = Self.categoryID
      content.userInfo = [UserInfoKey.taskID: item.taskID]
      content.interruptionLevel = .timeSensitive

      let trigger: UNNotificationTrigger
      if !item.isSnoozed && item.mode == .floating {
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
        comps.second = 0
        trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
      } else {
        let interval = max(1, item.fireDate.timeIntervalSince(now))
        trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
      }

      let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
      do {
        try await center.add(request)
      } catch {
        SeptenaLog.error("[TaskReminderScheduler] failed to schedule \(item.taskID)", error)
      }
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    if let handler = await MainActor.run(body: { Self.externalResponseHandler }),
       await handler(response) {
      return
    }

    let actionID = response.actionIdentifier
    let taskID = response.notification.request.content.userInfo[UserInfoKey.taskID] as? String
    guard let taskID, !taskID.isEmpty else { return }

    await MainActor.run {
      SeptenaServices.shared.bindWriteBoundary()
    }
    await SeptenaServices.shared.start()

    await MainActor.run {
      let mutator = SeptenaServices.shared.taskMutator
      switch actionID {
      case ActionID.complete:
        mutator.complete(id: taskID)
      case ActionID.snooze15m:
        mutator.snoozeReminder(id: taskID, until: Date().addingTimeInterval(15 * 60))
      case ActionID.snooze1h:
        mutator.snoozeReminder(id: taskID, until: Date().addingTimeInterval(60 * 60))
      case ActionID.snoozeTomorrow:
        if let target = Self.tomorrowNineAM() {
          mutator.snoozeReminder(id: taskID, until: target)
        }
      case UNNotificationDismissActionIdentifier:
        mutator.dismissReminder(id: taskID)
      default:
        break
      }
    }
    await reconcile()
  }

  // MARK: - Helpers

  static func requestID(for taskID: String) -> String {
    requestPrefix + taskID
  }

  private func registerCategory(on center: UNUserNotificationCenter) {
    let complete = UNNotificationAction(
      identifier: ActionID.complete,
      title: String(localized: "Complete", comment: "Reminder notification action"),
      options: []
    )
    let snooze15 = UNNotificationAction(
      identifier: ActionID.snooze15m,
      title: String(localized: "Snooze 15 min", comment: "Reminder notification action"),
      options: []
    )
    let snooze1h = UNNotificationAction(
      identifier: ActionID.snooze1h,
      title: String(localized: "Snooze 1 hour", comment: "Reminder notification action"),
      options: []
    )
    let snoozeTomorrow = UNNotificationAction(
      identifier: ActionID.snoozeTomorrow,
      title: String(localized: "Tomorrow 9:00", comment: "Reminder notification action"),
      options: []
    )
    let category = UNNotificationCategory(
      identifier: Self.categoryID,
      actions: [complete, snooze15, snooze1h, snoozeTomorrow],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    center.getNotificationCategories { existing in
      var merged = existing.filter { $0.identifier != Self.categoryID }
      merged.insert(category)
      center.setNotificationCategories(merged)
    }
  }

  /// Resolves `fireAt` into an absolute `Date` in `timeZone`, handling DST
  /// spring-forward gaps by snapping forward to the first valid instant.
  nonisolated static func resolveFireDate(fireAt: String, mode: TaskReminderMode, timeZone: TimeZone) -> Date? {
    if mode == .fixed {
      return parseISOInstant(fireAt)
    }
    // Floating local wall-clock: "YYYY-MM-DDTHH:MM"
    let parts = fireAt.split(separator: "T")
    guard parts.count == 2 else { return parseISOInstant(fireAt) }
    let dParts = parts[0].split(separator: "-")
    let tParts = parts[1].split(separator: ":")
    guard dParts.count == 3, tParts.count >= 2,
          let y = Int(dParts[0]), let m = Int(dParts[1]), let d = Int(dParts[2]),
          let hh = Int(tParts[0]), let mm = Int(tParts[1]) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let comps = DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: 0)
    // `nextDate` with `.strict` false / `.nextTime` steps cleanly over a DST gap.
    if let exact = cal.date(from: comps) {
      let check = cal.dateComponents([.year, .month, .day, .hour, .minute], from: exact)
      if check.hour == hh && check.minute == mm { return exact }
      return exact
    }
    return nil
  }

  nonisolated private static func parseISOInstant(_ value: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: value) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: value)
  }

  private static func tomorrowNineAM(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
    var comps = calendar.dateComponents([.year, .month, .day], from: tomorrow)
    comps.hour = 9
    comps.minute = 0
    comps.second = 0
    return calendar.date(from: comps)
  }

  private static func requestMatches(_ req: UNNotificationRequest, desiredTitle: String, fireDate: Date) -> Bool {
    guard req.content.title == desiredTitle else { return false }
    if let calTrigger = req.trigger as? UNCalendarNotificationTrigger,
       let next = calTrigger.nextTriggerDate() {
      return abs(next.timeIntervalSince(fireDate)) < 60
    }
    if let intTrigger = req.trigger as? UNTimeIntervalNotificationTrigger,
       let next = intTrigger.nextTriggerDate() {
      return abs(next.timeIntervalSince(fireDate)) < 60
    }
    return false
  }

  /// Opens the platform's Notifications settings screen when authorization is
  /// denied, backing the non-blocking banner in TR2 (`docs/TIMED_REMINDERS_SPEC.md` §5).
  static func openNotificationSettings() {
    #if os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
    #elseif os(iOS)
    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
      UIApplication.shared.open(url)
    }
    #endif
  }

  nonisolated static func parseISOInstantPublic(_ value: String) -> Date? {
    parseISOInstant(value)
  }
}

// MARK: - TaskReminder UI & formatting helpers (TR2)

extension TaskReminder {
  private static let timeOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()

  private static let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEE")
    return f
  }()

  private static let monthDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f
  }()

  static func make(date: Date, mode: TaskReminderMode = .floating, calendar: Calendar = .current) -> TaskReminder {
    switch mode {
    case .floating:
      let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
      let wire = String(format: "%04d-%02d-%02dT%02d:%02d",
                        c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                        c.hour ?? 9, c.minute ?? 0)
      return TaskReminder(fireAt: wire, mode: .floating)
    case .fixed:
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime]
      f.timeZone = TimeZone(secondsFromGMT: 0)
      return TaskReminder(fireAt: f.string(from: date), mode: .fixed)
    }
  }

  func effectiveFireDate(timeZone: TimeZone = .current) -> Date? {
    if let snoozed = snoozedUntil, let d = TaskReminderScheduler.parseISOInstantPublic(snoozed) {
      return d
    }
    return TaskReminderScheduler.resolveFireDate(fireAt: fireAt, mode: mode, timeZone: timeZone)
  }

  /// Quiet row/pill label for an active (undismissed) reminder.
  /// Returns nil if dismissed or unparseable.
  @MainActor
  func badgeText(now explicitNow: Date? = nil) -> (text: String, isPastDue: Bool)? {
    let now = explicitNow ?? DayClock.appNow
    guard dismissedAt == nil, let fire = effectiveFireDate() else { return nil }
    let cal = Calendar.current
    let time = Self.timeOnlyFormatter.string(from: fire)
    let isPastDue = fire < now
    if cal.isDate(fire, inSameDayAs: now) {
      return (time, isPastDue)
    }
    let startNow = cal.startOfDay(for: now)
    let startFire = cal.startOfDay(for: fire)
    let days = cal.dateComponents([.day], from: startNow, to: startFire).day ?? 99
    if days > 0 && days < 7 {
      return ("\(Self.weekdayFormatter.string(from: fire)) \(time)", isPastDue)
    }
    return ("\(Self.monthDayFormatter.string(from: fire)), \(time)", isPastDue)
  }

  /// Standard quick presets for progressive-disclosure reminder pickers.
  @MainActor
  static func quickPresets(now explicitNow: Date? = nil, calendar: Calendar = .current) -> [(title: String, date: Date)] {
    let now = explicitNow ?? DayClock.appNow
    var result: [(String, Date)] = []

    // 1. In 1 hour (seconds zeroed)
    if let oneHour = calendar.date(byAdding: .hour, value: 1, to: now) {
      var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: oneHour)
      comps.second = 0
      if let clean = calendar.date(from: comps) {
        result.append((String(localized: "In 1 hour", comment: "Reminder quick preset"), clean))
      }
    }

    // 2. Tonight 18:00 (when still before 18:00)
    var tonightComps = calendar.dateComponents([.year, .month, .day], from: now)
    tonightComps.hour = 18
    tonightComps.minute = 0
    tonightComps.second = 0
    if let tonight = calendar.date(from: tonightComps), tonight > now.addingTimeInterval(15 * 60) {
      result.append((String(localized: "Tonight 18:00", comment: "Reminder quick preset"), tonight))
    }

    // 3. Tomorrow 09:00
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
      var comps = calendar.dateComponents([.year, .month, .day], from: tomorrow)
      comps.hour = 9
      comps.minute = 0
      comps.second = 0
      if let tmw9 = calendar.date(from: comps) {
        result.append((String(localized: "Tomorrow 09:00", comment: "Reminder quick preset"), tmw9))
      }
    }

    return result
  }
}
