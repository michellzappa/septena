import SwiftUI

// Single canonical menu for the Cannabis tile — bound to *both* the
// trailing-circle button (Menu, opens on tap) and the tile-level
// `.contextMenu` (opens on long-press / right-click). Same surface from
// both gestures, matching Apple's pattern across Home Screen icons,
// Control Center, and Reminders rows: the explicit button is a visible
// affordance teaching the long-press.
//
// Capped to ~7 items including "More…" so it stays scannable; per-strain
// section is the main differentiator vs. just dropping into the sheet.

private struct CannabisQuickAddContext {
  let strains: [CannabisStrain]
  let lastVape: CannabisEntry?
  let usesPerCapsule: Int

  var lastStrain: String? {
    guard let s = lastVape?.strain, !s.isEmpty else { return nil }
    return s
  }

  /// Next hit against the current capsule. Wraps to 1 when the cap is hit
  /// or when there's no prior vape to advance from.
  var suggestedHit: Int {
    guard let h = lastVape?.hit else { return 1 }
    return (h >= 1 && h < usesPerCapsule) ? h + 1 : 1
  }

  /// Last-used strain pinned first; if the last strain isn't in the
  /// configured list (e.g. user-typed in an older entry), synthesize a
  /// row for it — same shim as AddCannabisPage. Capped at 4 entries.
  var orderedStrains: [CannabisStrain] {
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

  var continueLabel: String {
    if let s = lastStrain { return "Continue · \(s)" }
    return "Continue · Hit \(suggestedHit)"
  }
}

struct CannabisQuickAddMenu: View {
  let strains: [CannabisStrain]
  let lastVape: CannabisEntry?
  let usesPerCapsule: Int
  let onCommit: (_ method: String, _ strain: String?, _ hit: Int?) -> Void
  let onEditLast: (() -> Void)?
  let onMore: () -> Void

  private var ctx: CannabisQuickAddContext {
    .init(strains: strains, lastVape: lastVape, usesPerCapsule: usesPerCapsule)
  }

  var body: some View {
    Button {
      onCommit("vape", ctx.lastStrain, ctx.suggestedHit)
    } label: {
      Label(ctx.continueLabel, systemImage: "arrow.clockwise")
    }

    Button {
      onCommit("vape", nil, 1)
    } label: {
      Label("Start new capsule", systemImage: "plus.circle")
    }

    if !ctx.orderedStrains.isEmpty {
      Section("Strains") {
        ForEach(ctx.orderedStrains) { strain in
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

    if let onEditLast, lastVape != nil {
      Divider()
      Button {
        onEditLast()
      } label: {
        Label("Edit last entry", systemImage: "pencil")
      }
    }

    Divider()
    Button {
      onMore()
    } label: {
      Label("Cannabis…", systemImage: "ellipsis")
    }
  }
}
