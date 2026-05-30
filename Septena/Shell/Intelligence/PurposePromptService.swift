import Foundation
import FoundationModels

struct PurposeInputs {
  var love: [String]
  var identity: [String]
  var value: [String]
  var world: [String]
}

@Generable
struct PurposeAnalysis: Codable {
  let title: String
  let content: String
  let passion: String
  let mission: String
  let vocation: String
  let profession: String
}

@Generable
struct PurposeTitleAndDescription: Codable {
  let title: String
  let content: String
}

@Generable
struct PurposeIntersections: Codable {
  let passion: String
  let mission: String
  let vocation: String
  let profession: String
}

@Generable
struct AIGeneratedCommitment: Codable, Identifiable, Hashable {
  var id: String { "\(title)-\(frequency)" }
  let title: String
  let description: String
  let frequency: String
}

@Generable
struct CommitmentsResponse: Codable {
  let commitments: [AIGeneratedCommitment]
}

@Generable
struct Suggestions: Codable {
  let suggestions: [String]
}

@Generable
struct GoalSectionAssignment: Codable {
  let index: Int
  let sections: [String]
}

@Generable
struct GoalSectionAssignments: Codable {
  let assignments: [GoalSectionAssignment]
}

final class PurposePromptService {
  func generatePurposeAnalysis(inputs: PurposeInputs) async throws -> PurposeAnalysis {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildPurposePrompt(inputs: inputs),
                                           generating: PurposeAnalysis.self)
    return result.content
  }

  func generatePurposeTitleAndDescription(inputs: PurposeInputs) async throws -> PurposeTitleAndDescription {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildTitlePrompt(inputs: inputs),
                                           generating: PurposeTitleAndDescription.self)
    return result.content
  }

  func generatePurposeIntersections(inputs: PurposeInputs) async throws -> PurposeIntersections {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildIntersectionsPrompt(inputs: inputs),
                                           generating: PurposeIntersections.self)
    return result.content
  }

  func generateCommitments(purpose: String) async throws -> [AIGeneratedCommitment] {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildCommitmentPrompt(purpose: purpose),
                                           generating: CommitmentsResponse.self)
    return result.content.commitments
  }

  func generateSuggestions(for category: String, currentSelections: [String]) async throws -> [String] {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildSuggestionsPrompt(for: category,
                                                                      currentSelections: currentSelections),
                                           generating: Suggestions.self)
    return result.content.suggestions
  }

  func generateSectionAssignments(goalTexts: [String],
                                  availableSections: [SectionConfig]) async throws -> [Int: [String]] {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildSectionAssignmentPrompt(goalTexts: goalTexts,
                                                                            availableSections: availableSections),
                                           generating: GoalSectionAssignments.self)
    return Dictionary(uniqueKeysWithValues: result.content.assignments.map { assignment in
      (assignment.index, assignment.sections)
    })
  }

  private func buildPurposePrompt(inputs: PurposeInputs) -> String {
    """
    I am exploring a Purpose exercise. Given my inputs, what might constitute my unique Purpose? Respond with a title, one content paragraph (max 100 words), and four intersections.
    - title: A title summarizing the purpose (do not mention Purpose in title)
    - content: One paragraph (max 100 words) focusing on what makes me unique and next steps
    - passion: Describe how my love and skills combine (1-2 sentences)
    - mission: Describe how my skills and world needs align (1-2 sentences)
    - vocation: Describe how world needs and market value intersect (1-2 sentences)
    - profession: Describe how market value and love combine (1-2 sentences)

    Things I love: \(inputs.love.joined(separator: ", "))
    Things I am good at: \(inputs.identity.joined(separator: ", "))
    Things I can be paid for: \(inputs.value.joined(separator: ", "))
    Things the world needs: \(inputs.world.joined(separator: ", "))

    Guidelines:
    - Keep the content to exactly one paragraph of max 100 words
    - Do not waffle or be flowery
    - Emphasize what the lists have in common
    - Focus on personal insight
    - Be indirect, do not explicitly use the given words
    - Avoid these words: Nuanced, Multifaceted, Robust, Iterative, Paradigm, Ecosystem, Tapestry, Quintessential, Holistic, Unprecedented, Synergy, Dichotomy, Salient, Facet, Proliferation, Amalgam, Nexus, Idiosyncratic, Delve
    """
  }

  private func buildTitlePrompt(inputs: PurposeInputs) -> String {
    """
    I am exploring a Purpose exercise. Given my inputs, what might constitute my unique Purpose? Respond ONLY with:
    - title: A title summarizing the purpose (do not mention Purpose in title)
    - content: One paragraph (max 100 words) focusing on what makes me unique and next steps

    Things I love: \(inputs.love.joined(separator: ", "))
    Things I am good at: \(inputs.identity.joined(separator: ", "))
    Things I can be paid for: \(inputs.value.joined(separator: ", "))
    Things the world needs: \(inputs.world.joined(separator: ", "))

    Guidelines:
    - Keep the content to exactly one paragraph of max 100 words
    - Do not waffle or be flowery
    - Emphasize what the lists have in common
    - Focus on personal insight
    - Be indirect, do not explicitly use the given words
    - Avoid these words: Nuanced, Multifaceted, Robust, Iterative, Paradigm, Ecosystem, Tapestry, Quintessential, Holistic, Unprecedented, Synergy, Dichotomy, Salient, Facet, Proliferation, Amalgam, Nexus, Idiosyncratic, Delve
    """
  }

  private func buildIntersectionsPrompt(inputs: PurposeInputs) -> String {
    """
    I am exploring a Purpose exercise. Given my inputs, respond ONLY with the following intersections:
    - passion: Describe how my love and skills combine (1-2 sentences)
    - mission: Describe how my skills and world needs align (1-2 sentences)
    - vocation: Describe how world needs and market value intersect (1-2 sentences)
    - profession: Describe how market value and love combine (1-2 sentences)

    Things I love: \(inputs.love.joined(separator: ", "))
    Things I am good at: \(inputs.identity.joined(separator: ", "))
    Things I can be paid for: \(inputs.value.joined(separator: ", "))
    Things the world needs: \(inputs.world.joined(separator: ", "))

    Guidelines:
    - Each intersection should be 1-2 sentences
    - Be specific and actionable
    - Avoid generic terms
    - Make intersections unique and relevant to the input
    """
  }

  private func buildCommitmentPrompt(purpose: String) -> String {
    """
    As an expert life coach, help create meaningful commitments based on this purpose statement:
    \(purpose)

    Please provide three commitments:
    - title: Short, actionable title
    - description: Detailed explanation of the commitment
    - frequency: daily|weekly|monthly|quarterly

    Make the commitments specific, measurable, and aligned with the purpose statement.
    Include a mix of frequencies, with at least one daily commitment for building habits.
    Focus on actions that will help manifest the purpose in practical ways.
    """
  }

  private func buildSuggestionsPrompt(for category: String, currentSelections: [String]) -> String {
    let categoryDescription: String
    switch category {
    case "love":
      categoryDescription = "activities, interests, and passions that bring joy and fulfillment"
    case "identity":
      categoryDescription = "talents, skills, and personal strengths"
    case "value":
      categoryDescription = "professional skills, market needs, and ways to create value"
    case "world":
      categoryDescription = "ways to contribute to society and meet world needs"
    default:
      categoryDescription = "relevant suggestions"
    }

    let currentSelectionsText = currentSelections.isEmpty
      ? "No selections made yet."
      : "Current selections: \(currentSelections.joined(separator: ", "))"

    return """
    Generate 5 unique suggestions for \(categoryDescription). These should be different from but complementary to: \(currentSelectionsText)
    Guidelines:
    - Each suggestion should be 1-3 words
    - Be specific and actionable
    - Avoid generic terms
    - Make suggestions unique from current selections
    - Keep suggestions relevant to the category
    """
  }

  private func buildSectionAssignmentPrompt(goalTexts: [String],
                                            availableSections: [SectionConfig]) -> String {
    let sectionList = availableSections
      .map { "- \($0.key): \($0.label)" }
      .joined(separator: "\n")
    let goalList = goalTexts.enumerated()
      .map { "\($0.offset). \($0.element)" }
      .joined(separator: "\n")

    return """
    Tag each proposed Septena goal with the sections where the user would most likely act on it or log progress.

    Available sections. Use ONLY these exact section keys:
    \(sectionList)

    Proposed goals:
    \(goalList)

    Guidelines:
    - Return one assignment for every proposed goal index.
    - Choose 1 to 3 section keys per goal.
    - Prefer concrete action/logging sections over the generic Goals section.
    - A broad north-star goal can use the strongest practical sections implied by the text.
    - Do not invent keys, labels, metrics, or explanations.
    """
  }
}
