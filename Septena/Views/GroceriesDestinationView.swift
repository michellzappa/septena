import SwiftUI

// Groceries mini-app — pantry list with a "low" flag per item. Two
// sections: items currently marked low (shopping list) above the full
// stocked pantry, with stocked items grouped by user-defined category in
// the user's chosen order. Tap a row to toggle low ↔ in-stock; tap the
// emoji/name to edit. Category management lives in the webapp.

struct GroceriesDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var items: [GroceryItem] = []
  @State private var categories: [GroceryCategory] = DEFAULT_GROCERY_CATEGORIES
  @State private var pending: Set<String> = []
  @State private var loading = true
  @State private var editing: GroceryItem? = nil

  private var accent: Color { theme.color(for: "groceries") }

  private var categoryByID: [String: GroceryCategory] {
    Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
  }

  private func displayName(forCategory id: String) -> String {
    if let cat = categoryByID[id] {
      return cat.emoji.isEmpty ? cat.name : "\(cat.emoji) \(cat.name)"
    }
    return id.isEmpty ? "In stock" : id.capitalized
  }

  private var low: [GroceryItem] {
    items.filter { $0.low }.sorted {
      ($0.category, $0.name) < ($1.category, $1.name)
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
    List {
      if !low.isEmpty {
        Section {
          ForEach(low) { item in
            Button { editing = item } label: {
              GroceryRow(item: item,
                         categoryLabel: displayName(forCategory: item.category),
                         pending: pending.contains(item.id),
                         accent: accent,
                         showCategory: true,
                         onToggle: { toggle(item) })
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .contextMenu {
              Button(role: .destructive) {
                delete(item)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        } header: {
          HStack { Text("Shopping list"); Spacer(); Text("\(low.count)").monospacedDigit() }
        }
      }
      ForEach(stockedByCategory, id: \.category) { group in
        Section {
          ForEach(group.items) { item in
            Button { editing = item } label: {
              GroceryRow(item: item,
                         categoryLabel: group.label,
                         pending: pending.contains(item.id),
                         accent: accent,
                         showCategory: false,
                         onToggle: { toggle(item) })
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .contextMenu {
              Button(role: .destructive) {
                delete(item)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        } header: {
          Text(group.label)
        }
      }
      if !loading && items.isEmpty {
        ContentUnavailableView("No groceries yet",
                               systemImage: theme.icon(for: "groceries"),
                               description: Text("Set up your pantry in the webapp."))
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Groceries")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
    .sheet(item: $editing) { item in
      EditGroceryItemSheet(
        original: item,
        categories: categories,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  private func applyLocalUpdate(_ updated: GroceryItem) {
    guard let idx = items.firstIndex(where: { $0.id == updated.id }) else { return }
    items[idx] = updated
    ResponseCache.save(items, forKey: Self.cacheKey)
  }

  private func delete(_ item: GroceryItem) {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/groceries/item/\(item.id)",
      body: nil,
      kind: "groceries.delete"
    )
    items.removeAll { $0.id == item.id }
    ResponseCache.save(items, forKey: Self.cacheKey)
    Haptics.warning()
  }

  // MARK: - Actions

  private func toggle(_ item: GroceryItem) {
    let next = !item.low
    if let i = items.firstIndex(where: { $0.id == item.id }) {
      items[i].low = next   // optimistic flip
    }
    Haptics.tap()
    outbox.enqueue(method: "PATCH",
                   path: "/api/groceries/item/\(item.id)",
                   body: ["low": next],
                   kind: "groceries.patch")
  }

  private static let cacheKey = "groceries.items"
  private static let categoriesCacheKey = "groceries.categories"

  private func paintFromCache() {
    if let v = ResponseCache.load([GroceryItem].self, forKey: Self.cacheKey) { items = v }
    if let c = ResponseCache.load([GroceryCategory].self, forKey: Self.categoriesCacheKey), !c.isEmpty {
      categories = c
    }
    loading = false
  }

  private func load() async {
    loading = true
    if let res = try? await client.groceriesFull() {
      items = res.items
      categories = res.categories
      ResponseCache.save(res.items, forKey: Self.cacheKey)
      ResponseCache.save(res.categories, forKey: Self.categoriesCacheKey)
    }
    loading = false
  }
}

private struct GroceryRow: View {
  let item: GroceryItem
  let categoryLabel: String
  let pending: Bool
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

      Text(item.emoji.isEmpty ? "•" : item.emoji)
        .font(.system(size: 16))
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name)
          .font(.septenaTaskTitle)
          .foregroundStyle(item.low ? Theme.inkPrimary : Theme.inkSecondary)
          .strikethrough(!item.low)
          .opacity(item.low ? 1 : 0.55)
        if showCategory, !item.category.isEmpty {
          Text(categoryLabel)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      Spacer()
      if pending {
        ProgressView().scaleEffect(0.7)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding + 2)
  }
}
