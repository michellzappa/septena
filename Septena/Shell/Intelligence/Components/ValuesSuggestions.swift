import Foundation

struct ValuesSuggestions {
  static let categories: [(title: String, key: String, values: [String])] = [
    (
      "Personal Growth",
      "personal",
      ["Growth", "Authenticity", "Creativity", "Independence", "Learning", "Wisdom",
       "Balance", "Health", "Adventure"]
    ),
    (
      "Relationships",
      "relational",
      ["Connection", "Empathy", "Trust", "Family", "Friendship", "Love", "Community",
       "Collaboration", "Loyalty"]
    ),
    (
      "Ethics & Principles",
      "ethical",
      ["Integrity", "Honesty", "Justice", "Responsibility", "Compassion", "Equality",
       "Respect", "Service", "Sustainability"]
    ),
    (
      "Professional",
      "professional",
      ["Excellence", "Innovation", "Leadership", "Achievement", "Impact", "Contribution",
       "Competence", "Recognition", "Success"]
    ),
  ]

  static var all: [String] {
    categories.flatMap(\.values)
  }

  static func categoryKey(for value: String) -> String? {
    categories.first { $0.values.contains(value) }?.key
  }
}
