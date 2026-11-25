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
@Observable
final class WatchBridge: NSObject {
  static let shared = WatchBridge()

  /// What Settings ▸ Apple Watch shows.
  struct WatchState: Equatable {
    var supported = false
    var paired = false
    var installed = false
    var reachable = false
  }
  private(set) var state = WatchState()
  private(set) var lastHandoff: Date? = UserDefaults.standard.object(forKey: "septena.watch.lastHandoff") as? Date
  private(set) var lastError: String?

  private static let debounce: Duration = .seconds(2)
  /// The account a session was last handed to the watch for.
  private static let deliveredKey = "septena.watch.sessionDeliveredFor"

  @ObservationIgnored private var started = false
  @ObservationIgnored private var pending: Task<Void, Never>?
  private(set) var minting = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// The newest handoff, re-sent in every context update until the account
  /// changes. Memory only: after a relaunch the watch asks again if needed.
  @ObservationIgnored private var handoffData: Data?

  private override init() { super.init() }

  func start() {
    guard !started, WCSession.isSupported() else { return }
    started = true
    let session = WCSession.default
    session.delegate = self
    session.activate()
    let names: [Notification.Name] = [.septenaTasksChanged, .septenaStructureChanged, .septenaAppearanceChanged, .NSCalendarDayChanged]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { WatchBridge.shared.schedulePublish() }
      })
    }
  }

  /// App came to the foreground: refresh the watch's context, and hand over
  /// a session if this account never did.
  func appDidBecomeActive() {
    guard started else { return }
    publishNow()
  }

  /// Re-reads pairing / install state (Settings calls it on appear).
  func refreshState() {
    guard WCSession.isSupported() else { state = WatchState(); return }
    let s = WCSession.default
    let activated = s.activationState == .activated
    state = WatchState(supported: true,
                       paired: activated && s.isPaired,
                       installed: activated && s.isWatchAppInstalled,
                       reachable: activated && s.isReachable)
  }

  /// Settings ▸ Apple Watch ▸ Reconnect: mint and send a fresh session.
  func reconnect() {
    refreshState()
    deliverSessionIfNeeded(force: true)
    publishNow()
  }

  /// Sign-out, account switch or delete. Clears the watch's rows and session.
  func accountChanged() {
    UserDefaults.standard.removeObject(forKey: Self.deliveredKey)
    handoffData = nil
    guard started, canTalk else { return }
    WCSession.default.transferUserInfo(WatchLink.message(.signedOut))
    publishNow()
  }

  // MARK: - Snapshot

  private var canTalk: Bool {
    let s = WCSession.default
    return s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
  }

  /// The signed-in account, or nil. An account signed in before the sync
  /// engine recorded `lastUserKey` still counts as signed in.
  private var userID: String? {
    guard TaskBackendClient.hasSession else { return nil }
    return UserDefaults.standard.string(forKey: TaskSyncEngine.lastUserKey) ?? "signed-in"
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
    publishContext()
    deliverSessionIfNeeded()
  }

  private func publishContext() {
    refreshState()
    let s = WCSession.default
    guard s.activationState == .activated, s.isPaired else { return }
    let fruit = AppearancePreferences.shared.currentFruit
    var context: [String: Any] = [
      WatchLink.contextUserKey: userID ?? "",
      WatchLink.contextAccentHexKey: fruit.darkHex,
      WatchLink.contextAccentInkHexKey: fruit.checkDarkHex,
    ]
    if userID != nil, let data = try? JSONEncoder.watchWire.encode(todayList()) {
      context[WatchLink.contextTodayKey] = data
      if let handoffData { context[WatchLink.contextSessionKey] = handoffData }
    }
    do { try WCSession.default.updateApplicationContext(context) } catch {
      SeptenaLog.error("[WatchBridge] context update failed", error)
    }
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

  /// `force` = the watch asked: it is installed by definition, whatever
  /// `isWatchAppInstalled` says (it lags, and stays false for a side-loaded
  /// debug build).
  @discardableResult
  private func deliverSessionIfNeeded(force: Bool = false) -> String {
    let s = WCSession.default
    guard s.activationState == .activated else { return "link not active" }
    guard force || canTalk else { return "watch app not installed" }
    guard !minting else { return "already sending" }
    guard let userID else {
      lastError = String(localized: "Sign in to Septena on this iPhone first.")
      return "iPhone not signed in"
    }
    if !force, UserDefaults.standard.string(forKey: Self.deliveredKey) == userID { return "already sent" }
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
        // Three channels, fastest first; the watch adopts each token once.
        let message = WatchLink.message(.session, payload: data)
        handoffData = data
        let session = WCSession.default
        if session.isReachable {
          session.sendMessage(message, replyHandler: nil) { _ in
            Task { @MainActor in WCSession.default.transferUserInfo(message) }
          }
        } else {
          session.transferUserInfo(message)
        }
        // The same value the check above reads: `userID` is not `s.userId` for
        // an account signed in before `lastUserKey`, and a mismatch minted a
        // new session at every publish.
        UserDefaults.standard.set(userID, forKey: Self.deliveredKey)
        lastHandoff = .now
        lastError = nil
        UserDefaults.standard.set(lastHandoff, forKey: "septena.watch.lastHandoff")
        publishContext()
      } catch {
        lastError = error.localizedDescription
        SeptenaLog.error("[WatchBridge] device session failed", error)
        sendStatus("sign-in failed: \(error.localizedDescription)")
      }
    }
    return "sending sign-in"
  }

  /// A one-line status for the watch's not-connected screen.
  private func sendStatus(_ text: String) {
    let s = WCSession.default
    guard s.activationState == .activated, s.isReachable else { return }
    s.sendMessage([WatchLink.kindKey: "status", WatchLink.payloadKey: Data(text.utf8)], replyHandler: nil, errorHandler: nil)
  }

  @discardableResult
  fileprivate func handle(_ message: [String: Any]) -> String {
    switch WatchLink.kind(of: message) {
    case .requestSession: return deliverSessionIfNeeded(force: true)
    case .changed: TaskSyncEngine.shared.activate(); return "ok"
    default: return "ok"
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

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in WatchBridge.shared.refreshState() }
  }

  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in WatchBridge.shared.publishNow() }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                           replyHandler: @escaping ([String: Any]) -> Void) {
    let kind = WatchLink.kind(of: message)
    nonisolated(unsafe) let reply = replyHandler
    Task { @MainActor in
      let status = WatchBridge.shared.handle(WatchLink.message(kind ?? .changed))
      reply(["status": status])
    }
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
