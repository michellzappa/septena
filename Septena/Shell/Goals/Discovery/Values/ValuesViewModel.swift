import Foundation
import SwiftUI

@MainActor
@Observable
final class ValuesViewModel {
  enum Phase: Equatable {
    case collecting
    case generating
    case ready
    case failed(String)
  }

  var selectedValues: Set<String> = []
  var customValues: [String] = []
  var note = ""
  var phase: Phase = .collecting
  var drafts: [DraftGoal] = []
  var generationMessage: String?

  private let valuesService: ValuesPromptService
  private let sectionService: PurposePromptService

  init(valuesService: ValuesPromptService = ValuesPromptService(),
       sectionService: PurposePromptService = PurposePromptService()) {
    self.valuesService = valuesService
    self.sectionService = sectionService
  }

  var canGenerate: Bool {
    selectedValues.count >= 3
  }

  var sortedValues: [String] {
    Array(selectedValues).sorted()
  }

  func addCustom(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    if !customValues.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
      customValues.append(clean)
    }
    selectedValues.insert(clean)
  }

  func generateDrafts(availableSections: [SectionConfig]) async {
    guard canGenerate else { return }
    phase = .generating
    generationMessage = "Finding the through-line..."

    do {
      let inputs = ValuesInputs(
        values: sortedValues,
        notes: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      )
      let purpose = try await valuesService.generatePurpose(inputs: inputs)
      let purposeText = "\(purpose.title): \(purpose.content)"
      generationMessage = "Drafting commitments..."
      let commitments = try await valuesService.generateCommitments(values: sortedValues,
                                                                    purpose: purposeText)

      var nextDrafts = [
        DraftGoal(text: purposeText, kind: .purpose),
      ]
      nextDrafts.append(contentsOf: commitments.prefix(4).map { commitment in
        DraftGoal(text: "\(commitment.title): \(commitment.description)", kind: .commitment)
      })

      generationMessage = "Tagging sections..."
      drafts = await draftsWithSectionSelections(nextDrafts, availableSections: availableSections)
      generationMessage = nil
      phase = .ready
      Haptics.success()
    } catch {
      drafts = fallbackDrafts(availableSections: availableSections)
      generationMessage = nil
      phase = .failed("The on-device model could not finish this generation. You can still review a local fallback draft.")
      Haptics.warning()
    }
  }

  private func fallbackDrafts(availableSections: [SectionConfig]) -> [DraftGoal] {
    let values = sortedValues
    let first = values.first ?? "what matters"
    let second = values.dropFirst().first ?? "daily life"
    let third = values.dropFirst(2).first ?? "follow-through"
    let base = [
      DraftGoal(text: "Live \(values.prefix(3).joined(separator: ", ")): Make weekly choices that protect \(first), express \(second), and turn \(third) into visible action.", kind: .purpose),
      DraftGoal(text: "Weekly values review: Choose one decision each week and check whether it matched \(first).", kind: .commitment),
      DraftGoal(text: "Daily alignment check: Name one action each day that reflects \(second).", kind: .commitment),
      DraftGoal(text: "Protect one hard choice: When tradeoffs appear, choose the option that best serves \(third).", kind: .commitment),
    ]
    return base.map { draft in
      var copy = draft
      copy.sections = fallbackSections(for: copy.text, availableSections: availableSections)
      return copy
    }
  }

  private func draftsWithSectionSelections(_ drafts: [DraftGoal],
                                           availableSections: [SectionConfig]) async -> [DraftGoal] {
    guard !availableSections.isEmpty else { return drafts }
    let availableKeys = Set(availableSections.map(\.key))
    let assignments = try? await sectionService.generateSectionAssignments(
      goalTexts: drafts.map(\.text),
      availableSections: availableSections
    )

    return drafts.enumerated().map { index, draft in
      var copy = draft
      let generated = assignments?[index] ?? []
      let clean = uniqueSections(generated.filter { availableKeys.contains($0) })
      copy.sections = clean.isEmpty
        ? fallbackSections(for: draft.text, availableSections: availableSections)
        : clean
      return copy
    }
  }

  private func uniqueSections(_ sections: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for section in sections {
      guard !seen.contains(section) else { continue }
      seen.insert(section)
      result.append(section)
    }
    return result
  }

  private func fallbackSections(for text: String,
                                availableSections: [SectionConfig]) -> [String] {
    let lower = "\(text) \(sortedValues.joined(separator: " "))".lowercased()
    let hints: [String: [String]] = [
      "activity": ["activity", "active", "adventure", "movement"],
      "body": ["body", "health", "balance"],
      "chores": ["home", "responsibility", "family"],
      "habits": ["daily", "weekly", "habit", "consistency", "discipline"],
      "mood": ["empathy", "compassion", "stress", "reflection"],
      "nutrition": ["health", "food", "balance"],
      "sleep": ["rest", "balance", "health"],
      "tasks": ["work", "project", "creativity", "learning", "achievement", "excellence"],
      "training": ["health", "strength", "growth"],
    ]

    let matches = availableSections.compactMap { section -> String? in
      let sectionHints = hints[section.key, default: []] + [section.key.lowercased(), section.label.lowercased()]
      return sectionHints.contains(where: { lower.contains($0) }) ? section.key : nil
    }
    return Array(matches.prefix(3))
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
