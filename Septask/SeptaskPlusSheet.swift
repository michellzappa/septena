// The Plus sheet: the one place in the app that sells Septena Plus
// (docs/SYNC_SUBSCRIPTION_SPEC.md §7.1, ADR 0026).
//
// It opens only from a tap: "See Plus" on an upsell moment (§3.2), on the
// trial-end notice, or on Settings ▸ Septena Plus. Never on launch, never
// on a timer. Every word comes from `registry/plans.json` (`RegistryPlans`).
//
// The purchase UI is StoreKit's own `SubscriptionStoreView`: it draws the
// products, the localized prices and periods and the purchase button. The
// sheet adds the header, the plan states, and hands every result to
// `PlusStore`, which posts it to the server before anything turns on.

import StoreKit
import SwiftUI

struct SeptaskPlusSheet: View {
  /// The upsell moment that opened the sheet (`RegistryPlans.upsell(_:)`),
  /// shown as the first line so the user sees why it opened.
  var upsellID: String?
  /// Closes the sheet where SwiftUI's `dismiss` does not reach: the AppKit
  /// shell presents it from an `NSHostingController`.
  var onClose: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  private var status: PlanStatus { .shared }
  private var store: PlusStore { .shared }

  private func close() {
    if let onClose { onClose() } else { dismiss() }
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(RegistryPlans.name)
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
    .frame(minWidth: 420, minHeight: 560)
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
        PlusOwnedView(source: source)
      case .free, .trial:
        if status.plusOwnedByAnotherAccount {
          PlusInfoView(upsellID: upsellID, onSynced: close)
        } else if PlusStore.checkoutAvailable, status.canPurchase {
          storeView
        } else {
          PlusInfoView(upsellID: upsellID, onSynced: close)
        }
      case .device, nil:
        PlusInfoView(upsellID: upsellID, onSynced: close)
      }
    }
  }

  /// StoreKit's subscription store, with the registry header on top.
  private var storeView: some View {
    SubscriptionStoreView(productIDs: PlusStore.productIDs) {
      PlusSheetHeader(upsellID: upsellID, onSynced: close)
    }
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
        Text(RegistryPlans.Paywall.cancelNote)
        PlusRestoreButton()
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.bottom, 8)
    }
  }
}

/// The top of the sheet: why it opened, the name, the headline and the three
/// outcomes.
private struct PlusSheetHeader: View {
  var upsellID: String?
  /// Runs after this device took the sync slot; the sheet then closes.
  var onSynced: () -> Void = {}
  private var status: PlanStatus { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let id = upsellID, let moment = RegistryPlans.upsell(id) {
        Text(moment.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      }
      // The second-device moment also offers the free way out: move the
      // free account's one sync slot to this device (spec §3.2, §6.3).
      if upsellID == "second_device", status.deviceNotSyncing {
        SyncThisDeviceButton(onSynced: onSynced)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.weight(.bold))
        Text(RegistryPlans.headline).font(.title3)
      }
      VStack(alignment: .leading, spacing: 10) {
        ForEach(RegistryPlans.outcomes) { outcome in
          Label(outcome.title, systemImage: RegistryIcons.sfSymbols[outcome.icon] ?? "circle")
        }
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

  private var title: String {
    if case .free(lapsed: true) = status.plan { return RegistryPlans.Paywall.welcomeBack }
    return RegistryPlans.name
  }
}

/// The sheet when it cannot sell here: signed out (the trial is the offer),
/// this Apple ID's Plus belongs to another Septena account (spec §6.4
/// finding 7), or before checkout opens.
private struct PlusInfoView: View {
  var upsellID: String?
  var onSynced: () -> Void = {}
  private var status: PlanStatus { .shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PlusSheetHeader(upsellID: upsellID, onSynced: onSynced)
        if !status.plusOwnedByAnotherAccount {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(RegistryPlans.prices) { price in
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
          } else {
            Text(RegistryPlans.checkoutNotice).font(.subheadline).foregroundStyle(.secondary)
          }
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
  @State private var managing = false

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: RegistryIcons.sfSymbols["settings.plus"] ?? "plus.circle.fill")
        .font(.largeTitle)
        .foregroundStyle(.tint)
      Text(line).multilineTextAlignment(.center)
      if source == "apple" {
        #if os(iOS)
        Button(RegistryPlans.Action.manage) { managing = true }
          .buttonStyle(.borderedProminent)
          .manageSubscriptionsSheet(isPresented: $managing)
        #else
        // macOS has no manage sheet; the App Store app owns subscriptions.
        Link(RegistryPlans.Action.manage, destination: Self.macSubscriptionsURL)
          .buttonStyle(.borderedProminent)
        #endif
      }
      PlusRestoreButton().font(.footnote)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  #if os(macOS)
  private static let macSubscriptionsURL = URL(string: "macappstores://apps.apple.com/account/subscriptions")!
  #endif

  private var line: String {
    switch source {
    case "apple": return RegistryPlans.Paywall.ownedApple
    case "stripe": return RegistryPlans.Paywall.ownedWeb
    case "google": return RegistryPlans.Paywall.ownedGoogle
    default: return RegistryPlans.Paywall.ownedGrant
    }
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
