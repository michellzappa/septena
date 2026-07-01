import SwiftUI
import PhotosUI
import Photos
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// Edit/create sheet for a logged nutrition entry. A SwiftUI `Form` wrapped in
// `AdaptiveEditScaffold` (which supplies the chrome — inline header in a docked
// inspector, NavigationStack + toolbar in a bottom sheet) and presented via
// `.adaptiveDetail(item:)` (edit) or `.adaptiveDetail(isPresented:)` (create).
// Mutations go through NutritionMutator (local SwiftData + CKEngine queue).

struct EditNutritionEntrySheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  let original: NutritionEntry?
  let onDone: () -> Void

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

  // Photo attachment. The picker yields a `PhotosPickerItem` whose
  // `itemIdentifier` is the PHAsset.localIdentifier — but only when the
  // user has granted read access to Photos. We request that on first pick.
  @State private var photoItem: PhotosPickerItem? = nil
  @State private var photoAssetID: String? = nil
  // Edited flag so we can distinguish "unchanged" from "explicitly cleared".
  @State private var photoEdited: Bool = false

  var body: some View {
    AdaptiveEditScaffold(title: original == nil ? "New Meal" : "Edit Meal",
                         onSave: save) {
      formBody
        .onAppear { seed() }
        .onChange(of: photoItem) { _, new in
          // PhotosPicker hands us a PhotosPickerItem; the local identifier is
          // present when we have Photos library read access. Request it lazily
          // — the user only sees the prompt after their first pick.
          guard let new else { return }
          Task { await capturePickedIdentifier(new) }
        }
    }
  }

  @ViewBuilder private var formBody: some View {
      Form {
        Section("When") {
          SteppedDatePicker("Date & time",
                            selection: $time,
                            displayedComponents: [.date, .hourAndMinute])
        }
        Section("Meal") {
          LabeledContent("Emoji") { EmojiSlotPicker(emoji: $emoji) }
          // `axis: .vertical` is the documented SwiftUI affordance for a
          // growing multi-line `TextField` (iOS 16+). One food per line —
          // mirrors what the server already parses on POST/PUT.
          TextField("Foods (one per line)", text: $foodsText, axis: .vertical)
            .lineLimit(2...8)
          TextField("Ingredients (one per line)",
                    text: $ingredientsText, axis: .vertical)
            .lineLimit(1...6)
        }
        Section("Photo") {
          photoRow
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

  @ViewBuilder
  private var photoRow: some View {
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
            photoEdited = true
          } label: {
            Text("Remove").font(.caption)
          }
        }
      }
    }
  }

  private func capturePickedIdentifier(_ item: PhotosPickerItem) async {
    // Photos read access is needed for `itemIdentifier` to be non-nil.
    await PhotosBridge.shared.ensureAccess()
    await MainActor.run {
      photoAssetID = item.itemIdentifier
      photoEdited = true
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

  private func seed() {
    if let original {
      emoji          = original.emoji ?? ""
      foodsText      = original.foods.joined(separator: "\n")
      ingredientsText = (original.ingredients ?? []).joined(separator: "\n")
      proteinG       = numString(original.proteinG)
      fatG           = numString(original.fatG)
      saturatedFatG  = optString(original.saturatedFatG)
      carbsG         = numString(original.carbsG)
      sugarG         = optString(original.sugarG)
      fiberG         = optString(original.fiberG)
      alcoholG       = optString(original.alcoholG)
      kcal           = numString(original.kcal)
      sodiumMg       = optString(original.sodiumMg)
      cholesterolMg  = optString(original.cholesterolMg)
      potassiumMg    = optString(original.potassiumMg)
      waterMl        = optString(original.waterMl.map { VolumeUnit.current.displayDouble($0) })
      photoAssetID   = original.photoAssetID
      time = EventTimestamp.from(date: original.date, time: original.time)
    } else {
      emoji = ""; foodsText = ""; ingredientsText = ""
      proteinG = ""; fatG = ""; saturatedFatG = ""
      carbsG = ""; sugarG = ""; fiberG = ""
      alcoholG = ""; kcal = ""
      sodiumMg = ""; cholesterolMg = ""; potassiumMg = ""; waterMl = ""
      photoAssetID = nil
      time = Date()
    }
  }

  private func numString(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : d.decimalString()
  }

  private func optString(_ d: Double?) -> String {
    guard let d, d != 0 else { return "" }
    return d == d.rounded() ? String(Int(d)) : d.decimalString()
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
    let ingredients = lines(ingredientsText)
    let emojiValue = emoji.trimmingCharacters(in: .whitespacesAndNewlines)

    let mutator = SeptenaServices.shared.nutritionMutator
    // Edit = quiet correction; new meal = a warm bloom. Both funnel through
    // SectionLog; dismissal is owned by AdaptiveEditScaffold.
    if let original {
      // Double-optional: pass `.some(photoAssetID)` only when the user
      // touched the picker this session; otherwise leave nil so the mutator
      // doesn't clobber the existing value.
      let photoArg: String?? = photoEdited ? .some(photoAssetID) : nil
      SectionLog.edit {
        mutator.updateEntry(
          id: original.file,
          pickedAt: time,
          emoji: emojiValue.isEmpty ? nil : emojiValue,
          foods: foods,
          ingredients: ingredients.isEmpty ? [] : ingredients,
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
          photoAssetID: photoArg
        )
        AddInfoSection.nutrition.notifyTilesChanged()
      }
    } else {
      NutritionPlugin.commitMeal(
        loggedAt: time,
        today: clock.today,
        accent: theme.color(for: "nutrition"),
        announce: "Logged \(foods.first ?? "meal").",
        logCommit: logCommit
      ) {
        mutator.addEntry(
          loggedAt: time,
          emoji: emojiValue.isEmpty ? nil : emojiValue,
          foods: foods,
          ingredients: ingredients.isEmpty ? nil : ingredients,
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
    onDone()
  }
}

// MARK: - Photo thumbnail
//
// Resolves a `PHAsset.localIdentifier` to a square thumbnail using PhotoKit.
// Falls back to a neutral placeholder when no ID is set, when the asset has
// been deleted from Photos, or when the user picked it on another device
// (local identifiers don't roam — see [[project_cloudkit_migration]]).

struct MealPhotoThumbnail: View {
  let assetID: String?
  let size: CGFloat

  #if canImport(UIKit)
  @State private var image: UIImage? = nil
  #elseif canImport(AppKit)
  @State private var image: NSImage? = nil
  #endif

  var body: some View {
    Group {
      if let image {
        #if canImport(UIKit)
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
        #elseif canImport(AppKit)
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
        #endif
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.12))
          Image(systemName: assetID == nil ? "photo" : "photo.badge.exclamationmark")
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task(id: assetID) { await load() }
  }

  private func load() async {
    image = nil
    guard let assetID, !assetID.isEmpty else { return }
    // Photo-library reads require granted access; if it's unavailable
    // (denied/restricted/not-yet-asked) silently skip — the placeholder shows.
    guard PhotosBridge.shared.canRead else { return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
    guard let asset = assets.firstObject else { return }
    let opts = PHImageRequestOptions()
    opts.deliveryMode = .opportunistic
    opts.isNetworkAccessAllowed = true
    let target = CGSize(width: size * 3, height: size * 3)  // @3x
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      var resumed = false
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: target,
        contentMode: .aspectFill,
        options: opts
      ) { img, info in
        Task { @MainActor in self.image = img }
        // `opportunistic` may call the handler twice (low-res then hi-res);
        // resume only on the final delivery.
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        if !isDegraded && !resumed {
          resumed = true
          cont.resume()
        }
      }
    }
  }
}
