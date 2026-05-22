import SwiftUI

// Supplements mini-app — single flat list of today's stack. Simpler than
// Habits (no time-of-day bucketing) and Chores (no defer / overdue);
// supplements are taken or not, that's it. Reuses NextItemsModel and the
// promoted SupplementRow.

struct SupplementsDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: SupplementDayItem? = nil
  @State private var creating = false
  @State private var history: [SupplementHistoryPoint] = []

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    List {
      summary
      Section {
        ForEach(model.supplements) { supp in
          Button { editing = supp } label: {
            SupplementRow(supplement: supp, model: model, outbox: outbox, tint: accent,
                          onDelete: { delete(supp) })
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets())
        }
      } header: {
        Text("Today")
      }
      if model.hasLoaded && model.supplements.isEmpty {
        ContentUnavailableView("No supplements configured",
                               systemImage: theme.icon(for: "supplements"),
                               description: Text("Add some in the webapp's Supplements settings."))
      }
      if !history.isEmpty {
        ChecklistHeatmapSection(
          title: "Supplement consistency",
          noun: "supplement",
          accent: accent,
          daily: history,
          date: { $0.date },
          done: { $0.done },
          total: { $0.total }
        )
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Supplements")
    .trackScreen("supplements")
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
    .task {
      model.paintFromCache()
      await model.load(client: client)
      if let resp = try? await client.supplementsHistory(days: 365) {
        history = resp.daily
      }
    }
    .sheet(item: $editing) { supp in
      EditSupplementSheet(
        original: supp,
        onDone: { updated in
          if let updated, let idx = model.supplements.firstIndex(where: { $0.id == updated.id }) {
            model.supplements[idx] = updated
          }
        }
      )
    }
    .sheet(isPresented: $creating) {
      EditSupplementSheet(
        original: nil,
        onDone: { _ in Task { await model.load(client: client) } }
      )
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
    }
  }

  private func delete(_ supp: SupplementDayItem) {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/supplements/delete/\(supp.id)",
      body: nil,
      kind: "supplements.delete"
    )
    model.supplements.removeAll { $0.id == supp.id }
    Haptics.warning()
  }

  private var summary: some View {
    let total = model.supplements.count
    let done = model.supplements.filter { $0.done }.count
    return Section {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(done)/\(total)")
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(accent)
          Text("taken today")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
  }
}
