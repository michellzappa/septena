import Foundation
import Testing

@Suite struct PlusAccountOwnershipTests {
  private let plusProducts = RegistryPlans.prices.map(\.productId)
  private let accountA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let accountB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  @Test func returnsTrueWhenPlusBelongsToAnotherAccount() {
    let annual = plusProducts[0]
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [StoreEntitlementSummary(productID: annual, appAccountToken: accountA)],
      plusProductIDs: plusProducts,
      accountToken: accountB
    )
    #expect(result == true)
  }

  @Test func returnsFalseWhenPlusBelongsToCurrentAccount() {
    let annual = plusProducts[0]
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [StoreEntitlementSummary(productID: annual, appAccountToken: accountA)],
      plusProductIDs: plusProducts,
      accountToken: accountA
    )
    #expect(result == false)
  }

  @Test func returnsFalseWhenCurrentAccountAlsoHoldsMatchingPlus() {
    let annual = plusProducts[0]
    let monthly = plusProducts[1]
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [
        StoreEntitlementSummary(productID: annual, appAccountToken: accountA),
        StoreEntitlementSummary(productID: monthly, appAccountToken: accountB),
      ],
      plusProductIDs: plusProducts,
      accountToken: accountB
    )
    #expect(result == false)
  }

  @Test func returnsFalseWhenSignedOutOrAccountTokenUnknown() {
    let annual = plusProducts[0]
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [StoreEntitlementSummary(productID: annual, appAccountToken: accountA)],
      plusProductIDs: plusProducts,
      accountToken: nil
    )
    #expect(result == false)
  }

  @Test func returnsFalseForUnrelatedProducts() {
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [
        StoreEntitlementSummary(productID: "com.septena.cloud.support.annual", appAccountToken: accountA),
      ],
      plusProductIDs: plusProducts,
      accountToken: accountB
    )
    #expect(result == false)
  }

  @Test func returnsFalseWhenEntitlementHasNoAccountToken() {
    let annual = plusProducts[0]
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [StoreEntitlementSummary(productID: annual, appAccountToken: nil)],
      plusProductIDs: plusProducts,
      accountToken: accountB
    )
    #expect(result == false)
  }

  @Test func returnsFalseWhenNoEntitlements() {
    let result = PlusAccountOwnership.isOwnedByAnotherAccount(
      entitlements: [],
      plusProductIDs: plusProducts,
      accountToken: accountB
    )
    #expect(result == false)
  }

  @Test func registryExposesOwnedOtherAccountCopy() {
    #expect(!RegistryPlans.Paywall.ownedOtherAccount.isEmpty)
    #expect(RegistryPlans.Paywall.ownedOtherAccount.contains("Septena"))
  }
}
