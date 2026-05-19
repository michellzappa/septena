import SwiftUI

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
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var beans: [CaffeineBean] = []
  @State private var lastEntry: CaffeineTimePoint? = nil
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
          Button { repeatLast(last) } label: {
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
                systemImage: "cup.and.saucer",
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

  private func repeatSubtitle(for entry: CaffeineTimePoint) -> String {
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
    g == g.rounded() ? String(Int(g)) : String(format: "%.1f", g)
  }

  private func repeatLast(_ entry: CaffeineTimePoint) {
    commit(method: entry.method, beans: entry.beans, grams: entry.grams)
  }

  private func logBean(_ bean: CaffeineBean) {
    commit(method: lastMethod, beans: bean.name, grams: lastGrams)
  }

  private func commit(method: String, beans: String?, grams: Double?) {
    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": nowHHMM(),
      "method": method,
      "timezone": TimeZone.current.identifier,
    ]
    if let beans { body["beans"] = beans }
    if let grams { body["grams"] = grams }
    outbox.enqueue(method: "POST", path: "/api/caffeine/entry",
                   body: body, kind: "caffeine.add")
    AddInfoSection.caffeine.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    if let cfg = try? await client.caffeineConfig() {
      beans = cfg.beans
    }
    // Pull a 7-day window so "Repeat" still works the morning after a gap,
    // matching getCaffeineEntries(7) in the webapp's command palette.
    if let res = try? await client.caffeineEntries(days: 7) {
      lastEntry = res.entries.last
    }
  }
}
