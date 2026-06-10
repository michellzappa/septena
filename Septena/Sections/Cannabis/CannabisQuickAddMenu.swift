import SwiftUI

// Single canonical menu for the Cannabis tile — bound to *both* the
// trailing-circle button (Menu, opens on tap) and the tile-level
// `.contextMenu` (opens on long-press / right-click).
//
// Designed to answer "what's the next step right now?" rather than
// enumerate options. When the current capsule has room we offer *both*
// Continue (next hit) and New capsule; once the last vape filled the
// capsule (hit == cap) we never suggest hit+1 — only New capsule. + Edible.
// Keeps the menu to 3-5 items even with Edit last + Cannabis…

struct CannabisQuickAddMenu: View {
  let lastVape: CannabisEntry?
  let usesPerCapsule: Int
  let onCommit: (_ method: String, _ hit: Int?) -> Void
  let onEditLast: (() -> Void)?

  // Capsule math is single-sourced in `CannabisCapsule` (SeptenaCore) so this
  // menu and the watch quick-add can't disagree about the next step.
  private var hasActiveCapsule: Bool {
    CannabisCapsule.hasActiveCapsule(lastHit: lastVape?.hit, usesPerCapsule: usesPerCapsule)
  }
  private var continueHit: Int { CannabisCapsule.continueHit(lastHit: lastVape?.hit) }

  var body: some View {
    if hasActiveCapsule {
      Button {
        onCommit("vape", continueHit)
      } label: {
        Label("Continue (Hit \(continueHit))", systemImage: "arrow.clockwise")
      }
    }

    Button {
      onCommit("vape", 1)
    } label: {
      Label("New capsule", systemImage: "plus.circle")
    }

    Button {
      onCommit("edible", nil)
    } label: {
      Label("Edible", systemImage: "circle.fill")
    }

    if let onEditLast, lastVape != nil {
      Divider()
      Button { onEditLast() } label: {
        Label("Edit last entry", systemImage: "pencil")
      }
    }

  }
}
