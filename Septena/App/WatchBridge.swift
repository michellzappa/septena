#if os(iOS)
import WatchConnectivity

/// iPhone side of the watch ↔ phone WCSession channel.
/// Receives fetch/mutation messages from SeptenaWatch, answers reads from
/// the client, and routes checklist writes through the shared CloudKit
/// mutation stack so the watch doesn't keep a hidden FastAPI write path.
final class WatchBridge: NSObject, WCSessionDelegate {
  static let shared = WatchBridge()

  private override init() {
    super.init()
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    Task { await handle(message, replyHandler: replyHandler) }
  }

  // Queued mutations sent when the phone wasn't reachable.
  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    Task { await handle(userInfo, replyHandler: { _ in }) }
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}

  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) {
    WCSession.default.activate()
  }

  // MARK: - Message dispatch

  private func handle(
    _ msg: [String: Any],
    replyHandler: ([String: Any]) -> Void
  ) async {
    guard let action = msg["action"] as? String else {
      replyHandler(["error": "missing action"])
      return
    }
    let client = await MainActor.run { ClientProvider.shared.client }
    let services = await MainActor.run { SeptenaServices.shared }
    let date   = msg["date"] as? String ?? SeptenaDate.today
    let id     = msg["id"]   as? String ?? ""

    do {
      switch action {
      case "fetchNext":
        let response  = try await client.nextItems(date: date)
        let data      = try JSONEncoder().encode(response)
        let serverURL = UserDefaults.standard.string(forKey: "septena.serverURL")
                        ?? SeptenaClient.default.absoluteString
        replyHandler(["items": data, "serverURL": serverURL])

      case "toggleHabit":
        let done = msg["done"] as? Bool ?? true
        await services.start()
        await MainActor.run {
          services.checklistMutator.toggleHabit(id: id, date: date, done: done)
        }
        replyHandler(["ok": true])

      case "toggleSupplement":
        let done = msg["done"] as? Bool ?? true
        await services.start()
        await MainActor.run {
          services.checklistMutator.toggleSupplement(id: id, date: date, done: done)
        }
        replyHandler(["ok": true])

      case "completeChore":
        await services.start()
        await MainActor.run {
          services.checklistMutator.completeChore(id: id, date: date)
        }
        replyHandler(["ok": true])

      default:
        replyHandler(["error": "unknown action: \(action)"])
      }
    } catch {
      replyHandler(["error": error.localizedDescription])
    }
  }
}
#endif
