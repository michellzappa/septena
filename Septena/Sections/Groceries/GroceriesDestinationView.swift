import SwiftUI
import SwiftData

// Groceries mini-app — pantry list with a "low" flag per item. Reads
// from SwiftData (CloudKit-synced) and writes via GroceryMutator. Two
// sections: items currently marked low (shopping list) above the full
// stocked pantry, with stocked items grouped by user-defined category in
// the user's chosen order. Tap a row to toggle low ↔ in-stock; tap the
// emoji/name to edit.

struct GroceriesDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  private var grocery: GroceryMutator { SeptenaServices.shared.groceryMutator }

  @State private var items: [GroceryItem] = []
  @State private var categories: [GroceryCategory] = DEFAULT_GROCERY_CATEGORIES
  @State private var loading = true
  @State private var editing: GroceryItem? = nil
  @State private var creating = false

  private var accent: Color { theme.color(for: "groceries") }

  private var categoryByID: [String: GroceryCategory] {
    Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
  }

  private func displayName(forCategory id: String) -> String {
    if let cat = categoryByID[id] {
      return cat.name
    }
    return id.isEmpty ? "In stock" : id.capitalized
  }

  /// Position of each category in the user-defined order, for sorting.
  /// Unknown categories sort to the end.
  private var categoryRank: [String: Int] {
    Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
  }

  /// Shopping list — low items grouped in the same aisle order as the
  /// stocked pantry, so you shop top-to-bottom the way the list reads.
  private var low: [GroceryItem] {
    let rank = categoryRank
    return items.filter { $0.low }.sorted {
      let lr = rank[$0.category] ?? Int.max
      let rr = rank[$1.category] ?? Int.max
      if lr != rr { return lr < rr }
      return $0.name < $1.name
    }
  }

  private var stocked: [GroceryItem] {
    items.filter { !$0.low }
  }

  /// Stocked items grouped by category, in the user-defined category order.
  /// Items whose category is unknown are dropped to the end under their raw id.
  private var stockedByCategory: [(category: String, label: String, items: [GroceryItem])] {
    let bucketed = Dictionary(grouping: stocked) { $0.category }
    var out: [(category: String, label: String, items: [GroceryItem])] = []
    var consumed: Set<String> = []
    for cat in categories {
      if let arr = bucketed[cat.id], !arr.isEmpty {
        out.append((cat.id, displayName(forCategory: cat.id), arr.sorted { $0.name < $1.name }))
        consumed.insert(cat.id)
      }
    }
    for (cid, arr) in bucketed where !consumed.contains(cid) {
      out.append((cid, displayName(forCategory: cid), arr.sorted { $0.name < $1.name }))
    }
    return out
  }

  var body: some View {
    SectionDrawer(sectionKey: "groceries",
                  onLog: { _ in creating = true }) {
      if !low.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Shopping list")
            Spacer()
            Button("Mark all bought") { markAllBought() }
              .font(.subheadline.weight(.medium))
              .foregroundStyle(accent)
            Text("\(low.count)").monospacedDigit()
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
          DrawerSection(padding: .none) {
            ForEach(low) { item in
              groceryButton(item: item,
                            categoryLabel: displayName(forCategory: item.category),
                            showCategory: true)
            }
          }
        }
      }
      ForEach(stockedByCategory, id: \.category) { group in
        DrawerSection(group.label, padding: .none) {
          ForEach(group.items) { item in
            groceryButton(item: item,
                          categoryLabel: group.label,
                          showCategory: false)
          }
        }
      }
      if !loading && items.isEmpty {
        ContentUnavailableView {
          Label("No groceries yet", systemImage: "basket")
        } description: {
          Text("Add items to build your pantry and shopping list.")
        } actions: {
          Button("Add item") { creating = true }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .trackScreen("groceries")
    .tint(accent)
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .adaptiveDetail(item: $editing) { item in
      EditGroceryItemSheet(
        original: item,
        categories: categories,
        onDone: { _ in reload() }
      )
    }
    .adaptiveDetail(isPresented: $creating) {
      EditGroceryItemSheet(
        original: nil,
        categories: categories,
        onDone: { _ in reload() }
      )
    }
  }


  /// Standard grocery row button with edit-on-tap, long-press context
  /// menu for delete. Replaces the prior `.swipeActions(.trailing)` per
  /// the app convention "context menu on long-press, no swipes anywhere."
  @ViewBuilder
  private func groceryButton(item: GroceryItem,
                             categoryLabel: String,
                             showCategory: Bool) -> some View {
    Button { editing = item } label: {
      GroceryRow(item: item,
                 categoryLabel: categoryLabel,
                 accent: accent,
                 showCategory: showCategory,
                 onToggle: { toggle(item) })
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button { editing = item } label: {
        Label("Edit", systemImage: "pencil")
      }
      Button(role: .destructive) {
        delete(item)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  private func delete(_ item: GroceryItem) {
    grocery.deleteItem(id: item.id)
    reload()
    Haptics.warning()
  }

  // MARK: - Actions

  private func toggle(_ item: GroceryItem) {
    grocery.setLow(id: item.id, low: !item.low)
    reload()
    Haptics.tap()
  }

  /// Clear the whole shopping list in one shot — marks every low item
  /// back in-stock (each stamps `lastBought` to today). For the
  /// post-shop "I bought everything" moment.
  private func markAllBought() {
    let lowItems = items.filter { $0.low }
    guard !lowItems.isEmpty else { return }
    // The one grocery moment worth celebrating — a burst that grows with the
    // size of the shop you just cleared.
    SectionLog.newLog(
      section: "groceries",
      accent: accent,
      intensity: min(1.5, max(0.8, Double(lowItems.count) / 8)),
      announce: "Marked \(lowItems.count) items bought.",
      logCommit: logCommit
    ) {
      for item in lowItems {
        grocery.setLow(id: item.id, low: false)
      }
      reload()
      AddInfoSection.groceries.notifyTilesChanged()
    }
  }

  private func reload() {
    items = ChecklistMirror.loadGroceryItems(context: modelContext)
    let cats = ChecklistMirror.loadGroceryCategories(context: modelContext)
    categories = cats.isEmpty ? DEFAULT_GROCERY_CATEGORIES : cats
    loading = false
  }
}

private struct GroceryRow: View {
  let item: GroceryItem
  let categoryLabel: String
  let accent: Color
  let showCategory: Bool
  let onToggle: () -> Void

  var body: some View {
    HStack(spacing: Theme.iconTextGap) {
      Button(action: onToggle) {
        Image(systemName: item.low ? "circle" : "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(item.low ? Theme.iconMuted : accent)
          .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
      }
      .buttonStyle(.plain)

      // Low items lead with full-ink prominence — they need action.
      // Stocked items stay calm/secondary but fully legible: the filled
      // accent checkmark already signals "in stock," so no strikethrough
      // (which would read as disabled/unavailable — the opposite of true).
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name)
          .font(.septenaTaskTitle)
          .foregroundStyle(item.low ? Theme.inkPrimary : Theme.inkSecondary)
        if showCategory, !item.category.isEmpty {
          Text(categoryLabel)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding + 2)
  }
}
