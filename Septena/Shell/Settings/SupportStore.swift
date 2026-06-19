import StoreKit
import SwiftUI
import OSLog

private let supportLog = Logger(subsystem: "com.septena.cloud", category: "Support")

// SupportStore — the StoreKit 2 backing for "Support Septena" (patronage).
//
// The whole app is free; this buys NOTHING functional. Buying a tier only
// flips the cosmetic supporter state (the "Supporter" badge + avatar foil
// ring). So this store's single job is: load the three products, run a
// purchase / restore, and derive whether the user currently owns any of them
// from `Transaction.currentEntitlements`.
//
// To keep the rest of the app untouched, the derived entitlement is *mirrored*
// into the existing `SettingsKey.plusUnlocked` @AppStorage flag every cosmetic
// reader already observes — so those views need no knowledge of StoreKit.
//
// Locally (simulator / Debug) purchases resolve against Config/Septena.storekit
// wired into the scheme, so the whole flow is testable with no App Store
// Connect account. The product ids below must match that file (and, later, the
// real ASC products — they're permanent once created there).
@MainActor
@Observable
final class SupportStore {

  enum ProductID {
    static let annual   = "com.septena.cloud.support.annual"
    static let monthly  = "com.septena.cloud.support.monthly"
    static let lifetime = "com.septena.cloud.support.lifetime"
    /// Display order: annual (the highlighted default) first.
    static let all = [annual, monthly, lifetime]
  }

  /// Loaded products, in `ProductID.all` order. Empty until `start()` resolves.
  private(set) var products: [Product] = []
  /// True when the user currently owns any support product (the source of
  /// truth for the cosmetic supporter state).
  private(set) var isSupporter = false
  /// The product id of an in-flight purchase, so the screen can show a spinner
  /// on exactly that tier. `nil` when idle.
  private(set) var purchaseInFlight: String?
  /// Set when product loading fails / returns nothing (e.g. offline, or the
  /// ASC products aren't live yet) so the screen can show a graceful fallback.
  private(set) var loadFailed = false

  private var updatesTask: Task<Void, Never>?

  init() {
    // Start listening immediately so a transaction that completes outside a
    // purchase() call (Ask to Buy approval, another device, a renewal) still
    // updates entitlement. The store is an app-lifetime singleton, so this task
    // intentionally runs for the whole session (no deinit cancellation).
    updatesTask = listenForTransactions()
  }

  /// Resolve products and current entitlement. Call once at launch.
  func start() async {
    await loadProducts()
    await refreshEntitlement()
  }

  func loadProducts() async {
    do {
      let loaded = try await Product.products(for: ProductID.all)
      // Preserve our intended display order regardless of return order.
      products = ProductID.all.compactMap { id in loaded.first { $0.id == id } }
      loadFailed = products.isEmpty
    } catch {
      products = []
      loadFailed = true
    }
  }

  /// The loaded `Product` for a `SupportTier.id` ("annual"/"monthly"/"lifetime").
  func product(forTier tierID: String) -> Product? {
    products.first { $0.id == productID(forTier: tierID) }
  }

  func purchase(_ product: Product) async {
    purchaseInFlight = product.id
    defer { purchaseInFlight = nil }
    do {
      let result = try await product.purchase()
      switch result {
      case .success(let verification):
        if case .verified(let transaction) = verification {
          supportLog.log("purchase verified: \(transaction.productID, privacy: .public)")
          await transaction.finish()
          // Mark ownership straight from the verified transaction. Don't wait
          // on a `currentEntitlements` re-query — in the StoreKit test
          // environment a freshly-purchased item isn't always returned by that
          // query on the very next call, which would leave the UI unchanged.
          setSupporter(true)
          // Reconcile anyway (picks up revocation / other devices).
          await refreshEntitlement()
        } else {
          supportLog.error("purchase succeeded but failed verification")
        }
      case .pending:
        supportLog.log("purchase pending (deferred / Ask to Buy)")
      case .userCancelled:
        supportLog.log("purchase cancelled by user")
      @unknown default:
        break
      }
    } catch {
      supportLog.error("purchase threw: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Restore — re-sync the App Store account, then recompute entitlement.
  func restore() async {
    try? await AppStore.sync()
    await refreshEntitlement()
  }

  /// Recompute `isSupporter` from current entitlements and mirror it into the
  /// cosmetic `plusUnlocked` flag the rest of the app reads.
  func refreshEntitlement() async {
    var owned = false
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result else { continue }
      if ProductID.all.contains(transaction.productID),
         transaction.revocationDate == nil {
        owned = true
      }
    }
    supportLog.log("refreshEntitlement → owned=\(owned, privacy: .public)")
    // Never downgrade a just-completed purchase if the re-query lags behind in
    // the test environment; only this call can clear it once it actually sees
    // no entitlement AND we weren't mid-purchase.
    if owned || purchaseInFlight == nil {
      setSupporter(owned)
    }
  }

  // MARK: - Helpers

  /// The single place `isSupporter` changes: updates the observable property
  /// (drives in-session UI: screen dismiss, supporter section) and mirrors into
  /// the `plusUnlocked` @AppStorage flag (drives the badge + avatar ring).
  private func setSupporter(_ value: Bool) {
    isSupporter = value
    UserDefaults.standard.set(value, forKey: SettingsKey.plusUnlocked)
  }

  private func productID(forTier tierID: String) -> String {
    switch tierID {
    case "annual":   return ProductID.annual
    case "monthly":  return ProductID.monthly
    case "lifetime": return ProductID.lifetime
    default:         return tierID
    }
  }

  private func listenForTransactions() -> Task<Void, Never> {
    Task(priority: .background) { [weak self] in
      for await result in Transaction.updates {
        if case .verified(let transaction) = result {
          await transaction.finish()
        }
        await self?.refreshEntitlement()
      }
    }
  }
}
