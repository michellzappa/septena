import Foundation
import WatchConnectivity

// The watch's half of the phone link (docs/WATCH.md). The phone hands over a
// backend session and pushes Today as application context; the watch asks
// for a session when it has none and nudges the phone after a change.
@MainActor
final class WatchPhoneLink: NSObject {
  static let shared = WatchPhoneLink()

  private var lastRequest: Date = .distantPast

  func start() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  /// Asks the phone for a session. Live message when the phone is reachable,
  /// else a queued transfer. Throttled: each failed fetch calls this.
  func requestSession() {
    guard Date().timeIntervalSince(lastRequest) > 20 else { return }
    lastRequest = Date()
    let s = WCSession.default
    guard s.activationState == .activated else { return }
    let message = WatchLink.message(.requestSession)
    if s.isReachable {
      s.sendMessage(message, replyHandler: nil) { _ in s.transferUserInfo(message) }
    } else {
      s.transferUserInfo(message)
    }
  }

  /// Lets an open phone app pull the change right away.
  func notifyChanged() {
    let s = WCSession.default
    guard s.activationState == .activated, s.isReachable else { return }
    s.sendMessage(WatchLink.message(.changed), replyHandler: nil, errorHandler: nil)
  }

  fileprivate func receive(kind: WatchLink.Kind?, payload: Data?) async {
    switch kind {
    case .session:
      guard let payload,
            let handoff = try? JSONDecoder.watchWire.decode(WatchSessionHandoff.self, from: payload) else { return }
      await WatchStore.shared.adopt(handoff)
    case .signedOut:
      await WatchStore.shared.signedOutOnPhone()
    default:
      break
    }
  }

  fileprivate func receive(context: [String: Any]) {
    if let data = context[WatchLink.contextTodayKey] as? Data,
       let list = try? JSONDecoder.watchWire.decode(WatchTaskList.self, from: data) {
      WatchStore.shared.adoptPhoneSnapshot(list)
    }
    if !WatchAPI.hasSession, let user = context[WatchLink.contextUserKey] as? String, !user.isEmpty {
      // The phone is signed in and we aren't: ask, even before any fetch.
      requestSession()
    }
  }
}

extension WatchPhoneLink: WCSessionDelegate {
  nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    let context = session.receivedApplicationContext
    let data = context[WatchLink.contextTodayKey] as? Data
    let user = context[WatchLink.contextUserKey] as? String
    Task { @MainActor in
      var c: [String: Any] = [:]
      if let data { c[WatchLink.contextTodayKey] = data }
      if let user { c[WatchLink.contextUserKey] = user }
      WatchPhoneLink.shared.receive(context: c)
      if !WatchAPI.hasSession { WatchPhoneLink.shared.requestSession() }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    let data = applicationContext[WatchLink.contextTodayKey] as? Data
    let user = applicationContext[WatchLink.contextUserKey] as? String
    Task { @MainActor in
      var c: [String: Any] = [:]
      if let data { c[WatchLink.contextTodayKey] = data }
      if let user { c[WatchLink.contextUserKey] = user }
      WatchPhoneLink.shared.receive(context: c)
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let kind = WatchLink.kind(of: userInfo)
    let payload = userInfo[WatchLink.payloadKey] as? Data
    Task { @MainActor in await WatchPhoneLink.shared.receive(kind: kind, payload: payload) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    let kind = WatchLink.kind(of: message)
    let payload = message[WatchLink.payloadKey] as? Data
    Task { @MainActor in await WatchPhoneLink.shared.receive(kind: kind, payload: payload) }
  }
}
