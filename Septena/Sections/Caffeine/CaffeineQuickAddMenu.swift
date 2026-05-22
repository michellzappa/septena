import SwiftUI

// Single canonical menu for the Caffeine tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Smart and concise: just Repeat-last (the overwhelming common case)
// and Edit-last when there's a prior entry, plus the Caffeine… tail.
// Bean-picking lives in the sheet; the menu is for "another of the
// same" not "let me browse my beans."

struct CaffeineQuickAddMenu: View {
  let lastEntry: CaffeineTimePoint?
  let onCommit: (_ method: String, _ beans: String?, _ grams: Double?) -> Void
  let onEditLast: (() -> Void)?
  let onMore: () -> Void

  /// Prefer the bean name; fall back to the brew method (e.g. "V60") for
  /// entries logged without a bean.
  private func repeatLabel(_ entry: CaffeineTimePoint) -> String {
    "Repeat: \(entry.beans ?? entry.method.uppercased())"
  }

  var body: some View {
    if let last = lastEntry {
      Button {
        onCommit(last.method, last.beans, last.grams)
      } label: {
        Label(repeatLabel(last), systemImage: "arrow.clockwise")
      }
    }

    if let onEditLast, lastEntry != nil {
      Divider()
      Button { onEditLast() } label: {
        Label("Edit last entry", systemImage: "pencil")
      }
    }

    Divider()
    Button { onMore() } label: {
      Label("Caffeine…", systemImage: "ellipsis")
    }
  }
}
