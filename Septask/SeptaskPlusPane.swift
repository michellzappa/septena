// Settings ▸ Account ▸ Septena Plus (ADR 0010, ADR 0023).
//
// Renders `registry/plans.json` through `RegistryPlans`, the same source as
// the site's /pricing page, so the two never disagree. The pane shows the
// account's plan as the server reports it (`PlanStatus`) and what it
// includes, then each plan above it, in the premium language
// (docs/PREMIUM_LANGUAGE.md). It sells nothing itself: each plan's button
// opens the plan sheet (`SeptaskPlusSheet`, spec §7.1) on that plan.

import SwiftUI

struct SeptaskPlusPane: View {
  private var status: PlanStatus { .shared }
  @State private var showingSheet = false
  /// The plan the sheet opens on, from the card whose button opened it.
  @State private var sheetTier: PlanTier?

  var body: some View {
    Form {
      Section {
        if let current = currentTier {
          PlanHead(tier: current, line: headLine(current))
            .padding(.vertical, 6)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Text(RegistryPlans.headline).font(.title2.weight(.bold))
            Text(RegistryPlans.subhead).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
          if let line = status.statusLine {
            LabeledContent(RegistryPlans.Copy.yourPlan) { Text(line).foregroundStyle(.secondary) }
          }
        }
        // The second-device moment's quiet line (spec §3.2, §7.1): it stays
        // here, where the limit is, after the Today notice was seen.
        if status.deviceNotSyncing, let moment = RegistryPlans.upsell("second_device") {
          VStack(alignment: .leading, spacing: 8) {
            Text(moment.title).foregroundStyle(.secondary)
            SyncThisDeviceButton()
          }
        }
        if status.hasAppleSubscription {
          ManageSubscriptionButton()
        }
      }

      // What the account has: its plan's benefits, the same rows the sheet
      // and onboarding draw (docs/PREMIUM_LANGUAGE.md).
      if let current = currentTier {
        Section(RegistryPlans.Paywall.yourPlanIncludes) {
          ForEach(current.benefits) { PlanBenefitRow(benefit: $0).padding(.vertical, 2) }
        }
      }

      // Each plan above the account's: Plus and Pro, or only Pro on Plus
      // (ADR 0059). Head, benefits, price, one button into the sheet.
      ForEach(tiersAbove) { tier in
        Section {
          PlanHead(tier: tier, line: tier.card?.detail, markSize: 44)
            .padding(.vertical, 4)
          ForEach(tier.benefits) { PlanBenefitRow(benefit: $0).padding(.vertical, 2) }
          PlanPriceLine(tier: tier)
          Button(tier == .pro ? RegistryPlans.Paywall.seePro : RegistryPlans.Paywall.seePlus) {
            sheetTier = tier
            showingSheet = true
          }
          .fontWeight(.semibold)
        } footer: {
          if tier == tiersAbove.last {
            Text(RegistryPlans.checkoutOpen ? RegistryPlans.priceFootnote : RegistryPlans.checkoutNotice)
          }
        }
      }

      if status.plan == .device {
        Section {
          Label {
            Text(RegistryPlans.trialTitle)
            Text(RegistryPlans.trialDetail)
          } icon: {
            PlanMark(tier: .plus, size: 28)
          }
        }
      }

      // The full table lives on the website, where it has room; the app
      // shows benefits, never a truncated grid.
      Section {
        Link(RegistryPlans.Paywall.compareAll, destination: RegistryPlans.compareURL)
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(RegistryPlans.promises) { promise in
            Label(promise.title, systemImage: "checkmark")
          }
        }
        .padding(.top, 8)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(status.title)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await PlanStatus.shared.refresh() }
    .sheet(isPresented: $showingSheet) { SeptaskPlusSheet(initialTier: sheetTier) }
  }

  /// The line under the account's wordmark: its date ("Pro through …",
  /// "Plus trial until …"), or the plan's card line when the status would
  /// only repeat the plan's name.
  private func headLine(_ tier: PlanTier) -> String? {
    guard let line = status.statusLine, line != tier.title else { return tier.card?.detail }
    return line
  }

  /// The account's paid plan: Pro, Plus (bought, given or the trial), else nil.
  private var currentTier: PlanTier? {
    if status.isPro { return .pro }
    switch status.plan {
    case .plus, .trial: return .plus
    default: return nil
    }
  }

  /// The plans above the account's: none on Pro, Pro on Plus, else both.
  private var tiersAbove: [PlanTier] {
    if status.isPro { return [] }
    if case .plus = status.plan { return [.pro] }
    return PlanTier.allCases
  }
}

/// The plan's price in one line: the highlighted price strong, the other
/// after it.
private struct PlanPriceLine: View {
  let tier: PlanTier

  var body: some View {
    let main = tier.prices.first(where: \.highlighted) ?? tier.prices.first
    VStack(alignment: .leading, spacing: 2) {
      if let main {
        Text(main.label).font(.headline)
        Text(main.detail).font(.subheadline).foregroundStyle(.secondary)
      }
      ForEach(tier.prices.filter { $0.id != main?.id }) { other in
        Text(other.label).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
