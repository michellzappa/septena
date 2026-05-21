import SwiftUI

// Menu items shared by the tile's trailing-button Menu and the tile-level
// `.contextMenu`. Mirrors the AddCannabisPage row order in a flatter form:
//
//   1. Continue · {strain}  → vape, last strain, next hit (the most common
//      path — same capsule, advance the hit counter).
//   2. Start new capsule    → vape, no strain, hit 1.
//   3. Strains (last-used pinned, then up to 3 more) — each starts a new
//      capsule with that strain at hit 1.
//   4. Edible.
//   5. More… → falls through to the full AddInfo sheet for search and
//      anything the menu doesn't surface.
struct CannabisQuickAddMenu: View {
  let strains: [CannabisStrain]
  let lastVape: CannabisEntry?
  let usesPerCapsule: Int
  let onCommit: (_ method: String, _ strain: String?, _ hit: Int?) -> Void
  let onMore: () -> Void

  private var lastStrain: String? {
    guard let s = lastVape?.strain, !s.isEmpty else { return nil }
    return s
  }

  /// Next hit against the current capsule. Wraps to 1 when the cap is hit
  /// or when there's no prior vape to advance from.
  private var suggestedHit: Int {
    guard let h = lastVape?.hit else { return 1 }
    return (h >= 1 && h < usesPerCapsule) ? h + 1 : 1
  }

  /// Last-used strain pinned first; if it isn't in the configured strain
  /// list (e.g. user-typed in an older entry), synthesize a row for it —
  /// same shim as AddCannabisPage. Capped at 4 total entries.
  private var orderedStrains: [CannabisStrain] {
    let base: [CannabisStrain]
    if let last = lastStrain {
      if let match = strains.first(where: { $0.name == last }) {
        base = [match] + strains.filter { $0.name != last }
      } else {
        base = [CannabisStrain(id: "last-strain", name: last)] + strains
      }
    } else {
      base = strains
    }
    return Array(base.prefix(4))
  }

  var body: some View {
    Button {
      onCommit("vape", lastStrain, suggestedHit)
    } label: {
      Label(continueLabel, systemImage: "arrow.clockwise")
    }

    Button {
      onCommit("vape", nil, 1)
    } label: {
      Label("Start new capsule", systemImage: "plus.circle")
    }

    if !orderedStrains.isEmpty {
      Section("Strains") {
        ForEach(orderedStrains) { strain in
          Button {
            onCommit("vape", strain.name, 1)
          } label: {
            Label(strain.name, systemImage: "leaf")
          }
        }
      }
    }

    Button {
      onCommit("edible", nil, nil)
    } label: {
      Label("Edible", systemImage: "circle.fill")
    }

    Divider()
    Button {
      onMore()
    } label: {
      Label("More…", systemImage: "ellipsis")
    }
  }

  private var continueLabel: String {
    if let s = lastStrain { return "Continue · \(s)" }
    return "Continue · Hit \(suggestedHit)"
  }
}
