import SwiftUI
import SwiftData

/// One row in the global Add Info palette — mirrors a homepage tile (or one
/// intake tracker) in the user's section order with the section's SF Symbol.
struct AddInfoPaletteEntry: Identifiable, Hashable {
  enum Destination: Hashable {
    case addInfoPage(AddInfoSection)
    case moodCheckin
    case presentSection(String)
    case intakeKind(String)
  }

  let id: String
  let title: String
  let iconSymbol: String
  /// Section key for accent lookup (`theme.color(for:)`). Intake kinds use
  /// `"intake"` unless `accentHex` overrides with the kind's own color.
  let sectionKey: String
  var accentHex: String? = nil
  let destination: Destination
}

@MainActor
enum AddInfoPalette {
  /// Enabled dashboard domains in the user's section order — shared by the
  /// Week dashboard and the global Add Info palette so the two surfaces
  /// never list different things or in a different order.
  static func visibleDashboardDomains(
    sections: [SectionConfig],
    mirroredFallback: [SectionConfig]
  ) -> [HomepageDomain] {
    let enabledKeys = sections.filter(\.isEnabled).map(\.key)
    if !enabledKeys.isEmpty {
      var seen = Set<HomepageDomain>()
      return enabledKeys.compactMap { HomepageDomain(rawValue: $0) }
        .filter { seen.insert($0).inserted }
    }
    if mirroredFallback.isEmpty {
      return SectionManifest.all
        .filter(\.supportsDashboard)
        .compactMap { HomepageDomain(rawValue: $0.key) }
    }
    var seen = Set<HomepageDomain>()
    return mirroredFallback.filter(\.isEnabled)
      .compactMap { HomepageDomain(rawValue: $0.key) }
      .filter { seen.insert($0).inserted }
  }

  static func entries(
    sections: [SectionConfig],
    intakeTiles: [IntakeTileDTO],
    mirroredFallback: [SectionConfig]
  ) -> [AddInfoPaletteEntry] {
    let labelByKey = Dictionary(uniqueKeysWithValues: sections.map { ($0.key, $0.label) })
    let domains = visibleDashboardDomains(
      sections: sections,
      mirroredFallback: mirroredFallback
    )

    return domains.flatMap { domain in
      entry(for: domain,
            labelByKey: labelByKey,
            intakeTiles: intakeTiles)
    }
  }

  private static func entry(
    for domain: HomepageDomain,
    labelByKey: [String: String],
    intakeTiles: [IntakeTileDTO]
  ) -> [AddInfoPaletteEntry] {
    if domain == .intake {
      if intakeTiles.isEmpty {
        return [sectionEntry(key: domain.rawValue, labelByKey: labelByKey)]
      }
      return intakeTiles.map { tile in
        AddInfoPaletteEntry(
          id: "intake:\(tile.id)",
          title: tile.name,
          iconSymbol: tile.symbol,
          sectionKey: "intake",
          accentHex: tile.color,
          destination: .intakeKind(tile.id)
        )
      }
    }
    return [sectionEntry(key: domain.rawValue, labelByKey: labelByKey)]
  }

  private static func sectionEntry(
    key: String,
    labelByKey: [String: String]
  ) -> AddInfoPaletteEntry {
    let title = SectionManifest.displayLabel(key: key, stored: labelByKey[key] ?? "")
    let icon = SectionManifest.byKey[key]?.iconSymbol ?? "circle.fill"
    let destination: AddInfoPaletteEntry.Destination = {
      if let section = AddInfoSection(rawValue: key) { return .addInfoPage(section) }
      if key == HomepageDomain.mood.rawValue { return .moodCheckin }
      return .presentSection(key)
    }()
    return AddInfoPaletteEntry(
      id: key,
      title: title,
      iconSymbol: icon,
      sectionKey: key,
      destination: destination
    )
  }

  @MainActor
  static func accent(for entry: AddInfoPaletteEntry, theme: SectionTheme) -> Color {
    if let hex = entry.accentHex, let color = AdaptiveColor.adaptive(hex) {
      return color
    }
    return theme.color(for: entry.sectionKey)
  }
}
