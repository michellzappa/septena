import SwiftUI

// Create-a-kind form. Phrased as plain questions over the §4 aspect axes, not
// schema. The 15-second path is load-bearing: name + symbol → Create works
// (one default method, doseStyle "none"); every axis is editable later in the
// Manage sheet. This is also the container-tracker path — two methods,
// one with container semantics, under a minute. See docs/CONSUMABLES_PLAN.md.

struct IntakeKindWizard: View {
  var onCreated: (String) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var symbol = "cup.and.saucer"
  @State private var color = sectionPalette.first?.hex ?? "#3b82f6"

  @State private var objective = "log"
  @State private var objectiveTarget: Double = 3
  @State private var objectiveWeekly = false

  @State private var doseStyle = "none"
  @State private var unit = "g"
  @State private var countNoun = "use"
  @State private var usesContainers = false
  @State private var containerNoun = "container"
  @State private var containerCap = 3

  @State private var methods: [IntakeMethodRow] = [
    .init(token: "default", label: "Default")
  ]
  @State private var newMethod = ""

  @State private var catalogNoun = ""

  private var mutator: IntakeMutator { SeptenaServices.shared.intakeMutator }
  private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

  // The kind/type always carries an SF Symbol (DesignSpec Tier-1/2). Emoji is
  // for the long-tail instances (methods, varieties), not the type itself.
  static let symbols = ["cup.and.saucer", "leaf", "mug", "wineglass", "pills",
                        "drop", "flame", "carrot", "bolt", "heart", "pencil", "circle"]

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        objectiveSection
        measurementSection
        methodsSection
        varietiesSection
      }
      .formStyle(.grouped)
      .navigationTitle("New tracker")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create", action: create).disabled(!canCreate)
        }
      }
    }
    .macSheetFrame()
  }

  // MARK: Sections

  private var identitySection: some View {
    Section("Identity") {
      HStack(spacing: 10) {
        TextField("Name (e.g. Caffeine, Tea)", text: $name)
        // Shared compact swatch button — same picker the section detail and
        // the Manage sheet use — not a full inline grid of colors.
        PaletteSwatchButton(selectedHex: color) { color = $0 }
      }
      symbolPicker
    }
  }

  private var symbolPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 14) {
        ForEach(Self.symbols, id: \.self) { s in
          Image(systemName: s)
            .font(.title3)
            .frame(width: 38, height: 38)
            .foregroundStyle(symbol == s ? AdaptiveColor.inkOnSolidFill(AdaptiveColor.adaptive(color) ?? .accentColor) : Color.primary)
            .background(symbol == s ? (AdaptiveColor.adaptive(color) ?? .accentColor) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9))
            .inlineHover(cornerRadius: 9)
            .onTapGesture { symbol = s }
        }
      }
      .padding(.vertical, 2)
    }
  }

  private var objectiveSection: some View {
    Section {
      Picker("Your goal", selection: $objective) {
        ForEach(IntakeObjective.all, id: \.token) { Text($0.label).tag($0.token) }
      }
      .onChange(of: objective) { _, new in
        objectiveWeekly = IntakeObjective.defaultWeekly(new)
        if let spec = IntakeObjective.goalSpec(new, weekly: objectiveWeekly) {
          objectiveTarget = spec.defaultTarget
        }
      }
      if IntakeObjective.supportsWindowToggle(objective) {
        Picker("Counted", selection: $objectiveWeekly) {
          Text("Per day").tag(false)
          Text("Per week").tag(true)
        }
        .pickerStyle(.segmented)
      }
      if IntakeObjective.goalSpec(objective) != nil {
        Stepper("\(IntakeObjective.targetLabel(objective, weekly: objectiveWeekly)): \(Int(objectiveTarget))",
                value: $objectiveTarget, in: 1...365)
      }
    } header: {
      Text("Goal")
    } footer: {
      Text("This creates a goal you can track. Reduce and Quit also show a days-since-last streak.")
    }
  }

  private var measurementSection: some View {
    Section("Measurement") {
      Picker("How do you measure it?", selection: $doseStyle) {
        Text("Just log it").tag("none")
        Text("Amount").tag("amount")
        Text("Count").tag("count")
        Text("Both").tag("both")
      }
      if doseStyle == "amount" || doseStyle == "both" {
        TextField("Unit (g, mg, ml)", text: $unit)
      }
      if doseStyle == "count" || doseStyle == "both" {
        TextField("Count name (hit, cup, puff)", text: $countNoun)
      }
      Toggle("Comes in containers with limited uses", isOn: $usesContainers)
      if usesContainers {
        TextField("Container name (capsule, pack)", text: $containerNoun)
        Stepper("Uses per container: \(containerCap)", value: $containerCap, in: 1...50)
      }
    }
  }

  private var methodsSection: some View {
    Section("Methods") {
      ForEach(methods.indices, id: \.self) { idx in
        HStack {
          // A method can carry its own Tier-3 emoji (shown in the quick-add).
          EmojiSlotPicker(emoji: Binding(
            get: { methods[idx].emoji ?? "" },
            set: { methods[idx].emoji = $0.isEmpty ? nil : $0 }))
          Text(methods[idx].label)
          Spacer()
          if usesContainers {
            // Explicit per-method container flag (tap to mark the method that
            // consumes the container) — no add-order inference.
            Button {
              methods[idx].usesContainer.toggle()
            } label: {
              Image(systemName: methods[idx].usesContainer ? "shippingbox.fill" : "shippingbox")
                .foregroundStyle(methods[idx].usesContainer ? (AdaptiveColor.adaptive(color) ?? .accentColor) : .secondary)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .onDelete { methods.remove(atOffsets: $0) }
      HStack {
        TextField("Add a method", text: $newMethod)
        Button("Add") { addMethod() }
          .disabled(newMethod.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private var varietiesSection: some View {
    Section("Varieties (optional)") {
      TextField("Name for varieties (Beans, Strains)", text: $catalogNoun)
    }
  }

  // MARK: Actions

  private func addMethod() {
    let label = newMethod.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return }
    let token = IntakeTemplates.slug(label)
    guard !token.isEmpty, !methods.contains(where: { $0.token == token }) else { return }
    // The first container-marked method drives the container quick-add; here a
    // newly added method inherits the kind's container intent so container-style
    // reconstruction (vape uses the capsule) is a one-toggle setup.
    methods.append(.init(token: token, label: label, usesContainer: usesContainers && methods.allSatisfy { !$0.usesContainer }))
    newMethod = ""
  }

  private func create() {
    let kind = mutator.addKind(
      name: name.trimmingCharacters(in: .whitespaces),
      symbol: symbol,
      color: color,
      unit: (doseStyle == "amount" || doseStyle == "both") ? unit : nil,
      doseStyle: doseStyle,
      countNoun: (doseStyle == "count" || doseStyle == "both") ? countNoun : nil,
      containerNoun: usesContainers ? containerNoun : nil,
      containerCap: usesContainers ? containerCap : nil,
      catalogNoun: catalogNoun.isEmpty ? nil : catalogNoun,
      objective: objective,
      methods: methods)
    // The unify: the objective creates its matching Goal (limit's cap = target).
    SeptenaServices.shared.goalMutator.syncIntakeObjectiveGoal(
      kindID: kind.id, kindName: name.trimmingCharacters(in: .whitespaces),
      objective: objective, target: objectiveTarget, weekly: objectiveWeekly)
    Haptics.success()
    onCreated(kind.id)
    dismiss()
  }
}
