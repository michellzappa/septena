import SwiftUI
import SwiftData

// Manage a kind — the generalization of caffeine's "Manage types"
// (CaffeineTypeSheet). Methods, varieties, identity, container cap, and the
// archive control all live here at the destination; Settings stays read-only
// (the established convention). Deletion posture: kinds archive (never hard
// delete); items keep the legacy single-row delete. See docs/CONSUMABLES_PLAN.md.

struct IntakeManageSheet: View {
  let kindID: String

  @Environment(\.dismiss) private var dismiss

  @State private var kind: IntakeKindDTO? = nil
  @State private var items: [IntakeItemDTO] = []
  @State private var name = ""
  @State private var color = ""
  @State private var objective = "log"
  @State private var objectiveTarget: Double = 3
  @State private var containerCap = 3
  @State private var newMethod = ""
  @State private var newItem = ""

  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        goalSection
        methodsSection
        if let kind, kind.hasCatalog { varietiesSection(kind) }
        if kind?.containerCap != nil { containerSection }
        dangerSection
      }
      .navigationTitle("Manage")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .task { await reload() }
  }

  // MARK: Sections

  private var identitySection: some View {
    Section("Identity") {
      TextField("Name", text: $name)
        .onSubmit { mutator.updateKind(id: kindID, name: name) }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(IntakeKindWizard.palette, id: \.self) { hex in
            Circle()
              .fill(AdaptiveColor.adaptive(hex) ?? .gray)
              .frame(width: 26, height: 26)
              .overlay(Circle().strokeBorder(Color.primary, lineWidth: color == hex ? 2 : 0))
              .onTapGesture {
                color = hex
                mutator.updateKind(id: kindID, color: hex)
              }
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private var methodsSection: some View {
    Section("Methods") {
      ForEach(kind?.methods ?? [], id: \.token) { m in
        HStack {
          Text(m.label)
          if m.usesContainer {
            Spacer()
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
          }
        }
      }
      .onDelete { offsets in
        guard var methods = kind?.methods else { return }
        methods.remove(atOffsets: offsets)
        mutator.updateKind(id: kindID, methods: methods)
        Task { await reload() }
      }
      HStack {
        TextField("Add a method", text: $newMethod)
        Button("Add") { addMethod() }
          .disabled(newMethod.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func varietiesSection(_ kind: IntakeKindDTO) -> some View {
    Section(kind.catalogNoun ?? "Varieties") {
      ForEach(items) { item in Text(item.name) }
        .onDelete { offsets in
          for i in offsets { mutator.deleteItem(id: items[i].id) }
          Task { await reload() }
        }
      HStack {
        TextField("Add", text: $newItem)
        Button("Add") {
          let n = newItem.trimmingCharacters(in: .whitespaces)
          guard !n.isEmpty else { return }
          mutator.addItem(kindID: kindID, name: n)
          newItem = ""
          Task { await reload() }
        }
        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private var containerSection: some View {
    Section("Container") {
      Stepper("Uses per container: \(containerCap)", value: $containerCap, in: 1...50)
        .onChange(of: containerCap) { _, new in
          mutator.updateKind(id: kindID, containerCap: new)
        }
    }
  }

  private var dangerSection: some View {
    Section {
      Button(role: .destructive) {
        mutator.setKindArchived(id: kindID, archived: true)
        dismiss()
      } label: {
        Label("Archive tracker", systemImage: "archivebox")
      }
    } footer: {
      Text("Archiving hides this tracker. Its entries stay and it can be restored.")
    }
  }

  private func addMethod() {
    let label = newMethod.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty, var methods = kind?.methods else { return }
    let token = IntakeMigrationMap.slug(label)
    guard !token.isEmpty, !methods.contains(where: { $0.token == token }) else { return }
    methods.append(.init(token: token, label: label))
    mutator.updateKind(id: kindID, methods: methods)
    newMethod = ""
    Task { await reload() }
  }

  private func reload() async {
    let id = kindID
    let bundle = await MirrorReader.shared.read { ctx -> (IntakeKindDTO?, [IntakeItemDTO], Double?) in
      (IntakeReader.loadKind(context: ctx, id: id),
       IntakeReader.loadItems(context: ctx, kindID: id),
       IntakeReader.objectiveGoalTarget(context: ctx, kindID: id))
    }
    kind = bundle.0
    items = bundle.1
    if name.isEmpty { name = bundle.0?.name ?? "" }
    if color.isEmpty { color = bundle.0?.color ?? "" }
    if let cap = bundle.0?.containerCap { containerCap = cap }
    objective = bundle.0?.objective ?? "log"
    objectiveTarget = bundle.2 ?? IntakeObjective.goalSpec(objective)?.defaultTarget ?? 3
  }

  private var goalSection: some View {
    // Explicit set-handlers (not .onChange) so reload-seeding the @State doesn't
    // re-fire writes — only a user pick/step writes.
    Section("Goal") {
      Picker("Your goal", selection: Binding(get: { objective }, set: setObjective)) {
        ForEach(IntakeObjective.all, id: \.token) { Text($0.label).tag($0.token) }
      }
      if IntakeObjective.goalSpec(objective) != nil {
        Stepper("\(IntakeObjective.targetLabel(objective)): \(Int(objectiveTarget))",
                value: Binding(get: { objectiveTarget }, set: setTarget), in: 1...365)
      }
    }
  }

  private func setObjective(_ new: String) {
    objective = new
    let t = IntakeObjective.goalSpec(new)?.defaultTarget ?? objectiveTarget
    objectiveTarget = t
    mutator.updateKind(id: kindID, objective: new)
    syncGoal(objective: new, target: t)
  }

  private func setTarget(_ t: Double) {
    objectiveTarget = t
    syncGoal(objective: objective, target: t)
  }

  private func syncGoal(objective: String, target: Double) {
    SeptenaServices.shared.goalMutator.syncIntakeObjectiveGoal(
      kindID: kindID, kindName: name, objective: objective, target: target)
  }
}
