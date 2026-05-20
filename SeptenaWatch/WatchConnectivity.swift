import WatchConnectivity
import WidgetKit

@Observable
final class WatchConnectivity: NSObject, WCSessionDelegate {
  static let shared = WatchConnectivity()

  var items: [NextItem] = []
  var bucket: String = ""
  var isLoading = false
  var errorMessage: String?

  @ObservationIgnored private var actedIDs: Set<String> = []

  private static let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  private var today: String { Self.dateFmt.string(from: Date()) }

  private var storedServerURL: String? {
    get { UserDefaults.standard.string(forKey: "septena.watch.serverURL") }
    set { UserDefaults.standard.set(newValue, forKey: "septena.watch.serverURL") }
  }

  private override init() {
    super.init()
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  // MARK: - Foreground fetch (via WCSession proxy)

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
        self?.applyFetchReply(reply)
      },
      errorHandler: { [weak self] _ in
        DispatchQueue.main.async {
          self?.errorMessage = "iPhone unreachable"
          self?.isLoading = false
        }
      }
    )
  }

  // MARK: - Background fetch (direct HTTP, no WCSession)

  func fetchInBackground() async {
    guard let urlString = storedServerURL,
          let url = URL(string: "\(urlString)/api/next/items?date=\(today)")
    else { return }

    guard let (data, _) = try? await URLSession.shared.data(from: url),
          let response  = try? JSONDecoder().decode(NextItemsResponse.self, from: data)
    else { return }

    let complicationData = NextComplicationData(
      bucket: response.bucket,
      remaining: response.items.count,
      firstTitle: response.items.first?.title,
      updatedAt: Date()
    )
    complicationData.save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptenaNext")
  }

  // MARK: - Mutations

  func complete(_ item: NextItem) {
    actedIDs.insert(item.id)
    items.removeAll { $0.id == item.id }
    updateComplicationData()

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
        self?.transferIfNeeded(msg)
      }
    } else {
      transferIfNeeded(msg)
    }
  }

  // MARK: - Helpers

  private func applyFetchReply(_ reply: [String: Any]) {
    if let urlString = reply["serverURL"] as? String {
      storedServerURL = urlString
    }
    guard
      let data     = reply["items"] as? Data,
      let response = try? JSONDecoder().decode(NextItemsResponse.self, from: data)
    else {
      DispatchQueue.main.async { self.isLoading = false }
      return
    }
    DispatchQueue.main.async {
      self.items  = response.items.filter { !self.actedIDs.contains($0.id) }
      self.bucket = response.bucket
      self.isLoading = false
      self.updateComplicationData()
      scheduleNextRefresh()
    }
  }

  private func updateComplicationData() {
    NextComplicationData(
      bucket: bucket,
      remaining: items.count,
      firstTitle: items.first?.title,
      updatedAt: Date()
    ).save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptenaNext")
  }

  private func transferIfNeeded(_ msg: [String: Any]) {
    guard WCSession.default.activationState == .activated else { return }
    WCSession.default.transferUserInfo(msg)
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}
}
