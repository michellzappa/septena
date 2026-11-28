import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif
#if canImport(AppKit)
import AppKit
#endif

// Drives the app-icon badge from local overdue-task state.
//
// Reacts to: the General toggle (`septena.badge.showOverdue`) and
// `.septenaTasksChanged` (posted after every task mutation / CK apply).
// Recomputes via LocalCache.overdueCount — same definition the Today sidebar
// pill uses, so the icon and the in-app pill always agree.
//
// The toggle lives in the SHARED App Group, not per-app UserDefaults. Septena
// Life and Septena badge the same overdue tasks off the same CloudKit zone, so two
// independent opt-ins meant two dock dots for one set of work — which reads as
// twice as many overdue tasks, not as two apps. One key, one owner.
// Cross-process propagation is not live: the other app picks up a change on
// its next launch or foreground refresh. That is enough to keep the two from
// disagreeing, which is the actual defect.

@MainActor
@Observable
final class BadgeManager {
  static let shared = BadgeManager()

  static let defaultsKey = "septena.badge.showOverdue"

  private var observer: NSObjectProtocol?
  private var defaultsObserver: NSObjectProtocol?
  private weak var contextRef: ModelContext?

  private init() {}

  func start(context: ModelContext) {
    contextRef = context
    // One-shot: carry a pre-existing per-app opt-in into the group, so an
    // update doesn't silently reset the badge to off.
    SeptenaAppGroup.migrateIfNeeded(key: Self.defaultsKey)
    refresh()
    let center = NotificationCenter.default
    observer = center.addObserver(forName: .septenaTasksChanged,
                                  object: nil,
                                  queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    defaultsObserver = center.addObserver(forName: UserDefaults.didChangeNotification,
                                          object: nil,
                                          queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh() {
    guard let context = contextRef else { return }
    refresh(context: context)
  }

  private func refresh(context: ModelContext) {
    let enabled = SeptenaAppGroup.defaults.bool(forKey: Self.defaultsKey)
    #if canImport(UIKit)
    // iOS never shows the count (see `apply`), and `overdueCount` reads every
    // task in the store on the main actor, once per task change and once per
    // defaults write. Skip the read.
    apply(count: 0, enabled: enabled)
    #else
    let count = enabled ? LocalCache.overdueCount(in: context) : 0
    apply(count: count, enabled: enabled)
    #endif
  }

  private func apply(count: Int, enabled: Bool) {
    #if canImport(AppKit)
    NSApp.dockTile.badgeLabel = count > 0 ? "•" : nil
    #endif
    // iOS app-icon badges are numeric only; we'd rather show nothing than a
    // running count, so the badge stays cleared on UIKit platforms.
    #if canImport(UIKit)
    UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    #endif
  }
}
