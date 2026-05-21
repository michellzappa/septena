import SwiftUI

// Menu items shared by the tile's trailing-button Menu and the tile-level
// `.contextMenu` (long-press / right-click). One source of truth so both
// affordances open exactly the same list of presets.
//
// Items, in order:
//   1. Repeat last — commits last (method, beans, grams). Only shown when
//      a 7-day lookback found a prior entry.
//   2. One row per configured bean preset, using last method + grams so
//      the most common path (same brew, swap bean) is one tap.
//   3. "Custom…" — falls through to the full AddInfo sheet for fields the
//      menu can't express (different method, custom grams, time edit).
struct CaffeineQuickAddMenu: View {
  let beans: [CaffeineBean]
  let lastEntry: CaffeineTimePoint?
  let onCommit: (_ method: String, _ beans: String?, _ grams: Double?) -> Void
  let onMore: () -> Void

  private var lastMethod: String { lastEntry?.method ?? "v60" }
  private var lastGrams: Double? { lastEntry?.grams }

  var body: some View {
    if let last = lastEntry {
      Button {
        onCommit(last.method, last.beans, last.grams)
      } label: {
        Label("Repeat: \(last.beans ?? last.method.uppercased())",
              systemImage: "arrow.clockwise")
      }
    }

    if !beans.isEmpty {
      Section("Beans") {
        ForEach(beans) { bean in
          Button {
            onCommit(lastMethod, bean.name, lastGrams)
          } label: {
            Label(bean.name, systemImage: "leaf")
          }
        }
      }
    }

    Divider()
    Button {
      onMore()
    } label: {
      Label("Custom…", systemImage: "ellipsis")
    }
  }
}
