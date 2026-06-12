import Foundation

// Pure, Foundation-only model core for the `intake` section. Kept
// dependency-free (no SwiftData / CloudKit) so the deterministic-id and
// field-map logic is unit-testable in the hermetic SeptenaCoreTests bundle.
// The SwiftData entities (Persistence.swift) consume these.
// See docs/CONSUMABLES_PLAN.md.

/// One method row on a kind (a coffee brew method, a vape/edible). Stored as a
/// JSON column on `IntakeKindEntity` (`methodsJSON`) rather than a 4th record
/// type — vocabularies are tiny and JSON is CloudKit-additive-friendly.
public struct IntakeMethodRow: Codable, Sendable, Hashable {
  public var token: String           // stable lowercase value stored on events
  public var label: String           // display
  public var symbol: String?         // SF Symbol
  public var defaultAmount: Double?   // prefilled dose, if any
  public var usesContainer: Bool      // routes through the container quick-add
  public init(token: String, label: String, symbol: String? = nil,
              defaultAmount: Double? = nil, usesContainer: Bool = false) {
    self.token = token; self.label = label; self.symbol = symbol
    self.defaultAmount = defaultAmount; self.usesContainer = usesContainer
  }
}

/// The per-kind objective — what the user is trying to do with this tracker.
/// Drives goal defaults and which streak/stat gets emphasized.
public enum IntakeObjective {
  public static let all: [(token: String, label: String)] = [
    ("log",    "Just log it"),
    ("limit",  "Stay under a daily limit"),
    ("reduce", "Cut back over time"),
    ("quit",   "Quit / stay clean"),
  ]
  public static func label(_ token: String) -> String {
    all.first { $0.token == token }?.label ?? "Just log it"
  }
  /// Objectives that emphasize a days-since-last streak.
  public static func emphasizesStreak(_ token: String) -> Bool {
    token == "reduce" || token == "quit"
  }
  /// The streak label for a tracker — a dry-streak reads "clean" for quit.
  public static func streakLabel(_ token: String) -> String {
    token == "quit" ? "clean" : "since last"
  }

  /// How an objective maps onto a Goal (the unify: the objective IS a goal on
  /// one of the kind's metrics — limit's cap is the goal target, not a separate
  /// field). `log` has no spec (no goal). `metricSuffix` matches the per-kind
  /// keys IntakePlugin emits (`intake.<id>.<suffix>`).
  public struct GoalSpec: Sendable, Hashable {
    public let metricSuffix: String   // "count" | "count_week" | "days_since_last"
    public let window: String
    public let comparator: String     // "lte" | "gte"
    public let defaultTarget: Double
  }

  /// `weekly` picks the goal's window for limit/reduce (count vs count_week —
  /// both per-kind metrics exist); nil = the objective's natural default.
  /// quit ignores it (a streak has no window).
  public static func goalSpec(_ token: String, weekly: Bool? = nil) -> GoalSpec? {
    switch token {
    case "limit", "reduce":
      let w = weekly ?? defaultWeekly(token)
      return GoalSpec(metricSuffix: w ? "count_week" : "count",
                      window: w ? "calendarWeek" : "today",
                      comparator: "lte",
                      defaultTarget: w ? 7 : 3)
    case "quit":
      return GoalSpec(metricSuffix: "days_since_last", window: "today",
                      comparator: "gte", defaultTarget: 30)
    default:
      return nil  // log → no goal
    }
  }

  /// Whether the objective's goal offers the daily/weekly window toggle.
  public static func supportsWindowToggle(_ token: String) -> Bool {
    token == "limit" || token == "reduce"
  }

  /// The natural window per objective: a limit is a daily cap, reduction is
  /// judged by the week.
  public static func defaultWeekly(_ token: String) -> Bool { token == "reduce" }

  /// Label for the goal's target number, by objective + window.
  public static func targetLabel(_ token: String, weekly: Bool = false) -> String {
    switch token {
    case "limit":  return weekly ? "Weekly limit" : "Daily limit"
    case "reduce": return weekly ? "Weekly target" : "Daily target"
    case "quit":   return "Days-clean goal"
    default:       return "Target"
    }
  }

  /// Goal title text seeded for the kind.
  public static func goalText(_ token: String, kindName: String) -> String {
    switch token {
    case "limit":  return "Keep \(kindName) under the daily limit"
    case "reduce": return "Cut back on \(kindName)"
    case "quit":   return "Stay off \(kindName)"
    default:       return kindName
    }
  }
}

/// A full kind configuration as plain data — what a template or the migrator
/// hands to `IntakeMutator.upsertKind`. The pure mirror of `IntakeKindEntity`'s
/// configurable fields (no id-generation, no persistence).
public struct IntakeKindSeed: Sendable, Hashable {
  public var id: String
  public var name: String
  public var symbol: String
  public var color: String
  public var unit: String?
  public var doseStyle: String
  public var countNoun: String?
  public var containerNoun: String?
  public var containerCap: Int?
  public var catalogNoun: String?
  public var flourish: String
  public var metricMode: String
  /// "log" | "limit" | "reduce" | "quit" — what the user is trying to do with
  /// this kind. Drives goal defaults + which streak/stat gets emphasized.
  public var objective: String
  public var methods: [IntakeMethodRow]
  public var templateID: String?
  public init(id: String, name: String, symbol: String, color: String,
              unit: String?, doseStyle: String, countNoun: String?,
              containerNoun: String?, containerCap: Int?, catalogNoun: String?,
              flourish: String, metricMode: String, objective: String = "log",
              methods: [IntakeMethodRow], templateID: String?) {
    self.id = id; self.name = name; self.symbol = symbol; self.color = color
    self.unit = unit; self.doseStyle = doseStyle; self.countNoun = countNoun
    self.containerNoun = containerNoun; self.containerCap = containerCap
    self.catalogNoun = catalogNoun; self.flourish = flourish
    self.metricMode = metricMode; self.objective = objective
    self.methods = methods; self.templateID = templateID
  }
}

/// The innocuous built-in templates shipped for first-enable (study §4): the
/// full caffeine config, tea, and a blank Custom. Deliberately no
/// review-sensitive templates — the binary ships no such noun; those are
/// reconstructed by the user (or were migrated from their own data).
public enum IntakeTemplates {
  public struct Choice: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let seed: IntakeKindSeed?   // nil = blank Custom (opens the wizard)
  }

  public static func tea() -> IntakeKindSeed {
    IntakeKindSeed(
      id: "ik-tea", name: "Tea", symbol: "cup.and.saucer", color: "#0d9488",
      unit: "g", doseStyle: "amount", countNoun: nil, containerNoun: nil,
      containerCap: nil, catalogNoun: "Teas", flourish: "bloom",
      metricMode: "countEvents",
      methods: [
        .init(token: "green",  label: "Green"),
        .init(token: "black",  label: "Black"),
        .init(token: "oolong", label: "Oolong"),
        .init(token: "herbal", label: "Herbal"),
      ],
      templateID: "tea")
  }

  /// Alcohol — a reduction-first tracker. Counts standard drinks (the unit that
  /// matters for cutting back), and `days_since_last` gives the dry-streak shape
  /// every kind gets for free. An allowed App Store category; not a 1.4.3 noun.
  public static func alcohol() -> IntakeKindSeed {
    IntakeKindSeed(
      id: "ik-alcohol", name: "Alcohol", symbol: "wineglass", color: "#be123c",
      unit: nil, doseStyle: "count", countNoun: "drink", containerNoun: nil,
      containerCap: nil, catalogNoun: nil, flourish: "ripple",
      metricMode: "countEvents", objective: "reduce",
      methods: [
        .init(token: "beer",     label: "Beer"),
        .init(token: "wine",     label: "Wine"),
        .init(token: "spirits",  label: "Spirits"),
        .init(token: "cocktail", label: "Cocktail"),
      ],
      templateID: "alcohol")
  }

  /// Nicotine — a reduction tracker that also teaches the container shape: a
  /// pack holds 20, so quick-add offers "New pack / Continue (cig N)" the way
  /// the container model does. Cigarettes use the container; vape/pouch don't.
  /// Allowed App Store category (quit-smoking); not a 1.4.3 noun.
  public static func nicotine() -> IntakeKindSeed {
    IntakeKindSeed(
      id: "ik-nicotine", name: "Nicotine", symbol: "lungs", color: "#475569",
      unit: nil, doseStyle: "count", countNoun: "cig", containerNoun: "pack",
      containerCap: 20, catalogNoun: nil, flourish: "ripple",
      metricMode: "countEvents", objective: "quit",
      methods: [
        .init(token: "cigarette", label: "Cigarette", usesContainer: true),
        .init(token: "vape",      label: "Vape"),
        .init(token: "pouch",     label: "Pouch"),
      ],
      templateID: "nicotine")
  }

  /// Caffeine — coffee/matcha with a bean catalog. The original consumable
  /// template; defaults to a `limit` objective.
  public static func caffeine() -> IntakeKindSeed {
    IntakeKindSeed(
      id: "ik-caffeine", name: "Caffeine", symbol: "cup.and.saucer", color: "#92400e",
      unit: "g", doseStyle: "amount", countNoun: nil, containerNoun: nil,
      containerCap: nil, catalogNoun: "Beans", flourish: "bloom",
      metricMode: "countEvents", objective: "limit",
      methods: [
        .init(token: "v60",    label: "V60",    symbol: "cup.and.saucer"),
        .init(token: "matcha", label: "Matcha", symbol: "leaf"),
        .init(token: "other",  label: "Other",  symbol: "mug"),
      ],
      templateID: "caffeine")
  }

  /// Slugify a free-text label into a stable token (lowercase; non-alphanumerics
  /// collapse to single hyphens). Derives method tokens from labels in the
  /// wizard / Manage / MCP.
  public static func slug(_ s: String) -> String {
    var out = ""
    var lastDash = false
    for ch in s.lowercased() {
      // ASCII-only: non-ascii letters become dashes so the token is a safe
      // CloudKit recordName component.
      if ch.isASCII, ch.isLetter || ch.isNumber {
        out.append(ch); lastDash = false
      } else if !lastDash {
        out.append("-"); lastDash = true
      }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  public static let all: [Choice] = [
    .init(id: "caffeine", title: "Caffeine",
          subtitle: "Coffee, matcha — methods and a bean catalog",
          symbol: "cup.and.saucer", seed: caffeine()),
    .init(id: "tea", title: "Tea",
          subtitle: "Green, black, oolong, herbal",
          symbol: "leaf", seed: tea()),
    .init(id: "alcohol", title: "Alcohol",
          subtitle: "Standard drinks — track to cut back",
          symbol: "wineglass", seed: alcohol()),
    .init(id: "nicotine", title: "Nicotine",
          subtitle: "Cigarettes, vape, pouches — track to quit",
          symbol: "lungs", seed: nicotine()),
    .init(id: "custom", title: "Custom",
          subtitle: "Start from scratch",
          symbol: "plus", seed: nil),
  ]
}
