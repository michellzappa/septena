import AppIntents
import Foundation

// Gut — digestive event log. One quick-log action backed by
// `GutMutator.addEntry`. Bristol is the required field, surfaced as an
// AppEnum picker (1–7); volume is an optional AppEnum (small/medium/large)
// mapped to the mutator's free-form String. Boot + auto-enable come from
// SectionLogIntent; the Siri phrases live in `SeptenaShortcuts`
// (SectionLogIntent.swift). Mutator + entity types come from SeptenaCore
// (same module — no import needed).

// MARK: - Enums

/// Bristol Stool Scale 1–7 as a pickable value. Raw `Int` maps straight to
/// the `bristol` the mutator wants; labels mirror `GutPlugin.bristolLabel`.
enum BristolType: Int, AppEnum {
  case type1 = 1
  case type2 = 2
  case type3 = 3
  case type4 = 4
  case type5 = 5
  case type6 = 6
  case type7 = 7

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Bristol Type" }

  static var caseDisplayRepresentations: [BristolType: DisplayRepresentation] {
    [
      .type1: "Type 1 — Separate hard lumps",
      .type2: "Type 2 — Lumpy sausage",
      .type3: "Type 3 — Cracked sausage",
      .type4: "Type 4 — Smooth, soft sausage",
      .type5: "Type 5 — Soft blobs",
      .type6: "Type 6 — Fluffy mush",
      .type7: "Type 7 — Liquid",
    ]
  }
}

/// Optional stool volume. Raw value is the lowercase token the mutator
/// stores ("small" | "medium" | "large"), matching EditGutEntrySheet.
enum GutVolume: String, AppEnum {
  case small
  case medium
  case large

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Volume" }

  static var caseDisplayRepresentations: [GutVolume: DisplayRepresentation] {
    [
      .small: "Small",
      .medium: "Medium",
      .large: "Large",
    ]
  }
}

// MARK: - Intents

/// The daily log action: record a bowel movement on the Bristol scale.
struct LogGutEntryIntent: SectionLogIntent {
  static let sectionKey = "gut"
  static let title: LocalizedStringResource = "Log Gut Entry"
  static let description = IntentDescription("Log a digestive event on the Bristol stool scale.")

  @Parameter(title: "Bristol Type")
  var bristol: BristolType

  @Parameter(title: "Volume")
  var volume: GutVolume?

  static var parameterSummary: some ParameterSummary {
    Summary("Log a \(\.$bristol) gut entry") {
      \.$volume
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    SeptenaServices.shared.gutMutator.addEntry(
      date: SeptenaDate.today,
      time: nowTimeString(),
      bristol: bristol.rawValue,
      volume: volume?.rawValue)
    return .result(dialog: "Logged a Bristol type \(bristol.rawValue) gut entry.")
  }

  /// Current HH:mm, matching the in-app AddGutPage quick-log (`nowHHMM`).
  private func nowTimeString() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: .now)
  }
}
