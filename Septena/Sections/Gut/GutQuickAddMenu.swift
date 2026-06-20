import SwiftUI

// Single canonical menu for the Gut tile. Recent Bristol types (derived from
// recent logged entries) are surfaced first, but always unioned with the common
// middle of the scale (3/4/5) so the menu offers at least three options even
// when you've only logged one type lately — a single recent type wouldn't be a
// usable picker. Labels are description-only; the numbered SF Symbol icon
// already communicates the type number.

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

/// Always-present common middle of the scale — also the standalone set when
/// there's no recent history. Guarantees the menu never drops below 3 options.
private let defaultBristolIDs: [Int] = [3, 4, 5]

struct GutQuickAddMenu: View {
  /// Distinct Bristol types from recent entries, in ascending order. May be
  /// empty; the common middle is always unioned in regardless.
  let recentBristolTypes: [Int]
  let onCommit: (_ bristol: Int) -> Void
  /// Opens the Gut section — the full editor (volume, note, back-dated time)
  /// lives there. The always-present escape every quick-add menu carries.
  let onOpen: () -> Void

  private var visibleEntries: [BristolEntry] {
    let ids = Set(defaultBristolIDs).union(recentBristolTypes)
    return ids.sorted().compactMap { bristolByID[$0] }
  }

  var body: some View {
    ForEach(visibleEntries) { item in
      Button { onCommit(item.id) } label: {
        Label(item.label, systemImage: item.systemImage)
      }
    }
    Divider()
    Button { onOpen() } label: {
      Label("Gut…", systemImage: "ellipsis")
    }
  }
}
