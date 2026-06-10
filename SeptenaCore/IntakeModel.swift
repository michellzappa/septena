import Foundation

// Pure, Foundation-only model + migration logic for the `intake` section. Kept
// dependency-free (no SwiftData / CloudKit) so the deterministic-id and
// field-map core — the load-bearing part of the caffeine/cannabis migration
// (study §7.1) — is unit-testable in the hermetic SeptenaCoreTests bundle.
// The SwiftData entities (Persistence.swift) and the CKRecord-bound migrator
// (Migration.swift) consume these. See docs/CONSUMABLES_PLAN.md.

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
  public var methods: [IntakeMethodRow]
  public var templateID: String?
  public init(id: String, name: String, symbol: String, color: String,
              unit: String?, doseStyle: String, countNoun: String?,
              containerNoun: String?, containerCap: Int?, catalogNoun: String?,
              flourish: String, metricMode: String, methods: [IntakeMethodRow],
              templateID: String?) {
    self.id = id; self.name = name; self.symbol = symbol; self.color = color
    self.unit = unit; self.doseStyle = doseStyle; self.countNoun = countNoun
    self.containerNoun = containerNoun; self.containerCap = containerCap
    self.catalogNoun = catalogNoun; self.flourish = flourish
    self.metricMode = metricMode; self.methods = methods; self.templateID = templateID
  }
}

/// A legacy caffeine/cannabis event in neutral form — fed to the migration map
/// from EITHER a raw `CKRecord` (record-level path, survives @Model deletion)
/// or a live legacy entity (local full-scan path). Keeps the field-map pure.
public struct LegacyIntakeEvent: Sendable, Hashable {
  public var section: String        // "caffeine" | "cannabis"
  public var legacyID: String
  public var date: String
  public var method: String
  public var note: String?
  public var grams: Double?
  public var beanOrStrain: String?  // caffeine: bean id · cannabis: strain text
  public var hit: Int?
  public var occurredAt: Date?
  public var updatedAt: Date?
  public init(section: String, legacyID: String, date: String, method: String,
              note: String? = nil, grams: Double? = nil, beanOrStrain: String? = nil,
              hit: Int? = nil, occurredAt: Date? = nil, updatedAt: Date? = nil) {
    self.section = section; self.legacyID = legacyID; self.date = date
    self.method = method; self.note = note; self.grams = grams
    self.beanOrStrain = beanOrStrain; self.hit = hit
    self.occurredAt = occurredAt; self.updatedAt = updatedAt
  }
}

/// The generic event the migration map produces — id is deterministic, so
/// re-running is an upsert and two devices converge byte-identically (§7.1).
public struct MigratedIntakeEvent: Sendable, Hashable {
  public var id: String
  public var kindID: String
  public var date: String
  public var method: String
  public var itemID: String?
  public var amount: Double?
  public var count: Int?
  public var note: String?
  public var occurredAt: Date?
  public var updatedAt: Date?
}

/// The innocuous built-in templates shipped for first-enable (study §4): the
/// full caffeine config, tea, and a blank Custom. Deliberately NO cannabis /
/// alcohol / nicotine templates — the binary ships no review-sensitive noun;
/// those are reconstructed by the user (or migrated from their own data).
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

  public static let all: [Choice] = [
    .init(id: "caffeine", title: "Caffeine",
          subtitle: "Coffee, matcha — methods and a bean catalog",
          symbol: "cup.and.saucer", seed: IntakeMigrationMap.caffeineSeed()),
    .init(id: "tea", title: "Tea",
          subtitle: "Green, black, oolong, herbal",
          symbol: "leaf", seed: tea()),
    .init(id: "custom", title: "Custom",
          subtitle: "Start from scratch",
          symbol: "plus", seed: nil),
  ]
}

/// The deterministic-id + field-map core. Every migrated record's id is a pure
/// function of its source, which buys idempotence, multi-device convergence,
/// and late-arrival safety (study §7.1). All Foundation, all testable.
public enum IntakeMigrationMap {
  public static let caffeineSection = "caffeine"
  public static let cannabisSection = "cannabis"
  public static let caffeineKindID = "ik-caffeine"
  public static let cannabisKindID = "ik-cannabis"

  /// Generic event id from a legacy one — e.g. ("caffeine", "ab12cd34") →
  /// "caffeine:ab12cd34". The full recordName becomes "intake-event:caffeine:ab12cd34".
  public static func eventID(section: String, legacyID: String) -> String {
    "\(section):\(legacyID)"
  }

  /// Generic item id from a legacy catalog key (a bean id, or a strain slug).
  public static func itemID(section: String, key: String) -> String {
    "\(section):\(key)"
  }

  /// Deterministic, name-independent slug for cannabis strains (which are free
  /// text, not ids). Collapses non-alphanumerics to single hyphens.
  public static func slug(_ s: String) -> String {
    var out = ""
    var lastDash = false
    for ch in s.lowercased() {
      // ASCII-only: non-ascii letters become dashes so the derived id is a safe
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

  /// The field map — the dumb copy plus three renames (§7.1). Lossless by
  /// construction (the study showed the inverse direction).
  public static func map(_ e: LegacyIntakeEvent) -> MigratedIntakeEvent {
    let kindID = (e.section == cannabisSection) ? cannabisKindID : caffeineKindID
    var itemRef: String?
    if let raw = e.beanOrStrain, !raw.isEmpty {
      // caffeine `beans` is already an id; cannabis `strain` is free text → slug.
      let key = (e.section == cannabisSection) ? slug(raw) : raw
      itemRef = itemID(section: e.section, key: key)
    }
    return MigratedIntakeEvent(
      id: eventID(section: e.section, legacyID: e.legacyID),
      kindID: kindID,
      date: e.date,
      method: e.method,
      itemID: itemRef,
      amount: e.grams,   // `.grams` → `.amount` (kind unit "g")
      count: e.hit,      // `.hit`   → `.count`
      note: e.note,
      occurredAt: e.occurredAt,
      updatedAt: e.updatedAt)
  }

  /// The caffeine kind, seeded from the Caffeine template (study §7.1). Methods
  /// default to today's static set; the migrator overrides with the user's
  /// `CaffeineConfig.methods` when present.
  public static func caffeineSeed(methods: [IntakeMethodRow]? = nil) -> IntakeKindSeed {
    IntakeKindSeed(
      id: caffeineKindID, name: "Caffeine", symbol: "cup.and.saucer", color: "#92400e",
      unit: "g", doseStyle: "amount", countNoun: nil, containerNoun: nil,
      containerCap: nil, catalogNoun: "Beans", flourish: "bloom",
      metricMode: "countEvents",
      methods: methods ?? [
        .init(token: "v60",    label: "V60",    symbol: "cup.and.saucer"),
        .init(token: "matcha", label: "Matcha", symbol: "leaf"),
        .init(token: "other",  label: "Other",  symbol: "mug"),
      ],
      templateID: "caffeine")
  }

  /// The cannabis kind, synthesized from the user's own data — no cannabis
  /// template ships (study §7.1). Name carries over from the old section label;
  /// methods come from observed `method` values; cap from `usesPerCapsule`.
  public static func cannabisSeed(name: String = "Cannabis",
                                  usesPerCapsule: Int,
                                  observedMethods: [String]) -> IntakeKindSeed {
    let known: [String: IntakeMethodRow] = [
      "vape":   .init(token: "vape",   label: "Vape",   symbol: "wind",        usesContainer: true),
      "edible": .init(token: "edible", label: "Edible", symbol: "circle.fill", usesContainer: false),
    ]
    let ordered = ["vape", "edible"]
    let observed = observedMethods.isEmpty ? Set(ordered) : Set(observedMethods)
    var methods: [IntakeMethodRow] = ordered.filter { observed.contains($0) }.map { known[$0]! }
    // Any unexpected legacy method token survives as a plain (non-container) row.
    for token in observed.subtracting(Set(ordered)).sorted() {
      methods.append(.init(token: token, label: token.capitalized, usesContainer: false))
    }
    return IntakeKindSeed(
      id: cannabisKindID, name: name, symbol: "leaf", color: "#65a30d",
      unit: "g", doseStyle: "both", countNoun: "Hit", containerNoun: "capsule",
      containerCap: usesPerCapsule, catalogNoun: "Strains", flourish: "ripple",
      metricMode: "countEvents", methods: methods, templateID: nil)
  }
}
