import SwiftUI
import SwiftData

// Caffeine palette — mirrors the webapp command palette (components/
// command-palette.tsx :: page === "caffeine"). Rows, in order:
//
//   1. Repeat: {beans or METHOD}  → commit last (method, beans, grams).
//      Sub: METHOD[ · Ng] · last {date}. Drawn from a 7-day lookback so
//      "repeat" still works if you haven't logged anything today.
//   2. {bean}  (one per configured bean preset, all shown — search
//      filters this group only). Sub: LAST_METHOD[ · Ng]. Commit with
//      last method + last grams but swap the bean. The most common path
//      (same brew, swap bean) is one tap.
//   3. Empty-state hint when no beans *and* no prior entry exists.

struct AddCaffeinePage: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  // Optional: present in the in-app capture flow, nil from hosts that don't
  // inherit the root environment (the flourish is then simply skipped).
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Bindable var router: AddInfoRouter
  @State private var beans: [CaffeineBean] = []
  @State private var lastEntry: (method: String, beans: String?, grams: Double?, date: String)? = nil
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var lastMethod: String { lastEntry?.method ?? "v60" }
  private var lastGrams: Double? { lastEntry?.grams }

  var body: some View {
    let tint = AddInfoSection.caffeine.accent(theme: theme)
    let filtered = beans.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }

    List {
      if let last = lastEntry {
        Section {
          Button {
            commit(method: last.method, beans: last.beans, grams: last.grams)
          } label: {
            AddInfoRow(
              title: "Repeat: \(last.beans ?? last.method.uppercased())",
              subtitle: repeatSubtitle(for: last),
              systemImage: "arrow.clockwise",
              tint: tint
            )
          }
          .buttonStyle(.plain)
          .disabled(working)
        }
      }

      if !filtered.isEmpty {
        Section("Beans") {
          ForEach(filtered) { bean in
            Button { logBean(bean) } label: {
              AddInfoRow(
                title: bean.name,
                subtitle: beanSubtitle,
                tint: tint
              )
            }
            .buttonStyle(.plain)
            .disabled(working)
          }
        }
      }

      if beans.isEmpty && lastEntry == nil {
        Section {
          Text("No bean presets yet — add some in Caffeine settings.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func repeatSubtitle(for entry: (method: String, beans: String?, grams: Double?, date: String)) -> String {
    var s = entry.method.uppercased()
    if let g = entry.grams { s += " · \(grams(g))g" }
    s += " · last \(entry.date)"
    return s
  }

  private var beanSubtitle: String {
    var s = lastMethod.uppercased()
    if let g = lastGrams { s += " · \(grams(g))g" }
    return s
  }

  private func grams(_ g: Double) -> String {
    g == g.rounded() ? String(Int(g)) : g.decimalString()
  }

  private func logBean(_ bean: CaffeineBean) {
    commit(method: lastMethod, beans: bean.name, grams: lastGrams)
  }

  private func commit(method: String, beans: String?, grams: Double?) {
    CaffeineCommit.logNew(
      method: method, beans: beans, grams: grams,
      accent: AddInfoSection.caffeine.accent(theme: theme),
      logCommit: logCommit)
    dismiss()
  }

  private func load() async {
    beans = ChecklistMirror.loadCaffeineBeans(context: modelContext)
    // Find the most recent entry across all entries for "repeat" support.
    let entries = (try? modelContext.fetch(FetchDescriptor<CaffeineEventEntity>(
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    ))) ?? []
    if let last = entries.first {
      lastEntry = (method: last.method, beans: last.beans, grams: last.grams, date: last.date)
    }
  }
}
