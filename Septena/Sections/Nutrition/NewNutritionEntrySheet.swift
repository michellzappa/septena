import SwiftUI
import PhotosUI

// New-entry sheet for a fresh meal. Same `Form` shape as
// `EditNutritionEntrySheet` so the UI feels identical, but POSTs to
// `/api/nutrition/entries` instead of PUTting an update. Presented
// from the Nutrition QuickAdd menu's "New meal…" item.

struct NewNutritionEntrySheet: View {
  /// Opened from a "Scan a meal…" entry point — surfaces a camera affordance in
  /// the Photo section, but never auto-launches the camera on appear.
  var autoStartScan: Bool = false

  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
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
  @State private var analyzing = false
  @State private var analysisNote: String? = nil
  @State private var scanPickerPresented = false
  @State private var cameraPresented = false

  var body: some View {
    AdaptiveEditScaffold(
      title: "New meal",
      canSave: !foodsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onSave: save
    ) {
      formBody
        .onChange(of: photoItem) { _, new in
          guard let new else { return }
          Task { await handlePicked(new) }
        }
        .photosPicker(
          isPresented: $scanPickerPresented,
          selection: $photoItem,
          matching: .images,
          photoLibrary: .shared()
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $cameraPresented) {
          MealCameraPicker { image in
            cameraPresented = false
            guard let image, let data = image.jpegData(compressionQuality: 0.8) else { return }
            Task { await handleScannedData(data) }
          }
          .ignoresSafeArea()
        }
        #endif
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
              if autoStartScan {
                Button { presentScanCapture() } label: {
                  Label(photoAssetID == nil ? "Take photo…" : "Retake photo",
                        systemImage: "camera.viewfinder")
                }
              }
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
                  analysisNote = nil
                } label: {
                  Text("Remove").font(.caption)
                }
              }
            }
          }
          if analyzing {
            HStack(spacing: 8) {
              ProgressView()
              Text("Reading the photo…").font(.caption).foregroundStyle(.secondary)
            }
          } else if let analysisNote {
            Text(analysisNote).font(.caption).foregroundStyle(.secondary)
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
          macroField("Water (\(VolumeUnit.current.suffix))", text: $waterMl)
        }
      }
  }

  private func presentScanCapture() {
    if MealCamera.isAvailable {
      cameraPresented = true
    } else {
      scanPickerPresented = true
    }
  }

  // Record the asset, then analyze the photo into a draft and pre-fill any
  // fields the user hasn't already typed into. The draft is a starting point —
  // every value lands in an editable field the user confirms before saving.
  private func handlePicked(_ item: PhotosPickerItem) async {
    await PhotosBridge.shared.ensureAccess()
    await MainActor.run {
      photoAssetID = item.itemIdentifier
      analyzing = true
      analysisNote = nil
    }
    guard let data = try? await item.loadTransferable(type: Data.self) else {
      await MainActor.run { analyzing = false }
      return
    }
    await analyzeAndFill(data)
  }

  // A camera capture isn't in the photo library, so save it first to mint the
  // asset ID the meal thumbnail renders from, then analyze the same bytes.
  private func handleScannedData(_ data: Data) async {
    await MainActor.run { analyzing = true; analysisNote = nil }
    await PhotosBridge.shared.ensureAccess()
    if let id = await MealPhotoLibrary.save(data) {
      await MainActor.run { photoAssetID = id }
    }
    await analyzeAndFill(data)
  }

  /// Analyze image bytes and pre-fill the empty fields. Caller has already set
  /// `analyzing = true`.
  private func analyzeAndFill(_ data: Data) async {
    let draft = await MealPhotoAnalyzer.analyze(imageData: data)
    await MainActor.run {
      prefill(from: draft)
      analysisNote = draft.note
      analyzing = false
    }
  }

  /// Fill only the fields the user has left blank — never clobber typed input.
  private func prefill(from draft: MealPhotoDraft) {
    if foodsText.isEmpty, !draft.foods.isEmpty {
      foodsText = draft.foods.joined(separator: "\n")
    }
    if ingredientsText.isEmpty, !draft.ingredients.isEmpty {
      ingredientsText = draft.ingredients.joined(separator: "\n")
    }
    fillIfEmpty($proteinG, draft.proteinG)
    fillIfEmpty($fatG, draft.fatG)
    fillIfEmpty($saturatedFatG, draft.saturatedFatG)
    fillIfEmpty($carbsG, draft.carbsG)
    fillIfEmpty($sugarG, draft.sugarG)
    fillIfEmpty($fiberG, draft.fiberG)
    fillIfEmpty($kcal, draft.kcal)
    fillIfEmpty($sodiumMg, draft.sodiumMg)
    fillIfEmpty($cholesterolMg, draft.cholesterolMg)
    fillIfEmpty($potassiumMg, draft.potassiumMg)
  }

  private func fillIfEmpty(_ field: Binding<String>, _ value: Double?) {
    guard field.wrappedValue.isEmpty, let value else { return }
    field.wrappedValue = value == value.rounded()
      ? String(Int(value))
      : String(format: "%.1f", value)
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
      today: clock.today,
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
        waterMl: parseOpt(waterMl).map { VolumeUnit.current.toMillilitersDouble($0) },
        photoAssetID: photoAssetID
      )
      AddInfoSection.nutrition.notifyTilesChanged()
    }
  }
}
