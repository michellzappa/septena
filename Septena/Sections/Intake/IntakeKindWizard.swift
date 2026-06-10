import SwiftUI

// Create-a-kind form. Phrased as plain questions over the §4 aspect axes, not
// schema. The 15-second path is load-bearing: name + symbol → Create works
// (one default method, doseStyle "none"); every axis is editable later in the
// Manage sheet. This is also the cannabis-reconstruction path — two methods,
// one with container semantics, under a minute. See docs/CONSUMABLES_PLAN.md.

struct IntakeKindWizard: View {
  var onCreated: (String) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var symbol = "cup.and.saucer"
  @State private var color = Self.palette[0]

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

  static let palette = ["#92400e", "#65a30d", "#0369a1", "#7c3aed",
                        "#be123c", "#ca8a04", "#0d9488", "#475569"]
  static let symbols = ["cup.and.saucer", "leaf", "mug", "wineglass", "pills",
                        "drop", "flame", "carrot", "bolt", "heart", "pencil", "circle"]

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        measurementSection
        methodsSection
        varietiesSection
      }
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
  }

  // MARK: Sections

  private var identitySection: some View {
    Section("Identity") {
      TextField("Name (e.g. Caffeine, Tea)", text: $name)
      symbolPicker
      colorPicker
    }
  }

  private var symbolPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 14) {
        ForEach(Self.symbols, id: \.self) { s in
          Image(systemName: s)
            .font(.title3)
            .frame(width: 38, height: 38)
            .foregroundStyle(symbol == s ? Color.white : Color.primary)
            .background(symbol == s ? (AdaptiveColor.adaptive(color) ?? .accentColor) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9))
            .onTapGesture { symbol = s }
        }
      }
      .padding(.vertical, 2)
    }
  }

  private var colorPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(Self.palette, id: \.self) { hex in
          Circle()
            .fill(AdaptiveColor.adaptive(hex) ?? .gray)
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(Color.primary, lineWidth: color == hex ? 2 : 0))
            .onTapGesture { color = hex }
        }
      }
      .padding(.vertical, 2)
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
      ForEach(methods, id: \.token) { m in
        HStack {
          Text(m.label)
          if m.usesContainer {
            Spacer()
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
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
    let token = IntakeMigrationMap.slug(label)
    guard !token.isEmpty, !methods.contains(where: { $0.token == token }) else { return }
    // The first container-marked method drives the container quick-add; here a
    // newly added method inherits the kind's container intent so cannabis-style
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
      methods: methods)
    Haptics.success()
    onCreated(kind.id)
    dismiss()
  }
}
