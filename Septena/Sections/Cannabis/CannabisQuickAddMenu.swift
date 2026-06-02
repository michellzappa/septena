import SwiftUI

// Single canonical menu for the Cannabis tile — bound to *both* the
// trailing-circle button (Menu, opens on tap) and the tile-level
// `.contextMenu` (opens on long-press / right-click).
//
// Designed to answer "what's the next step right now?" rather than
// enumerate options. One context-aware vape row (Continue when the
// current capsule has room, New capsule when it doesn't) + Edible.
// Keeps the menu to 3-4 items even with Edit last + Cannabis…

struct CannabisQuickAddMenu: View {
  let lastVape: CannabisEntry?
  let usesPerCapsule: Int
  let onCommit: (_ method: String, _ hit: Int?) -> Void
  let onEditLast: (() -> Void)?

  /// True when the current capsule has room — i.e. there's a last vape
  /// today and the next hit fits under the capsule cap. Drives whether
  /// the smart row reads "Continue" or "New capsule".
  private var hasActiveCapsule: Bool {
    guard let h = lastVape?.hit else { return false }
    return h >= 1 && h < usesPerCapsule
  }

  private var smartHit: Int {
    hasActiveCapsule ? (lastVape!.hit! + 1) : 1
  }

  private var smartLabel: String {
    if hasActiveCapsule { return "Continue (Hit \(smartHit))" }
    return "New capsule"
  }

  private var smartIcon: String {
    hasActiveCapsule ? "arrow.clockwise" : "plus.circle"
  }

  var body: some View {
    Button {
      onCommit("vape", smartHit)
    } label: {
      Label(smartLabel, systemImage: smartIcon)
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
