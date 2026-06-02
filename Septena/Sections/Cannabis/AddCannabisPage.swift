import SwiftUI
import SwiftData

// Cannabis palette. Rows, in order:
//
//   1. Start new capsule  → vape, hit 1
//   2. Continue · Hit N   → vape, next hit. "Continue" advances
//      hit = lastHit+1 against the last *vape* entry; wraps to 1 at the
//      configured cap.
//   3. Edible → edible, no hit
//
// The tracker is about quantity and capsule containment — strain is not
// tracked.

struct AddCannabisPage: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var entries: [CannabisEntry] = []
  @State private var working = false

  /// Constant capsule size — matches CannabisDestinationView. 3 uses × 0.05g.
  private let usesPerCapsule: Int = 3

  private var cannabis: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  // Last *vape* entry — edibles don't carry a hit and shouldn't influence
  // the suggested next hit.
  private var lastVape: CannabisEntry? {
    entries.reversed().first { $0.method == "vape" }
  }

  private var suggestedHit: Int {
    guard let h = lastVape?.hit else { return 1 }
    return (h >= 1 && h < usesPerCapsule) ? h + 1 : 1
  }

  var body: some View {
    let tint = AddInfoSection.cannabis.accent(theme: theme)

    List {
      Section {
        Button { commit(method: "vape", hit: 1) } label: {
          AddInfoRow(
            title: "Start new capsule",
            subtitle: "Hit 1",
            systemImage: "plus.circle",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)

        Button { continueCapsule() } label: {
          AddInfoRow(
            title: "Continue · Hit \(suggestedHit)",
            subtitle: "Keep current capsule · log hit \(suggestedHit)",
            systemImage: "arrow.clockwise",
            tint: tint
          )
        }
        .buttonStyle(.plain)
        .disabled(working)
      }

      Section {
        Button { commit(method: "edible", hit: nil) } label: {
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

  private func continueCapsule() {
    commit(method: "vape", hit: suggestedHit)
  }

  private func commit(method: String, hit: Int?) {
    cannabis.addEntry(date: SeptenaDate.today, time: nowHHMM(),
                      method: method, hit: hit)
    AddInfoSection.cannabis.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    let day = ChecklistMirror.loadCannabisDay(context: modelContext, date: SeptenaDate.today)
    entries = day.entries
  }
}
