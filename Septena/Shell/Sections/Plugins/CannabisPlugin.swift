import SwiftUI
import SwiftData

// Cannabis log section. Same pattern as CaffeinePlugin: one file owns
// the Today block, the display-label helper, and the full MCP contract,
// so adding a new method or column updates everything in lock-step.

@MainActor
enum CannabisPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["cannabis"]!
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "cannabis")
    return ctx.cannabis.map { entry in
      TodayEvent(
        id: "cnb-\(entry.id)",
        time: entry.time,
        section: "cannabis",
        color: accent,
        title: label(for: entry),
        detail: entry.strain,
        kind: .cannabis(entry)
      )
    }
  }

  static func destinationView() -> AnyView? { AnyView(CannabisDestinationView()) }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(CannabisOnboardingView(complete: complete))
  }

  /// Human-readable label for an intake method. Used by both the Today
  /// row and the edit sheet in TodayLogView — single source of truth.
  static func label(for entry: CannabisEntry) -> String {
    switch entry.method {
    case "vape":   return "Vape"
    case "edible": return "Edible"
    default:       return entry.method.capitalized
    }
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "cannabis",
      summary: "Log cannabis intake with strain and effect.",
      tools: [
        SectionSkill.Tool("cannabis_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("cannabis_event_log",    "Log an intake",
              inputs: "required: method (vape|edible) · optional: date (default today), time (HH:MM:SS), strain (CannabisStrain id), hit (count for vape), grams (for edibles), effect (free-form, e.g. relaxed/creative), note"),
        SectionSkill.Tool("cannabis_event_delete", "Remove an event",
              inputs: "required: id"),
        SectionSkill.Tool("cannabis_strains_list", "Strain catalog"),
        SectionSkill.Tool("cannabis_strain_create", "Add a strain",
              inputs: "required: name"),
        SectionSkill.Tool("cannabis_strain_delete", "Remove a strain",
              inputs: "required: id"),
      ],
      body: """
      `effect` is subjective free-form: "relaxed", "creative", "couch-locked".
      """
    )
  }
}

/// Generic strain placeholders. Real strains vary widely — these are
/// safe defaults that map to common categories the user can rename or
/// extend later. Additive only.
private struct CannabisStrainStarter: Identifiable, Hashable {
  let id: String
  let name: String

  static let all: [CannabisStrainStarter] = [
    .init(id: "starter-indica",       name: "Indica (generic)"),
    .init(id: "starter-sativa",       name: "Sativa (generic)"),
    .init(id: "starter-hybrid",       name: "Hybrid (generic)"),
    .init(id: "starter-cbd-dominant", name: "CBD-dominant"),
  ]
}

private struct CannabisOnboardingView: View {
  let complete: () -> Void
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingNames: Set<String> = []

  private var accent: Color { theme.color(for: "cannabis") }
  private var mutator: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  private func alreadyExists(_ s: CannabisStrainStarter) -> Bool {
    existingNames.contains(s.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<CannabisStrainEntity>())) ?? []
    existingNames = Set(rows.map { $0.name.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Text("Cannabis logs intake with strain and effect. Pre-populating a few generic strain placeholders lets you start logging immediately — rename them later as you identify specific strains.")
              .foregroundStyle(.secondary)
            Text("Skip to add your own strains by name.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
        Section("Strains") {
          ForEach(CannabisStrainStarter.all) { starter in
            starterRow(starter)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Set up Cannabis")
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
  private func starterRow(_ s: CannabisStrainStarter) -> some View {
    let exists = alreadyExists(s)
    let isSelected = selected.contains(s.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(s.id) } else { selected.insert(s.id) }
    } label: {
      HStack(spacing: 12) {
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
    selected.isEmpty ? "Done" : "Add \(selected.count) strain\(selected.count == 1 ? "" : "s")"
  }

  private func addAndFinish() {
    let toAdd = CannabisStrainStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      _ = mutator.addStrain(name: s.name)
    }
    complete()
  }
}
