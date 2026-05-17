import SwiftUI

// Groceries mini-app — pantry list with a "low" flag per item. Two
// sections: items currently marked low (shopping list) above the full
// stocked pantry. Tap a row to toggle low ↔ in-stock. Add/delete is
// out of scope for v1; manage that in the webapp.

struct GroceriesDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var items: [GroceryItem] = []
  @State private var pending: Set<String> = []
  @State private var loading = true

  private var accent: Color { theme.color(for: "groceries") }

  private var low: [GroceryItem] {
    items.filter { $0.low }.sorted {
      ($0.category, $0.name) < ($1.category, $1.name)
    }
  }

  private var stocked: [GroceryItem] {
    items.filter { !$0.low }.sorted {
      ($0.category, $0.name) < ($1.category, $1.name)
    }
  }

  var body: some View {
    List {
      if !low.isEmpty {
        Section {
          ForEach(low) { item in
            GroceryRow(item: item,
                       pending: pending.contains(item.id),
                       accent: accent,
                       onToggle: { toggle(item) })
              .listRowInsets(EdgeInsets())
          }
        } header: {
          HStack { Text("Shopping list"); Spacer(); Text("\(low.count)").monospacedDigit() }
        }
      }
      if !stocked.isEmpty {
        Section {
          ForEach(stocked) { item in
            GroceryRow(item: item,
                       pending: pending.contains(item.id),
                       accent: accent,
                       onToggle: { toggle(item) })
              .listRowInsets(EdgeInsets())
          }
        } header: {
          Text("In stock")
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
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  // MARK: - Actions

  private func toggle(_ item: GroceryItem) {
    let next = !item.low
    if let i = items.firstIndex(where: { $0.id == item.id }) {
      items[i].low = next   // optimistic flip
    }
    pending.insert(item.id)
    Haptics.tap()
    Task {
      do {
        try await client.patchGroceryItem(id: item.id, low: next)
      } catch {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
          items[i].low = !next   // revert on failure
        }
      }
      pending.remove(item.id)
    }
  }

  private func load() async {
    loading = true
    if let res = try? await client.groceries() {
      items = res
    }
    loading = false
  }
}

private struct GroceryRow: View {
  let item: GroceryItem
  let pending: Bool
  let accent: Color
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
        if !item.category.isEmpty {
          Text(item.category)
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
