import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// The ONE decision point for the notices on top of the task lists. Both shells
// read it: the SwiftUI list draws each notice with `TaskListNotice`, the AppKit
// list with `KitNoticeCell`. So which notices show, in what order, and how a
// dismissal is remembered live here once, never per shell.
//
// Two channels, two jobs (docs/DesignSpec.md, "Notices and toasts"):
//   - A NOTICE is a statement about the list or the app that stays until it
//     no longer applies or the user dismisses it: an action the user must take
//     (sign in), a fact about today (tasks rolled in), or an explainer for a
//     feature the user just met (the fade).
//   - A TOAST (`SeptenaToastStore`) is a one-line confirmation of something the
//     user just did, with an optional Undo, that leaves on its own.
// An explanation never goes in a toast: it must stay until it is read.
//
// Order: what the user must do, then facts about today, then at most ONE
// explainer, so a list never opens under a stack of tips.

/// What a notice is about. Drives the glyph tint and the fill in both shells.
enum TaskNoticeKind {
  /// A fact or an explainer the user can read and dismiss.
  case info
  /// Something the user should do (sign in).
  case actionNeeded
  /// Something went wrong (sync refused changes).
  case warning
}

struct TaskNotice: Identifiable, Equatable {
  enum ID: String {
    case signIn
    case rolledIn
    /// Explainer: tasks carried on Today fade (docs/TASK_FADE_SPEC.md §4).
    case fadeIntro
  }

  let id: ID
  var kind: TaskNoticeKind
  var symbol: String
  var title: String
  var detail: String?
  /// Title of the trailing action. The shell wires the action itself by `id`.
  var primaryTitle: String?
  var dismissible: Bool
}

@MainActor
enum TaskNotices {
  /// The notices for Today, in display order. `pool` is the list's open rows
  /// on Today; `requiresSignIn` is true where the app is backend-only and has
  /// no session (Septask).
  static func today(pool: [SeptenaTask], requiresSignIn: Bool,
                    today: String, context: ModelContext) -> [TaskNotice] {
    var out: [TaskNotice] = []
    if requiresSignIn { out.append(signIn) }
    if let rolled = rolledIn(pool: pool, today: today, context: context) { out.append(rolled) }
    if let explainer = explainers(pool: pool).first { out.append(explainer) }
    return out
  }

  /// Remembers a dismissal. Rolled-in is per day and account-wide (synced);
  /// an explainer is once per device, until explainers get a synced key.
  static func dismiss(_ id: TaskNotice.ID, today: String, context: ModelContext) {
    switch id {
    case .signIn:
      return
    case .rolledIn:
      SettingsMirror.dismissRolledIn(on: today, context: context,
                                     engine: SeptenaServices.shared.ckEngine)
    case .fadeIntro:
      markSeen(id)
    }
  }

  // MARK: - Notices

  private static var signIn: TaskNotice {
    TaskNotice(
      id: .signIn, kind: .actionNeeded,
      symbol: "person.crop.circle.badge.exclamationmark",
      title: String(localized: "Not signed in",
                    comment: "Task list notice title when the task backend has no session"),
      detail: signInDetail,
      primaryTitle: String(localized: "Sign in…",
                           comment: "Task list notice button that starts Sign in with Apple"),
      dismissible: false)
  }

  private static var signInDetail: String {
    #if os(macOS)
    String(localized: "Your changes stay on this Mac until you sign in.",
           comment: "Task list notice detail when the task backend has no session")
    #else
    UIDevice.current.userInterfaceIdiom == .pad
      ? String(localized: "Your changes stay on this iPad until you sign in.",
               comment: "Task list notice detail when the task backend has no session, iPad")
      : String(localized: "Your changes stay on this iPhone until you sign in.",
               comment: "Task list notice detail when the task backend has no session, iPhone")
    #endif
  }

  /// Tasks that arrived on Today on their own: scheduled STRICTLY before today.
  /// A task scheduled for today, or merely due today, was placed by the user.
  private static func rolledIn(pool: [SeptenaTask], today: String,
                               context: ModelContext) -> TaskNotice? {
    guard SettingsMirror.rolledInDismissedOn(context: context) != today else { return nil }
    let count = pool.filter { task in
      guard task.status == .open, let scheduled = task.scheduled, !scheduled.isEmpty else { return false }
      return String(scheduled.prefix(10)) < today
    }.count
    guard count > 0 else { return nil }
    return TaskNotice(
      id: .rolledIn, kind: .info, symbol: "arrow.down.circle",
      title: count == 1
        ? String(localized: "1 task rolled into Today",
                 comment: "Start-of-day notice: one task arrived on Today on its own")
        : String(localized: "\(count) tasks rolled into Today",
                 comment: "Start-of-day notice: tasks arrived on Today on their own"),
      detail: nil, primaryTitle: nil, dismissible: true)
  }

  // MARK: - Explainers
  //
  // An explainer shows the first time the user meets a feature in the list,
  // and never again once dismissed. Add one by adding an `ID` case, a trigger
  // here, and copy that went through the humanizer pass.

  private static func explainers(pool: [SeptenaTask]) -> [TaskNotice] {
    var out: [TaskNotice] = []
    if !hasSeen(.fadeIntro), TaskRowFlags.agingEnabled,
       pool.contains(where: { $0.todayTenureFill() != nil }) {
      out.append(TaskNotice(
        id: .fadeIntro, kind: .info, symbol: "circle.lefthalf.filled",
        title: String(localized: "Tasks left on Today start to fade",
                      comment: "Explainer notice title: the Today fade, shown the first time a task fades"),
        detail: String(localized: "A task fades a little each day it carries over. Check it off or move it to bring it back. You can turn this off in Settings.",
                       comment: "Explainer notice detail: how the Today fade works and how to undo or disable it"),
        primaryTitle: nil, dismissible: true))
    }
    return out
  }

  private static let seenKey = "septena.notices.seen.v1"

  private static func hasSeen(_ id: TaskNotice.ID) -> Bool {
    (UserDefaults.standard.stringArray(forKey: seenKey) ?? []).contains(id.rawValue)
  }

  private static func markSeen(_ id: TaskNotice.ID) {
    var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    seen.insert(id.rawValue)
    UserDefaults.standard.set(seen.sorted(), forKey: seenKey)
  }
}
