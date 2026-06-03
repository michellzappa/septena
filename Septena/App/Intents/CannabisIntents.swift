import AppIntents
import Foundation
import SwiftData

// Cannabis — section intents following the SupplementIntents / CaffeineIntents
// template. One thin `LogCannabisIntent` that leans on `SectionLogIntent` for
// boot + auto-enable. The matching Siri phrases go in `SeptenaShortcuts`
// (SectionLogIntent.swift) — the metadata processor needs every AppShortcut
// literal inline there. Mutator + entity types come from SeptenaCore (same
// module — no import needed).
//
// SENSITIVITY: cannabis logging is private. The intent + a Shortcuts action
// exist so it's scriptable and usable from the share sheet / Shortcuts.app,
// but it is a deliberate candidate to OMIT from the zero-config Siri phrase
// set in `SeptenaShortcuts` (spoken "Hey Siri" surfaces). See DELIVERABLE notes.

// MARK: - Method

/// Intake method for a logged session. Cases mirror `CannabisPlugin.logActions`
/// (vape / edible); raw values match the strings `CannabisPlugin.label`
/// switches on so the Today timeline labels logged intents correctly.
enum CannabisMethod: String, AppEnum {
  case vape
  case edible

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Method" }

  static var caseDisplayRepresentations: [CannabisMethod: DisplayRepresentation] {
    [
      .vape: "Vape",
      .edible: "Edible",
    ]
  }

  /// Plain-text label for spoken dialog (mirrors the display reps above).
  var label: String {
    switch self {
    case .vape:   return "vape"
    case .edible: return "edible"
    }
  }
}

// MARK: - Intents

/// The daily log action: record a cannabis session for today. `hits` applies to
/// vape, `grams` to edibles — both optional, matching the in-app quick-log path
/// (vape defaults to one hit; edible carries a dose). The mutator auto-fills
/// vape grams from its per-use constant when none is supplied.
struct LogCannabisIntent: SectionLogIntent {
  static let sectionKey = "cannabis"
  static let title: LocalizedStringResource = "Log Cannabis"
  static let description = IntentDescription("Log a cannabis session by method.")

  @Parameter(title: "Method", default: .vape)
  var method: CannabisMethod

  @Parameter(title: "Hits")
  var hits: Int?

  @Parameter(title: "Grams")
  var grams: Double?

  static var parameterSummary: some ParameterSummary {
    Summary("Log a \(\.$method) session") {
      \.$hits
      \.$grams
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    // Vape defaults to a single hit, as in-app.
    let resolvedHit = method == .vape ? (hits ?? 1) : hits
    SeptenaServices.shared.cannabisMutator.addEntry(
      date: SeptenaDate.today,
      time: SeptenaDate.nowHHMM,
      method: method.rawValue,
      hit: resolvedHit,
      grams: grams)
    return .result(dialog: "Logged \(method.label).")
  }
}
