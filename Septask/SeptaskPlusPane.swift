// Settings ▸ Account ▸ Septena Plus (ADR 0010, ADR 0023).
//
// Renders `registry/plans.json` through `RegistryPlans`, the same source as
// the site's /pricing page, so the two never disagree. The pane shows the
// account's plan as the server reports it (`PlanStatus`), then what Plus
// adds. It sells nothing yet: `RegistryPlans.checkoutOpen` is false until
// the App Store products exist, so no purchase control draws.

import SwiftUI

struct SeptaskPlusPane: View {
  private var status: PlanStatus { .shared }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(RegistryPlans.headline)
            .font(.title2.weight(.semibold))
          Text(RegistryPlans.subhead)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        if let line = status.statusLine {
          LabeledContent(RegistryPlans.Copy.yourPlan) {
            Text(line).foregroundStyle(.secondary)
          }
        }
      }

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

      if status.plan == .device || status.plan == .free {
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
              Text(RegistryPlans.Status.free).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Text(RegistryPlans.shortName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(outcome.rows) { row in
              GridRow(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(row.label)
                  if row.planned {
                    Text(RegistryPlans.Copy.planned).font(.caption).foregroundStyle(.secondary)
                  }
                }
                PlanCellView(cell: row.account)
                PlanCellView(cell: row.plus)
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
    .navigationTitle(RegistryPlans.name)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await PlanStatus.shared.refresh() }
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
