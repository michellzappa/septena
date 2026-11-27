// Septena Plus purchases through the App Store (spec §5, §7.1, ADR 0026).
//
// The app never decides access. A purchase only becomes Plus when the server
// has verified the signed transaction (`POST /v1/entitlement/apple`) and
// `PlanStatus` reads the new plan back. This store is the one path from
// StoreKit to that call:
//
// - the Plus sheet hands it every purchase result (`handle`),
// - `start()` listens to `Transaction.updates` from launch, so a renewal, an
//   Ask to Buy approval or a purchase the server missed lands later,
// - Restore Purchases repeats the post for every current entitlement.
//
// A transaction is finished only after the server answered for it. A
// network failure keeps it unfinished, and StoreKit hands it back on the
// next launch, so the user never pays twice for a purchase the server missed.

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class PlusStore {
  static let shared = PlusStore()

  /// What the sheet shows after a purchase (registry `paywall` copy).
  enum Outcome: Equatable {
    /// The server recorded it. Plus is on.
    case success
    /// Ask to Buy or a bank check: StoreKit reports the result later.
    case pending
    /// StoreKit charged, the server could not be reached. The listener
    /// retries until it answers.
    case serverRetry
    /// StoreKit failed or the server refused the transaction.
    case failed
  }

  private(set) var outcome: Outcome?
  private(set) var restoring = false
  private var listener: Task<Void, Never>?

  private init() {}

  /// Every product the sheet sells, Plus (subscriptions + 7-Year Pass, ADR 0061)
  /// and Pro, from `registry/plans.json` (ADR 0059).
  static var productIDs: [String] { PlanTier.allCases.flatMap(\.productIDs) + [RegistryPlans.pass.productId] }

  /// The sheet offers a purchase when checkout is open on a build the App
  /// Store sold, or in a run Xcode launched with the `Septask` scheme, where
  /// `Config/Septena.storekit` stands in for App Store Connect (the scheme
  /// sets `SEPTENA_STOREKIT_TEST`). The Mac sells through the Mac App Store
  /// like the iPhone (ADR 0026).
  static var checkoutAvailable: Bool {
    if ProcessInfo.processInfo.environment["SEPTENA_STOREKIT_TEST"] == "1" { return true }
    return RegistryPlans.checkoutOpen && !isDirectDownload
  }

  /// The Mac download from GitHub (Developer ID, Sparkle updates): it has
  /// no App Store receipt, so StoreKit cannot complete a purchase there
  /// (#683). It signs in to the same account and gets the account's plan,
  /// wherever the plan was bought; the sheet points to the App Store
  /// version instead of selling. The Mac App Store build drops Sparkle and
  /// its feed key (#266).
  static var isDirectDownload: Bool {
    #if os(macOS)
    guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return false }
    guard let receipt = Bundle.main.appStoreReceiptURL else { return true }
    return !FileManager.default.fileExists(atPath: receipt.path)
    #else
    return false
    #endif
  }

  /// Starts the transaction listener once per process. Call at launch.
  func start() {
    guard listener == nil else { return }
    listener = Task { [weak self] in
      // A purchase the server missed on an earlier run, then everything new.
      for await result in Transaction.unfinished { await self?.deliver(result) }
      for await result in Transaction.updates { await self?.deliver(result) }
    }
  }

  /// The options every purchase carries: the account's token, so the
  /// transaction belongs to the account, not to the device (spec §5).
  func purchaseOptions() -> Set<Product.PurchaseOption> {
    guard let token = PlanStatus.shared.appAccountToken else { return [] }
    return [.appAccountToken(token)]
  }

  func clearOutcome() { outcome = nil }

  /// The result of a purchase the Plus sheet started.
  func handle(_ result: Result<Product.PurchaseResult, Error>) async {
    switch result {
    case .success(.success(let verification)):
      switch await deliver(verification) {
      case .recorded: outcome = .success
      case .retryLater: outcome = .serverRetry
      case .refused:
        // If StoreKit holds Plus for another Septena account, leave outcome
        // clear so the sheet shows the wrong-account message instead of a
        // generic failure (spec §6.4 finding 7).
        outcome = PlanStatus.shared.plusOwnedByAnotherAccount ? nil : .failed
      }
    case .success(.pending):
      outcome = .pending
    case .success(.userCancelled):
      outcome = nil
    case .success:
      outcome = nil
    case .failure:
      outcome = .failed
    }
  }

  /// Restore Purchases: asks the App Store for the account's transactions,
  /// then posts each current one to the server.
  func restore() async {
    restoring = true
    defer { restoring = false }
    try? await AppStore.sync()
    for await result in Transaction.currentEntitlements { await deliver(result) }
    await PlanStatus.shared.refresh()
  }

  private enum Delivery { case recorded, retryLater, refused }

  /// Posts one transaction to the server and finishes it once the server
  /// has answered for good.
  @discardableResult
  private func deliver(_ result: VerificationResult<Transaction>) async -> Delivery {
    // StoreKit could not verify it on the device: never grant, never post.
    guard case .verified(let transaction) = result else { return .refused }
    guard Self.productIDs.contains(transaction.productID) else { return .refused }
    // Signed out: keep it. It is posted after the next sign-in.
    guard TaskBackendClient.hasSession else { return .retryLater }
    do {
      let status = try await TaskBackendClient.shared.postAppleTransaction(signedTransaction: result.jwsRepresentation)
      switch status {
      case 200:
        await transaction.finish()
        await PlanStatus.shared.refresh()
        return .recorded
      case 403:
        await transaction.finish()
        await PlanStatus.shared.refresh()
        return .refused
      case 400, 422:
        // The server will never accept this one (bad signature, a product it
        // does not sell). Finishing it does not end the subscription; it stops
        // StoreKit from handing it back forever.
        await transaction.finish()
        return .refused
      default:
        return .retryLater
      }
    } catch {
      return .retryLater
    }
  }
}

/// The two paid plans the sheet sells (ADR 0059). Plus is every device;
/// Pro is every agent. Words, prices and rows come from `registry/plans.json`.
enum PlanTier: String, CaseIterable, Identifiable, Sendable {
  case plus, pro

  var id: String { rawValue }

  /// The short name on the plan picker ("Plus", "Pro").
  var title: String {
    switch self {
    case .plus: return RegistryPlans.shortName
    case .pro: return RegistryPlans.proName
    }
  }

  var card: RegistryPlanCard? {
    switch self {
    case .plus: return RegistryPlans.card("plus")
    case .pro: return RegistryPlans.proCard
    }
  }

  var prices: [RegistryPlanPrice] {
    switch self {
    case .plus: return RegistryPlans.prices
    case .pro: return RegistryPlans.proPrices
    }
  }

  var productIDs: [String] { prices.map(\.productId) }

  /// This plan's value in a comparison row.
  func cell(_ row: RegistryPlanRow) -> RegistryPlanCell {
    switch self {
    case .plus: return row.plus
    case .pro: return row.pro
    }
  }

  /// The rows every plan card lists (`cardRows`): the lines that set the
  /// plans apart.
  static var cardRows: [RegistryPlanRow] {
    let all = RegistryPlans.outcomes.flatMap(\.rows)
    return RegistryPlans.cardRowIDs.compactMap { id in all.first { $0.id == id } }
  }

  /// The plan the sheet opens on. A Plus account looks at Pro, the plan
  /// above it. Otherwise the moment that opened the sheet names the plan
  /// that answers it (`upsells[].plan`); with no moment, Plus.
  @MainActor
  static func recommended(upsellID: String?, status: PlanStatus) -> PlanTier {
    if case .plus = status.plan, !status.isPro { return .pro }
    if let id = upsellID, let plan = RegistryPlans.upsell(id)?.plan, let tier = PlanTier(rawValue: plan) {
      return tier
    }
    return .plus
  }
}
