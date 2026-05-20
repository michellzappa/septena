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
// Reacts to: the General toggle (UserDefaults `septena.badge.showOverdue`)
// and `.septenaTasksChanged` (posted after every mutation by SeptenaClient).
// Recomputes via LocalCache.overdueCount — same definition the Today sidebar
// pill uses, so the icon and the in-app pill always agree.

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
    let enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    let count = enabled ? LocalCache.overdueCount(in: context) : 0
    apply(count: enabled ? count : 0, enabled: enabled)
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
