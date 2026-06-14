import SwiftUI
import PhotosUI

// New-entry sheet for a fresh meal. Same `Form` shape as
// `EditNutritionEntrySheet` so the UI feels identical, but POSTs to
// `/api/nutrition/entries` instead of PUTting an update. Presented
// from the Nutrition QuickAdd menu's "New meal…" item.

struct NewNutritionEntrySheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @State private var time: Date = Date()
  @State private var emoji: String = ""
  @State private var foodsText: String = ""
  @State private var ingredientsText: String = ""
  @State private var proteinG: String = ""
  @State private var fatG: String = ""
  @State private var saturatedFatG: String = ""
  @State private var carbsG: String = ""
  @State private var sugarG: String = ""
  @State private var fiberG: String = ""
  @State private var alcoholG: String = ""
  @State private var kcal: String = ""
  @State private var sodiumMg: String = ""
  @State private var cholesterolMg: String = ""
  @State private var potassiumMg: String = ""
  @State private var waterMl: String = ""

  @State private var photoItem: PhotosPickerItem? = nil
  @State private var photoAssetID: String? = nil

  var body: some View {
    AdaptiveEditScaffold(
      title: "New meal",
      canSave: !foodsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onSave: save
    ) {
      formBody
        .onChange(of: photoItem) { _, new in
          guard let new else { return }
          Task {
            await PhotosBridge.shared.ensureAccess()
            await MainActor.run { photoAssetID = new.itemIdentifier }
          }
        }
    }
  }

  @ViewBuilder private var formBody: some View {
      Form {
        Section("When") {
          SteppedDatePicker("Time",
                            selection: $time,
                            displayedComponents: .hourAndMinute)
        }
        Section("Meal") {
          LabeledContent("Emoji") { EmojiSlotPicker(emoji: $emoji) }
          TextField("Foods (one per line)", text: $foodsText, axis: .vertical)
            .lineLimit(2...8)
          TextField("Ingredients (one per line)",
                    text: $ingredientsText, axis: .vertical)
            .lineLimit(1...6)
        }
        Section("Photo") {
          HStack(spacing: 12) {
            MealPhotoThumbnail(assetID: photoAssetID, size: 56)
            VStack(alignment: .leading, spacing: 2) {
              PhotosPicker(
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
              ) {
                Text(photoAssetID == nil ? "Choose photo…" : "Change photo")
              }
              if photoAssetID != nil {
                Button(role: .destructive) {
                  photoItem = nil
                  photoAssetID = nil
                } label: {
                  Text("Remove").font(.caption)
                }
              }
            }
          }
        }
        Section("Macros") {
          macroField("Protein (g)", text: $proteinG)
          macroField("Fat (g)", text: $fatG)
          macroField("Saturated Fat (g)", text: $saturatedFatG)
          macroField("Carbs (g)", text: $carbsG)
          macroField("Sugar (g)", text: $sugarG)
          macroField("Fiber (g)", text: $fiberG)
          macroField("Alcohol (g)", text: $alcoholG)
          macroField("kcal", text: $kcal)
        }
        Section("Other Nutrients") {
          macroField("Sodium (mg)", text: $sodiumMg)
          macroField("Cholesterol (mg)", text: $cholesterolMg)
          macroField("Potassium (mg)", text: $potassiumMg)
          macroField("Water (ml)", text: $waterMl)
        }
      }
  }

  private func macroField(_ label: String, text: Binding<String>) -> some View {
    LabeledContent(label) {
      TextField("", text: text)
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
        .multilineTextAlignment(.trailing)
    }
  }

  private func parseDouble(_ s: String) -> Double {
    Double(s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")) ?? 0
  }

  private func parseOpt(_ s: String) -> Double? {
    let v = parseDouble(s)
    return v == 0 ? nil : v
  }

  private func lines(_ s: String) -> [String] {
    s.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func save() {
    let foods = lines(foodsText)
    guard !foods.isEmpty else { return }
    let emojiValue = emoji.trimmingCharacters(in: .whitespacesAndNewlines)

    NutritionPlugin.commitMeal(
      loggedAt: time,
      accent: theme.color(for: "nutrition"),
      announce: "Logged \(foods.first ?? "meal").",
      logCommit: logCommit
    ) {
      SeptenaServices.shared.nutritionMutator.addEntry(
        loggedAt: time,
        emoji: emojiValue.isEmpty ? nil : emojiValue,
        foods: foods,
        proteinG: parseDouble(proteinG),
        fatG: parseDouble(fatG),
        carbsG: parseDouble(carbsG),
        fiberG: parseOpt(fiberG),
        sugarG: parseOpt(sugarG),
        saturatedFatG: parseOpt(saturatedFatG),
        alcoholG: parseOpt(alcoholG),
        kcal: parseOpt(kcal),
        sodiumMg: parseOpt(sodiumMg),
        cholesterolMg: parseOpt(cholesterolMg),
        potassiumMg: parseOpt(potassiumMg),
        waterMl: parseOpt(waterMl),
        photoAssetID: photoAssetID
      )
      AddInfoSection.nutrition.notifyTilesChanged()
    }
  }
}
