#if os(iOS)
import Foundation
import SwiftData
import WatchConnectivity

// The phone's half of the Apple Watch link (docs/WATCH.md).
//
// The watch talks to the backend itself, so the phone does two small jobs:
// 1. Session handoff. The watch can't share the phone's refresh token (it is
//    single-use and rotates), so the phone mints a sibling session
//    (`TaskBackendClient.mintDeviceSession`) and sends it with
//    `transferUserInfo`, which is queued and delivered even when the watch app
//    isn't running. It does that when the watch asks, and once per account
//    when a watch app is installed. On sign-out it tells the watch to drop
//    its session.
// 2. Instant first frame. After every task change (debounced, like the
//    launch snapshot) it pushes today's rows as application context. The
//    watch shows them before its own network fetch finishes.
@MainActor
final class WatchBridge: NSObject {
  static let shared = WatchBridge()

  private static let debounce: Duration = .seconds(2)
  /// The account a session was last handed to the watch for.
  private static let deliveredKey = "septena.watch.sessionDeliveredFor"

  private var started = false
  private var pending: Task<Void, Never>?
  private var minting = false
  private var observers: [NSObjectProtocol] = []

  private override init() { super.init() }

  func start() {
    guard !started, WCSession.isSupported() else { return }
    started = true
    let session = WCSession.default
    session.delegate = self
    session.activate()
    let names: [Notification.Name] = [.septenaTasksChanged, .septenaStructureChanged, .NSCalendarDayChanged]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { WatchBridge.shared.schedulePublish() }
      })
    }
  }

  /// Sign-out, account switch or delete. Clears the watch's rows and session.
  func accountChanged() {
    UserDefaults.standard.removeObject(forKey: Self.deliveredKey)
    guard started, canTalk else { return }
    WCSession.default.transferUserInfo(WatchLink.message(.signedOut))
    publishNow()
  }

  // MARK: - Snapshot

  private var canTalk: Bool {
    let s = WCSession.default
    return s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
  }

  private var userID: String? {
    TaskBackendClient.hasSession ? UserDefaults.standard.string(forKey: TaskSyncEngine.lastUserKey) : nil
  }

  private func schedulePublish() {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      self.publishNow()
    }
  }

  private func publishNow() {
    guard canTalk else { return }
    var context: [String: Any] = [WatchLink.contextUserKey: userID ?? ""]
    if userID != nil, let data = try? JSONEncoder.watchWire.encode(todayList()) {
      context[WatchLink.contextTodayKey] = data
    }
    do { try WCSession.default.updateApplicationContext(context) } catch {
      SeptenaLog.error("[WatchBridge] context update failed", error)
    }
    deliverSessionIfNeeded()
  }

  /// The same Today the phone draws: the Inbox section, then the rest of
  /// Today (`LocalCache.todayInboxTasks` + `.today`), in the phone's order.
  private func todayList() -> WatchTaskList {
    let context = LocalStore.shared.container.mainContext
    let inbox = LocalCache.todayInboxTasks(in: context)
    let inboxIDs = Set(inbox.map(\.id))
    let rest = LocalCache.tasks(in: context, filter: .today).filter { !inboxIDs.contains($0.id) }
    let structure = StructureCache.snapshot(in: context)
    var names: [String: String] = [:]
    for a in structure.areas { names[a.id] = a.title }
    for p in structure.projects { names[p.id] = p.title }
    func row(_ t: SeptenaTask, inbox: Bool) -> WatchTask {
      WatchTask(
        id: t.id,
        title: t.title,
        notes: t.notes.map { String($0.prefix(WatchTaskList.notesPrefix)) },
        scheduled: t.scheduled,
        deadline: t.deadline,
        startTime: t.startTime,
        area: t.area.flatMap { names[$0] },
        project: t.project.flatMap { names[$0] },
        inbox: inbox ? true : nil,
        repeats: t.recurrence != nil ? true : nil,
        starred: t.starred ? true : nil)
    }
    let rows = inbox.map { row($0, inbox: true) } + rest.map { row($0, inbox: false) }
    return WatchTaskList(
      view: .today, today: SeptenaDate.today, total: rows.count,
      truncated: rows.count > WatchTaskList.rowCap ? true : nil,
      tasks: Array(rows.prefix(WatchTaskList.rowCap)), fetchedAt: .now)
  }

  // MARK: - Session handoff

  private func deliverSessionIfNeeded(force: Bool = false) {
    guard canTalk, let userID, !minting else { return }
    if !force, UserDefaults.standard.string(forKey: Self.deliveredKey) == userID { return }
    minting = true
    Task { @MainActor in
      defer { minting = false }
      do {
        let s = try await TaskBackendClient.shared.mintDeviceSession()
        let handoff = WatchSessionHandoff(refreshToken: s.refreshToken, userId: s.userId)
        let data = try JSONEncoder.watchWire.encode(handoff)
        // Drop any handoff still queued: only the newest token is valid to use.
        for transfer in WCSession.default.outstandingUserInfoTransfers
        where WatchLink.kind(of: transfer.userInfo) == .session { transfer.cancel() }
        WCSession.default.transferUserInfo(WatchLink.message(.session, payload: data))
        UserDefaults.standard.set(s.userId, forKey: Self.deliveredKey)
      } catch {
        SeptenaLog.error("[WatchBridge] device session failed", error)
      }
    }
  }

  fileprivate func handle(_ message: [String: Any]) {
    switch WatchLink.kind(of: message) {
    case .requestSession: deliverSessionIfNeeded(force: true)
    case .changed: TaskSyncEngine.shared.activate()
    default: break
    }
  }
}

extension WatchBridge: WCSessionDelegate {
  nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    Task { @MainActor in WatchBridge.shared.publishNow() }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    // Switched to another watch: activate again for the new one.
    WCSession.default.activate()
  }

  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in WatchBridge.shared.publishNow() }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    let kind = WatchLink.kind(of: message)
    Task { @MainActor in WatchBridge.shared.handle(WatchLink.message(kind ?? .changed)) }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let kind = WatchLink.kind(of: userInfo)
    Task { @MainActor in WatchBridge.shared.handle(WatchLink.message(kind ?? .changed)) }
  }
}
#endif
