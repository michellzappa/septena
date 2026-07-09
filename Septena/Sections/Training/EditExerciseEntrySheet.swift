import SwiftUI

// Edit sheet for a logged training entry. A SwiftUI `Form` hosted by the
// shared `AdaptiveEditScaffold` and presented via `.adaptiveDetail(item:)`.
// Saves go through the local-first training mutator; cardio and strength use
// the same entry record with their respective fields.

struct EditExerciseEntrySheet: View {
  private var trainingMutator: TrainingMutator { SeptenaServices.shared.trainingMutator }

  let original: ExerciseEntry
  let onSave: (ExerciseEntry) -> Void

  // Strength fields
  @State private var weight: String = ""
  @State private var sets: String = ""
  @State private var reps: String = ""
  @State private var difficulty: String = ""

  // Cardio fields
  @State private var durationMin: String = ""
  @State private var distanceM: String = ""
  @State private var level: String = ""

  @State private var note: String = ""

  // Drives the keyboard "Done" bar — decimal pads have no return key.
  @FocusState private var numberFocused: Bool

  @AppStorage(EffortScale.storageKey) private var effortScaleRaw = EffortScale.difficulty.rawValue
  private var effortScale: EffortScale { EffortScale(rawValue: effortScaleRaw) ?? .difficulty }

  @AppStorage(WeightUnit.defaultsKey) private var weightUnitRaw = WeightUnit.kg.rawValue
  private var weightUnit: WeightUnit { WeightUnit.resolve(weightUnitRaw) }

  /// Cardio if the loaded entry already carries any cardio-shaped field.
  private var isCardio: Bool {
    original.durationMin != nil || original.distanceM != nil || original.level != nil
  }

  var body: some View {
    AdaptiveEditScaffold(title: "Edit entry", canSave: original.file != nil, onSave: save) {
      formBody
        .keyboardDoneBar($numberFocused)
        .onAppear { seed() }
    }
  }

  @ViewBuilder private var formBody: some View {
    Form {
        Section(original.exercise ?? "Exercise") {
          Text(original.session.capitalized.isEmpty ? "Session" : original.session.capitalized)
            .foregroundStyle(.secondary)
        }
        if isCardio {
          Section("Cardio") {
            numberRow("Duration (min)", text: $durationMin)
            numberRow("Distance (\(DistanceUnit.current.inputSuffix))", text: $distanceM)
            numberRow("Level", text: $level)
          }
        } else {
          Section("Strength") {
            numberRow("Weight (\(weightUnit.suffix))", text: $weight)
            numberRow("Sets", text: $sets)
            numberRow("Reps", text: $reps)
            // Leading label already says "RIR"/"Difficulty", so the RIR
            // segments stay bare numbers ("3+","2","1","0") to fit five
            // segments on a phone.
            Picker(effortScale.label, selection: $difficulty) {
              Text("—").tag("")
              ForEach(TrainingEffort.levels) { lvl in
                Text(effortScale == .rir ? lvl.rirLabel : lvl.label).tag(lvl.key)
              }
            }
            .pickerStyle(.segmented)
          }
        }
        Section("Note") {
          TextField("Note", text: $note, axis: .vertical)
            .lineLimit(1...4)
        }
      }
  }

  private func numberRow(_ label: String, text: Binding<String>) -> some View {
    HStack {
      Text(label)
      Spacer()
      TextField("", text: text)
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
        .focused($numberFocused)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 100)
    }
  }

  private func seed() {
    // Stored in kg; show in the user's chosen unit, parse back to kg on save.
    weight = original.weight.map { numString(weightUnit.display($0)) } ?? ""
    sets = original.sets ?? ""
    reps = original.reps ?? ""
    // Fold any legacy spelling ("medium"/"max") to a canonical key so the
    // segmented picker selects a real tag; saving then rewrites it canonical.
    difficulty = TrainingEffort.canonicalKey(original.difficulty) ?? ""
    durationMin = original.durationMin.map(numString) ?? ""
    // Stored in meters; show in the user's distance input unit (m or mi).
    distanceM = original.distanceM.map { numString(DistanceUnit.current.inputFromMeters($0)) } ?? ""
    level = original.level.map(numString) ?? ""
  }

  private func numString(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : d.decimalString()
  }

  /// The typed weight parsed back into kilograms for storage (the field shows
  /// the user's unit; the model is always kg).
  private func parseWeightKg() -> Double? {
    parseWeightKg().map { weightUnit.toKilograms($0) }
  }

  private func parseDouble(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    return t.isEmpty ? nil : Double(t)
  }

  private func parseInt(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : Int(t)
  }

  /// The typed distance parsed back into meters (the field shows m or mi).
  private func parseDistanceMeters() -> Double? {
    parseDouble(distanceM).map { DistanceUnit.current.metersFromInput($0) }
  }

  private func save() {
    guard let id = original.file else { return }
    let noteTrim = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let setsStr = parseInt(sets).map(String.init) ?? sets.trimmingCharacters(in: .whitespaces)
    let repsStr = parseInt(reps).map(String.init) ?? reps.trimmingCharacters(in: .whitespaces)

    if isCardio {
      trainingMutator.updateEntry(
        id: id,
        weight: .some(nil),
        sets: .some(nil),
        reps: .some(nil),
        difficulty: .some(nil),
        durationMin: .some(parseDouble(durationMin)),
        distanceM: .some(parseDistanceMeters()),
        level: .some(parseInt(level).map(Double.init)),
        note: .some(noteTrim.isEmpty ? nil : noteTrim)
      )
    } else {
      trainingMutator.updateEntry(
        id: id,
        weight: .some(parseWeightKg()),
        sets: .some(setsStr.isEmpty ? nil : setsStr),
        reps: .some(repsStr.isEmpty ? nil : repsStr),
        difficulty: .some(difficulty.isEmpty ? nil : difficulty),
        durationMin: .some(nil),
        distanceM: .some(nil),
        level: .some(nil),
        note: .some(noteTrim.isEmpty ? nil : noteTrim)
      )
    }
    Haptics.tick()

    // Optimistic in-flight callback. Synthesize an updated entry so the
    // caller's list refreshes immediately; the mirror reload via
    // .septenaDataChanged will reconcile shortly after.
    let updated = ExerciseEntry(
      date: original.date,
      session: original.session,
      exercise: original.exercise,
      weight: isCardio ? nil : parseWeightKg(),
      sets: isCardio ? nil : (setsStr.isEmpty ? nil : setsStr),
      reps: isCardio ? nil : (repsStr.isEmpty ? nil : repsStr),
      difficulty: isCardio ? nil : (difficulty.isEmpty ? nil : difficulty),
      durationMin: isCardio ? parseDouble(durationMin) : nil,
      distanceM: isCardio ? parseDistanceMeters() : nil,
      level: isCardio ? parseInt(level).map(Double.init) : nil,
      file: id,
      concludedAt: original.concludedAt,
      loggedAt: original.loggedAt
    )
    onSave(updated)
  }
}
