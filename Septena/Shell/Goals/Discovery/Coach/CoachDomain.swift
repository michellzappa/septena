import SwiftUI

// A coach "persona" — the one knob that turns a single conversation
// engine into N domain coaches. Identity only: which sections feed its
// context, and the voice it speaks in. The facts themselves are computed
// by `CoachContextBuilder` (Swift does the math; the model only talks).
//
// Adding a coach is one case here — no new tile, no new registry entry.

enum CoachDomain: String, CaseIterable, Identifiable {
  case training
  case food
  case accountability
  case wholeLife
  case custom

  var id: String { rawValue }

  /// Freeform presets start with NOTHING in scope — the user opts sections
  /// in via the pills, rather than muting an opinionated default down.
  var handPicksContext: Bool { self == .custom }

  var title: String {
    switch self {
    case .training:       return "Training Coach"
    case .food:           return "Food Coach"
    case .accountability: return "Accountability Coach"
    case .wholeLife:      return "Whole-Life Coach"
    case .custom:         return "Custom Coach"
    }
  }

  var blurb: String {
    switch self {
    case .training:       return "Talk through your training week."
    case .food:           return "Reflect on what you ate, drank, and how your gut felt."
    case .accountability: return "Where did your tasks, chores, and habits land?"
    case .wholeLife:      return "A view across everything you tracked this week."
    case .custom:         return "Hand-pick exactly what I can see, then talk."
    }
  }

  var systemImage: String {
    switch self {
    case .training:       return "figure.run"
    case .food:           return "fork.knife"
    case .accountability: return "checklist"
    case .wholeLife:      return "sparkles"
    case .custom:         return "slider.horizontal.3"
    }
  }

  var accent: Color {
    switch self {
    case .training:       return .orange
    case .food:           return .green
    case .accountability: return .blue
    case .wholeLife:      return .teal
    case .custom:         return .purple
    }
  }

  /// Which `SectionPlugin` keys feed this coach's context.
  /// `nil` means "every section that contributes facts" — the
  /// whole-life coach sees across domains.
  var sectionKeys: [String]? {
    switch self {
    case .training:       return ["training"]
    case .food:           return ["nutrition", "supplements", "hydration", "gut"]
    case .accountability: return ["tasks", "chores", "habits"]
    case .wholeLife:      return nil
    case .custom:         return nil   // all sections offered; user scopes via pills
    }
  }

  /// The persona prompt. `CoachContextBuilder` appends the computed
  /// facts; together they seed the conversation on its first turn.
  /// Same discipline as the Examined Week mirror: cite the numbers
  /// you're given, never invent data, stay brief.
  var persona: String {
    let shared = """
      You are speaking with the person whose data this is, inside their private \
      life-tracking app. The context has two parts: FACTS are what they actually \
      LOGGED (true, computed — never invent, add, or recompute numbers), and GOALS \
      are targets they SET for themselves (intentions, not events). Reflect facts \
      back with concrete figures; nudge gently toward goals, and never speak of a \
      goal as if it already happened. Ask one good question at a time. Keep replies \
      short (2–4 sentences). No grades, no emoji, no "you should" lectures. Avoid \
      the words: journey, holistic, nuanced, synergy, leverage.
      """
    switch self {
    case .training:
      return "You are a calm, evidence-minded training coach. You care about consistency, recovery, and honest effort.\n\n" + shared
    case .food:
      return "You are a steady, non-judgmental food coach. You care about patterns, not perfection — energy, hydration, and how the gut responds.\n\n" + shared
    case .accountability:
      return "You are a warm but direct accountability coach. You care about follow-through on the things the person said mattered.\n\n" + shared
    case .wholeLife:
      return "You are a thoughtful life coach with a view across all the person's tracked domains. You gently connect patterns between areas.\n\n" + shared
    case .custom:
      return "You are a flexible coach. The person has hand-picked which areas you can see. Talk only about what's in scope; if the FACTS show nothing, invite them to add a section via the pills above.\n\n" + shared
    }
  }

  /// Tappable conversation starters shown before the first message.
  /// Phrased as the user's own questions — tapping sends them as-is.
  var starters: [String] {
    switch self {
    case .training:
      return ["How was my consistency?",
              "Am I training enough?",
              "What should I focus on next?"]
    case .food:
      return ["How did I eat this period?",
              "Is my protein on track?",
              "How's my hydration?"]
    case .accountability:
      return ["How did I follow through?",
              "What did I let slip?",
              "Where am I most consistent?"]
    case .wholeLife:
      return ["What stands out this period?",
              "Where am I doing well?",
              "What needs my attention?"]
    case .custom:
      return ["What stands out?",
              "Any patterns here?",
              "What should I notice?"]
    }
  }

  /// The coach's opening line — deterministic, so the conversation
  /// starts instantly without a model round-trip.
  var opener: String {
    switch self {
    case .training:       return "Let's look at your training week. What's on your mind — consistency, recovery, or something specific?"
    case .food:           return "I've got your last week of food, hydration, and gut logs in view. Where do you want to start?"
    case .accountability: return "I can see how your tasks, chores, and habits landed this week. What's nagging at you?"
    case .wholeLife:      return "I've got the whole week in front of me. What feels worth talking through?"
    case .custom:         return "Tap the sections above to bring them into view, then ask me anything about them."
    }
  }
}
