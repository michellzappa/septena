import Foundation
import WatchConnectivity

// The watch's half of the phone link (docs/WATCH.md). The phone hands over a
// backend session and pushes Today as application context; the watch asks
// for a session when it has none and nudges the phone after a change.
@MainActor
@Observable
final class WatchPhoneLink: NSObject {
  static let shared = WatchPhoneLink()

  @ObservationIgnored private var lastRequest: Date = .distantPast
  /// For the not-connected screen: when the watch last asked, and how.
  fileprivate(set) var lastAsked: String?

  func start() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  /// Asks the phone for a session. Live message when the phone is reachable,
  /// else a queued transfer. Throttled: each failed fetch calls this.
  func requestSession(force: Bool = false) {
    guard force || Date().timeIntervalSince(lastRequest) > 20 else { return }
    lastRequest = Date()
    let s = WCSession.default
    guard s.activationState == .activated else { return }
    let message = WatchLink.message(.requestSession)
    let time = Date().formatted(date: .omitted, time: .shortened)
    if s.isReachable {
      lastAsked = String(localized: "Asked iPhone at \(time)")
      s.sendMessage(message, replyHandler: { reply in
        let status = reply["status"] as? String ?? "?"
        Task { @MainActor in WatchPhoneLink.shared.lastAsked = "iPhone (\(time)): \(status)" }
      }, errorHandler: { error in
        let text = error.localizedDescription
        Task { @MainActor in WatchPhoneLink.shared.lastAsked = "Couldn't reach iPhone: \(text)" }
        s.transferUserInfo(message)
      })
    } else {
      lastAsked = String(localized: "iPhone not reachable (\(time)), queued")
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
      guard let payload else { return }
      await adoptIfNew(payload)
    case .signedOut:
      await WatchStore.shared.signedOutOnPhone()
    default:
      break
    }
  }

  private static let adoptedKey = "septena.watch.adoptedHandoffs"

  /// Adopts a handoff once. The same token arrives on up to three channels
  /// and stays in the application context after the watch has rotated it;
  /// adopting a spent token again would sign the watch out.
  private func adoptIfNew(_ payload: Data) async {
    guard let handoff = try? JSONDecoder.watchWire.decode(WatchSessionHandoff.self, from: payload) else { return }
    let print = WatchLink.fingerprint(handoff)
    var seen = UserDefaults.standard.stringArray(forKey: Self.adoptedKey) ?? []
    guard !seen.contains(print) else { return }
    seen = Array((seen + [print]).suffix(20))
    UserDefaults.standard.set(seen, forKey: Self.adoptedKey)
    await WatchStore.shared.adopt(handoff)
  }

  fileprivate func receive(context: [String: Any]) {
    if let hex = context[WatchLink.contextAccentHexKey] as? String {
      let ink = context[WatchLink.contextAccentInkHexKey] as? String
      WatchStore.shared.adoptAccent(hex: hex, inkHex: ink)
    }
    if let session = context[WatchLink.contextSessionKey] as? Data {
      Task { await adoptIfNew(session) }
    }
    if let data = context[WatchLink.contextTodayKey] as? Data,
       let list = try? JSONDecoder.watchWire.decode(WatchTaskList.self, from: data) {
      WatchStore.shared.adoptPhoneSnapshot(list)
    }
    if !WatchAPI.hasSession, context[WatchLink.contextSessionKey] == nil,
       let user = context[WatchLink.contextUserKey] as? String, !user.isEmpty {
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
    let handoff = context[WatchLink.contextSessionKey] as? Data
    let accentHex = context[WatchLink.contextAccentHexKey] as? String
    let accentInkHex = context[WatchLink.contextAccentInkHexKey] as? String
    Task { @MainActor in
      var c: [String: Any] = [:]
      if let data { c[WatchLink.contextTodayKey] = data }
      if let user { c[WatchLink.contextUserKey] = user }
      if let handoff { c[WatchLink.contextSessionKey] = handoff }
      if let accentHex { c[WatchLink.contextAccentHexKey] = accentHex }
      if let accentInkHex { c[WatchLink.contextAccentInkHexKey] = accentInkHex }
      WatchPhoneLink.shared.receive(context: c)
      if !WatchAPI.hasSession && handoff == nil { WatchPhoneLink.shared.requestSession() }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    let data = applicationContext[WatchLink.contextTodayKey] as? Data
    let user = applicationContext[WatchLink.contextUserKey] as? String
    let handoff = applicationContext[WatchLink.contextSessionKey] as? Data
    let accentHex = applicationContext[WatchLink.contextAccentHexKey] as? String
    let accentInkHex = applicationContext[WatchLink.contextAccentInkHexKey] as? String
    Task { @MainActor in
      var c: [String: Any] = [:]
      if let data { c[WatchLink.contextTodayKey] = data }
      if let user { c[WatchLink.contextUserKey] = user }
      if let handoff { c[WatchLink.contextSessionKey] = handoff }
      if let accentHex { c[WatchLink.contextAccentHexKey] = accentHex }
      if let accentInkHex { c[WatchLink.contextAccentInkHexKey] = accentInkHex }
      WatchPhoneLink.shared.receive(context: c)
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let kind = WatchLink.kind(of: userInfo)
    let payload = userInfo[WatchLink.payloadKey] as? Data
    Task { @MainActor in await WatchPhoneLink.shared.receive(kind: kind, payload: payload) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    if message[WatchLink.kindKey] as? String == "status",
       let data = message[WatchLink.payloadKey] as? Data {
      let text = String(decoding: data, as: UTF8.self)
      Task { @MainActor in WatchPhoneLink.shared.lastAsked = "iPhone: \(text)" }
      return
    }
    let kind = WatchLink.kind(of: message)
    let payload = message[WatchLink.payloadKey] as? Data
    Task { @MainActor in await WatchPhoneLink.shared.receive(kind: kind, payload: payload) }
  }
}
