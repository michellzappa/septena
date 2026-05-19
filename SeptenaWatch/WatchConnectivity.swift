import WatchConnectivity

@Observable
final class WatchConnectivity: NSObject, WCSessionDelegate {
  static let shared = WatchConnectivity()

  var items: [NextItem] = []
  var bucket: String = ""
  var isLoading = false
  var errorMessage: String?

  // IDs acted on this session — keeps optimistic removes stable across reload.
  @ObservationIgnored private var actedIDs: Set<String> = []

  private static let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  private var today: String { Self.dateFmt.string(from: Date()) }

  private override init() {
    super.init()
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func fetchNext() {
    guard WCSession.default.isReachable else {
      errorMessage = "Open Septena on your iPhone"
      isLoading = false
      return
    }
    isLoading = true
    errorMessage = nil
    WCSession.default.sendMessage(
      ["action": "fetchNext", "date": today],
      replyHandler: { [weak self] reply in
        guard let self else { return }
        guard
          let data = reply["items"] as? Data,
          let response = try? JSONDecoder().decode(NextItemsResponse.self, from: data)
        else {
          DispatchQueue.main.async { self.isLoading = false }
          return
        }
        DispatchQueue.main.async {
          self.items = response.items.filter { !self.actedIDs.contains($0.id) }
          self.bucket = response.bucket
          self.isLoading = false
        }
      },
      errorHandler: { [weak self] error in
        DispatchQueue.main.async {
          self?.errorMessage = "iPhone unreachable"
          self?.isLoading = false
        }
      }
    )
  }

  func complete(_ item: NextItem) {
    actedIDs.insert(item.id)
    items.removeAll { $0.id == item.id }

    var msg: [String: Any] = ["id": item.id, "date": today]
    switch item.kind {
    case "habit":
      msg["action"] = "toggleHabit"
      msg["done"] = true
    case "supplement":
      msg["action"] = "toggleSupplement"
      msg["done"] = true
    default:
      msg["action"] = "completeChore"
    }

    if WCSession.default.isReachable {
      WCSession.default.sendMessage(msg, replyHandler: { _ in }) { [weak self] _ in
        // Phone wasn't reachable in time — queue for background delivery.
        self?.transferIfNeeded(msg)
      }
    } else {
      transferIfNeeded(msg)
    }
  }

  private func transferIfNeeded(_ msg: [String: Any]) {
    guard WCSession.default.activationState == .activated else { return }
    WCSession.default.transferUserInfo(msg)
  }

  // MARK: WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}
}
