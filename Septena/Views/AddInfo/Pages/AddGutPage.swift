import SwiftUI

// Bristol-scale capture. Static labels (1–7) — the server has no /config
// endpoint we depend on; the webapp does the same. Tap logs with the
// current time and blood=0; full editor lives outside the palette.

private struct BristolEntry: Identifiable {
  let id: Int
  let label: String
  let emoji: String
}

private let bristolScale: [BristolEntry] = [
  .init(id: 1, label: "Hard pellets",        emoji: "1️⃣"),
  .init(id: 2, label: "Lumpy sausage",       emoji: "2️⃣"),
  .init(id: 3, label: "Cracked sausage",     emoji: "3️⃣"),
  .init(id: 4, label: "Smooth, soft sausage", emoji: "4️⃣"),
  .init(id: 5, label: "Soft blobs",          emoji: "5️⃣"),
  .init(id: 6, label: "Fluffy mush",         emoji: "6️⃣"),
  .init(id: 7, label: "Liquid",              emoji: "7️⃣"),
]

struct AddGutPage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.gut.accent(theme: theme)
    let filtered = bristolScale.filter { trimmed.isEmpty || $0.label.localizedCaseInsensitiveContains(trimmed) || trimmed == String($0.id) }

    List {
      Section("Bristol scale") {
        ForEach(filtered) { item in
          Button { log(item) } label: {
            AddInfoRow(
              title: "\(item.emoji)  Type \(item.id) — \(item.label)",
              systemImage: "drop",
              tint: tint
            )
          }
          .buttonStyle(.plain)
          .disabled(working)
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func log(_ item: BristolEntry) {
    outbox.enqueue(method: "POST", path: "/api/gut/entry",
                   body: ["date": SeptenaDate.today,
                          "time": nowHHMM(),
                          "bristol": item.id,
                          "blood": 0],
                   kind: "gut.add")
    Haptics.tick()
    dismiss()
  }
}
