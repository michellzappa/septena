import Foundation
import Vision

// Turn a meal photo into a draft the user confirms. Capability ladder:
//
//   rung 1  iOS 27 + Apple Intelligence + eligible device → multimodal model
//           (`MealPhotoModelAnalyzer`, stubbed until Xcode 27)
//   rung 2  ANY iOS 26+ device, no Apple Intelligence needed → Vision OCR reads
//           a printed nutrition label; barcode detection is surfaced for a
//           future packaged-food lookup
//
// Rung 2 always runs and is merged under rung 1, so the feature works on every
// device and in every region (Apple Intelligence is not required for Vision).

enum MealPhotoAnalyzer {
  /// Best-effort analysis. Never throws — returns an empty draft on failure so
  /// the photo still attaches and the user just fills the form by hand.
  static func analyze(imageData: Data) async -> MealPhotoDraft {
    let model = await MealPhotoModelAnalyzer.analyze(imageData: imageData)
    let label = labelRung(imageData: imageData)
    if let model { return model.merging(label) }
    return label
  }

  // MARK: - Rung 2: Vision OCR + barcode (on-device, no Apple Intelligence)

  private static func labelRung(imageData: Data) -> MealPhotoDraft {
    let handler = VNImageRequestHandler(data: imageData, options: [:])

    let textRequest = VNRecognizeTextRequest()
    textRequest.recognitionLevel = .accurate
    textRequest.usesLanguageCorrection = false  // we want digits and units verbatim

    let barcodeRequest = VNDetectBarcodesRequest()

    do {
      try handler.perform([textRequest, barcodeRequest])
    } catch {
      return MealPhotoDraft(source: .label)
    }

    let lines = (textRequest.results ?? []).compactMap {
      $0.topCandidates(1).first?.string
    }
    let barcode = (barcodeRequest.results ?? [])
      .compactMap { $0.payloadStringValue }
      .first

    return parseLabel(lines: lines, barcode: barcode)
  }

  // MARK: - Label text → nutrients

  /// Parse a US/EU nutrition panel out of OCR'd lines. Best-effort and lenient:
  /// matches "Protein 12 g", "Energy 240 kcal", "Total Fat 9g", comma decimals
  /// ("4,5 g", common in Europe), and kJ/kcal energy lines (kcal preferred).
  static func parseLabel(lines: [String], barcode: String?) -> MealPhotoDraft {
    var draft = MealPhotoDraft(source: .label)
    draft.barcode = barcode
    let text = lines.joined(separator: "\n")

    draft.proteinG = number(in: text, labeledBy: ["protein"])
    draft.fatG = number(in: text, labeledBy: ["total fat", "fat", "fett", "grasas", "matières grasses"])
    draft.saturatedFatG = number(in: text, labeledBy: ["saturated", "of which saturates", "saturates", "gesättigte"])
    draft.carbsG = number(in: text, labeledBy: ["total carbohydrate", "carbohydrate", "carbs", "kolhydrat", "glucides"])
    draft.sugarG = number(in: text, labeledBy: ["of which sugars", "sugars", "sugar", "zucker", "sucres"])
    draft.fiberG = number(in: text, labeledBy: ["dietary fiber", "fiber", "fibre", "ballaststoffe"])
    draft.sodiumMg = number(in: text, labeledBy: ["sodium"], scaleSaltGramsToSodiumMg: true)
    draft.cholesterolMg = number(in: text, labeledBy: ["cholesterol"])
    draft.potassiumMg = number(in: text, labeledBy: ["potassium"])
    draft.kcal = energyKcal(in: text)

    return draft
  }

  // MARK: - Number extraction

  /// First numeric value that appears after any of `labels` on the same logical
  /// line. `scaleSaltGramsToSodiumMg`: EU labels list "Salt 0,5 g" instead of
  /// sodium — convert (salt g × 400 ≈ sodium mg) only when the match is "salt".
  private static func number(in text: String,
                             labeledBy labels: [String],
                             scaleSaltGramsToSodiumMg: Bool = false) -> Double? {
    let haystack = text.lowercased()
    for raw in labels {
      let label = raw.lowercased()
      guard let r = haystack.range(of: label) else { continue }
      let tail = String(haystack[r.upperBound...].prefix(40))
      guard let value = firstDecimal(in: tail) else { continue }
      return value
    }
    if scaleSaltGramsToSodiumMg, let salt = number(in: text, labeledBy: ["salt", "salz", "sel"]) {
      return (salt * 400).rounded()  // 1 g salt ≈ 0.4 g sodium = 400 mg
    }
    return nil
  }

  /// Energy in kcal. Prefer an explicit kcal figure; ignore kJ.
  private static func energyKcal(in text: String) -> Double? {
    let lower = text.lowercased()
    // "240 kcal" or "kcal 240" forms.
    if let m = firstMatch(#"([0-9][0-9.,]*)\s*kcal"#, in: lower) { return decimal(m) }
    if let m = firstMatch(#"kcal\s*[:\-]?\s*([0-9][0-9.,]*)"#, in: lower) { return decimal(m) }
    // "Calories 240" (no unit).
    if let r = lower.range(of: "calories") {
      return firstDecimal(in: String(lower[r.upperBound...].prefix(40)))
    }
    return nil
  }

  private static func firstDecimal(in s: String) -> Double? {
    firstMatch(#"([0-9]+(?:[.,][0-9]+)?)"#, in: s).flatMap(decimal)
  }

  private static func decimal(_ s: String) -> Double? {
    Double(s.replacingOccurrences(of: ",", with: "."))
  }

  /// First capture group of `pattern` in `s`.
  private static func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
          let g = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[g])
  }
}
