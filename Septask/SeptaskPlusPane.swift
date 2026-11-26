// Settings ▸ Account ▸ Septena Plus (ADR 0010, ADR 0023).
//
// Renders `registry/plans.json` through `RegistryPlans`, the same source as
// the site's /pricing page, so the two never disagree. The pane shows the
// account's plan as the server reports it (`PlanStatus`), then what Plus
// adds. It sells nothing itself: its button opens the Plus sheet
// (`SeptaskPlusSheet`, spec §7.1), the one place that sells Plus.

import SwiftUI

struct SeptaskPlusPane: View {
  private var status: PlanStatus { .shared }
  @State private var showingSheet = false

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(status.isPro ? RegistryPlans.proCard.title : RegistryPlans.headline)
            .font(.title2.weight(.semibold))
          Text(status.isPro ? RegistryPlans.proCard.detail : RegistryPlans.subhead)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        if let line = status.statusLine {
          LabeledContent {
            Text(line).foregroundStyle(.secondary)
          } label: {
            Label(RegistryPlans.Copy.yourPlan, systemImage: planSymbol)
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
        if status.showsPlanButton {
          Button(sheetButtonTitle) { showingSheet = true }
        }
      }

      if !status.isPro {
        Section {
          ForEach(RegistryPlans.prices) { price in
            LabeledContent {
              if price.highlighted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
              }
            } label: {
              Text(price.label).font(.body.weight(price.highlighted ? .semibold : .regular))
              Text(price.detail)
            }
          }
        } header: {
          Text(RegistryPlans.name)
        } footer: {
          Text(RegistryPlans.checkoutOpen ? RegistryPlans.priceFootnote : RegistryPlans.checkoutNotice)
        }
      }

      if status.plan == .device {
        Section {
          Label {
            Text(RegistryPlans.trialTitle)
            Text(RegistryPlans.trialDetail)
          } icon: {
            Image(systemName: RegistryIcons.sfSymbols["onboarding.welcome"] ?? "sparkles")
          }
        }
      }

      ForEach(RegistryPlans.outcomes) { outcome in
        Section {
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
              Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
              Label(status.isPro ? RegistryPlans.shortName : RegistryPlans.card("free")?.title ?? "",
                    systemImage: Self.cardSymbol(status.isPro ? "plus" : "free"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Label(status.isPro ? RegistryPlans.proName : RegistryPlans.shortName,
                    systemImage: status.isPro ? Self.proSymbol : Self.cardSymbol("plus"))
                .font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
            ForEach(outcome.rows) { row in
              GridRow(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(row.label)
                  if row.planned {
                    Text(RegistryPlans.Copy.planned).font(.caption).foregroundStyle(.secondary)
                  }
                }
                // The account's plan next to the plan below it.
                PlanCellView(cell: status.isPro ? row.plus : row.free)
                PlanCellView(cell: status.isPro ? row.pro : row.plus)
              }
            }
          }
          .padding(.vertical, 4)
        } header: {
          Label(outcome.title, systemImage: RegistryIcons.sfSymbols[outcome.icon] ?? "circle")
        } footer: {
          Text(outcome.detail)
        }
      }

      Section {
        ForEach(RegistryPlans.promises) { promise in
          VStack(alignment: .leading, spacing: 2) {
            Text(promise.title).font(.body.weight(.medium))
            Text(promise.detail).font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(status.title)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await PlanStatus.shared.refresh() }
    .sheet(isPresented: $showingSheet) { SeptaskPlusSheet() }
  }

  /// "Manage Subscription" once the account pays, "See Plus" before.
  private var sheetButtonTitle: String {
    if case .plus = status.plan { return RegistryPlans.Action.manage }
    if status.hasAppleSubscription { return RegistryPlans.Action.manage }
    return RegistryPlans.Paywall.seePlus
  }

  /// SF Symbol of a plan card's registry icon (plans.json `cards[].icon`).
  private var planSymbol: String {
    if status.isPro { return Self.proSymbol }
    return Self.cardSymbol(status.isPlus ? "plus" : "free")
  }

  private static var proSymbol: String { RegistryIcons.sfSymbols[RegistryPlans.proCard.icon] ?? "circle" }

  private static func cardSymbol(_ id: String) -> String {
    RegistryIcons.sfSymbols[RegistryPlans.card(id)?.icon ?? ""] ?? "circle"
  }
}

/// One comparison cell: a check, a dash, or the registry's text.
private struct PlanCellView: View {
  let cell: RegistryPlanCell

  var body: some View {
    switch cell {
    case .included:
      Image(systemName: "checkmark").foregroundStyle(.secondary)
        .accessibilityLabel(Text(RegistryPlans.Copy.included))
    case .notIncluded:
      Image(systemName: "minus").foregroundStyle(.tertiary)
        .accessibilityLabel(Text(RegistryPlans.Copy.notIncluded))
    case .text(let text):
      Text(text).font(.subheadline).foregroundStyle(.secondary)
    }
  }
}
