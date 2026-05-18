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

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    List {
      summary
      Section {
        ForEach(model.supplements) { supp in
          SupplementRow(supplement: supp, model: model, outbox: outbox, tint: accent)
            .listRowInsets(EdgeInsets())
        }
      } header: {
        Text("Today")
      }
      if model.hasLoaded && model.supplements.isEmpty {
        ContentUnavailableView("No supplements configured",
                               systemImage: "pills",
                               description: Text("Add some in the webapp's Supplements settings."))
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Supplements")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load(client: client)
    }
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
