import SwiftUI

// Single canonical menu for the Gut tile — all 7 Bristol types + Edit
// last entry, bound to both the trailing-circle button and the tile's
// `.contextMenu`. 7 items is fine in a menu (Apple's own Reminders /
// Calendar / Mail menus go higher); splitting into a "normal range"
// quick variant + "all" full variant felt arbitrary because the scale
// is one conceptual choice.

private struct BristolEntry: Identifiable {
  let id: Int
  let label: String
  let systemImage: String
}

private let bristolScale: [BristolEntry] = [
  .init(id: 1, label: "Hard pellets",  systemImage: "1.circle.fill"),
  .init(id: 2, label: "Lumpy sausage", systemImage: "2.circle.fill"),
  .init(id: 3, label: "Cracked",       systemImage: "3.circle.fill"),
  .init(id: 4, label: "Smooth",        systemImage: "4.circle.fill"),
  .init(id: 5, label: "Soft blobs",    systemImage: "5.circle.fill"),
  .init(id: 6, label: "Fluffy mush",   systemImage: "6.circle.fill"),
  .init(id: 7, label: "Liquid",        systemImage: "7.circle.fill"),
]

struct GutQuickAddMenu: View {
  let onCommit: (_ bristol: Int) -> Void
  let hasLastEntry: Bool
  let onEditLast: (() -> Void)?

  var body: some View {
    ForEach(bristolScale) { item in
      Button { onCommit(item.id) } label: {
        Label("Type \(item.id) — \(item.label)", systemImage: item.systemImage)
      }
    }

    if let onEditLast, hasLastEntry {
      Divider()
      Button { onEditLast() } label: {
        Label("Edit last entry", systemImage: "pencil")
      }
    }
  }
}
