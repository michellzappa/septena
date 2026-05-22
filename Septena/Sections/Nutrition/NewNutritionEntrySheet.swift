import SwiftUI

// New-entry sheet for a fresh meal. Same `Form` shape as
// `EditNutritionEntrySheet` so the UI feels identical, but POSTs to
// `/api/nutrition/entries` instead of PUTting an update. Presented
// from the Nutrition QuickAdd menu's "New meal…" item.

struct NewNutritionEntrySheet: View {
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(\.dismiss) private var dismiss

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
      .navigationTitle("New meal")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(foodsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
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
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    let hhmm = fmt.string(from: time)
    let foods = lines(foodsText)
    guard !foods.isEmpty else { return }
    let emojiValue = emoji.trimmingCharacters(in: .whitespacesAndNewlines)

    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": hhmm,
      "foods": foods,
      "protein_g": parseDouble(proteinG),
      "fat_g": parseDouble(fatG),
      "carbs_g": parseDouble(carbsG),
      "kcal": parseDouble(kcal),
    ]
    let fiber = parseDouble(fiberG)
    if fiber > 0 { body["fiber_g"] = fiber }
    if !emojiValue.isEmpty { body["emoji"] = emojiValue }
    let ings = lines(ingredientsText)
    if !ings.isEmpty { body["ingredients"] = ings }

    outbox.enqueue(method: "POST", path: "/api/nutrition/entries",
                   body: body, kind: "nutrition.add")
    AddInfoSection.nutrition.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }
}
