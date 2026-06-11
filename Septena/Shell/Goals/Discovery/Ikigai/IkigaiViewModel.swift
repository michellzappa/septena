import Foundation
import SwiftUI

@MainActor
@Observable
final class IkigaiViewModel {
  enum Phase: Equatable {
    case collecting
    case generating
    case ready
    case failed(String)
  }

  var love: Set<String> = []
  var identity: Set<String> = []
  var value: Set<String> = []
  var world: Set<String> = []
  var suggestions: [String: [String]]
  var phase: Phase = .collecting
  var drafts: [DraftGoal] = []
  var generationMessage: String?

  private let service: PurposePromptService

  init(service: PurposePromptService = PurposePromptService()) {
    self.service = service
    self.suggestions = [
      "love": PurposeSuggestions.getRandomSuggestions(for: "love"),
      "identity": PurposeSuggestions.getRandomSuggestions(for: "identity"),
      "value": PurposeSuggestions.getRandomSuggestions(for: "value"),
      "world": PurposeSuggestions.getRandomSuggestions(for: "world"),
    ]
  }

  var canGenerate: Bool {
    !love.isEmpty && !identity.isEmpty && !value.isEmpty && !world.isEmpty
  }

  var inputs: PurposeInputs {
    PurposeInputs(
      love: Array(love).sorted(),
      identity: Array(identity).sorted(),
      value: Array(value).sorted(),
      world: Array(world).sorted()
    )
  }

  func addCustom(_ text: String, to quadrant: IkigaiQuadrant) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    var selected = selection(for: quadrant)
    selected.insert(clean)
    setSelection(selected, for: quadrant)
    if !(suggestions[quadrant.key] ?? []).contains(clean) {
      suggestions[quadrant.key, default: []].append(clean)
    }
  }

  func refreshSuggestions(for quadrant: IkigaiQuadrant) async {
    do {
      let generated = try await service.generateSuggestions(
        for: quadrant.key,
        currentSelections: Array(selection(for: quadrant)).sorted()
      )
      let clean = generated.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if !clean.isEmpty {
        let existing = suggestions[quadrant.key] ?? []
        var seen = Set(existing.map(normalizedSuggestionKey))
        var merged = existing
        for item in clean {
          let key = normalizedSuggestionKey(item)
          guard !seen.contains(key) else { continue }
          seen.insert(key)
          merged.append(item)
        }
        suggestions[quadrant.key] = merged
      }
    } catch {
      suggestions[quadrant.key] = PurposeSuggestions.getRandomSuggestions(for: quadrant.key)
    }
  }

  private func normalizedSuggestionKey(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  func generateDrafts(availableSections: [SectionConfig] = []) async {
    guard canGenerate else { return }
    // Entry points are availability-gated, but guard here too so a future
    // deep link or intent can't retry a generation that can never succeed.
    guard OnDeviceAI.isAvailable else {
      drafts = fallbackDrafts(availableSections: availableSections)
      phase = .failed(OnDeviceAI.unavailableReason ?? "On-device intelligence is unavailable right now.")
      Haptics.warning()
      return
    }
    phase = .generating
    generationMessage = String(localized: "Finding the through-line...", comment: "Discovery generation status")

    do {
      let purpose = try await service.generatePurposeTitleAndDescription(inputs: inputs)
      generationMessage = String(localized: "Drafting commitments...", comment: "Discovery generation status")
      let commitments = try await service.generateCommitments(
        purpose: "\(purpose.title): \(purpose.content)"
      )

      var nextDrafts = [
        DraftGoal(
          text: "\(purpose.title): \(purpose.content)",
          kind: .purpose
        ),
      ]
      nextDrafts.append(contentsOf: commitments.prefix(4).map { commitment in
        DraftGoal(
          text: "\(commitment.title): \(commitment.description)",
          kind: .commitment
        )
      })

      generationMessage = String(localized: "Tagging sections...", comment: "Discovery generation status")
      nextDrafts = await draftsWithSectionSelections(nextDrafts, availableSections: availableSections)
      drafts = nextDrafts
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

  private func selection(for quadrant: IkigaiQuadrant) -> Set<String> {
    switch quadrant {
    case .love:
      return love
    case .identity:
      return identity
    case .value:
      return value
    case .world:
      return world
    }
  }

  private func setSelection(_ selection: Set<String>, for quadrant: IkigaiQuadrant) {
    switch quadrant {
    case .love:
      love = selection
    case .identity:
      identity = selection
    case .value:
      value = selection
    case .world:
      world = selection
    }
  }

  private func fallbackDrafts() -> [DraftGoal] {
    let purpose = "Build a life around \(Array(love).sorted().prefix(2).joined(separator: " and ")) while using \(Array(identity).sorted().prefix(2).joined(separator: " and ")) to serve \(Array(world).sorted().prefix(2).joined(separator: " and "))."
    return [
      DraftGoal(text: purpose, kind: .purpose),
      DraftGoal(text: "Protect weekly time for \(Array(love).sorted().first ?? "meaningful work").", kind: .commitment),
      DraftGoal(text: "Apply \(Array(identity).sorted().first ?? "a core strength") to one useful project each week.", kind: .commitment),
      DraftGoal(text: "Create value through \(Array(value).sorted().first ?? "a practical offer") without losing sight of \(Array(world).sorted().first ?? "real-world needs").", kind: .commitment),
    ]
  }

  private func fallbackDrafts(availableSections: [SectionConfig]) -> [DraftGoal] {
    fallbackDrafts().map { draft in
      var copy = draft
      copy.sections = fallbackSections(for: draft.text, availableSections: availableSections)
      return copy
    }
  }

  private func draftsWithSectionSelections(_ drafts: [DraftGoal],
                                           availableSections: [SectionConfig]) async -> [DraftGoal] {
    guard !availableSections.isEmpty else { return drafts }
    let availableKeys = Set(availableSections.map(\.key))
    let assignments = try? await service.generateSectionAssignments(
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
    let lower = text.lowercased()
    let hints: [String: [String]] = [
      "activity": ["activity", "active", "steps", "walk", "movement", "move"],
      "body": ["body", "weight", "weigh", "composition", "physique"],
      "caffeine": ["coffee", "caffeine", "energy", "focus"],
      "cannabis": ["cannabis", "weed", "thc", "cbd"],
      "chores": ["home", "clean", "organize", "chore", "errand"],
      "groceries": ["grocery", "groceries", "shopping", "pantry"],
      "gut": ["gut", "digest", "symptom", "stomach", "bowel"],
      "habits": ["habit", "daily", "routine", "practice", "streak"],
      "hydration": ["water", "hydrate", "hydration"],
      "mood": ["mood", "stress", "emotion", "mental", "reflect"],
      "nutrition": ["food", "meal", "eat", "nutrition", "protein", "calorie"],
      "sleep": ["sleep", "rest", "bed", "wake"],
      "supplements": ["supplement", "vitamin", "creatine", "magnesium"],
      "tasks": ["task", "project", "plan", "work", "ship", "build", "create"],
      "training": ["training", "exercise", "workout", "lift", "run", "strength"],
    ]

    var matches: [String] = []
    for section in availableSections {
      let labelTerms = [section.key.lowercased(), section.label.lowercased()]
      let sectionHints = hints[section.key, default: []] + labelTerms
      if sectionHints.contains(where: { lower.contains($0) }) {
        matches.append(section.key)
      }
    }
    return Array(matches.prefix(3))
  }
}
