import SwiftUI

// Bristol-scale capture. Static labels (1–7) — the server has no /config
// endpoint we depend on; the webapp does the same. Tap logs with the
// current time and blood=0; full editor lives outside the palette.

private struct BristolEntry: Identifiable {
  let id: Int
  let label: String
}

private let bristolScale: [BristolEntry] = [
  .init(id: 1, label: "Hard pellets"),
  .init(id: 2, label: "Lumpy sausage"),
  .init(id: 3, label: "Cracked sausage"),
  .init(id: 4, label: "Smooth, soft sausage"),
  .init(id: 5, label: "Soft blobs"),
  .init(id: 6, label: "Fluffy mush"),
  .init(id: 7, label: "Liquid"),
]

struct AddGutPage: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Bindable var router: AddInfoRouter
  @State private var working = false

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

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
              title: item.label,
              leadingNumber: item.id,
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
    SectionLog.newLog(
      section: "gut",
      accent: AddInfoSection.gut.accent(theme: theme),
      announce: "Logged type \(item.id).",
      logCommit: logCommit
    ) {
      gut.addEntry(date: SeptenaDate.today, time: SeptenaDate.nowHHMM, bristol: item.id)
      GutBristolRecorder.record(item.id)
      AddInfoSection.gut.notifyTilesChanged()
    }
    dismiss()
  }
}
