import SwiftUI

// Single canonical menu for the Cannabis tile — bound to *both* the
// trailing-circle button (Menu, opens on tap) and the tile-level
// `.contextMenu` (opens on long-press / right-click).
//
// Designed to answer "what's the next step right now?" rather than
// enumerate options. One context-aware vape row (Continue when the
// current capsule has room, New capsule when it doesn't) + Edible.
// Strain-picking lives in the sheet — the menu only commits the smart
// default. Keeps the menu to 3-4 items even with Edit last + Cannabis…

struct CannabisQuickAddMenu: View {
  let lastVape: CannabisEntry?
  let usesPerCapsule: Int
  let onCommit: (_ method: String, _ strain: String?, _ hit: Int?) -> Void
  let onEditLast: (() -> Void)?

  private var lastStrain: String? {
    guard let s = lastVape?.strain, !s.isEmpty else { return nil }
    return s
  }

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
    let strainSuffix = lastStrain.map { " · \($0)" } ?? ""
    if hasActiveCapsule { return "Continue\(strainSuffix) (Hit \(smartHit))" }
    return "New capsule\(strainSuffix)"
  }

  private var smartIcon: String {
    hasActiveCapsule ? "arrow.clockwise" : "plus.circle"
  }

  var body: some View {
    Button {
      // Continue keeps the last strain; new capsule also reuses it (we
      // assume same physical product unless the user picks otherwise via
      // the sheet). nil strain only when nothing was logged previously.
      onCommit("vape", lastStrain, smartHit)
    } label: {
      Label(smartLabel, systemImage: smartIcon)
    }

    Button {
      onCommit("edible", nil, nil)
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
