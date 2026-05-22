import SwiftUI

// Single canonical menu for the Caffeine tile — same content from both
// the trailing-circle button (Menu) and the tile's `.contextMenu`. The
// bean list is small enough (<8 typically) to show in full; Edit-last
// surfaces when there's a prior entry. Matches the iOS pattern of one
// menu per surface, accessible from both tap-button and long-press.

private struct CaffeineQuickAddContext {
  let beans: [CaffeineBean]
  let lastEntry: CaffeineTimePoint?

  var lastMethod: String { lastEntry?.method ?? "v60" }
  var lastGrams: Double? { lastEntry?.grams }

  /// Label for the "repeat" row — prefers the bean name, falls back to
  /// the method (e.g. "V60") if no bean was attached to the last entry.
  func repeatLabel(_ entry: CaffeineTimePoint) -> String {
    "Repeat: \(entry.beans ?? entry.method.uppercased())"
  }
}

struct CaffeineQuickAddMenu: View {
  let beans: [CaffeineBean]
  let lastEntry: CaffeineTimePoint?
  let onCommit: (_ method: String, _ beans: String?, _ grams: Double?) -> Void
  let onEditLast: (() -> Void)?
  let onMore: () -> Void

  private var ctx: CaffeineQuickAddContext {
    .init(beans: beans, lastEntry: lastEntry)
  }

  var body: some View {
    if let last = lastEntry {
      Button {
        onCommit(last.method, last.beans, last.grams)
      } label: {
        Label(ctx.repeatLabel(last), systemImage: "arrow.clockwise")
      }
    }

    if !beans.isEmpty {
      Section("Beans") {
        ForEach(beans) { bean in
          Button {
            onCommit(ctx.lastMethod, bean.name, ctx.lastGrams)
          } label: {
            Label(bean.name, systemImage: "leaf")
          }
        }
      }
    }

    if let onEditLast, lastEntry != nil {
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
      Label("Caffeine…", systemImage: "ellipsis")
    }
  }
}
