import SwiftUI

// Bristol scale (1–7) as a flat menu — same fixed enum as AddGutPage, no
// sheet fallback. 7 items is at the upper end of comfortable menu length
// but the scale is a single conceptual choice, so splitting it would hurt
// more than help. Numbers go up the menu in order; the system orders top
// → bottom which matches Bristol's "harder → looser" progression.
struct GutQuickAddMenu: View {
  let onCommit: (_ bristol: Int) -> Void

  private struct Entry: Identifiable {
    let id: Int
    let label: String
    let systemImage: String
  }

  private static let scale: [Entry] = [
    .init(id: 1, label: "Hard pellets",   systemImage: "1.circle.fill"),
    .init(id: 2, label: "Lumpy sausage",  systemImage: "2.circle.fill"),
    .init(id: 3, label: "Cracked",        systemImage: "3.circle.fill"),
    .init(id: 4, label: "Smooth",         systemImage: "4.circle.fill"),
    .init(id: 5, label: "Soft blobs",     systemImage: "5.circle.fill"),
    .init(id: 6, label: "Fluffy mush",    systemImage: "6.circle.fill"),
    .init(id: 7, label: "Liquid",         systemImage: "7.circle.fill"),
  ]

  var body: some View {
    ForEach(Self.scale) { item in
      Button { onCommit(item.id) } label: {
        Label("Type \(item.id) — \(item.label)", systemImage: item.systemImage)
      }
    }
  }
}
