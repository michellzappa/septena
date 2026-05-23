import SwiftUI
import SwiftData

// Cannabis palette — mirrors the webapp command palette (components/
// command-palette.tsx :: page === "cannabis"). Rows, in order:
//
//   1. Start new capsule  → vape, no strain, hit 1
//   2. Continue · {strain} (or "Continue · Hit N") → vape, last strain,
//      next hit. "Continue" advances hit = lastHit+1 against the last
//      *vape* entry; wraps to 1 at the configured cap.
//   3. Start over · {strain} (one per configured strain, last-used first)
//      → vape, that strain, hit 1
//   4. Edible → edible, no strain, no hit
//
// The search query filters the per-strain rows only; the fixed rows
// (start/continue/edible) always show.

struct AddCannabisPage: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var strains: [CannabisStrain] = []
  @State private var entries: [CannabisEntry] = []
  @State private var working = false

  /// Constant capsule size — matches CannabisDestinationView. 3 uses × 0.05g.
  private let usesPerCapsule: Int = 3

  private var cannabis: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // Last *vape* entry — edibles don't carry a hit and shouldn't influence
  // the suggested next hit or the pinned strain order.
  private var lastVape: CannabisEntry? {
    entries.reversed().first { $0.method == "vape" }
  }

  private var lastStrain: String? {
    entries.reversed().first { $0.method == "vape" && ($0.strain?.isEmpty == false) }?.strain
  }

  private var suggestedHit: Int {
    guard let h = lastVape?.hit else { return 1 }
    return (h >= 1 && h < usesPerCapsule) ? h + 1 : 1
  }

  // Strain list, with the last-used strain pinned to the top. If the last
  // strain isn't present in the configured strain list (e.g. user-typed in
  // an old entry), synthesize a row for it — same shim the webapp uses.
  private var orderedStrains: [CannabisStrain] {
    guard let last = lastStrain else { return strains }
    if let match = strains.first(where: { $0.name == last }) {
      return [match] + strains.filter { $0.name != last }
    }
    return [CannabisStrain(id: "last-strain", name: last)] + strains
  }

  private var filteredStrains: [CannabisStrain] {
    orderedStrains.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
  }

  var body: some View {
    let tint = AddInfoSection.cannabis.accent(theme: theme)

    List {
      Section {
        Button { commit(method: "vape", strain: nil, hit: 1) } label: {
          AddInfoRow(
            title: "Start new capsule",
            subtitle: "No strain · hit 1",
            systemImage: "plus.circle",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)

        Button { continueCapsule() } label: {
          AddInfoRow(
            title: continueLabel,
            subtitle: "Keep current capsule · log hit \(suggestedHit)",
            systemImage: "arrow.clockwise",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)
      }

      if !filteredStrains.isEmpty {
        Section("Strains") {
          ForEach(filteredStrains) { strain in
            Button { commit(method: "vape", strain: strain.name, hit: 1) } label: {
              AddInfoRow(
                title: "Start over · \(strain.name)",
                subtitle: strain.name == lastStrain
                  ? "New capsule · reset to hit 1"
                  : "New capsule · hit 1",
                tint: tint
              )
            }
            .buttonStyle(.plain)
            .disabled(working)
          }
        }
      }

      Section {
        Button { commit(method: "edible", strain: nil, hit: nil) } label: {
          AddInfoRow(
            title: "Edible",
            subtitle: "Standalone",
            systemImage: "circle.fill",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private var continueLabel: String {
    if let s = lastStrain { return "Continue · \(s)" }
    return "Continue · Hit \(suggestedHit)"
  }

  private func continueCapsule() {
    commit(method: "vape", strain: lastStrain, hit: suggestedHit)
  }

  private func commit(method: String, strain: String?, hit: Int?) {
    cannabis.addEntry(date: SeptenaDate.today, time: nowHHMM(),
                      method: method, strain: strain, hit: hit)
    AddInfoSection.cannabis.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    strains = ChecklistMirror.loadCannabisStrains(context: modelContext)
    let day = ChecklistMirror.loadCannabisDay(context: modelContext, date: SeptenaDate.today)
    entries = day.entries
  }
}
