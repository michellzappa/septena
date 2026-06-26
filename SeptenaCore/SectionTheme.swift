import SwiftUI

// MARK: - SectionConfig (value type for palette plumbing)

/// In-memory shape for a single section's accent. Lives here (not in
/// SeptenaClient) because it has no FastAPI dependency anymore — the
/// SectionTheme palette and CloudKit SectionEntity mirror both produce
/// and consume values of this type.
public struct SectionConfig: Codable, Hashable {
  public let key: String
  public let label: String
  public let color: String          // hex (e.g. "#ef4444") or "hsl(...)"
  /// Whether the section is visible in the dashboard / sidebar. Disabled
  /// rows still exist in the central store so their color / label
  /// customizations survive a toggle.
  public let isEnabled: Bool
  /// Whether this section contributes to the Today log. Only meaningful
  /// for sections the manifest flags as `appearsInToday`.
  public let showInToday: Bool
  /// Whether this section's entries are exposed to Spotlight / Siri / Apple
  /// Intelligence. Default true; the user opts a section out in Settings.
  public let showInSpotlight: Bool
  /// True once the section's first-time onboarding has completed (or
  /// been skipped). Distinguishes "first ever enable" from a later
  /// toggle off → on. Stays true forever once set.
  public let hasOnboarded: Bool

  public init(key: String,
              label: String,
              color: String,
              isEnabled: Bool = true,
              showInToday: Bool = true,
              showInSpotlight: Bool = true,
              hasOnboarded: Bool = false) {
    self.key = key
    self.label = label
    self.color = color
    self.isEnabled = isEnabled
    self.showInToday = showInToday
    self.showInSpotlight = showInSpotlight
    self.hasOnboarded = hasOnboarded
  }

  // Custom decode so older ResponseCache blobs (pre-isEnabled /
  // pre-showInToday / pre-showInSpotlight / pre-hasOnboarded) decode cleanly
  // with sensible defaults.
  private enum CodingKeys: String, CodingKey {
    case key, label, color, isEnabled, showInToday, showInSpotlight, hasOnboarded
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    self.label = try c.decode(String.self, forKey: .label)
    self.color = try c.decode(String.self, forKey: .color)
    self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
    self.showInToday = (try? c.decode(Bool.self, forKey: .showInToday)) ?? true
    self.showInSpotlight = (try? c.decode(Bool.self, forKey: .showInSpotlight)) ?? true
    self.hasOnboarded = (try? c.decode(Bool.self, forKey: .hasOnboarded)) ?? false
  }
}

// Live mirror of Septena's section accents. Sources, in order of preference:
//   1. CloudKit-backed `SectionEntity` (user-customized colors).
//   2. ResponseCache disk blob (last-known state, primes cold launch).
//   3. Hardcoded `defaultPalette` below (fresh install with no CK records).
// No FastAPI involvement.

@MainActor
@Observable
final class SectionTheme {
  /// Baseline palette used when neither the CloudKit mirror nor the on-
  /// disk cache has anything to offer (first-launch state). Keys match
  /// `HomepageDomain.rawValue` so every tile renders with a sensible color
  /// before the user touches Settings. Edits in Settings overwrite the
  /// SectionEntity records and CK syncs the change to other devices.
  static let defaultPalette: [SectionConfig] = [
    .init(key: "tasks",       label: "Tasks",       color: "#ef4444"),
    .init(key: "habits",      label: "Habits",      color: "#22c55e"),
    .init(key: "training",    label: "Training",    color: "#f97316"),
    .init(key: "chores",      label: "Chores",      color: "#a855f7"),
    .init(key: "supplements", label: "Supplements", color: "#3b82f6"),
    .init(key: "sleep",       label: "Sleep",       color: "#6366f1"),
    .init(key: "nutrition",   label: "Nutrition",   color: "#f59e0b"),
    .init(key: "groceries",   label: "Groceries",   color: "#84cc16"),
    .init(key: "body",        label: "Body",        color: "#ec4899"),
    .init(key: "gut",         label: "Gut",         color: "#b45309"),
    .init(key: "activity",    label: "Activity",    color: "#06b6d4"),
    .init(key: "goals",       label: "Coach",       color: "#8b5cf6"),
  ]

  /// Neutral fallback — inherits from the asset catalog's AccentColor.
  static let fallback = Color.accentColor

  /// The app's primary accent — the asset-catalog `AccentColor`, a standalone
  /// brand tint intentionally independent of any section color. Applied at the
  /// app root via `.tint(theme.accent)`, so `Color.accentColor` inherits it
  /// app-wide. Per-section colors come from `color(for:)`, never this.
  let accent: Color = SectionTheme.fallback
  /// All section accents keyed by Septena section id (`tasks`, `habits`,
  /// `chores`, `supplements`, ...). Populated by `refresh()`.
  private(set) var accentByKey: [String: Color] = [:]
  /// Authored color tokens (`#rrggbb`, `hsl(...)`, …) keyed by section id.
  /// Used when publishing widget snapshots so the extension needn't run
  /// `SectionTheme`.
  private(set) var tokenByKey: [String: String] = [:]

  /// Hydrate from the local mirror / disk cache during construction so the
  /// very first frame the dashboard renders already has the user's accent
  /// colors. Doing this in `.task` instead leaves a half-second flash of
  /// gray placeholders while SwiftUI waits for the task closure to fire.
  init() {
    paintFromCache()
  }

  /// Resolve any section's accent — falls back to `inkSecondary` for
  /// sections we don't know about (or before the first refresh completes).
  func color(for sectionKey: String) -> Color {
    accentByKey[sectionKey] ?? Color(red: 0.541, green: 0.514, blue: 0.471)
  }

  /// Resolve the authored accent token for a section — for wire payloads.
  func token(for sectionKey: String) -> String {
    tokenByKey[sectionKey]
      ?? Self.defaultPalette.first { $0.key == sectionKey }?.color
      ?? "#8b8680"
  }

  /// Glyph for "this is the X section" chrome (e.g. SwiftUI's
  /// `ContentUnavailableView` empty states). Delegates to the manifest so
  /// there is a single source of truth for section iconography — the same
  /// per-section SF Symbol shown on tiles and in the sidebar. Falls back to
  /// a neutral dot for unknown keys.
  func icon(for sectionKey: String) -> String {
    SectionManifest.byKey[sectionKey]?.iconSymbol ?? "circle.fill"
  }

  /// Synchronous cache prime — reads the last-known `/api/sections`
  /// response out of disk and populates `accentByKey`. Called before
  /// `refresh()` on app launch so tiles render with the right color on
  /// cold launch instead of the fallback gray.
  func paintFromCache() {
    if let sections = loadSectionsForPaint() {
      applySections(sections)
    }
  }

  static let cacheKey = "theme.sections"

  func refresh() async {
    if let sections = loadSectionsForPaint(), !sections.isEmpty {
      applySections(sections)
      ResponseCache.save(sections, forKey: Self.cacheKey)
      return
    }

    // Fresh install with no CK records yet — paint with the hardcoded
    // baseline palette and seed CloudKit so other devices inherit the
    // same starting point. Users can recolor in Settings; that overwrite
    // syncs through SettingsMirror.replaceSections.
    let sections = Self.defaultPalette
    applySections(sections)
    ResponseCache.save(sections, forKey: Self.cacheKey)
    SettingsMirror.replaceSections(sections,
                                   context: LocalStore.shared.container.mainContext,
                                   engine: SeptenaServices.shared.ckEngine)
  }

  private func loadSectionsForPaint() -> [SectionConfig]? {
    let context = LocalStore.shared.container.mainContext
    let mirrored = SettingsMirror.loadSections(context: context)
    if !mirrored.isEmpty { return mirrored }
    return ResponseCache.load([SectionConfig].self,
                              forKey: Self.cacheKey)
  }

  /// Repaint a single section's accent in place. Called from the Settings
  /// color picker so the dashboard and section views recolor immediately —
  /// the SwiftData/CloudKit write is already done by the caller; this just
  /// keeps the in-memory accent cache in sync without a full `refresh()`.
  func setColor(_ raw: String, for sectionKey: String) {
    if let c = parseColor(raw) { accentByKey[sectionKey] = c }
  }

  private func applySections(_ sections: [SectionConfig]) {
    var byKey: [String: Color] = [:]
    var tokens: [String: String] = [:]
    for s in sections {
      tokens[s.key] = s.color
      if let c = parseColor(s.color) { byKey[s.key] = c }
    }
    accentByKey = byKey
    tokenByKey = tokens
  }

  // MARK: - Color string parsing

  /// Resolve an authored color token ("#rrggbb", "rgb(...)", or "hsl(...)")
  /// to an appearance-adaptive accent. The dark-mode lift that keeps low-
  /// lightness swatches legible lives in `AdaptiveColor` — the single
  /// resolver every color token in the app flows through (section accents,
  /// macro tiles, the fasting band, and Settings swatches all share it).
  private func parseColor(_ raw: String) -> Color? {
    AdaptiveColor.adaptive(raw)
  }
}

// `AdaptiveColor` (the global color-token resolver) lives in its own file —
// `SeptenaCore/AdaptiveColor.swift` — so the leaner targets (the widget
// extension) can compile just the resolver without the SectionTheme runtime.
