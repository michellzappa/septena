// The plan sheet: the one place in the app that sells Septena Plus and Pro
// (docs/SYNC_SUBSCRIPTION_SPEC.md §7.1, ADR 0026, ADR 0059).
//
// It opens only from a tap: "See Plus" on an upsell moment (§3.2), on the
// trial-end notice, on a full agent list, or on Settings ▸ Septena Plus.
// Never on launch, never on a timer. Every word comes from
// `registry/plans.json` (`RegistryPlans`).
//
// The sheet sells in context:
// - the moment that opened it comes first, title and detail, so the reader
//   sees why the sheet is there before any price;
// - it opens on the plan that answers that moment (`upsells[].plan`), and an
//   account on Plus opens on Pro, the plan above it;
// - the picked plan shows its mark, wordmark and benefits in the premium
//   language (docs/PREMIUM_LANGUAGE.md), one benefit per line;
// - the price comes last, from StoreKit, with cancel-anytime and the
//   no-hostage promise under it.
//
// The purchase UI is StoreKit's own `SubscriptionStoreView`: it draws the
// products, the localized prices and periods and the purchase button. The
// sheet adds the pitch and the plan states, and hands every result to
// `PlusStore`, which posts it to the server before anything turns on.

import StoreKit
import SwiftUI

struct SeptaskPlusSheet: View {
  /// The upsell moment that opened the sheet (`RegistryPlans.upsell(_:)`).
  var upsellID: String?
  /// Closes the sheet where SwiftUI's `dismiss` does not reach: the AppKit
  /// shell presents it from an `NSHostingController`.
  var onClose: (() -> Void)? = nil
  /// The plan to open on, when the caller already knows it (a plan card's
  /// button). Else the moment's plan (`PlanTier.recommended`).
  var initialTier: PlanTier? = nil

  @Environment(\.dismiss) private var dismiss
  /// The plan the reader picked; nil until they pick one.
  @State private var picked: PlanTier?
  private var status: PlanStatus { .shared }
  private var store: PlusStore { .shared }

  private func close() {
    if let onClose { onClose() } else { dismiss() }
  }

  /// The plans this account can buy: both, or only Pro for an account on
  /// Plus (an upgrade in the same subscription group).
  private var tiers: [PlanTier] {
    if case .plus = status.plan { return [.pro] }
    return PlanTier.allCases
  }

  /// The picked plan, else the recommended one, limited to `tiers`. The
  /// plan state is read here, on the main actor, not inside the binding.
  private var selection: Binding<PlanTier> {
    let allowed = tiers
    let chosen = picked ?? initialTier ?? PlanTier.recommended(upsellID: upsellID, status: status)
    let tier = allowed.contains(chosen) ? chosen : allowed[0]
    return Binding(get: { tier }, set: { picked = $0 })
  }

  /// An account on Plus through the App Store or a grant can move to Pro
  /// here. Plus bought on Google Play or the web changes plan there, so the
  /// account never pays twice (ADR 0026).
  private var canUpgrade: Bool {
    guard case .plus(_, let source) = status.plan, !status.isPro else { return false }
    guard source == "apple" || source == "grant" else { return false }
    return PlusStore.checkoutAvailable && status.appAccountToken != nil && !status.plusOwnedByAnotherAccount
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(status.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(RegistryPlans.Action.notNow) { close() }
          }
        }
    }
    #if os(macOS)
    .frame(minWidth: 440, minHeight: 600)
    #endif
    // Again after a sign-in from inside the sheet: the server starts the
    // trial on the first sign-in, and the sheet then shows the store.
    .task(id: TaskSyncEngine.shared.signedIn) { await status.refresh() }
    .onDisappear { store.clearOutcome() }
  }

  @ViewBuilder
  private var content: some View {
    if let outcome = store.outcome {
      PlusOutcomeView(outcome: outcome) { close() }
    } else {
      switch status.plan {
      case .plus(_, let source):
        if canUpgrade {
          storeView(upgrade: true)
        } else {
          PlusOwnedView(source: source)
        }
      case .free, .trial:
        if !status.plusOwnedByAnotherAccount, PlusStore.checkoutAvailable, status.canPurchase {
          storeView(upgrade: false)
        } else {
          PlusInfoView(upsellID: upsellID, tiers: tiers, selection: selection, onSynced: close)
        }
      case .device, nil:
        PlusInfoView(upsellID: upsellID, tiers: tiers, selection: selection, onSynced: close)
      }
    }
  }

  /// StoreKit's subscription store for the picked plan, with the pitch on
  /// top. It is rebuilt when the plan changes, so it lists only that plan's
  /// two prices.
  private func storeView(upgrade: Bool) -> some View {
    SubscriptionStoreView(productIDs: selection.wrappedValue.productIDs) {
      PlanPitch(upsellID: upsellID, tiers: tiers, selection: selection, upgrade: upgrade && status.hasAppleSubscription, onSynced: close)
    }
    .id(selection.wrappedValue)
    .subscriptionStoreControlStyle(.picker)
    .subscriptionStoreButtonLabel(.action)
    // Restore goes through PlusStore, which posts every transaction to the
    // server; StoreKit's own button would only sync with the App Store.
    .storeButton(.hidden, for: .restorePurchases)
    .storeButton(.visible, for: .policies)
    .subscriptionStorePolicyDestination(url: RegistryPlans.termsURL, for: .termsOfService)
    .subscriptionStorePolicyDestination(url: RegistryPlans.privacyURL, for: .privacyPolicy)
    .inAppPurchaseOptions { _ in await PlusStore.shared.purchaseOptions() }
    .onInAppPurchaseCompletion { _, result in await PlusStore.shared.handle(result) }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 6) {
        PlanTrustLine()
        PlusRestoreButton()
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.bottom, 8)
    }
  }
}

/// The top of the sheet, in the order a reader decides: why the sheet
/// opened, which plan, what that plan changes for this account.
private struct PlanPitch: View {
  var upsellID: String?
  var tiers: [PlanTier]
  @Binding var selection: PlanTier
  var upgrade = false
  /// Runs after this device took the sync slot; the sheet then closes.
  var onSynced: () -> Void = {}
  private var status: PlanStatus { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      reason
      // The second-device moment also offers the free way out: move the
      // free account's one sync slot to this device (spec §3.2, §6.3).
      if upsellID == "second_device", status.deviceNotSyncing {
        SyncThisDeviceButton(onSynced: onSynced)
      }
      if tiers.count > 1 {
        Picker(RegistryPlans.Paywall.choosePlan, selection: $selection) {
          ForEach(tiers) { tier in Text(tier.title).tag(tier) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      // The picked plan: its mark and wordmark, then what it gives, one
      // benefit per line (docs/PREMIUM_LANGUAGE.md).
      PlanHead(tier: selection, line: selection.card?.detail, markSize: 44)
      VStack(alignment: .leading, spacing: 12) {
        ForEach(selection.benefits) { PlanBenefitRow(benefit: $0) }
      }
      if upgrade {
        Text(RegistryPlans.Paywall.upgradeNote).font(.footnote).foregroundStyle(.secondary)
      }
      if case .trial(let end) = status.plan {
        VStack(alignment: .leading, spacing: 4) {
          Text(RegistryPlans.Paywall.trialStarted(date: end.formatted(date: .abbreviated, time: .omitted)))
            .font(.subheadline.weight(.semibold))
          if !status.plusOwnedByAnotherAccount {
            Text(RegistryPlans.Paywall.trialBilling).font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
  }

  /// Why the sheet is open: the moment, else the plan ladder's headline.
  @ViewBuilder
  private var reason: some View {
    if let id = upsellID, let moment = RegistryPlans.upsell(id) {
      VStack(alignment: .leading, spacing: 4) {
        Text(moment.title).font(.title3.weight(.semibold))
        Text(moment.detail).foregroundStyle(.secondary)
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.weight(.bold))
        Text(RegistryPlans.headline).font(.title3).foregroundStyle(.secondary)
      }
    }
  }

  private var title: String {
    if case .free(lapsed: true) = status.plan { return RegistryPlans.Paywall.welcomeBack }
    return RegistryPlans.name
  }
}

/// The reassurance under the price: cancel at any time, and nothing is held
/// back when a plan ends (`promises`).
private struct PlanTrustLine: View {
  var body: some View {
    VStack(spacing: 2) {
      Text(RegistryPlans.Paywall.cancelNote)
      if let promise = RegistryPlans.promises.first(where: { $0.id == "no_hostage" }) {
        Text(promise.title)
      }
    }
    .multilineTextAlignment(.center)
  }
}

/// The sheet when it cannot sell here: signed out (the trial is the offer),
/// this Apple ID's Plus belongs to another Septena account (spec §6.4
/// finding 7), the Mac download build (#683), or before checkout opens.
/// It still shows the same pitch and the picked plan's prices.
private struct PlusInfoView: View {
  var upsellID: String?
  var tiers: [PlanTier]
  @Binding var selection: PlanTier
  var onSynced: () -> Void = {}
  private var status: PlanStatus { .shared }

  init(upsellID: String?, tiers: [PlanTier], selection: Binding<PlanTier>, onSynced: @escaping () -> Void = {}) {
    self.upsellID = upsellID
    self.tiers = tiers
    self._selection = selection
    self.onSynced = onSynced
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PlanPitch(upsellID: upsellID, tiers: tiers, selection: $selection, onSynced: onSynced)
        if !status.plusOwnedByAnotherAccount {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(selection.prices) { price in
              VStack(alignment: .leading, spacing: 2) {
                Text(price.label).font(.body.weight(price.highlighted ? .semibold : .regular))
                Text(price.detail).font(.subheadline).foregroundStyle(.secondary)
              }
            }
          }
          .padding(.horizontal)
        }
        VStack(alignment: .leading, spacing: 10) {
          if status.plusOwnedByAnotherAccount {
            Text(RegistryPlans.Paywall.ownedOtherAccount)
          } else if status.plan == .device || status.plan == nil {
            Text(RegistryPlans.Paywall.startTrial).font(.headline)
            Text(RegistryPlans.trialDetail).font(.subheadline).foregroundStyle(.secondary)
            SeptaskSignInButton()
          } else if RegistryPlans.checkoutOpen, PlusStore.isDirectDownload {
            Text(RegistryPlans.Paywall.buyElsewhere).font(.subheadline).foregroundStyle(.secondary)
          } else {
            Text(RegistryPlans.checkoutNotice).font(.subheadline).foregroundStyle(.secondary)
          }
          PlanTrustLine().font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
      }
      .padding(.bottom)
    }
  }
}

/// The sheet for an account already on Plus: where it is managed, and no
/// second purchase (ADR 0026).
private struct PlusOwnedView: View {
  let source: String

  var body: some View {
    VStack(spacing: 16) {
      PlanMark(tier: PlanStatus.shared.isPro ? .pro : .plus, size: 64)
      PlanWordmark(tier: PlanStatus.shared.isPro ? .pro : .plus)
      Text(line).multilineTextAlignment(.center)
      // Plus bought on Google Play or the web moves to Pro where it was
      // bought (ADR 0026: no second purchase for the same account).
      if !PlanStatus.shared.isPro, source == "google" || source == "stripe" {
        Text(RegistryPlans.Paywall.upgradeElsewhere)
          .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      // A grant can sit on top of a paid App Store subscription (Pro on a
      // paid Plus). The subscription still renews, so Manage stays here.
      if source == "apple" || PlanStatus.shared.hasAppleSubscription {
        ManageSubscriptionButton().buttonStyle(.borderedProminent)
      }
      PlusRestoreButton().font(.footnote)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var line: String {
    switch source {
    case "apple": return RegistryPlans.Paywall.ownedApple
    case "stripe": return RegistryPlans.Paywall.ownedWeb
    case "google": return RegistryPlans.Paywall.ownedGoogle
    default: return PlanStatus.shared.isPro ? RegistryPlans.Paywall.ownedGrantPro : RegistryPlans.Paywall.ownedGrant
    }
  }
}

/// Manage Subscription for an App Store subscription: the system sheet on
/// iOS, the App Store's subscriptions page on macOS (it has no sheet).
struct ManageSubscriptionButton: View {
  @State private var managing = false

  var body: some View {
    #if os(iOS)
    Button(RegistryPlans.Action.manage) { managing = true }
      .manageSubscriptionsSheet(isPresented: $managing)
    #else
    Link(RegistryPlans.Action.manage, destination: URL(string: "macappstores://apps.apple.com/account/subscriptions")!)
    #endif
  }
}

/// What happened after the purchase.
private struct PlusOutcomeView: View {
  let outcome: PlusStore.Outcome
  let done: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint)
      Text(line).multilineTextAlignment(.center)
      if outcome == .failed {
        Button(RegistryPlans.Action.subscribe) { PlusStore.shared.clearOutcome() }
      } else {
        Button(RegistryPlans.Paywall.done, action: done).buttonStyle(.borderedProminent)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var line: String {
    switch outcome {
    case .success: return RegistryPlans.Paywall.success
    case .pending: return RegistryPlans.Paywall.pending
    case .serverRetry: return RegistryPlans.Paywall.serverRetry
    case .failed: return RegistryPlans.Paywall.failed
    }
  }

  private var symbol: String {
    switch outcome {
    case .success: return "checkmark.circle.fill"
    case .pending, .serverRetry: return "clock"
    case .failed: return "exclamationmark.circle"
    }
  }
}

/// Restore Purchases, through `PlusStore` so the server sees every
/// transaction.
private struct PlusRestoreButton: View {
  var body: some View {
    Button(RegistryPlans.Action.restore) {
      Task { await PlusStore.shared.restore() }
    }
    .disabled(PlusStore.shared.restoring || !TaskBackendClient.hasSession)
  }
}

/// Moves the free account's sync slot to this device
/// (`POST /v1/entitlement/device`). The other device stops syncing and keeps
/// its tasks. Shown for the `second_device` moment only: in the Plus sheet
/// and as the quiet line in Settings ▸ Septena Plus.
struct SyncThisDeviceButton: View {
  var onSynced: () -> Void = {}
  @State private var working = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(RegistryPlans.Action.syncThisDevice) {
        working = true
        failed = false
        Task {
          let moved = await PlanStatus.shared.syncThisDevice()
          working = false
          failed = !moved
          if moved { onSynced() }
        }
      }
      .buttonStyle(.bordered)
      .disabled(working)
      if failed {
        Text(PlanStatus.shared.syncThisDeviceLimitMessage ?? RegistryPlans.Paywall.syncThisDeviceFailed)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}

#if os(macOS)
import AppKit

extension SeptaskPlusSheet {
  /// Presents the sheet from the AppKit shell (an `NSViewController`), for
  /// an upsell moment. Marks the moment seen first: opening the sheet from
  /// the moment counts as seeing it (spec §7.1).
  @MainActor
  static func present(upsellID: String, from presenter: NSViewController) {
    TaskNotices.markUpsellSeen(upsellID)
    var host: NSHostingController<AnyView>?
    let sheet = SeptaskPlusSheet(upsellID: upsellID, onClose: { [weak presenter] in
      if let host { presenter?.dismiss(host) }
    })
    let controller = NSHostingController(rootView: AnyView(sheet))
    host = controller
    presenter.presentAsSheet(controller)
  }
}
#endif
