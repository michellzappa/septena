import SwiftUI

// Supplements palette — undone-only. Tap toggles done. No type-to-create
// here in the webapp; matched here. Supplements live in a flat list per
// day (no bucket grouping returned by the server).

struct AddSupplementPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var day: SupplementsDayResponse? = nil

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.supplements.accent(theme: theme)
    List {
      if let day {
        let items = day.items
          .filter { !$0.done }
          .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
        if items.isEmpty {
          Section { Text("Nothing left for today").foregroundStyle(.secondary) }
        } else {
          Section("Remaining") {
            ForEach(items) { item in
              Button { toggle(item) } label: {
                AddInfoRow(
                  title: "\(item.emoji ?? "") \(item.name)".trimmingCharacters(in: .whitespaces),
                  systemImage: "pills",
                  tint: tint,
                  accessory: .check(false)
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func toggle(_ item: SupplementDayItem) {
    outbox.enqueue(method: "POST", path: "/api/supplements/toggle",
                   body: ["supplement_id": item.id,
                          "date": SeptenaDate.today,
                          "done": true],
                   kind: "supplements.toggle")
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    day = try? await client.supplementsDay(date: SeptenaDate.today)
  }
}
