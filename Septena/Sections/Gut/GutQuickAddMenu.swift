import SwiftUI

// Single canonical menu for the Gut tile — recent Bristol types only
// (derived from today's logged entries; falls back to [3,4,5] when no
// history exists today). Labels are description-only; the numbered SF
// Symbol icon already communicates the type number.

private struct BristolEntry: Identifiable {
  let id: Int        // Bristol type 1–7
  let label: String  // description only, no number prefix
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

private let bristolByID: [Int: BristolEntry] = Dictionary(
  uniqueKeysWithValues: bristolScale.map { ($0.id, $0) }
)

/// Default shown when the user has no entries today.
private let defaultBristolIDs: [Int] = [3, 4, 5]

struct GutQuickAddMenu: View {
  /// Distinct Bristol types from recent (today's) entries, in ascending order.
  /// Pass an empty array to use the default [3,4,5] fallback.
  let recentBristolTypes: [Int]
  let onCommit: (_ bristol: Int) -> Void
  let hasLastEntry: Bool
  let onEditLast: (() -> Void)?

  private var visibleEntries: [BristolEntry] {
    let ids = recentBristolTypes.isEmpty ? defaultBristolIDs : recentBristolTypes
    return ids.sorted().compactMap { bristolByID[$0] }
  }

  var body: some View {
    ForEach(visibleEntries) { item in
      Button { onCommit(item.id) } label: {
        Label(item.label, systemImage: item.systemImage)
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
