import Foundation

// MARK: - Practitioner Reports — models
//
// A "report" is a saved, reusable bundle: a set of section keys + a date
// window + an audience title, rendered to an aggregates-only, read-only view a
// practitioner (doctor / therapist / PT / coach) can read without the app.
// See docs/PRACTITIONER_REPORTS_SPEC.md.
//
// This file holds the value types only. `ReportPayloadBuilder` computes the
// payload from the local SwiftData mirror; `ReportHTMLRenderer` renders it.
// Everything here is `Sendable` so the payload can be computed off-main on the
// `MirrorReader` actor and handed back to the UI.

// MARK: - Saved config

/// A user-saved report definition. Persisted locally (no CloudKit in the
/// prototype) via `ReportStore`. The payload is always recomputed fresh from
/// live data when viewed/exported — the bundle stores only the recipe.
public struct ReportBundle: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  /// Audience-facing title shown on the report header, e.g.
  /// "Dr. Lindqvist — Endocrinology" or "Anna (PT)".
  public var title: String
  /// Optional short note to the practitioner ("Knee rehab — weeks 4–8").
  public var note: String
  /// Section keys included, in display order.
  public var sectionKeys: [String]
  /// Trailing window in days (30 / 60 / 90 / 365).
  public var windowDays: Int
  /// yyyy-MM-dd the bundle was created.
  public var createdAt: String
  /// Whether this report would also expose a scoped read-only MCP endpoint
  /// (design flag only in the prototype — surfaced in the UI, not yet wired).
  public var mcpEnabled: Bool
  /// Unguessable token for the shareable link, minted on first "Create link".
  /// Stays stable so re-pushing refreshes the same URL. nil until shared.
  public var token: String?
  /// The public /r/<token> URL, cached for display once created.
  public var linkURL: String?
  /// How many days the shared link stays live, from each push. nil = never
  /// expires. Default 90.
  public var linkExpiryDays: Int?

  public init(id: String,
              title: String,
              note: String = "",
              sectionKeys: [String],
              windowDays: Int = 90,
              createdAt: String,
              mcpEnabled: Bool = false,
              token: String? = nil,
              linkURL: String? = nil,
              linkExpiryDays: Int? = 90) {
    self.id = id
    self.title = title
    self.note = note
    self.sectionKeys = sectionKeys
    self.windowDays = windowDays
    self.createdAt = createdAt
    self.mcpEnabled = mcpEnabled
    self.token = token
    self.linkURL = linkURL
    self.linkExpiryDays = linkExpiryDays
  }
}

// MARK: - Worker endpoint

/// Where report payloads are pushed / served from. Defaults to the deployed
/// prototype Worker; overridable via UserDefaults for testing.
public enum ReportEndpoint {
  public static let defaultBaseURL = URL(string: "https://septena-reports.mz-508.workers.dev")!

  public static var baseURL: URL {
    if let s = UserDefaults.standard.string(forKey: "septena.reports.baseURL"),
       let u = URL(string: s) { return u }
    return defaultBaseURL
  }

  /// 128-bit unguessable token (32 hex chars) for a new shareable link.
  public static func newToken() -> String {
    (UUID().uuidString + UUID().uuidString)
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
      .prefix(40).description
  }
}

// MARK: - Audience presets

/// A starting bundle the user edits once. `defaultSections` pre-checks the
/// section list in the builder; the user adds/removes freely.
public struct ReportPreset: Identifiable, Sendable, Hashable {
  public let id: String
  public let title: String
  public let symbol: String
  public let blurb: String
  public let defaultSections: [String]

  public init(id: String, title: String, symbol: String, blurb: String, defaultSections: [String]) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.blurb = blurb
    self.defaultSections = defaultSections
  }

  /// Defaults lean on sections that already produce aggregate trends so a
  /// fresh report is rich out of the box. The user can add any enabled
  /// section; ones without aggregates yet render a "not yet aggregated" note.
  public static let all: [ReportPreset] = [
    .init(id: "doctor", title: "Doctor", symbol: "stethoscope",
          blurb: "Symptoms, intake and digestion trends for a clinic visit.",
          defaultSections: ["nutrition", "gut", "supplements", "activity"]),
    .init(id: "therapist", title: "Therapist", symbol: "brain.head.profile",
          blurb: "Mood rhythm and daily-routine adherence over time.",
          defaultSections: ["mood", "habits", "gut"]),
    .init(id: "pt", title: "Physical therapist", symbol: "figure.run",
          blurb: "Training load, movement and recovery for rehab check-ins.",
          defaultSections: ["training", "activity", "habits"]),
    .init(id: "coach", title: "Coach", symbol: "trophy",
          blurb: "Habits, supplements, training and nutrition consistency.",
          defaultSections: ["habits", "supplements", "training", "nutrition"]),
    .init(id: "custom", title: "Custom", symbol: "slider.horizontal.3",
          blurb: "Start from nothing and pick exactly what to share.",
          defaultSections: []),
  ]

  public static let windowOptions: [Int] = [30, 60, 90, 365]
}

// MARK: - Section display metadata (computed on-main, passed into the builder)

/// Label + accent color for a section key, resolved from the live
/// `SettingsStore` on the main actor and handed to the off-main builder so the
/// builder never needs to touch `@MainActor` stores.
public struct ReportSectionMeta: Sendable, Hashable {
  public let label: String
  public let colorHex: String
  public init(label: String, colorHex: String) {
    self.label = label
    self.colorHex = colorHex
  }
}

// MARK: - Rendered payload (the wire/DTO shape, versioned)

/// The full, deterministic report payload. Aggregates only — never individual
/// timestamped rows (per spec decision). This is exactly what the future
/// Worker would store and serve; the in-app renderer reads the same shape.
public struct ReportPayload: Codable, Sendable {
  public var v: Int
  public var title: String
  public var note: String
  public var owner: String
  public var windowDays: Int
  /// yyyy-MM-dd the data was current as of (the build time).
  public var asOf: String
  public var sections: [ReportSection]

  public init(v: Int = 1,
              title: String,
              note: String,
              owner: String,
              windowDays: Int,
              asOf: String,
              sections: [ReportSection]) {
    self.v = v
    self.title = title
    self.note = note
    self.owner = owner
    self.windowDays = windowDays
    self.asOf = asOf
    self.sections = sections
  }
}

public struct ReportSection: Codable, Sendable, Identifiable {
  public var key: String
  public var label: String
  public var colorHex: String
  /// Headline numbers shown as chips at the top of the section.
  public var stats: [ReportStat]
  /// Trend charts rendered as inline SVG.
  public var charts: [ReportChart]
  /// True when no live aggregates were available for this section in the
  /// prototype (renders a quiet "not yet aggregated" note instead of charts).
  public var unavailable: Bool

  public var id: String { key }

  public init(key: String,
              label: String,
              colorHex: String,
              stats: [ReportStat] = [],
              charts: [ReportChart] = [],
              unavailable: Bool = false) {
    self.key = key
    self.label = label
    self.colorHex = colorHex
    self.stats = stats
    self.charts = charts
    self.unavailable = unavailable
  }
}

public struct ReportStat: Codable, Sendable, Hashable {
  public var label: String
  public var value: String
  public var detail: String?
  public init(label: String, value: String, detail: String? = nil) {
    self.label = label
    self.value = value
    self.detail = detail
  }
}

public struct ReportChart: Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case line, bar, heatmap }
  public var title: String
  public var kind: Kind
  public var unit: String
  public var points: [ReportPoint]
  public init(title: String, kind: Kind, unit: String = "", points: [ReportPoint]) {
    self.title = title
    self.kind = kind
    self.unit = unit
    self.points = points
  }
}

public struct ReportPoint: Codable, Sendable, Hashable {
  /// x-axis label — a yyyy-MM-dd date or a category name.
  public var label: String
  public var value: Double
  public init(label: String, value: Double) {
    self.label = label
    self.value = value
  }
}

// MARK: - Local persistence

/// Local-only store for saved report bundles (UserDefaults + JSON, matching
/// the `ResponseCache` convention). No CloudKit in the prototype.
public enum ReportStore {
  private static let key = "septena.reports.bundles"

  public static func load() -> [ReportBundle] {
    guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([ReportBundle].self, from: data)) ?? []
  }

  public static func save(_ bundles: [ReportBundle]) {
    guard let data = try? JSONEncoder().encode(bundles) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }

  /// Insert-or-update by id, then persist.
  public static func upsert(_ bundle: ReportBundle) {
    var all = load()
    if let i = all.firstIndex(where: { $0.id == bundle.id }) { all[i] = bundle }
    else { all.append(bundle) }
    save(all)
  }

  public static func delete(id: String) {
    save(load().filter { $0.id != id })
  }
}
