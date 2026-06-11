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
  @State private var symbol = ""
  @State private var objective = "log"
  @State private var objectiveTarget: Double = 3
  @State private var goalWeekly = false
  @State private var doseStyle = "none"
  @State private var unit = "g"
  @State private var countNoun = "use"
  @State private var containerOn = false
  @State private var containerNoun = "container"
  @State private var containerCap = 3
  @State private var newMethod = ""
  @State private var newItem = ""

  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        goalSection
        measurementSection
        containerSection
        methodsSection
        if let kind, kind.hasCatalog { varietiesSection(kind) }
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
        HStack(spacing: 14) {
          ForEach(IntakeKindWizard.symbols, id: \.self) { s in
            Image(systemName: s)
              .font(.title3)
              .frame(width: 38, height: 38)
              .foregroundStyle(symbol == s ? Color.white : Color.primary)
              .background(symbol == s ? (AdaptiveColor.adaptive(color) ?? .accentColor) : Color.secondary.opacity(0.12),
                          in: RoundedRectangle(cornerRadius: 9))
              .onTapGesture {
                symbol = s
                mutator.updateKind(id: kindID, symbol: s)
              }
          }
        }
        .padding(.vertical, 2)
      }
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

  // Editing with history present follows the §4.2 safety rules: widening
  // doseStyle is free, narrowing hides the field but keeps stored values;
  // changing the unit never rewrites stored amounts.
  private var measurementSection: some View {
    Section {
      Picker("How do you measure it?",
             selection: Binding(get: { doseStyle }, set: setDoseStyle)) {
        Text("Just log it").tag("none")
        Text("Amount").tag("amount")
        Text("Count").tag("count")
        Text("Both").tag("both")
      }
      if doseStyle == "amount" || doseStyle == "both" {
        TextField("Unit (g, mg, ml)", text: $unit)
          .onSubmit { mutator.updateKind(id: kindID, unit: .some(unit)) }
      }
      if doseStyle == "count" || doseStyle == "both" {
        TextField("Count name (hit, cup, puff)", text: $countNoun)
          .onSubmit { mutator.updateKind(id: kindID, countNoun: .some(countNoun)) }
      }
    } header: {
      Text("Measurement")
    } footer: {
      if doseStyle == "amount" || doseStyle == "both" {
        Text("Changing the unit doesn't rewrite past entries — history reads in the new unit.")
      }
    }
  }

  private var containerSection: some View {
    Section {
      Toggle("Comes in containers with limited uses",
             isOn: Binding(get: { containerOn }, set: setContainerOn))
      if containerOn {
        TextField("Container name (capsule, pack)", text: $containerNoun)
          .onSubmit { mutator.updateKind(id: kindID, containerNoun: .some(containerNoun)) }
        Stepper("Uses per container: \(containerCap)",
                value: Binding(get: { containerCap }, set: setContainerCap), in: 1...50)
      }
    } header: {
      Text("Container")
    } footer: {
      if containerOn {
        Text("Mark which method uses the container below. Changing the cap only affects future quick-adds.")
      }
    }
  }

  private var methodsSection: some View {
    Section {
      ForEach(kind?.methods ?? [], id: \.token) { m in
        HStack {
          Text(m.label)
          Spacer()
          if containerOn {
            // Explicit per-method container flag — tap the box to mark this
            // method as the one that consumes the container (vape, cigarette).
            Button {
              toggleContainer(token: m.token)
            } label: {
              Image(systemName: m.usesContainer ? "shippingbox.fill" : "shippingbox")
                .foregroundStyle(m.usesContainer ? (AdaptiveColor.adaptive(color) ?? .accentColor) : .secondary)
            }
            .buttonStyle(.plain)
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
    } header: {
      Text("Methods")
    } footer: {
      if containerOn {
        Text("Tap the box to mark the container method. Deleting a method keeps its entries — they display by name.")
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

  // MARK: Set-handlers (explicit, not .onChange — reload-seeding must not re-fire writes)

  private func setDoseStyle(_ new: String) {
    doseStyle = new
    mutator.updateKind(id: kindID,
                       unit: .some((new == "amount" || new == "both") ? unit : nil),
                       doseStyle: new,
                       countNoun: .some((new == "count" || new == "both") ? countNoun : nil))
    Task { await reload() }
  }

  private func setContainerOn(_ on: Bool) {
    containerOn = on
    mutator.updateKind(id: kindID,
                       containerNoun: .some(on ? containerNoun : nil),
                       containerCap: .some(on ? containerCap : nil))
    Task { await reload() }
  }

  private func setContainerCap(_ cap: Int) {
    containerCap = cap
    mutator.updateKind(id: kindID, containerCap: .some(cap))
  }

  /// Flip one method's "uses container" flag — the explicit control replacing
  /// the wizard's add-order inference.
  private func toggleContainer(token: String) {
    guard var methods = kind?.methods,
          let idx = methods.firstIndex(where: { $0.token == token }) else { return }
    methods[idx].usesContainer.toggle()
    mutator.updateKind(id: kindID, methods: methods)
    Task { await reload() }
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
    let bundle = await MirrorReader.shared.read { ctx -> (IntakeKindDTO?, [IntakeItemDTO], (target: Double, weekly: Bool)?) in
      (IntakeReader.loadKind(context: ctx, id: id),
       IntakeReader.loadItems(context: ctx, kindID: id),
       IntakeReader.objectiveGoalInfo(context: ctx, kindID: id))
    }
    kind = bundle.0
    items = bundle.1
    if name.isEmpty { name = bundle.0?.name ?? "" }
    if color.isEmpty { color = bundle.0?.color ?? "" }
    if symbol.isEmpty { symbol = bundle.0?.symbol ?? "circle" }
    doseStyle = bundle.0?.doseStyle ?? "none"
    if let u = bundle.0?.unit, !u.isEmpty { unit = u }
    if let n = bundle.0?.countNoun, !n.isEmpty { countNoun = n }
    containerOn = bundle.0?.containerCap != nil
    if let n = bundle.0?.containerNoun, !n.isEmpty { containerNoun = n }
    if let cap = bundle.0?.containerCap { containerCap = cap }
    objective = bundle.0?.objective ?? "log"
    goalWeekly = bundle.2?.weekly ?? IntakeObjective.defaultWeekly(objective)
    objectiveTarget = bundle.2?.target
      ?? IntakeObjective.goalSpec(objective, weekly: goalWeekly)?.defaultTarget ?? 3
  }

  private var goalSection: some View {
    // Explicit set-handlers (not .onChange) so reload-seeding the @State doesn't
    // re-fire writes — only a user pick/step writes.
    Section("Goal") {
      Picker("Your goal", selection: Binding(get: { objective }, set: setObjective)) {
        ForEach(IntakeObjective.all, id: \.token) { Text($0.label).tag($0.token) }
      }
      if IntakeObjective.supportsWindowToggle(objective) {
        Picker("Counted", selection: Binding(get: { goalWeekly }, set: setGoalWeekly)) {
          Text("Per day").tag(false)
          Text("Per week").tag(true)
        }
        .pickerStyle(.segmented)
      }
      if IntakeObjective.goalSpec(objective) != nil {
        Stepper("\(IntakeObjective.targetLabel(objective, weekly: goalWeekly)): \(Int(objectiveTarget))",
                value: Binding(get: { objectiveTarget }, set: setTarget), in: 1...365)
      }
    }
  }

  private func setObjective(_ new: String) {
    objective = new
    goalWeekly = IntakeObjective.defaultWeekly(new)
    let t = IntakeObjective.goalSpec(new, weekly: goalWeekly)?.defaultTarget ?? objectiveTarget
    objectiveTarget = t
    mutator.updateKind(id: kindID, objective: new)
    syncGoal(objective: new, target: t)
  }

  private func setGoalWeekly(_ weekly: Bool) {
    goalWeekly = weekly
    syncGoal(objective: objective, target: objectiveTarget)
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
