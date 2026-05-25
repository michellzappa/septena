import SwiftUI
import SwiftData

// Groceries mini-app — pantry list with a "low" flag per item. Reads
// from SwiftData (CloudKit-synced) and writes via GroceryMutator. Two
// sections: items currently marked low (shopping list) above the full
// stocked pantry, with stocked items grouped by user-defined category in
// the user's chosen order. Tap a row to toggle low ↔ in-stock; tap the
// emoji/name to edit. Category management lives in the webapp.

struct GroceriesDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  private var grocery: GroceryMutator { SeptenaServices.shared.groceryMutator }

  @State private var items: [GroceryItem] = []
  @State private var categories: [GroceryCategory] = DEFAULT_GROCERY_CATEGORIES
  @State private var pending: Set<String> = []
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
      SectionGoalsStrip(sectionKey: "groceries")
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
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
                               systemImage: "basket",
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
    .trackScreen("groceries")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { creating = true } label: { Image(systemName: "plus") }
          .tint(accent)
      }
    }
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(item: $editing) { item in
      EditGroceryItemSheet(
        original: item,
        categories: categories,
        onDone: { _ in reload() }
      )
    }
    .sheet(isPresented: $creating) {
      EditGroceryItemSheet(
        original: nil,
        categories: categories,
        onDone: { _ in reload() }
      )
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
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
