import SwiftUI

// Single canonical menu for the Caffeine tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Matches the section drawer's "+" option set: Repeat-last (the common
// case) on top, then the per-method quick-logs (V60 / Matcha / other), then
// Edit-last. Each method logs immediately — reusing the last entry's bean +
// grams when it shares that method, else a bare log you can refine later.
// Bean-browsing lives in the sheet.

struct CaffeineQuickAddMenu: View {
  let lastEntry: CaffeineTimePoint?
  let onCommit: (_ method: String, _ beans: String?, _ grams: Double?) -> Void
  let onEditLast: (() -> Void)?

  /// Prefer the bean name; fall back to the brew method (e.g. "V60") for
  /// entries logged without a bean.
  private func repeatLabel(_ entry: CaffeineTimePoint) -> String {
    "Repeat: \(entry.beans ?? entry.method.uppercased())"
  }

  /// Reuse the last entry's bean / grams only when logging the same method,
  /// so "Log V60" keeps your usual bean but "Log Matcha" starts clean.
  private func beans(for method: String) -> String? {
    lastEntry?.method == method ? lastEntry?.beans : nil
  }
  private func grams(for method: String) -> Double? {
    lastEntry?.method == method ? lastEntry?.grams : nil
  }

  var body: some View {
    if let last = lastEntry {
      Button {
        onCommit(last.method, last.beans, last.grams)
      } label: {
        Label(repeatLabel(last), systemImage: "arrow.clockwise")
      }
      Divider()
    }

    Button { onCommit("v60", beans(for: "v60"), grams(for: "v60")) } label: {
      Label("Log V60", systemImage: "cup.and.saucer")
    }
    Button { onCommit("matcha", beans(for: "matcha"), grams(for: "matcha")) } label: {
      Label("Log Matcha", systemImage: "leaf")
    }
    Button { onCommit("other", beans(for: "other"), grams(for: "other")) } label: {
      Label("Log other", systemImage: "plus.circle")
    }

    if let onEditLast, lastEntry != nil {
      Divider()
      Button { onEditLast() } label: {
        Label("Edit last entry", systemImage: "pencil")
      }
    }

  }
}
