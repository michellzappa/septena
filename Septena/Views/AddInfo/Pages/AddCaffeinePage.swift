import SwiftUI

// Caffeine palette — "Repeat last" pinned at top, then one row per
// configured bean preset. Each bean row swaps the bean but inherits the
// last (method, grams) so the most common path (same brew, swap bean) is
// one tap. Config endpoint may not exist on every backend; we degrade
// gracefully if it 404s.

struct AddCaffeinePage: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var beans: [CaffeineBean] = []
  @State private var lastEntry: CaffeineEntry? = nil
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.caffeine.accent(theme: theme)
    let filtered = beans.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }

    List {
      if let last = lastEntry {
        Section {
          Button { repeatLast(last) } label: {
            AddInfoRow(
              title: "Repeat last",
              subtitle: subtitle(for: last),
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
                subtitle: lastEntry.map { "\($0.method) · \(grams($0.grams))g" },
                systemImage: "cup.and.saucer",
                tint: tint
              )
            }
            .buttonStyle(.plain)
            .disabled(working)
          }
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func subtitle(for entry: CaffeineEntry) -> String {
    var parts: [String] = [entry.method]
    if let b = entry.beans { parts.append(b) }
    if let g = entry.grams { parts.append("\(grams(g))g") }
    return parts.joined(separator: " · ")
  }

  private func grams(_ g: Double?) -> String {
    guard let g else { return "?" }
    return g == g.rounded() ? String(Int(g)) : String(format: "%.1f", g)
  }

  private func repeatLast(_ entry: CaffeineEntry) {
    commit(method: entry.method, beans: entry.beans, grams: entry.grams)
  }

  private func logBean(_ bean: CaffeineBean) {
    let method = lastEntry?.method ?? "v60"
    commit(method: method, beans: bean.name, grams: lastEntry?.grams)
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
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    if let cfg = try? await client.caffeineConfig() {
      beans = cfg.beans
    }
    if let day = try? await client.caffeineDay(date: SeptenaDate.today) {
      lastEntry = day.entries.last
    }
  }
}
