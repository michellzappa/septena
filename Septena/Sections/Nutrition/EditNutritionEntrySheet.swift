import SwiftUI

// Edit/create sheet for a logged nutrition entry. Standard SwiftUI `Form` in a
// `NavigationStack` presented via `.sheet(item:)` (edit) or
// `.sheet(isPresented:)` (create). Mutations go through NutritionMutator
// (local SwiftData + CKEngine queue).

struct EditNutritionEntrySheet: View {
  @Environment(\.dismiss) private var dismiss

  let original: NutritionEntry?
  let onDone: () -> Void

  @State private var time: Date = Date()
  @State private var emoji: String = ""
  @State private var foodsText: String = ""
  @State private var ingredientsText: String = ""
  @State private var proteinG: String = ""
  @State private var fatG: String = ""
  @State private var carbsG: String = ""
  @State private var fiberG: String = ""
  @State private var kcal: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("When") {
          DatePicker("Time",
                     selection: $time,
                     displayedComponents: .hourAndMinute)
        }
        Section("Meal") {
          TextField("Emoji", text: $emoji)
          // `axis: .vertical` is the documented SwiftUI affordance for a
          // growing multi-line `TextField` (iOS 16+). One food per line —
          // mirrors what the server already parses on POST/PUT.
          TextField("Foods (one per line)", text: $foodsText, axis: .vertical)
            .lineLimit(2...8)
          TextField("Ingredients (one per line)",
                    text: $ingredientsText, axis: .vertical)
            .lineLimit(1...6)
        }
        Section("Macros") {
          macroField("Protein (g)", text: $proteinG)
          macroField("Fat (g)", text: $fatG)
          macroField("Carbs (g)", text: $carbsG)
          macroField("Fiber (g)", text: $fiberG)
          macroField("kcal", text: $kcal)
        }
      }
      .navigationTitle(original == nil ? "New Meal" : "Edit Meal")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
        }
      }
      .onAppear { seed() }
    }
  }

  private func macroField(_ label: String, text: Binding<String>) -> some View {
    HStack {
      Text(label)
      Spacer()
      TextField("0", text: text)
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 100)
    }
  }

  private func seed() {
    if let original {
      emoji = original.emoji ?? ""
      foodsText = original.foods.joined(separator: "\n")
      ingredientsText = (original.ingredients ?? []).joined(separator: "\n")
      proteinG = numString(original.proteinG)
      fatG     = numString(original.fatG)
      carbsG   = numString(original.carbsG)
      fiberG   = numString(original.fiberG ?? 0)
      kcal     = numString(original.kcal)
      let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
      time = fmt.date(from: original.time) ?? Date()
    } else {
      emoji = ""
      foodsText = ""
      ingredientsText = ""
      proteinG = ""
      fatG = ""
      carbsG = ""
      fiberG = ""
      kcal = ""
      time = Date()
    }
  }

  private func numString(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
  }

  private func parseDouble(_ s: String) -> Double {
    Double(s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")) ?? 0
  }

  private func lines(_ s: String) -> [String] {
    s.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func save() {
    let foods = lines(foodsText)
    let p = parseDouble(proteinG)
    let f = parseDouble(fatG)
    let c = parseDouble(carbsG)
    let fb = parseDouble(fiberG)
    let k = parseDouble(kcal)
    let emojiValue = emoji.trimmingCharacters(in: .whitespacesAndNewlines)

    let mutator = SeptenaServices.shared.nutritionMutator
    if let original {
      mutator.updateEntry(
        id: original.file,
        pickedTime: time,
        emoji: emojiValue.isEmpty ? nil : emojiValue,
        foods: foods,
        proteinG: p, fatG: f, carbsG: c,
        fiberG: fb == 0 ? nil : fb,
        kcal: k == 0 ? nil : k
      )
    } else {
      mutator.addEntry(
        loggedAt: time,
        emoji: emojiValue.isEmpty ? nil : emojiValue,
        foods: foods,
        proteinG: p, fatG: f, carbsG: c,
        fiberG: fb == 0 ? nil : fb,
        kcal: k == 0 ? nil : k
      )
    }
    Haptics.tick()
    onDone()
    dismiss()
  }
}
