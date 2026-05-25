import SwiftUI
import SwiftData

@MainActor
enum SupplementsPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["supplements"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "supplements")
    return ctx.supplements
      .filter { $0.done }
      .compactMap { sup -> TodayEvent? in
        guard let time = sup.time else { return nil }
        return TodayEvent(
          id: "supp-\(sup.id)",
          time: time,
          section: "supplements",
          color: accent,
          title: [sup.emoji, sup.name].compactMap { $0 }.joined(separator: " "),
          detail: nil,
          kind: .supplement(sup)
        )
      }
  }

  static func destinationView() -> AnyView? { AnyView(SupplementsDestinationView()) }

  static func detailPaneContent() -> AnyView? { AnyView(SupplementsDetailContent()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SupplementsOnboardingView(complete: complete))
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "supplements",
      summary: "Daily supplement log — same shape as habits.",
      tools: [
        SectionSkill.Tool("supplements_list",   "Definitions with today's state merged",
              inputs: "optional: date (default today)"),
        SectionSkill.Tool("supplements_create", "New definition",
              inputs: "required: title · optional: emoji"),
        SectionSkill.Tool("supplements_update", "Update fields",
              inputs: "required: id · optional: title, emoji"),
        SectionSkill.Tool("supplements_delete", "Delete definition and events",
              inputs: "required: id"),
        SectionSkill.Tool("supplements_toggle", "Mark taken/untaken for a date",
              inputs: "required: id, done · optional: date"),
      ],
      body: """
      Same definition+state shape as habits. \
      `supplements_toggle(id, done: false)` removes today's mark.
      """
    )
  }
}

private struct SupplementsDetailContent: View {
  @State private var showingSheet = false

  var body: some View {
    Section {
      Button {
        showingSheet = true
      } label: {
        Label("Manage Supplements", systemImage: "pills")
      }
    } footer: {
      Text("Renaming a supplement doesn't affect its history — events are linked by ID.")
    }
    .sheet(isPresented: $showingSheet) {
      SupplementTypeSheet()
        .environment(SeptenaServices.shared.checklistMutator)
    }
  }
}

/// Curated starter supplements. Additive only — items the user already
/// has (case-insensitive title match) render as "Already added".
private struct SupplementStarter: Identifiable, Hashable {
  let id: String
  let name: String
  let emoji: String

  static let all: [SupplementStarter] = [
    .init(id: "starter-vitamin-d",     name: "Vitamin D",         emoji: "☀️"),
    .init(id: "starter-omega-3",       name: "Omega-3",           emoji: "🐟"),
    .init(id: "starter-magnesium",     name: "Magnesium",         emoji: "🧂"),
    .init(id: "starter-multivitamin",  name: "Multivitamin",      emoji: "💊"),
    .init(id: "starter-creatine",      name: "Creatine",          emoji: "💪"),
    .init(id: "starter-protein",       name: "Protein",           emoji: "🥛"),
    .init(id: "starter-probiotic",     name: "Probiotic",         emoji: "🦠"),
    .init(id: "starter-b-complex",     name: "B-complex",         emoji: "🌾"),
    .init(id: "starter-iron",          name: "Iron",              emoji: "🩸"),
    .init(id: "starter-zinc",          name: "Zinc",              emoji: "⚙️"),
  ]
}

private struct SupplementsOnboardingView: View {
  let complete: () -> Void
  @Environment(ChecklistMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingTitles: Set<String> = []

  private var accent: Color { theme.color(for: "supplements") }

  private func alreadyExists(_ s: SupplementStarter) -> Bool {
    existingTitles.contains(s.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
    existingTitles = Set(rows.map { $0.title.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Text("Supplements logs the things you take daily. Pick a few common ones to start — you can edit or delete them anytime.")
              .foregroundStyle(.secondary)
            Text("Skip if you'd rather add your own.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
        Section {
          ForEach(SupplementStarter.all) { starter in
            starterRow(starter)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Set up Supplements")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) {
        bottomBar
      }
      .onAppear { loadExisting() }
    }
  }

  @ViewBuilder
  private func starterRow(_ s: SupplementStarter) -> some View {
    let exists = alreadyExists(s)
    let isSelected = selected.contains(s.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(s.id) } else { selected.insert(s.id) }
    } label: {
      HStack(spacing: 12) {
        Text(s.emoji).font(.title3)
          .opacity(exists ? 0.4 : 1)
        Text(s.name)
          .foregroundStyle(exists ? .secondary : .primary)
          .strikethrough(exists, color: .secondary)
        Spacer()
        if exists {
          Text("Already added")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
            .font(.title3)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

  @ViewBuilder
  private var bottomBar: some View {
    HStack(spacing: 12) {
      Button("Skip") { complete() }
        .buttonStyle(.bordered)
      Spacer()
      Button(actionTitle) { addAndFinish() }
        .buttonStyle(.borderedProminent)
        .tint(accent)
    }
    .padding()
    .background(.bar)
  }

  private var actionTitle: String {
    selected.isEmpty ? "Done" : "Add \(selected.count) supplement\(selected.count == 1 ? "" : "s")"
  }

  private func addAndFinish() {
    let toAdd = SupplementStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      mutator.createSupplement(name: s.name, emoji: s.emoji)
    }
    complete()
  }
}
