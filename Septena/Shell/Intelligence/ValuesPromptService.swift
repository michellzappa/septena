import Foundation
import FoundationModels

struct ValuesInputs {
  var values: [String]
  var notes: String?
}

@Generable
struct ValuesPurpose: Codable {
  let title: String
  let content: String
}

@Generable
struct ValuesGeneratedCommitment: Codable, Hashable {
  let title: String
  let description: String
  let frequency: String
}

@Generable
struct ValuesCommitmentsResponse: Codable {
  let commitments: [ValuesGeneratedCommitment]
}

final class ValuesPromptService {
  func generatePurpose(inputs: ValuesInputs) async throws -> ValuesPurpose {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildPurposePrompt(inputs: inputs),
                                           generating: ValuesPurpose.self)
    return result.content
  }

  func generateCommitments(values: [String], purpose: String) async throws -> [ValuesGeneratedCommitment] {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildCommitmentPrompt(values: values, purpose: purpose),
                                           generating: ValuesCommitmentsResponse.self)
    return result.content.commitments
  }

  private func buildPurposePrompt(inputs: ValuesInputs) -> String {
    let notes = inputs.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    I am exploring my values. Given these selected values, create a practical north-star goal I can save into a goals app.

    Selected values: \(inputs.values.joined(separator: ", "))
    \(notes.map { "Personal note: \($0)" } ?? "")

    Respond ONLY with:
    - title: A short, memorable title. Do not use the word Values.
    - content: One concrete paragraph, max 80 words, describing how to live these values in daily life.

    Guidelines:
    - Be direct and grounded.
    - Make the output actionable, not inspirational fluff.
    - Do not list the values back mechanically.
    - Avoid these words: Nuanced, Multifaceted, Robust, Paradigm, Ecosystem, Tapestry, Holistic, Synergy, Nexus.
    """
  }

  private func buildCommitmentPrompt(values: [String], purpose: String) -> String {
    """
    Turn this values-based north-star goal into practical commitments.

    Selected values: \(values.joined(separator: ", "))
    North-star goal: \(purpose)

    Respond with three commitments:
    - title: Short actionable title.
    - description: One sentence describing the behavior.
    - frequency: daily|weekly|monthly|quarterly

    Guidelines:
    - Make each commitment observable in real life.
    - Include at least one daily or weekly commitment.
    - Avoid vague self-improvement language.
    """
  }
}
