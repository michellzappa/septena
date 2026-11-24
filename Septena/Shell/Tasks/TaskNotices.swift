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

  /// The kind a registry notice row names (`info`, `actionNeeded`, `warning`).
  init(registry kind: String) {
    switch kind {
    case "actionNeeded": self = .actionNeeded
    case "warning": self = .warning
    default: self = .info
    }
  }
}

struct TaskNotice: Identifiable, Equatable {
  enum ID: String {
    case signIn
    case rolledIn
    /// Weekly sweep prompt: tasks faded since the last sweep (docs/TASK_FADE_SPEC.md §5).
    case weeklySweep
    /// Explainer: untouched tasks fade over 14 days (docs/TASK_FADE_SPEC.md §4).
    case fadeIntro
    /// The first-run checklist (Septask): steps drawn like task rows that
    /// tick off as the user does them.
    case getStarted
    /// Upsell (spec §3.2): the free account's trial ran out.
    case trialEnd
    /// Upsell (spec §3.2): the free account syncs another device, not this one.
    case secondDevice
  }

  let id: ID
  var kind: TaskNoticeKind
  var symbol: String
  var title: String
  var detail: String?
  /// Title of the trailing action. The shell wires the action itself by `id`.
  var primaryTitle: String?
  /// The `registry/plans.json` upsell this notice shows; the shell opens the
  /// Plus sheet with it. Nil for every other notice.
  var upsellID: String? = nil
  var dismissible: Bool
  /// Checklist rows under the notice, drawn like task rows. Empty for a
  /// plain notice.
  var steps: [TaskNoticeStep] = []
}

/// One row of a checklist notice. `done` comes from what the user actually
/// did (an approved agent pairing, an import, a first task) or from ticking
/// the row by hand, the same gesture as checking off a task.
struct TaskNoticeStep: Identifiable, Equatable {
  enum ID: String, CaseIterable {
    case connectAI
    case importTasks
    case addTask
  }

  let id: ID
  var title: String
  var detail: String
  var done: Bool

  /// The step's identity in a task list's selection. Task ids are UUIDs, so
  /// the `getstarted.` prefix can never collide with one; every task command
  /// looks its id up as a task, finds none and does nothing.
  var selectionID: String { Self.selectionPrefix + id.rawValue }
  static let selectionPrefix = "getstarted."

  /// The step a selection id names, or nil for a task id.
  static func stepID(fromSelection selection: String) -> ID? {
    guard selection.hasPrefix(selectionPrefix) else { return nil }
    return ID(rawValue: String(selection.dropFirst(selectionPrefix.count)))
  }
}

@MainActor
enum TaskNotices {
  /// The notices for Today, in display order. `pool` is the list's open rows
  /// on Today; `requiresSignIn` is true where the app is backend-only and has
  /// no session (Septask).
  static func today(pool: [SeptenaTask], requiresSignIn: Bool,
                    today: String, context: ModelContext) -> [TaskNotice] {
    var out: [TaskNotice] = []
    if requiresSignIn, !hasSeen(.signIn) { out.append(signIn) }
    if let upsell = upsell(context: context) { out.append(upsell) }
    if let sweep = weeklySweep(context: context) { out.append(sweep) }
    // The "N tasks rolled into Today" banner is hidden (2026-11-23): the
    // carry-over is daily noise the user dismisses every morning. Today's
    // rollover behavior (Ask vs. Clean slate, like Microsoft To Do's My Day)
    // decides what replaces it: #139. `rolledIn` stays for that work.
    // Onboarding counts as the one explainer slot: never a tip and a
    // checklist at once.
    if let start = getStarted(context: context) {
      out.append(start)
    } else if let explainer = explainers(pool: pool).first {
      out.append(explainer)
    }
    // A notice whose capability does not ship here never shows (ADR 0015).
    return out.filter(isShippedHere)
  }

  private static func isShippedHere(_ notice: TaskNotice) -> Bool {
    guard let row = RegistryNotices.byId[notice.id.rawValue] else { return true }
    return RegistryCapabilities.isAvailable(row.featureId, on: RegistryPlatform.current)
  }

  /// Remembers a dismissal. Rolled-in and Get started are account-wide (synced);
  /// other explainers are once per device until they get a synced key.
  static func dismiss(_ id: TaskNotice.ID, today: String, context: ModelContext) {
    switch id {
    case .signIn:
      markSeen(id)
    case .rolledIn:
      SettingsMirror.dismissRolledIn(on: today, context: context,
                                     engine: SeptenaServices.shared.ckEngine)
    case .getStarted:
      markSeen(id)
      SettingsMirror.dismissGetStarted(context: context,
                                       engine: SeptenaServices.shared.ckEngine)
    case .weeklySweep:
      TaskFade.dismissSweepForCurrentWeek(now: DayClock.appNow)
    case .fadeIntro:
      markSeen(id)
    case .trialEnd, .secondDevice:
      if let upsell = registry(id).upsellId { markUpsellSeen(upsell, context: context) }
    }
  }

  /// Marks an upsell moment seen for the whole account (synced setting
  /// `upsellsSeen`). Opening the Plus sheet from a notice and dismissing it
  /// both call this, so the moment never shows as a prompt again. Posts
  /// `.septenaTasksChanged` so both task lists drop the notice.
  static func markUpsellSeen(_ upsellID: String, context: ModelContext? = nil) {
    let ctx = context ?? LocalStore.shared.container.mainContext
    guard !SettingsMirror.upsellsSeen(context: ctx).contains(upsellID) else { return }
    SettingsMirror.markUpsellSeen(upsellID, context: ctx, engine: SeptenaServices.shared.ckEngine)
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }

  /// Re-arms the sign-in notice after a successful sign-in so a future
  /// sign-out can surface it once again.
  static func clearSignInDismissal() {
    var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    guard seen.remove(TaskNotice.ID.signIn.rawValue) != nil else { return }
    UserDefaults.standard.set(seen.sorted(), forKey: seenKey)
  }

  /// Shows Get started again from the start (Settings ▸ About, and after an
  /// account is deleted). Steps the data still proves come back ticked.
  static func resetGetStarted(context: ModelContext? = nil) {
    let ctx = context ?? LocalStore.shared.container.mainContext
    var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    seen.remove(TaskNotice.ID.getStarted.rawValue)
    UserDefaults.standard.set(seen.sorted(), forKey: seenKey)
    UserDefaults.standard.removeObject(forKey: stepsKey)
    SettingsMirror.resetGetStarted(context: ctx, engine: SeptenaServices.shared.ckEngine)
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }

  /// Ticks a checklist step: by hand from its checkbox, or from the code
  /// path that just did the thing (pairing approved, an import finished).
  static func completeStep(_ id: TaskNoticeStep.ID, context: ModelContext? = nil) {
    let ctx = context ?? LocalStore.shared.container.mainContext
    let synced = SettingsMirror.getStartedSteps(context: ctx)
    var done = Set(synced ?? (UserDefaults.standard.stringArray(forKey: stepsKey) ?? []))
    let inserted = done.insert(id.rawValue).inserted
    let sorted = done.sorted()
    if inserted || UserDefaults.standard.stringArray(forKey: stepsKey) != sorted {
      UserDefaults.standard.set(sorted, forKey: stepsKey)
    }
    SettingsMirror.setGetStartedSteps(sorted, context: ctx,
                                      engine: SeptenaServices.shared.ckEngine)
    if TaskNoticeStep.ID.allCases.allSatisfy({ done.contains($0.rawValue) }) {
      markSeen(.getStarted)
      SettingsMirror.dismissGetStarted(context: ctx,
                                       engine: SeptenaServices.shared.ckEngine)
    }
  }

  /// Unticks a step ticked by hand (Mark as Not Done). A step the data shows
  /// as done (an agent task, an import, a first task) ticks itself again on
  /// the next read, the same as before.
  static func reopenStep(_ id: TaskNoticeStep.ID, context: ModelContext? = nil) {
    let ctx = context ?? LocalStore.shared.container.mainContext
    let synced = SettingsMirror.getStartedSteps(context: ctx)
    var done = Set(synced ?? (UserDefaults.standard.stringArray(forKey: stepsKey) ?? []))
    guard done.remove(id.rawValue) != nil else { return }
    let sorted = done.sorted()
    UserDefaults.standard.set(sorted, forKey: stepsKey)
    SettingsMirror.setGetStartedSteps(sorted, context: ctx,
                                      engine: SeptenaServices.shared.ckEngine)
  }

  /// Ticks or unticks a step: the ⌘K / checkbox gesture on a step row, the
  /// same toggle a task row has.
  static func toggleStep(_ step: TaskNoticeStep) {
    if step.done { reopenStep(step.id) } else { completeStep(step.id) }
  }

  // MARK: - Notices

  /// The registry row for a notice (`registry/surfaces.json` `notices`).
  /// The registry owns symbol, kind, copy and dismissibility; this file owns
  /// only when a notice shows.
  private static func registry(_ id: TaskNotice.ID) -> RegistryNotice {
    guard let row = RegistryNotices.byId[id.rawValue] else {
      preconditionFailure("registry/surfaces.json has no notice \(id.rawValue)")
    }
    return row
  }

  /// A notice from its registry row. `title` overrides the row's title for
  /// notices whose title carries a count.
  private static func notice(_ id: TaskNotice.ID, title: String? = nil,
                             steps: [TaskNoticeStep] = []) -> TaskNotice {
    let row = registry(id)
    return TaskNotice(
      id: id, kind: TaskNoticeKind(registry: row.kind), symbol: row.sfSymbol,
      title: title ?? row.title ?? "",
      detail: row.detail(for: RegistryPlatform.current),
      primaryTitle: row.primaryTitle, dismissible: row.dismissible, steps: steps)
  }

  // MARK: - Upsell moments (docs/SYNC_SUBSCRIPTION_SPEC.md §3.2)
  //
  // A moment shows only when the user meets the limit, once per account,
  // with one tap to the Plus sheet. The server judges the plan
  // (`PlanStatus`, read from `GET /v1/entitlement`); this only reads its
  // answer. At most one upsell at a time, so Today never opens under a
  // stack of them. The words come from `registry/plans.json` `upsells`.

  private static func upsell(context: ModelContext) -> TaskNotice? {
    guard TaskBackendClient.hasSession else { return nil }
    let status = PlanStatus.shared
    let seen = SettingsMirror.upsellsSeen(context: context)
    var candidates: [TaskNotice.ID] = []
    if status.trialEnded, !status.isPlus { candidates.append(.trialEnd) }
    if status.deviceNotSyncing { candidates.append(.secondDevice) }
    for id in candidates {
      let row = registry(id)
      guard let upsellID = row.upsellId, !seen.contains(upsellID),
            let moment = RegistryPlans.upsell(upsellID) else { continue }
      return TaskNotice(
        id: id, kind: TaskNoticeKind(registry: row.kind), symbol: row.sfSymbol,
        title: moment.title, detail: moment.detail,
        primaryTitle: row.primaryTitle, upsellID: upsellID, dismissible: row.dismissible)
    }
    return nil
  }

  private static var signIn: TaskNotice { notice(.signIn) }

  /// Tasks that arrived on Today on their own. Same rule as the row's arrived
  /// dot (`SeptenaTask.showsArrivedToday`, `docs/TASK_DATES_SPEC.md` R8), so
  /// the notice never counts a task that carries no dot, or the reverse.
  private static func rolledIn(pool: [SeptenaTask], today: String,
                               context: ModelContext) -> TaskNotice? {
    guard SettingsMirror.rolledInDismissedOn(context: context) != today else { return nil }
    let count = pool.filter { $0.showsArrivedToday() }.count
    guard count > 0 else { return nil }
    return notice(.rolledIn, title: RegistryNotices.rolledInTitle(count: count))
  }

  // MARK: - Get started (Septask)
  //
  // Shown until every step is done or the user dismisses it. A step is done
  // once ticked, or once the data shows it happened: a task an agent wrote
  // (an agent is connected), a task imported from Things, a task the user
  // added. Done is latched, so a finished step never costs a query again.

  private static let stepsKey = "septena.notices.getStarted.steps.v1"

  private static func getStarted(context: ModelContext) -> TaskNotice? {
    let syncedDismissed = SettingsMirror.getStartedDismissed(context: context)
    let localDismissed = hasSeen(.getStarted)
    if syncedDismissed || localDismissed {
      if syncedDismissed && !localDismissed { markSeen(.getStarted) }
      // Promote a pre-sync local dismissal so sibling devices hide it too.
      if localDismissed && !syncedDismissed {
        SettingsMirror.dismissGetStarted(context: context,
                                         engine: SeptenaServices.shared.ckEngine)
      }
      return nil
    }
    let syncedSteps = SettingsMirror.getStartedSteps(context: context)
    let localSteps = UserDefaults.standard.stringArray(forKey: stepsKey) ?? []
    let latched: Set<String>
    if let syncedSteps {
      latched = Set(syncedSteps)
      if localSteps != syncedSteps {
        UserDefaults.standard.set(syncedSteps, forKey: stepsKey)
      }
    } else {
      latched = Set(localSteps)
      if !localSteps.isEmpty {
        // Promote pre-sync local step progress so sibling devices see it.
        SettingsMirror.setGetStartedSteps(localSteps, context: context,
                                          engine: SeptenaServices.shared.ckEngine)
      }
    }
    let headingKind = TaskKind.heading
    func done(_ id: TaskNoticeStep.ID, source: String) -> Bool {
      if latched.contains(id.rawValue) { return true }
      // Inline capture inserts an untitled placeholder (`title == ""`) as soon
      // as the user taps "New task" and fills `title` only on save (or purges
      // it if abandoned). Exclude blank drafts and project headings so a step
      // — especially `.addTask` — concludes only once a real task is saved.
      let descriptor = FetchDescriptor<TaskEntity>(
        predicate: #Predicate {
          $0.source == source && $0.title != "" && $0.kind != headingKind
        }
      )
      guard ((try? context.fetchCount(descriptor)) ?? 0) > 0 else { return false }
      completeStep(id, context: context)
      return true
    }
    let sources: [TaskNoticeStep.ID: String] = [
      .connectAI: TaskSource.mcp, .importTasks: TaskSource.things, .addTask: TaskSource.app,
    ]
    let steps: [TaskNoticeStep] = registry(.getStarted).steps.compactMap { row in
      guard let id = TaskNoticeStep.ID(rawValue: row.id), let source = sources[id] else { return nil }
      return TaskNoticeStep(id: id, title: row.title,
                            detail: row.detail(for: RegistryPlatform.current),
                            done: done(id, source: source))
    }
    guard steps.contains(where: { !$0.done }) else {
      markSeen(.getStarted)
      SettingsMirror.dismissGetStarted(context: context,
                                       engine: SeptenaServices.shared.ckEngine)
      return nil
    }
    return notice(.getStarted, steps: steps)
  }

  /// Weekly sweep prompt (`docs/TASK_FADE_SPEC.md` §5): once a week on Sunday
  /// (or the first day opened after Sunday), offers a one-tap review of tasks
  /// that faded since the last sweep. Ignoring it drops nothing.
  static func sweepCandidates(context: ModelContext) -> [SeptenaTask] {
    let lastSweep = TaskFade.lastSweepAt
    return LocalCache.tasks(in: context, filter: .faded)
      .filter { TaskFade.isInCurrentSweep(fadedAt: $0.fadedAt, lastSweepAt: lastSweep) }
  }

  private static func weeklySweep(context: ModelContext) -> TaskNotice? {
    let candidates = sweepCandidates(context: context)
    let dates = candidates.compactMap(\.fadedAt)
    guard TaskFade.isSweepDue(now: DayClock.appNow,
                              lastSweepAt: TaskFade.lastSweepAt,
                              dismissedWeek: TaskFade.dismissedSweepWeek,
                              fadedDates: dates) else { return nil }
    let count = candidates.count
    return notice(.weeklySweep, title: RegistryNotices.weeklySweepTitle(count: count))
  }

  /// The notice on top of the Faded pile. Its action opens the same sweep
  /// sheet as the weekly prompt, so it shares the `weeklySweep` id. Copy comes
  /// from the registry (`registry/surfaces.json` `fadedPile`), so the Mac and
  /// iOS shells cannot drift.
  static var fadedPile: TaskNotice {
    guard let row = RegistryNotices.byId["fadedPile"] else {
      preconditionFailure("registry/surfaces.json has no notice fadedPile")
    }
    return TaskNotice(
      id: .weeklySweep, kind: TaskNoticeKind(registry: row.kind), symbol: row.sfSymbol,
      title: row.title ?? "",
      detail: row.detail(for: RegistryPlatform.current),
      primaryTitle: row.primaryTitle, dismissible: row.dismissible)
  }

  // MARK: - Explainers
  //
  // An explainer shows the first time the user meets a feature in the list,
  // and never again once dismissed. Add one by adding a notice to
  // `registry/surfaces.json` (copy through the humanizer pass), an `ID` case
  // and a trigger here.

  private static func explainers(pool: [SeptenaTask]) -> [TaskNotice] {
    var out: [TaskNotice] = []
    if !hasSeen(.fadeIntro), TaskRowFlags.agingEnabled,
       pool.contains(where: { $0.fadeFill() != nil }) {
      out.append(notice(.fadeIntro))
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
