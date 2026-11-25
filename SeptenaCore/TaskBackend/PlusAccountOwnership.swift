// Pure ownership check for StoreKit Plus entitlements (spec §6.4 finding 7).
//
// Kept Foundation-only so `SeptenaCoreTests` can exercise every case without
// linking StoreKit or SwiftUI.

import Foundation

/// Minimal verified StoreKit transaction data needed to check whether this
/// Apple ID's Plus subscription belongs to another Septena account.
struct StoreEntitlementSummary: Equatable, Sendable {
  let productID: String
  let appAccountToken: UUID?
}

enum PlusAccountOwnership {
  /// True when StoreKit holds an active Plus entitlement tied to a different
  /// Septena account's `appAccountToken` (and none matching `accountToken`).
  ///
  /// Returns `false` when `accountToken` is `nil` (signed out or not yet read
  /// from the server) or when a transaction carries no `appAccountToken`.
  static func isOwnedByAnotherAccount(
    entitlements: [StoreEntitlementSummary],
    plusProductIDs: [String],
    accountToken: UUID?
  ) -> Bool {
    guard let accountToken else { return false }
    let productSet = Set(plusProductIDs)
    let plusEntitlements = entitlements.filter { productSet.contains($0.productID) }
    guard !plusEntitlements.isEmpty else { return false }
    if plusEntitlements.contains(where: { $0.appAccountToken == accountToken }) {
      return false
    }
    return plusEntitlements.contains { tx in
      guard let txToken = tx.appAccountToken else { return false }
      return txToken != accountToken
    }
  }
}
